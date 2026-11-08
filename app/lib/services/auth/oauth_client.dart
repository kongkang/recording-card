import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'auth_exception.dart';
import 'oauth_config.dart';

/// Minimal adaptation of reference OAuthClient (PKCE public client only).
class OAuthClient {
  OAuthClient({
    required this.config,
    http.Client? httpClient,
    Random? random,
    this.timeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _random = random ?? Random.secure();
  final OAuthConfig config;
  final http.Client _http;
  final bool _ownsHttp;
  final Random _random;
  final Duration timeout;

  OAuthAuthorizationRequest createAuthorizationRequest({String? loginHint}) {
    config.validate();
    final verifier = _randomString(
      64,
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~',
    );
    final state = _randomString(
      32,
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789',
    );
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    return OAuthAuthorizationRequest(
      url: config
          .endpoint('/oauth/authorize')
          .replace(
            queryParameters: {
              'response_type': 'code',
              'client_id': config.clientId,
              'redirect_uri': config.redirectUri.toString(),
              'scope': config.scope,
              'state': state,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
              'prompt': 'select_account',
              if (loginHint != null && loginHint.trim().isNotEmpty)
                'login_hint': loginHint.trim(),
            },
          ),
      state: state,
      codeVerifier: verifier,
      codeChallenge: challenge,
    );
  }

  Future<OAuthTokenResponse> exchangeCodeForToken({
    required String code,
    required String codeVerifier,
  }) async => OAuthTokenResponse.fromJson(
    await _postForm('/oauth/token', {
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': config.clientId,
      'redirect_uri': config.redirectUri.toString(),
      'code_verifier': codeVerifier,
    }),
  );

  Future<OAuthTokenResponse> refreshAccessToken(String refreshToken) async =>
      OAuthTokenResponse.fromJson(
        await _postForm('/oauth/token', {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': config.clientId,
        }),
      );

  Future<void> revoke({
    required String token,
    required String tokenTypeHint,
  }) async {
    await _postForm('/oauth/revoke', {
      'token': token,
      'token_type_hint': tokenTypeHint,
      'client_id': config.clientId,
    }, acceptEmpty: true);
  }

  Future<Map<String, dynamic>> _postForm(
    String path,
    Map<String, String> body, {
    bool acceptEmpty = false,
  }) async {
    config.validate();
    final request = http.Request('POST', config.endpoint(path))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json'
      ..bodyFields = body;
    final http.Response response;
    try {
      response = await (() async => http.Response.fromStream(
        await _http.send(request),
      ))().timeout(timeout);
    } on TimeoutException {
      throw const AuthException('timeout', 'OAuth服务请求超时');
    } catch (_) {
      throw const AuthException('network', 'OAuth服务网络请求失败');
    }
    if (response.statusCode == 401) throw const AuthRequiredException();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Only recognize fixed error codes. Do not expose untrusted error strings.
      var code = 'server_error';
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map &&
            const {
              'invalid_grant',
              'invalid_token',
              'unauthorized_client',
              'invalid_client',
              'invalid_scope',
              'access_denied',
            }.contains(decoded['error'])) {
          code = decoded['error'] as String;
        }
      } catch (_) {
        /* Deliberately ignore untrusted error bodies. */
      }
      throw AuthException(code, 'OAuth服务拒绝请求', statusCode: response.statusCode);
    }
    if (acceptEmpty) return {};
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      /* Translate parsing failure without leaking response. */
    }
    throw const AuthException('invalid_response', 'OAuth服务响应格式无效');
  }

  String _randomString(int count, String alphabet) => List.generate(
    count,
    (_) => alphabet[_random.nextInt(alphabet.length)],
  ).join();
  void close() {
    if (_ownsHttp) _http.close();
  }
}

class OAuthAuthorizationRequest {
  const OAuthAuthorizationRequest({
    required this.url,
    required this.state,
    required this.codeVerifier,
    required this.codeChallenge,
  });
  final Uri url;
  final String state;
  final String codeVerifier;
  final String codeChallenge;
}

class OAuthTokenResponse {
  const OAuthTokenResponse({
    required this.accessToken,
    this.refreshToken,
    required this.expiresInSeconds,
    this.refreshExpiresInSeconds,
    this.scope,
  });
  final String accessToken;
  final String? refreshToken;
  final int expiresInSeconds;
  final int? refreshExpiresInSeconds;
  final String? scope;

  factory OAuthTokenResponse.fromJson(Map<String, dynamic> json) {
    final access = json['access_token'];
    final refresh = json['refresh_token'];
    final type = json['token_type'];
    final ttl = json['expires_in'];
    final refreshTtl = json['refresh_expires_in'];
    if (access is! String ||
        access.trim().isEmpty ||
        (type is! String || type.toLowerCase() != 'bearer') ||
        (refresh != null && (refresh is! String || refresh.trim().isEmpty)) ||
        ttl is! num ||
        !ttl.isFinite ||
        ttl <= 0 ||
        (refreshTtl != null &&
            (refreshTtl is! num || !refreshTtl.isFinite || refreshTtl <= 0)) ||
        (json['scope'] != null && json['scope'] is! String)) {
      throw const AuthException('invalid_response', 'OAuth票据缺少有效token或有效期');
    }
    return OAuthTokenResponse(
      accessToken: access,
      refreshToken: refresh as String?,
      expiresInSeconds: ttl.toInt(),
      refreshExpiresInSeconds: (refreshTtl as num?)?.toInt(),
      scope: json['scope'] as String?,
    );
  }
}
