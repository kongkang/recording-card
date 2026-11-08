import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/config/auth_mode.dart';
import '../core/config/remote/client_config.dart';
import 'auth/auth_exception.dart';
import 'auth/auth_session.dart';
import 'auth/authorized_http_client.dart';
import 'auth/oauth_client.dart';
import 'auth/oauth_config.dart';
import 'auth/oauth_token_store.dart';
import 'auth/web_auth_launcher.dart';

export 'auth/auth_exception.dart';
export 'auth/auth_session.dart';

/// Production facade. Password input never creates a session. Publish a session
/// only after secure token persistence and authenticated server /profile.
class AuthService extends ChangeNotifier {
  factory AuthService({
    ClientConfig? config,
    OAuthClient? oauthClient,
    OAuthTokenStore? tokenStore,
    WebAuthLauncher? launcher,
    http.Client? httpClient,
    DateTime Function()? clock,
  }) {
    final effectiveConfig =
        config ??
        oauthClient?.config.clientConfig ??
        tokenStore?.client.config.clientConfig ??
        ClientConfig.instance;
    final client =
        oauthClient ??
        tokenStore?.client ??
        OAuthClient(
          config: OAuthConfig(clientConfig: effectiveConfig),
          httpClient: httpClient,
        );
    if (tokenStore != null && !identical(tokenStore.client, client)) {
      throw ArgumentError(
        'OAuthTokenStore and OAuthClient must share the same client',
      );
    }
    if (client.config.storageNamespace !=
        OAuthConfig(clientConfig: effectiveConfig).storageNamespace) {
      throw ArgumentError(
        'OAuth client configuration must match AuthService configuration',
      );
    }
    final store = tokenStore ?? OAuthTokenStore(client: client, clock: clock);
    return AuthService._(
      effectiveConfig,
      client,
      store,
      launcher ?? const FlutterWebAuthLauncher(),
      AuthorizedHttpClient(
        tokenStore: store,
        httpClient: httpClient,
        trustedHosts: effectiveConfig.trustedHosts,
      ),
      clock ?? DateTime.now,
      ownsOAuthClient: oauthClient == null && tokenStore == null,
    );
  }

  AuthService._(
    this.config,
    this._oauth,
    this._tokens,
    this._launcher,
    this.authorizedClient,
    this._clock, {
    required bool ownsOAuthClient,
  }) : _ownsOAuthClient = ownsOAuthClient {
    _tokens.onSessionInvalidated = _onInvalidated;
  }

  final ClientConfig config;
  final OAuthClient _oauth;
  final OAuthTokenStore _tokens;
  final WebAuthLauncher _launcher;
  final DateTime Function() _clock;
  final bool _ownsOAuthClient;
  final AuthorizedHttpClient authorizedClient;
  AuthSession? _session;
  Future<AuthSession>? _signingIn;
  Future<void>? _restoring;
  int _operation = 0;
  bool _disposed = false;

  AuthSession? get session => _tokens.hasUsableSession ? _session : null;
  bool get isSignedIn => session != null;
  bool get useRemoteOAuth => kIsOAuthAuthMode;

  /// Legacy compatibility only. Never authenticates any account/password pair.
  String? signIn(String account, String password) {
    if (account.trim().isEmpty) return '请输入账号';
    if (password.isEmpty) return '请输入密码';
    return '请使用OAuth授权登录，账号密码不能在本地验证';
  }

  Future<void> restore() {
    if (_restoring != null) return _restoring!;
    final future = _restore();
    _restoring = future;
    return future.whenComplete(() {
      _restoring = null;
    });
  }

  Future<void> _restore() async {
    _ensureOAuth();
    final operation = _operation;
    try {
      await _tokens.bootstrap();
      if (_tokens.accessToken == null && _tokens.refreshToken == null) return;
      final profile = await _fetchProfile();
      _checkOperation(operation);
      _session = profile;
      _notify();
    } on AuthRequiredException {
      if (_operation == operation) {
        await _tokens.clearTokens();
        _session = null;
        _notify();
      }
      rethrow;
    }
  }

  Future<AuthSession> signInWithOAuth({String? loginHint}) {
    if (_signingIn != null) return _signingIn!;
    final future = _signInWithOAuth(loginHint);
    _signingIn = future;
    return future.whenComplete(() {
      _signingIn = null;
    });
  }

