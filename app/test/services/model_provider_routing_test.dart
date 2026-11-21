import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
