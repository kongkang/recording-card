/// 模型网关客户端 —— 后端 `/api/model-gateway/v1` 的 OpenAI-compatible
/// `/models` 与 `/chat/completions`。认证头由注入函数提供（OAuth token），
/// 客户端本身不持有密钥、不写死模型。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

class ModelInfo {
  const ModelInfo({required this.id, required this.capabilities});

  final String id;
  final List<String> capabilities;

  bool supports(String capability) => capabilities.contains(capability);
}

class ModelGatewayException implements Exception {
  const ModelGatewayException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ModelGatewayException(${statusCode ?? '-'}): $message';
}

class ModelGatewayClient {
  ModelGatewayClient({
    required this.modelsUri,
    required this.chatCompletionsUri,
    required this.headers,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri modelsUri;
  final Uri chatCompletionsUri;
  final Future<Map<String, String>> Function() headers;
  final http.Client _client;

  Future<List<ModelInfo>> listModels() async {
    final response = await _client.get(modelsUri, headers: await headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelGatewayException(
        '模型目录请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
      throw const ModelGatewayException('模型目录响应格式错误');
    }
    final models = <ModelInfo>[];
    for (final item in decoded['data'] as List) {
      if (item is! Map) continue;
      final id = item['id'];
      final capabilities = item['capabilities'];
      if (id is! String || id.isEmpty || capabilities is! List) continue;
      models.add(ModelInfo(
        id: id,
        capabilities: [
          for (final c in capabilities)
            if (c is String && c.isNotEmpty) c
        ],
      ));
    }
    return models;
  }

  Future<String> chat({
    required String model,
    required List<ChatMessage> messages,
    double temperature = 0.2,
    int? maxTokens,
  }) async {
    if (model.trim().isEmpty) {
      throw const ModelGatewayException('未配置文本模型');
    }
    final body = <String, Object?>{
      'model': model,
      'stream': false,
      'temperature': temperature,
      'max_tokens': ?maxTokens,
      'messages': [for (final m in messages) m.toJson()],
    };
    final response = await _client.post(
      chatCompletionsUri,
      headers: {
        ...await headers(),
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelGatewayException(
        '模型请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const ModelGatewayException('模型响应不是 JSON 对象');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const ModelGatewayException('模型响应缺少 choices');
    }
    final first = choices.first;
    if (first is! Map) {
      throw const ModelGatewayException('模型响应 choices 格式错误');
    }
    final message = first['message'];
    if (message is! Map) {
      throw const ModelGatewayException('模型响应缺少 message');
    }
    final content = message['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const ModelGatewayException('模型响应内容为空');
    }
    return content.trim();
  }

  void close() => _client.close();
}
