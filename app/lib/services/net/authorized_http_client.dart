/// 带鉴权的 HTTP 客户端（其他模块的统一公共契约）。
///
/// 职责：
/// - 自动注入 `Authorization: Bearer <access_token>`；
/// - 收到 401 时用 refresh token 刷新一次并**重放一次**（不无限重试）；
/// - 超时 / 网络 / 401 统一归一到 [ApiException] 子类；
/// - 非 2xx 但不涉及鉴权的响应**原样返回**，由调用方按业务语义解读
///   （模型网关需要读错误体给用户更准的提示）。
///
/// 并发安全：
/// - 刷新经 [OAuthTokenStore.refresh] 的 inflight 去重，N 个并发 401 只刷一次；
/// - 发送前后比对 [OAuthTokenStore.identityEpoch]：请求在途时用户切换了账号，
///   就不拿新用户的 token 重放旧请求（业务操作会打到错账号）。
///
/// multipart 的 401 重放：请求体是纯字节（见 `multipart_body.dart`），
/// 每次重放都由构造闭包重新生成 `http.Request`，不存在 stream 不可重用的问题。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/oauth_exception.dart';
import '../auth/oauth_token_store.dart';
import 'api_exception.dart';
import 'multipart_body.dart';

/// 鉴权 HTTP 客户端。
class AuthorizedHttpClient {
  AuthorizedHttpClient({
    required OAuthTokenStore tokenStore,
    http.Client? httpClient,
    Duration defaultTimeout = const Duration(seconds: 15),
  })  : _tokens = tokenStore,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _defaultTimeout = defaultTimeout;

  final OAuthTokenStore _tokens;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration _defaultTimeout;

  /// 登出过程中置 true：401 不再触发刷新（避免给已废弃的会话续命）。
  bool _isLoggingOut = false;

  /// 鉴权失效时的全局通知（由 UI 层注入，用于跳回登录页）。
  void Function()? onAuthRequired;

  /// 当前是否有登录态（[ModelGateway.available] 等门控用）。
  bool get hasSession => _tokens.hasSession;

  /// 暴露 token store，便于上层读取账号信息（只读用途）。
  OAuthTokenStore get tokenStore => _tokens;

  /// 标记/清除「正在登出」状态。
  void setLoggingOut(bool value) => _isLoggingOut = value;

  // ===== 对外请求方法 =====

  /// 上传字节（multipart/form-data），用于 ASR 转写。
  ///
  /// [fields] 文本字段（如 `model` / `language` / `response_format`），
  /// 文件字段固定为 [fileField]（网关要求 `file`）。
  /// [mimeType] 为空时按 [filename] 后缀推断。
  Future<http.Response> postBytes(
    String url, {
    required Map<String, String> fields,
    required String fileField,
    required List<int> bytes,
    required String filename,
    String? mimeType,
    Duration? timeout,
  }) {
    final body = buildMultipartBody(
      fields: fields,
      fileField: fileField,
      fileBytes: bytes,
      filename: filename,
      mimeType: mimeType,
    );
    return _authorizedSend(
      timeout: timeout,
      build: (token) => http.Request('POST', _parseUrl(url))
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': body.contentType,
          'Accept': 'application/json',
        })
        ..bodyBytes = body.bytes,
    );
  }

  /// 发送 JSON（POST），用于 chat/completions 等。
  Future<http.Response> postJson(
    String url,
    Object body, {
    Duration? timeout,
  }) {
    final payload = utf8.encode(jsonEncode(body));
    return _authorizedSend(
      timeout: timeout,
      build: (token) => http.Request('POST', _parseUrl(url))
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
        })
        ..bodyBytes = payload,
    );
  }

  /// 发送 GET（JSON），用于 `/profile` 之类的轻量查询。
  Future<http.Response> getJson(String url, {Duration? timeout}) {
    return _authorizedSend(
      timeout: timeout,
      build: (token) => http.Request('GET', _parseUrl(url))
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        }),
    );
  }

  /// 释放内部创建的 http.Client（外部注入的由调用方负责）。
  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  // ===== 内部 =====

  Uri _parseUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ApiNetworkException('请求地址不合法：$url');
    }
    return uri;
  }

  /// 发请求 + 401 单次刷新重放。
  ///
  /// [build] 每次调用都必须返回**全新**的请求对象（重放时重建）。
  Future<http.Response> _authorizedSend({
    required http.BaseRequest Function(String token) build,
    Duration? timeout,
  }) async {
    final firstToken = await _currentAccessToken();
    final capturedEpoch = _tokens.identityEpoch;

    final first = await _dispatch(build, firstToken, timeout);
    if (first.statusCode != 401) return first;

    // 401：先判断能不能刷新
    if (_isLoggingOut) {
      throw const ApiUnauthorizedException();
    }
    if (_tokens.identityEpoch != capturedEpoch) {
      // 用户已切换：不能把旧请求重放到新账号
      throw const ApiUnauthorizedException();
    }

    final refreshedToken = await _refreshTokenAfter401();
    if (refreshedToken == null) {
      throw const ApiUnauthorizedException();
    }
    if (_tokens.identityEpoch != capturedEpoch) {
      throw const ApiUnauthorizedException();
    }

    final retried = await _dispatch(build, refreshedToken, timeout);
    if (retried.statusCode == 401) {
      // 只重放一次：还是 401 说明会话确实死了
      onAuthRequired?.call();
      throw const ApiUnauthorizedException();
    }
    return retried;
  }

  /// 取当前可用 token；没有登录态直接抛「需要登录」。
  Future<String> _currentAccessToken() async {
    try {
      final token = await _tokens.getValidAccessToken();
      if (token == null || token.isEmpty) {
        // 会话已经不可用（无 token / access 过期且无 refresh）：通知上层回登录页。
        onAuthRequired?.call();
        throw const ApiUnauthorizedException();
      }
      return token;
    } on OAuthAuthRequiredException {
      onAuthRequired?.call();
      throw const ApiUnauthorizedException();
    } on OAuthException catch (e) {
      throw ApiNetworkException(e.message, e);
    }
  }

  /// 401 后刷新；刷新失败统一归一成「需要登录」。
  Future<String?> _refreshTokenAfter401() async {
    try {
      final token = await _tokens.refresh();
      if (token == null || token.isEmpty) {
        onAuthRequired?.call();
        return null;
      }
      return token;
    } on OAuthAuthRequiredException {
      onAuthRequired?.call();
      return null;
    } on OAuthException catch (e) {
      // 网络类失败不算会话失效：提示网络问题，不强行踢回登录页
      throw ApiNetworkException(e.message, e);
    }
  }

  /// 真正发包：超时与传输层异常统一归一。
  Future<http.Response> _dispatch(
    http.BaseRequest Function(String token) build,
    String token,
    Duration? timeout,
  ) async {
    final request = build(token);
    try {
      // 超时覆盖「等响应头 + 读响应体」整段，避免只超时了前半段而卡在读 body。
      final responseFuture =
          _httpClient.send(request).then(http.Response.fromStream);
      return await responseFuture.timeout(timeout ?? _defaultTimeout);
    } on TimeoutException catch (e) {
      throw ApiTimeoutException(ApiTimeoutException.defaultMessage, e);
    } on http.ClientException catch (e) {
      throw ApiNetworkException(ApiNetworkException.defaultMessage, e);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiNetworkException(ApiNetworkException.defaultMessage, e);
    }
  }
}
