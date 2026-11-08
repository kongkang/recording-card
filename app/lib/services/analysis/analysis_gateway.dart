import 'dart:async';
import 'dart:convert';

/// Typed injection seam. The integration adapter is:
/// CallbackAnalysisGateway(gateway.complete), where gateway is A's ModelGateway.
abstract interface class AnalysisGateway {
  Future<String> complete(String prompt, {String? model});
}

typedef TextCompletion =
    Future<String> Function(String prompt, {String? model});

class CallbackAnalysisGateway implements AnalysisGateway {
  final TextCompletion completion;
  const CallbackAnalysisGateway(this.completion);
  @override
  Future<String> complete(String prompt, {String? model}) =>
      completion(prompt, model: model);
}

/// Keeps this module buildable before A's implementation is cherry-picked.
/// It also accepts A's exact complete(String,{String? model}) facade directly.
/// No seed, local LLM, implicit unauthorized endpoint, or model fallback exists.
class CompatibleAnalysisGateway implements AnalysisGateway {
  final Object gateway;
  const CompatibleAnalysisGateway(this.gateway);
  @override
  Future<String> complete(String prompt, {String? model}) async {
    final value = await (gateway as dynamic).complete(prompt, model: model);
    if (value is! String) {
      throw const AnalysisException('gateway_contract', '模型网关必须返回文本响应');
    }
    return value;
  }
}

class AnalysisException implements Exception {
  final String code;
  final String message;
  final bool retryable;
  const AnalysisException(this.code, this.message, {this.retryable = false});
  @override
  String toString() => 'AnalysisException($code): $message';
}

Map<String, dynamic> parseStructuredResponse(
  String response, {
  int maxChars = 120000,
}) {
  if (response.length > maxChars) {
    throw const AnalysisException('response_limit', '模型响应超过安全长度限额');
  }
  var text = response.trim();
  if (text.startsWith('```')) {
    final match = RegExp(
      r'^```(?:json)?\s*\n?([\s\S]*?)\n?```$',
    ).firstMatch(text);
    if (match == null) {
      throw const AnalysisException('schema_invalid', '模型响应不是单一JSON对象');
    }
    text = match.group(1)!;
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException();
    }
    return decoded;
  } on FormatException {
    throw const AnalysisException('schema_invalid', '模型响应JSON解析失败');
  }
}

String requiredText(dynamic value, String field, {int maxLength = 20000}) {
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    throw AnalysisException('schema_invalid', '$field 必须是非空有限长度文本');
  }
  return value.trim();
}

List<dynamic> requiredList(
  dynamic value,
  String field, {
  bool allowEmpty = false,
  int maxItems = 500,
}) {
  if (value is! List ||
      (!allowEmpty && value.isEmpty) ||
      value.length > maxItems) {
    throw AnalysisException('schema_invalid', '$field 必须是合法列表');
  }
  return value;
}

Map<String, dynamic> requiredMap(dynamic value, String field) {
  if (value is! Map<String, dynamic>) {
    throw AnalysisException('schema_invalid', '$field 必须是对象');
  }
  return value;
}
