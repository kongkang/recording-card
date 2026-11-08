import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_exception.dart';
import 'oauth_client.dart';
import 'oauth_config.dart';

abstract interface class TokenStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureTokenStorage implements TokenStorage {
  const SecureTokenStorage({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      throw const AuthException('storage_unavailable', '无法读取安全授权存储');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      throw const AuthException('storage_unavailable', '无法保存安全授权存储');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      throw const AuthException('storage_unavailable', '无法清除安全授权存储');
    }
  }
}

/// Adapted minimum of reference OAuthTokenStore. Does not depend on AuthStore,
/// Supabase, legacy migrations or shared_preferences. Never calls deleteAll.
/// All writes/deletes serialize, so an old refresh cannot delete a NEW login.
class OAuthTokenStore {
  OAuthTokenStore({
    required this.client,
    TokenStorage? storage,
    DateTime Function()? clock,
  }) : _storage = storage ?? const SecureTokenStorage(),
       _clock = clock ?? DateTime.now;
  final OAuthClient client;
  final TokenStorage _storage;
  final DateTime Function() _clock;
  _TokenBundle? _bundle;
  Future<void> _storageTail = Future.value();
  Future<String?>? _refreshing;
  int _generation = 0;
  int _identityEpoch = 0;
  void Function()? onSessionInvalidated;

  String get _bundleKey => '${client.config.storageNamespace}.bundle';
  String get _pendingKey => '${client.config.storageNamespace}.pending';
  int get userIdentityEpoch => _identityEpoch;
  String? get accessToken => _bundle?.accessToken;
  String? get refreshToken => _bundle?.refreshToken;
  DateTime? get issuedAt => _bundle?.issuedAt;
  bool get hasUsableSession {
    final b = _bundle;
    return b != null &&
        (b.accessExpiresAt.isAfter(_clock()) ||
            (b.refreshToken != null && b.refreshExpiresAt!.isAfter(_clock())));
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _storageTail.then((_) => operation());
    _storageTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> bootstrap() async {
    client.config.validate();
    final generation = _generation;
    await _serialized(() async {
      final raw = await _storage.read(_bundleKey);
      if (generation != _generation) return;
      _bundle = null;
      _identityEpoch++;
      if (raw != null) {
        try {
          _bundle = _TokenBundle.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        } catch (_) {
          _bundle = null;
          await _storage.delete(_bundleKey);
        }
      }
    });
    await readPendingAuthorization(); // Expired or corrupt pending is cleared.
  }

  Future<void> saveTokens(OAuthTokenResponse response) {
    final generation = ++_generation;
    _identityEpoch++;
    final bundle = _TokenBundle.fromResponse(response, _clock());
    return _serialized(() async {
      if (generation != _generation) throw const AuthRequiredException();
      await _storage.write(_bundleKey, jsonEncode(bundle.toJson()));
      if (generation != _generation) throw const AuthRequiredException();
      _bundle = bundle; // Storage first; a failed write NEVER authenticates.
    });
  }

  Future<String?> getValidAccessToken() async {
    final b = _bundle;
    if (b == null) return null;
    // Small skew prevents sending a token that expires while request is sent.
    if (b.accessExpiresAt.isAfter(_clock().add(const Duration(seconds: 15)))) {
      return b.accessToken;
    }
    return refresh();
  }

  Future<String?> refresh() {
    if (_refreshing != null) return _refreshing!;
    final completer = Completer<String?>();
    _refreshing = completer.future;
    () async {
      try {
        completer.complete(await _performRefresh());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _refreshing = null;
      }
    }();
    return completer.future;
  }

  Future<String?> _performRefresh() async {
    final generation = _generation;
    final previous = _bundle;
    if (previous?.refreshToken == null ||
        !previous!.refreshExpiresAt!.isAfter(_clock())) {
      await _invalidateIfCurrent(generation);
      throw const AuthRequiredException();
    }
    final OAuthTokenResponse response;
    try {
      response = await client.refreshAccessToken(previous.refreshToken!);
    } on AuthException catch (e) {
      if (e is AuthRequiredException ||
          const {
            'invalid_grant',
            'invalid_token',
            'unauthorized_client',
            'invalid_client',
          }.contains(e.code)) {
        await _invalidateIfCurrent(generation);
        throw const AuthRequiredException();
      }
      rethrow; // Network failure is NOT a reason to erase valid refresh tokens.
    }
    // RFC 6749 permits omitted refresh_token. Preserve old token/expiry then;
    // when rotation supplies a new token, commit it atomically with access.
    final bundle = _TokenBundle.fromResponse(
      response,
      _clock(),
      previous: previous,
    );
    await _serialized(() async {
      if (_generation != generation) throw const AuthRequiredException();
      await _storage.write(_bundleKey, jsonEncode(bundle.toJson()));
      if (_generation != generation) throw const AuthRequiredException();
      _bundle = bundle;
      _generation++;
    });
    return bundle.accessToken;
  }

  Future<void> _invalidateIfCurrent(int generation) async {
    if (_generation != generation) return;
    await clearTokens();
    onSessionInvalidated?.call();
  }

  /// Revokes locally immediately, then deletes only our current config bundle.
  Future<void> clearTokens() {
    _bundle = null;
    _generation++;
    _identityEpoch++;
    return _serialized(() async {
      await _storage.delete(_bundleKey);
      await _storage.delete(_pendingKey);
    });
  }

  Future<void> savePendingAuthorization(OAuthAuthorizationRequest request) =>
      _serialized(
        () => _storage.write(
          _pendingKey,
          jsonEncode({
            'state': request.state,
            'verifier': request.codeVerifier,
            'started_at': _clock().toUtc().toIso8601String(),
          }),
        ),
      );

  Future<PendingAuthorization?> readPendingAuthorization() =>
      _serialized(() async {
        final raw = await _storage.read(_pendingKey);
        if (raw == null) return null;
        try {
          final json = jsonDecode(raw) as Map<String, dynamic>;
          final state = json['state'] as String;
          final verifier = json['verifier'] as String;
          final startedAt = DateTime.parse(json['started_at'] as String);
          final age = _clock().difference(startedAt);
          if (state.length != 32 ||
              verifier.length < 43 ||
              verifier.length > 128 ||
              age.isNegative ||
              age > OAuthConfig.pendingTtl) {
            throw const FormatException();
          }
          return PendingAuthorization(
            state: state,
            codeVerifier: verifier,
            startedAt: startedAt,
          );
        } catch (_) {
          await _storage.delete(_pendingKey);
          return null;
        }
      });

  Future<void> clearPendingAuthorization() =>
      _serialized(() => _storage.delete(_pendingKey));
}

class PendingAuthorization {
  const PendingAuthorization({
    required this.state,
    required this.codeVerifier,
    required this.startedAt,
  });
  final String state;
  final String codeVerifier;
  final DateTime startedAt;
}

class _TokenBundle {
  const _TokenBundle({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.issuedAt,
    this.refreshToken,
    this.refreshExpiresAt,
    this.scope,
  });
  final String accessToken;
  final String? refreshToken;
  final DateTime accessExpiresAt;
  final DateTime? refreshExpiresAt;
  final DateTime issuedAt;
  final String? scope;

