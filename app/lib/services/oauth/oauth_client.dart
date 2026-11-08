/// OAuth 2.0 Authorization Code + PKCE (S256) 客户端。
///
/// 纯协议实现：不持有 token 状态、不启动浏览器；token 持久化由
/// [OAuthTokenStore] 负责，分享/刷新由 [AuthorizedHttpClient] 负责。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/config/oauth_config.dart';

class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime accessExpiresAt;
  final DateTime? refreshExpiresAt;

  /// 提前 30 秒视为过期，避免临界点请求。
  bool get isAccessExpired => !DateTime.now()
      .isBefore(accessExpiresAt.subtract(const Duration(seconds: 30)));

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'accessExpiresAt': accessExpiresAt.toIso8601String(),
        'refreshExpiresAt': refreshExpiresAt?.toIso8601String(),
      };

  factory OAuthTokens.fromJson(Map<String, dynamic> json) {
    final access = json['accessToken'];
    final accessExpiresAt = json['accessExpiresAt'];
    if (access is! String || access.isEmpty || accessExpiresAt is! String) {
      throw const OAuthException('invalid_token_bundle', 'token bundle 缺少字段');
    }
    return OAuthTokens(
      accessToken: access,
      refreshToken: json['refreshToken'] as String?,
      accessExpiresAt: DateTime.parse(accessExpiresAt),
      refreshExpiresAt: json['refreshExpiresAt'] is String
          ? DateTime.parse(json['refreshExpiresAt'] as String)
          : null,
    );
  }
}

class OAuthException implements Exception {
  const OAuthException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'OAuthException($code): $message';
}

class OAuthAuthorizationRequest {
  const OAuthAuthorizationRequest({
    required this.url,
    required this.state,
    required this.codeVerifier,
  });

  final Uri url;
  final String state;
  final String codeVerifier;
}

class OAuthClient {
  OAuthClient({
    required this.config,
    http.Client? httpClient,
    Random? random,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _random = random ?? Random.secure();

  final OAuthConfig config;
  final http.Client _http;
  final bool _ownsHttpClient;
  final Random _random;

  static const _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// RFC 7636 S256：BASE64URL(SHA256(verifier))，去 padding。
  static String codeChallengeS256(String verifier) =>
      base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');

  OAuthAuthorizationRequest createAuthorizationRequest({
    String? loginHint,
    String? prompt,
  }) {
    final verifier = _randomString(64);
    final state = _randomString(32);
    final url = config.authorizeUri.replace(queryParameters: {
      'response_type': 'code',
      'client_id': config.clientId,
      'redirect_uri': config.redirectUri,
      'scope': config.scope,
      'state': state,
      'code_challenge': codeChallengeS256(verifier),
      'code_challenge_method': 'S256',
      if (loginHint != null && loginHint.trim().isNotEmpty)
        'login_hint': loginHint.trim(),
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
    });
    return OAuthAuthorizationRequest(
      url: url,
      state: state,
      codeVerifier: verifier,
    );
  }

  Future<OAuthTokens> exchangeCode({
    required String code,
    required String codeVerifier,
  }) async {
    final response = await _postForm(config.tokenUri, {
      'grant_type': 'authorization_code',
      'client_id': config.clientId,
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': config.redirectUri,
    });
    return _parseTokens(response);
  }

  Future<OAuthTokens> refresh({required String refreshToken}) async {
    final response = await _postForm(config.tokenUri, {
      'grant_type': 'refresh_token',
      'client_id': config.clientId,
      'refresh_token': refreshToken,
    });
    return _parseTokens(response, fallbackRefreshToken: refreshToken);
  }

  Future<Map<String, dynamic>> fetchProfile(String accessToken) async {
    final response = await _http.get(
      config.profileUri,
      headers: {
        'authorization': 'Bearer $accessToken',
        'accept': 'application/json',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OAuthException(
        'profile_failed',
        'profile 请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const OAuthException('invalid_profile', 'profile 响应不是 JSON 对象');
    }
    return decoded;
  }

  Future<http.Response> _postForm(
      Uri uri, Map<String, String> fields) {
    return _http.post(
      uri,
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: fields,
    );
  }

  OAuthTokens _parseTokens(
    http.Response response, {
    String? fallbackRefreshToken,
  }) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OAuthException(
        _errorCode(response),
        'token 请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const OAuthException('invalid_token_response', 'token 响应不是 JSON 对象');
    }
    final access = decoded['access_token'];
    if (access is! String || access.isEmpty) {
      throw const OAuthException('invalid_token_response', 'token 响应缺少 access_token');
    }
    final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    final refreshExpiresIn = (decoded['refresh_expires_in'] as num?)?.toInt();
    final refreshRaw = decoded['refresh_token'];
    final refresh = refreshRaw is String && refreshRaw.isNotEmpty
        ? refreshRaw
        : fallbackRefreshToken;
    final now = DateTime.now();
    return OAuthTokens(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: now.add(Duration(seconds: expiresIn)),
      refreshExpiresAt: refreshExpiresIn == null
          ? null
          : now.add(Duration(seconds: refreshExpiresIn)),
    );
  }

  String _errorCode(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is String && error.isNotEmpty) return error;
      }
    } catch (_) {
      // 非 JSON 错误体，返回 HTTP 码
    }
    return 'http_${response.statusCode}';
  }

  String _randomString(int length) => String.fromCharCodes(Iterable.generate(
      length, (_) => _chars.codeUnitAt(_random.nextInt(_chars.length))));

  void dispose() {
    if (_ownsHttpClient) _http.close();
  }
}
