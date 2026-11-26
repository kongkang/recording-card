import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/model_gateway_config.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/services/net/api_exception.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/net/model_provider_store.dart';

import '../support/model_stub.dart';

const _reply = '{"choices":[{"message":{"content":"OK"}}]}';

void main() {
  test('各场景请求与凭据只发往选中的服务，失败也不回退', () async {
    final providers = ModelProviderStore(
      secureStore: InMemorySecureStore(),
      clientFactory: () => MockClient((request) async {
        expect(request.url.toString(), 'https://vendor.invalid/v1/models');
        expect(request.headers['authorization'], 'Bearer vendor-key');
        return http.Response('{"data":[{"id":"summary"},{"id":"agent"}]}', 200);
      }),
    );
    addTearDown(providers.dispose);
    const custom = ModelProvider.custom;
    final connected = await providers.connect(
      custom,
      apiKey: 'vendor-key',
      baseUrl: 'https://vendor.invalid/v1',
    );
    await providers.saveProfile(
      custom,
      connected.copyWith(
        summaryModel: 'summary',
        sceneModels: {ModelScene.agent: 'agent'},
      ),
    );
    var officialRequests = 0;
    final models = <String>[];
    var rejectRequest = false;
    final messages = [
      const ChatMessage.system('本机提示词和技能'),
      const ChatMessage.user('测试内容'),
    ];
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: await buildSignedInTokenStore(),
        httpClient: MockClient((request) async {
          officialRequests++;
          expect(request.url.host, 'stub.invalid');
          expect(request.headers['authorization'], 'Bearer test-access-token');
          expect(jsonDecode(request.body)['model'], 'refine-test');
          return http.Response(_reply, 200);
        }),
      ),
      config: kStubModelConfig,
      providers: providers,
      providerClient: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://vendor.invalid/v1/chat/completions',
        );
        expect(request.headers['authorization'], 'Bearer vendor-key');
        expect(request.followRedirects, isFalse);
        final body = jsonDecode(request.body);
        expect(body['messages'], messages.map((m) => m.toJson()).toList());
        models.add(body['model'] as String);
        return rejectRequest
            ? http.Response('secret provider body', 401)
            : http.Response(_reply, 200);
      }),
    );

    await providers.selectProvider(custom);
    for (final scene in ModelScene.values) {
      expect(
        await gateway.chat(messages, scene: scene, model: 'old-model'),
        'OK',
      );
    }
    expect(models, [
      'summary',
      'agent',
      'summary',
      'summary',
      'summary',
      'summary',
    ]);
    expect(officialRequests, 0);
    rejectRequest = true;
    await expectLater(
      gateway.chat(messages),
      throwsA(
        isA<ApiHttpException>()
            .having((e) => e.requiresSignIn, 'requiresSignIn', false)
            .having(
              (e) => e.toString(),
              'message',
              isNot(contains('secret provider body')),
            ),
      ),
    );
    expect(officialRequests, 0);

    await providers.selectProvider(ModelProvider.wainao);
    expect(await gateway.chat(messages, model: 'old-model'), 'OK');
    expect(officialRequests, 1);
  });

  test('DeepSeek 总结关闭思考并保留正文预算，Agent 对话沿用服务商默认值', () async {
    final providers = ModelProviderStore(
      secureStore: InMemorySecureStore(),
      clientFactory: () => MockClient(
        (_) async => http.Response('{"data":[{"id":"deepseek-flash"}]}', 200),
      ),
    );
    addTearDown(providers.dispose);
    const deepseek = ModelProvider.deepseek;
    final profile = await providers.connect(
      deepseek,
      apiKey: 'key',
      baseUrl: '',
    );
    await providers.saveProfile(
      deepseek,
      profile.copyWith(summaryModel: 'deepseek-flash'),
    );
    await providers.selectProvider(deepseek);

    final bodies = <Map<String, dynamic>>[];
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(tokenStore: await buildSignedInTokenStore()),
      config: kStubModelConfig,
      providers: providers,
      providerClient: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(_reply, 200);
      }),
    );
    final messages = [const ChatMessage.user('测试内容')];
    await gateway.chat(messages, maxTokens: 1600);
    await gateway.chat(messages, scene: ModelScene.agent, maxTokens: 1600);
    expect(bodies[0]['thinking'], {'type': 'disabled'});
    expect(bodies[0]['max_tokens'], 3200);
    expect(bodies[1].containsKey('thinking'), isFalse);
    expect(bodies[1]['max_tokens'], 1600);
  });

  test('DeepSeek 非 Agent 场景（如 organize）也关闭思考；Agent 对话保持默认', () async {
    final providers = ModelProviderStore(
      secureStore: InMemorySecureStore(),
      clientFactory: () => MockClient(
        (_) async => http.Response('{"data":[{"id":"deepseek-flash"}]}', 200),
      ),
    );
    addTearDown(providers.dispose);
    const deepseek = ModelProvider.deepseek;
    final profile = await providers.connect(
      deepseek,
      apiKey: 'key',
      baseUrl: '',
    );
    await providers.saveProfile(
      deepseek,
      profile.copyWith(summaryModel: 'deepseek-flash'),
    );
    await providers.selectProvider(deepseek);

    final bodies = <Map<String, dynamic>>[];
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(tokenStore: await buildSignedInTokenStore()),
      config: kStubModelConfig,
      providers: providers,
      providerClient: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(_reply, 200);
      }),
    );
    final messages = [const ChatMessage.user('测试内容')];
    await gateway.chat(messages, scene: ModelScene.organize, maxTokens: 1600);
    await gateway.chat(messages, scene: ModelScene.agent, maxTokens: 1600);
    expect(bodies[0]['thinking'], {'type': 'disabled'});
    expect(bodies[0]['max_tokens'], 2048);
    expect(bodies[1].containsKey('thinking'), isFalse);
    expect(bodies[1]['max_tokens'], 1600);
  });

  test('外脑 DeepSeek 系列默认关闭思考，空正文且 finish_reason=length 自动升至 8192 重试一次', () async {
    for (final modelId in const [
      'deepseek-v4-flash',
      'deepseek-deepseek-flash',
      'deepseek-flash',
    ]) {
      final providers = ModelProviderStore(secureStore: InMemorySecureStore());
      addTearDown(providers.dispose);
      await providers.selectProvider(ModelProvider.wainao);

      final bodies = <Map<String, dynamic>>[];
      final gateway = ModelGateway(
        client: AuthorizedHttpClient(
          tokenStore: await buildSignedInTokenStore(),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/models')) {
              return http.Response(
                jsonEncode({
                  'data': [
                    {
                      'id': modelId,
                      'capabilities': ['text'],
                    },
                  ],
                }),
                200,
              );
            }
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            bodies.add(body);
            if (bodies.length == 1) {
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'role': 'assistant', 'content': ''},
                      'finish_reason': 'length',
                    },
                  ],
                  'usage': {
                    'prompt_tokens': 7187,
                    'completion_tokens': 3200,
                    'completion_tokens_details': {'reasoning_tokens': 3200},
                  },
                }),
                200,
              );
            }
            return http.Response(_reply, 200);
          }),
        ),
        config: const ModelGatewayConfig(
          baseUrl: kStubApiBase,
          asrModel: '',
          refineModel: '',
        ),
        providers: providers,
      );

      final out = await gateway.chat([const ChatMessage.user('半小时转写')]);
      expect(out, 'OK');
      expect(bodies.length, 2);
      expect(bodies[0]['thinking'], {'type': 'disabled'});
      expect(bodies[0]['max_tokens'], 3200);
      expect(bodies[1]['thinking'], {'type': 'disabled'});
      expect(bodies[1]['max_tokens'], 8192);
    }
  });

  test('空正文且 finish_reason=length 重试 8192 后仍为空：最多重试一次并给出思考耗尽诊断', () async {
    final providers = ModelProviderStore(secureStore: InMemorySecureStore());
    addTearDown(providers.dispose);
    await providers.selectProvider(ModelProvider.wainao);

    final bodies = <Map<String, dynamic>>[];
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: await buildSignedInTokenStore(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'deepseek-v4-flash',
                    'capabilities': ['text'],
                  },
                ],
              }),
              200,
            );
          }
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': ''},
                  'finish_reason': 'length',
                },
              ],
              'usage': {
                'completion_tokens': bodies.length == 1 ? 3200 : 8192,
                'completion_tokens_details': {
                  'reasoning_tokens': bodies.length == 1 ? 3200 : 8192,
                },
              },
            }),
            200,
          );
        }),
      ),
      config: const ModelGatewayConfig(
        baseUrl: kStubApiBase,
        asrModel: '',
        refineModel: '',
      ),
      providers: providers,
    );

    await expectLater(
      gateway.chat([const ChatMessage.user('超长转写')]),
      throwsA(
        isA<ApiFormatException>()
            .having((e) => e.message, 'message', contains('输出长度上限 8192'))
            .having((e) => e.message, 'message', contains('推理 8192 tokens')),
      ),
    );
    expect(bodies.length, 2);
  });

  test('空正文且 finish_reason=stop：不重试，维持原错误文案', () async {
    final providers = ModelProviderStore(secureStore: InMemorySecureStore());
    addTearDown(providers.dispose);
    await providers.selectProvider(ModelProvider.wainao);

    var chatCalls = 0;
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: await buildSignedInTokenStore(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'deepseek-v4-flash',
                    'capabilities': ['text'],
                  },
                ],
              }),
              200,
            );
          }
          chatCalls++;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': ''},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      ),
      config: const ModelGatewayConfig(
        baseUrl: kStubApiBase,
        asrModel: '',
        refineModel: '',
      ),
      providers: providers,
    );

    await expectLater(
      gateway.chat([const ChatMessage.user('测试')]),
      throwsA(
        isA<ApiFormatException>().having(
          (e) => e.message,
          'message',
          '总结服务返回了空内容',
        ),
      ),
    );
    expect(chatCalls, 1);
  });

  test('自定义地址可连接无需密钥的服务', () async {
    final providers = ModelProviderStore(
      secureStore: InMemorySecureStore(),
      clientFactory: () => MockClient((request) async {
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response('{"data":[{"id":"local-chat"}]}', 200);
      }),
    );
    addTearDown(providers.dispose);
    const custom = ModelProvider.custom;
    final connected = await providers.connect(
      custom,
      apiKey: '',
      baseUrl: 'https://gateway.invalid/v1',
    );
    await providers.saveProfile(
      custom,
      connected.copyWith(summaryModel: 'local-chat'),
    );
    await providers.selectProvider(custom);
    final route = await providers.activeRoute(ModelScene.summary);
    expect(route?.apiKey, isEmpty);
    expect(route?.model, 'local-chat');
  });
}
