/// 把 [AuthorizedHttpClient] 适配成 `http.Client`，供 ModelGatewayClient 复用
/// Bearer 注入 / 401 刷新逻辑，而不把 OAuth 细节泄漏到网关层。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../oauth/authorized_http_client.dart';

class AuthorizedClientAdapter extends http.BaseClient {
  AuthorizedClientAdapter(this._inner);

  final AuthorizedHttpClient _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.Response response;
    if (request.method == 'GET') {
      response = await _inner.get(request.url);
    } else {
      final body = request is http.Request ? request.bodyBytes : null;
      response = await _inner.post(
        request.url,
        headers: request.headers,
        body: body,
      );
    }
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
