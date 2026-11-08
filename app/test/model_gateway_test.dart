// 模型网关验收（TDD）—— OpenAI-compatible /models 与 /chat/completions，
// 不依赖真实后端；认证头由注入函数提供。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/model_gateway/model_gateway_client.dart';

const _modelsUri = 'https://api.example.com/api/model-gateway/v1/models';
const _chatUri =
    'https://api.example.com/api/model-gateway/v1/chat/completions';

class _Headers {
  int calls = 0;

  Future<Map<String, String>> call() async {
    calls++;
    return {'authorization': 'Bearer token-1'};
  }
}

void main() {
  test('listModels 解析 id/capabilities 并过滤非法项', () async {
    late http.Request seen;
    final client = ModelGatewayClient(
      modelsUri: Uri.parse(_modelsUri),
      chatCompletionsUri: Uri.parse(_chatUri),
      headers: _Headers().call,
      client: MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'asr-1', 'capabilities': ['asr']},
              {'id': 'text-1', 'capabilities': ['chat', 'refine']},
              {'capabilities': ['chat']},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final models = await client.listModels();

    expect(seen.url.toString(), _modelsUri);
    expect(seen.headers['authorization'], 'Bearer token-1');
    expect(models.map((m) => m.id), ['asr-1', 'text-1']);
    expect(models.last.capabilities, ['chat', 'refine']);
  });

  test('listModels 非 2xx 抛 ModelGatewayException', () async {
    final client = ModelGatewayClient(
      modelsUri: Uri.parse(_modelsUri),
      chatCompletionsUri: Uri.parse(_chatUri),
      headers: _Headers().call,
      client: MockClient((_) async => http.Response('denied', 403)),
    );
    await expectLater(
      client.listModels(),
      throwsA(isA<ModelGatewayException>()
          .having((e) => e.statusCode, 'statusCode', 403)),
    );
  });

  test('chat 发送 model/messages/temperature 并解析 choices[0]', () async {
    late http.Request seen;
    final client = ModelGatewayClient(
      modelsUri: Uri.parse(_modelsUri),
      chatCompletionsUri: Uri.parse(_chatUri),
      headers: _Headers().call,
      client: MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '整理后的文本'}
              }
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final text = await client.chat(
      model: 'text-1',
      messages: const [
        ChatMessage(role: 'system', content: 'system'),
        ChatMessage(role: 'user', content: '原文'),
      ],
      temperature: 0.1,
    );

    expect(seen.url.toString(), _chatUri);
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['model'], 'text-1');
    expect(body['temperature'], 0.1);
    expect(body['stream'], false);
    expect((body['messages'] as List).length, 2);
    expect(text, '整理后的文本');
  });

  test('chat 响应缺 choices 抛异常', () async {
    final client = ModelGatewayClient(
      modelsUri: Uri.parse(_modelsUri),
      chatCompletionsUri: Uri.parse(_chatUri),
      headers: _Headers().call,
      client: MockClient((_) async => http.Response(
          jsonEncode({'choices': []}), 200,
          headers: {'content-type': 'application/json'})),
    );
    await expectLater(
      client.chat(model: 'm', messages: const [
        ChatMessage(role: 'user', content: 'x')
      ]),
      throwsA(isA<ModelGatewayException>()),
    );
  });
}
