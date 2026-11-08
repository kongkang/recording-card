/// 带 Bearer token 的 HTTP 客户端：过期前刷新；401 时只刷新一次并重试，
/// 并发 401 共享同一个 refresh future（防 token rotation 竞态）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'oauth_client.dart';
import 'oauth_token_store.dart';

class AuthorizedHttpClient {
  AuthorizedHttpClient({
    required http.Client client,
    required OAuthClient oauth,
    required OAuthTokenStore tokens,
  })  : _client = client,
        _oauth = oauth,
        _tokens = tokens;

  final http.Client _client;
  final OAuthClient _oauth;
  final OAuthTokenStore _tokens;
  Future<OAuthTokens>? _refreshInFlight;

  Future<http.Response> get(Uri uri) =>
      _send((headers) => _client.get(uri, headers: headers));

  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) =>
      _send((authHeaders) => _client.post(
            uri,
            headers: {...authHeaders, ...?headers},
            body: body,
            encoding: encoding,
          ));

  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) send,
  ) async {
    var current = await _tokens.read();
    if (current == null) {
      throw const OAuthException('not_authenticated', '尚未登录');
    }
    if (current.isAccessExpired) {
      current = await _refresh(current);
    }

    var response = await send(_headers(current.accessToken));
    if (response.statusCode != 401) return response;

    current = await _refresh(current);
    response = await send(_headers(current.accessToken));
    if (response.statusCode == 401) {
      throw const OAuthException('unauthorized', '刷新后仍无权限', statusCode: 401);
    }
    return response;
  }

  Future<OAuthTokens> _refresh(OAuthTokens current) {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final refreshToken = current.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const OAuthException('no_refresh_token', '缺少 refresh_token');
    }
    final future = _oauth
        .refresh(refreshToken: refreshToken)
        .then((tokens) async {
      await _tokens.save(tokens);
      return tokens;
    });
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
  }

  Map<String, String> _headers(String accessToken) => {
        'authorization': 'Bearer $accessToken',
        'accept': 'application/json',
      };
}
