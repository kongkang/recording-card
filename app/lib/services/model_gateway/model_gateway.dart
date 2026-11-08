import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config/remote/client_config.dart';
import '../../core/config/remote/endpoint_resolver.dart';
import '../auth/authorized_http_client.dart';
import '../auth_service.dart';

export '../auth/auth_exception.dart' show AuthException, AuthRequiredException;

class GatewayException implements Exception {
  const GatewayException(this.code, this.message, {this.statusCode});
  final String code;
  final String message;
  final int? statusCode;
  @override
  String toString() =>
      'GatewayException($code, ${statusCode ?? '-'}): $message';
}

class GatewayModel {
  const GatewayModel({
    required this.id,
    required this.name,
    required this.capabilities,
  });
  final String id;
  final String name;
  final Set<String> capabilities;
  bool get supportsText => capabilities.contains('text');
}

/// Real OAuth-only backend gateway. No provider API keys, static catalog,
/// automatic alternate-model selection, demo completion or raw-text fallback.
class ModelGateway {
  ModelGateway({
    AuthService? auth,
    AuthorizedHttpClient? client,
    ClientConfig? config,
    String? baseUrl,
    String? defaultModel,
  }) : _client =
           client ??
           auth?.authorizedClient ??
           (throw ArgumentError(
             'ModelGateway requires auth or authorized client',
           )),
       _config = config ?? auth?.config ?? ClientConfig.instance,
       _baseOverride = baseUrl,
       _modelOverride = defaultModel;
  final AuthorizedHttpClient _client;
  final ClientConfig _config;
  final String? _baseOverride;
  final String? _modelOverride;

  String get configuredModel => (_modelOverride ?? _config.textModel).trim();
  Uri get _base {
    final value = sanitizeTrustedEndpoint(
      _baseOverride ?? _config.effectiveModelGatewayBaseUrl,
      trustedHosts: _config.trustedHosts,
    );
    if (value == null) {
      throw const GatewayException('invalid_config', '模型网关未配置或不在获批HTTPS主机列表');
    }
    return Uri.parse(value);
  }

  Uri _endpoint(String path) => Uri.parse('${_base.toString()}$path');

  /// Server /models is authoritative for account permission and capabilities.
  /// Explicit disabled/unauthorized models are excluded. Missing capabilities
  /// are NOT assumed to support text. No available text model is an error.
  Future<List<GatewayModel>> listTextModels() async {
    final response = await _client.get(_endpoint('/models'));
    final json = _jsonObject(response);
    final data = json['data'];
    if (data is! List) {
      throw const GatewayException('invalid_catalog', '模型目录缺少data列表');
    }
    final models = <GatewayModel>[];
    final seen = <String>{};
    for (final item in data) {
      if (item is! Map ||
          item['id'] is! String ||
          (item['id'] as String).trim().isEmpty) {
        throw const GatewayException('invalid_catalog', '模型目录包含无效模型ID');
      }
      final capabilities = item['capabilities'];
      if (capabilities is! List ||
          !capabilities.contains('text') ||
          item['authorized'] == false ||
          item['available'] == false ||
          item['enabled'] == false) {
        continue;
      }
      final id = item['id'] as String;
      if (seen.add(id)) {
        models.add(
          GatewayModel(
            id: id,
            name: item['name'] is String ? item['name'] as String : id,
            capabilities: Set.unmodifiable(capabilities.whereType<String>()),
          ),
        );
      }
    }
    if (models.isEmpty) {
      throw const GatewayException('no_text_models', '当前账号没有可用的已授权文本模型');
    }
    return List.unmodifiable(models);
  }

  /// Caller selects an authorized ID, or config must supply RC_TEXT_MODEL.
  /// Empty/missing model errors before network. Check fresh /models permission
  /// before every potentially billable completion, then use that EXACT model.
  Future<String> complete(String prompt, {String? model}) async {
    if (prompt.trim().isEmpty) {
      throw const GatewayException('empty_prompt', '文本模型输入不能为空');
    }
    final selected = model == null ? configuredModel : model.trim();
    if (selected.isEmpty) {
      throw const GatewayException('model_not_configured', '请配置或明确选择已授权文本模型');
    }
    final epoch = _client.tokenStore.userIdentityEpoch;
    final models = await listTextModels();
    if (_client.tokenStore.userIdentityEpoch != epoch) {
      throw const AuthRequiredException();
    }
    if (!models.any((item) => item.id == selected)) {
      throw const GatewayException('model_not_authorized', '所选文本模型不在当前账号授权目录');
    }
    final response = await _client.postJson(
      _endpoint('/chat/completions'),
      body: {
        'model': selected,
        'stream': false,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
    );
    if (_client.tokenStore.userIdentityEpoch != epoch) {
      throw const AuthRequiredException();
    }
    final json = _jsonObject(response);
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final first = choices.first as Map;
      if (first['finish_reason'] == 'length') {
        throw const GatewayException('truncated_completion', '模型返回因长度限制而截断');
      }
      final message = first['message'];
      if (message is Map &&
          message['content'] is String &&
          (message['content'] as String).trim().isNotEmpty) {
        return (message['content'] as String).trim();
      }
    }
    throw const GatewayException('invalid_completion', '模型网关未返回有效文本');
  }

  Map<String, dynamic> _jsonObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayException(
        'http_error',
        '模型网关拒绝请求',
        statusCode: response.statusCode,
      );
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, dynamic>) return json;
    } catch (_) {
      /* Never include model/HTTP response bodies in exceptions. */
    }
    throw const GatewayException('invalid_response', '模型网关响应不是有效JSON对象');
  }
}