  Future<AuthSession> _signInWithOAuth(String? loginHint) async {
    _ensureOAuth();
    if (_restoring != null) await _restoring;
    final operation = ++_operation;
    authorizedClient.setLoggingOut(false);
    var savedTokens = false;
    try {
      final request = _oauth.createAuthorizationRequest(loginHint: loginHint);
      await _tokens.savePendingAuthorization(request);
      _checkOperation(operation);
      final callback = await _launcher.launch(
        authorizeUrl: request.url,
        callbackScheme: _oauth.config.callbackScheme,
      );
      _checkOperation(operation);
      final pending = await _tokens.readPendingAuthorization();
      final expected = _oauth.config.redirectUri;
      final values = callback.queryParametersAll;
      if (pending == null ||
          !_constantTimeEquals(pending.state, request.state) ||
          callback.scheme != expected.scheme ||
          callback.host != expected.host ||
          callback.path != expected.path ||
          callback.userInfo.isNotEmpty ||
          callback.hasPort ||
          callback.hasFragment ||
          values['state']?.length != 1 ||
          !_constantTimeEquals(values['state']!.single, pending.state)) {
        throw const AuthException(
          'invalid_callback',
          'OAuth回调地址、state或有效期校验失败',
        );
      }
      if (values.containsKey('error')) {
        throw const AuthException('authorization_denied', '服务端拒绝OAuth授权');
      }
      final codes = values['code'];
      if (codes == null || codes.length != 1 || codes.single.trim().isEmpty) {
        throw const AuthException('invalid_callback', 'OAuth回调缺少唯一授权码');
      }
      // Consume pending BEFORE exchange: callback/code can only be used once.
      await _tokens.clearPendingAuthorization();
      _checkOperation(operation);
      final response = await _oauth.exchangeCodeForToken(
        code: codes.single,
        codeVerifier: pending.codeVerifier,
      );
      _checkOperation(operation);
      _session = null;
      _notify();
      await _tokens.saveTokens(response);
      savedTokens = true;
      _checkOperation(operation);
      final profile = await _fetchProfile();
      _checkOperation(operation);
      _session = profile;
      _notify();
      return profile;
    } catch (_) {
      if (savedTokens && _operation == operation) {
        await _tokens.clearTokens();
        _session = null;
        _notify();
      }
      rethrow;
    } finally {
      // A stale operation must not delete a newer user's pending authorization.
      if (_operation == operation) await _tokens.clearPendingAuthorization();
    }
  }

  Future<AuthSession> _fetchProfile() async {
    final response = await authorizedClient.get(
      _oauth.config.endpoint('/profile'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        'profile_failed',
        '服务端用户身份验证失败',
        statusCode: response.statusCode,
      );
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map<String, dynamic>) throw const FormatException();
      return AuthSession.fromProfile(json, _tokens.issuedAt ?? _clock());
    } on FormatException {
      throw const AuthException('invalid_profile', '服务端用户身份响应无法解析');
    }
  }

  /// Local logout always happens even if remote revocation fails. Failure is
  /// reported; it never resurrects the session. Await before starting a login.
  Future<void> signOut() async {
    _operation++;
    authorizedClient.setLoggingOut(true);
    final refresh = _tokens.refreshToken;
    final access = _tokens.accessToken;
    _session = null;
    final clear = _tokens.clearTokens();
    _notify();
    await clear;
    try {
      if (refresh != null) {
        await _oauth.revoke(token: refresh, tokenTypeHint: 'refresh_token');
      }
      if (access != null) {
        await _oauth.revoke(token: access, tokenTypeHint: 'access_token');
      }
    } on AuthException {
      throw const AuthException('revocation_failed', '已清除本机会话，但服务端撤销失败');
    }
  }

  void _ensureOAuth() {
    if (_disposed) throw StateError('AuthService disposed');
    if (!kIsOAuthAuthMode) {
      throw const AuthException('auth_disabled', 'OAuth登录未启用');
    }
    _oauth.config.validate();
  }

  void _checkOperation(int operation) {
    if (_disposed || _operation != operation) {
      throw const AuthRequiredException();
    }
  }

  void _onInvalidated() {
    _session = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a), right = utf8.encode(b);
    var difference = left.length ^ right.length;
    for (var i = 0; i < left.length && i < right.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    authorizedClient.setLoggingOut(true);
    _tokens.onSessionInvalidated = null;
    authorizedClient.close();
    if (_ownsOAuthClient) _oauth.close();
    super.dispose();
  }
}
