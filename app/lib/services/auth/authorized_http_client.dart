import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config/remote/endpoint_resolver.dart';
import 'auth_exception.dart';
import 'oauth_token_store.dart';

/// Minimal reference AuthorizedHttpClient adaptation, with fail-closed host
/// allowlist and redirects disabled. Refresh dedup/rotation live in tokenStore.
class AuthorizedHttpClient {
  AuthorizedHttpClient({
    required this.tokenStore,
    http.Client? httpClient,
    Iterable<String> trustedHosts = kTrustedEndpointHosts,
    this.timeout = const Duration(seconds: 45),
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _trustedHosts = Set.unmodifiable(
         trustedHosts.map((h) => h.toLowerCase()),
       );
  final OAuthTokenStore tokenStore;
  final http.Client _http;
  final bool _ownsHttp;
  final Set<String> _trustedHosts;
  final Duration timeout;
  bool _loggingOut = false;

  void setLoggingOut(bool value) => _loggingOut = value;
  bool get isLoggingOut => _loggingOut;

  Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _run('GET', url, headers: headers);
  Future<http.Response> postJson(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) => _run('POST', url, headers: headers, body: body);

  void _validateUrl(Uri url) {
    if (sanitizeTrustedEndpoint(url.toString(), trustedHosts: _trustedHosts) ==
        null) {
      throw const AuthException('untrusted_endpoint', '请求地址不在获批HTTPS主机列表');
    }
  }

  Future<http.Response> _run(
    String method,
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    _validateUrl(url); // Before any token lookup or network request.
    if (_loggingOut) throw const AuthRequiredException();
    final epoch = tokenStore.userIdentityEpoch;
    final token = await tokenStore.getValidAccessToken();
    if (token == null || _loggingOut || tokenStore.userIdentityEpoch != epoch) {
      throw const AuthRequiredException();
    }
    final first = await _send(method, url, token, headers, body);
    if (_loggingOut || tokenStore.userIdentityEpoch != epoch) {
      throw const AuthRequiredException();
    }
    if (first.statusCode != 401) return first;
    // A staggered 401 may arrive after another request has already rotated.
    var replacement = tokenStore.accessToken;
    if (replacement == null || replacement == token) {
      replacement = await tokenStore.refresh();
    }
    if (replacement == null ||
        _loggingOut ||
        tokenStore.userIdentityEpoch != epoch) {
      throw const AuthRequiredException();
    }
    final retry = await _send(method, url, replacement, headers, body);
    if (retry.statusCode == 401 ||
        _loggingOut ||
        tokenStore.userIdentityEpoch != epoch) {
      throw const AuthRequiredException();
    }
    return retry;
  }

  Future<http.Response> _send(
    String method,
    Uri url,
    String token,
    Map<String, String>? headers,
    Object? body,
  ) async {
    final request = http.Request(method, url)..followRedirects = false;
    if (headers != null) request.headers.addAll(headers);
    // Ignore any caller-supplied bearer: always use the authoritative session.
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await (() async => http.Response.fromStream(
        await _http.send(request),
      ))().timeout(timeout);
    } on TimeoutException {
      throw const AuthException('timeout', '授权服务请求超时');
    } catch (_) {
      throw const AuthException('network', '授权服务网络请求失败');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const AuthException(
        'redirect_refused',
        '已阻止服务端重定向以保护授权票据',
        statusCode: 300,
      );
    }
    return response;
  }

  void close() {
    if (_ownsHttp) _http.close();
  }
}