  factory _TokenBundle.fromResponse(
    OAuthTokenResponse response,
    DateTime now, {
    _TokenBundle? previous,
  }) {
    final refresh = response.refreshToken ?? previous?.refreshToken;
    final refreshExpiry = response.refreshToken == null
        ? previous?.refreshExpiresAt
        : now.add(
            Duration(
              seconds: response.refreshExpiresInSeconds ?? 30 * 24 * 3600,
            ),
          );
    return _TokenBundle(
      accessToken: response.accessToken,
      accessExpiresAt: now.add(Duration(seconds: response.expiresInSeconds)),
      refreshToken: refresh,
      refreshExpiresAt: refreshExpiry,
      issuedAt: previous?.issuedAt ?? now,
      scope: response.scope ?? previous?.scope,
    );
  }

  factory _TokenBundle.fromJson(Map<String, dynamic> json) {
    final access = json['access_token'] as String;
    final refresh = json['refresh_token'] as String?;
    if (access.trim().isEmpty || (refresh != null && refresh.trim().isEmpty)) {
      throw const FormatException();
    }
    return _TokenBundle(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: DateTime.parse(json['access_expires_at'] as String),
      refreshExpiresAt: refresh == null
          ? null
          : DateTime.parse(json['refresh_expires_at'] as String),
      issuedAt: DateTime.parse(json['issued_at'] as String),
      scope: json['scope'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': refreshExpiresAt?.toUtc().toIso8601String(),
    'issued_at': issuedAt.toUtc().toIso8601String(),
    'scope': scope,
  };
}
