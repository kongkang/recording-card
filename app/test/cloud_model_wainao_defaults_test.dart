import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/model_gateway_config.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/auth/oauth_client.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_catalog.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/net/model_provider_store.dart';

import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _NoopSpeechBackend implements AgentSpeechBackend {
  @override
  Stream<AgentSpeechEvent> get events => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {}

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async => false;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> stopSpeaking() async {}
}

Future<OAuthTokenStore> _buildSignedOutTokenStore() async {
  final store = OAuthTokenStore(
    secure: InMemorySecureStore(),
    client: OAuthClient(
      config: kStubOAuthConfig,
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    ),
    config: kStubOAuthConfig,
  );
  await store.bootstrap();
  return store;
}

void main() {
  test('ModelCatalog.textModel 兼容无 capabilities 字段的标准列表并跳过非对话模型', () {
    const catalog = ModelCatalog([
      GatewayModel(id: 'paraformer-asr', capabilities: {'asr'}),
      GatewayModel(id: 'text-embedding-3-small', capabilities: {}),
      GatewayModel(id: 'qwen-plus', capabilities: {}),
    ]);
    expect(catalog.asrModel, 'paraformer-asr');
    expect(catalog.textModel, 'qwen-plus');

    const asrOnly = ModelCatalog([
      GatewayModel(id: 'paraformer-asr', capabilities: {'asr'}),
    ]);
    expect(asrOnly.textModel, isNull);
  });

  test('第三方服务连接后自动预选默认总结模型，且支持保存/清除外脑模型覆盖', () async {
    final secure = InMemorySecureStore();
    final store = ModelProviderStore(
      secureStore: secure,
      clientFactory: () => MockClient((_) async {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'deepseek-reasoner'},
              {'id': 'deepseek-chat'},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(store.dispose);

    final deepseek = await store.connect(
      ModelProvider.deepseek,
      apiKey: 'ds-key',
      baseUrl: '',
    );
    expect(deepseek.summaryModel, 'deepseek-chat');
    await store.selectProvider(ModelProvider.deepseek);
    expect(store.activeProvider, ModelProvider.deepseek);

    await store.saveWainaoOverrides(
      summaryModel: 'qwen-max',
      sceneModels: {ModelScene.agent: 'deepseek-v3'},
    );
    await store.selectProvider(ModelProvider.wainao);

    final reopened = ModelProviderStore(secureStore: secure);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.activeProvider, ModelProvider.wainao);
    expect(reopened.profileFor(ModelProvider.wainao).summaryModel, 'qwen-max');
    expect(
      reopened.profileFor(ModelProvider.wainao).sceneModels[ModelScene.agent],
      'deepseek-v3',
    );

    await reopened.saveWainaoOverrides(summaryModel: '', sceneModels: const {});
    expect(reopened.profileFor(ModelProvider.wainao).summaryModel, isEmpty);
    expect(reopened.profileFor(ModelProvider.wainao).sceneModels, isEmpty);
  });

  test('选外脑且已登录但未先拉目录时：Agent 对话按需补拉默认模型并正常完成', () async {
    final tokens = await buildSignedInTokenStore();
    final providers = ModelProviderStore(secureStore: InMemorySecureStore());
    addTearDown(providers.dispose);
    await providers.selectProvider(ModelProvider.wainao);

    var modelsRequests = 0;
    final chatRequests = <Map<String, dynamic>>[];
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: tokens,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            modelsRequests++;
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'wainao-default-chat'},
                ],
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/chat/completions')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            chatRequests.add(body);
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'role': 'assistant',
                        'content': jsonEncode({
                          'react': '👌',
                          'reply': '已自动加载默认模型并完成回答。',
                        }),
                      },
                    },
                  ],
                }),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('not found', 404);
        }),
      ),
      config: const ModelGatewayConfig(
        baseUrl: kStubApiBase,
        asrModel: '',
        refineModel: '',
      ),
      providers: providers,
    );

    final appStore = AppStore(loadPersistedState: false);
    final agentConfig = AgentConfigStore(store: InMemoryStore());
    await agentConfig.load();
    final worker = AgentHarnessWorker(
      complete: (msgs, {required model, temperature = 0.3, maxTokens = 2048}) =>
          gateway.chat(
            msgs,
            model: model,
            scene: ModelScene.agent,
            temperature: temperature,
            maxTokens: maxTokens,
          ),
      inProcess: true,
    );
    final chat = AgentChatController(
      appStore: appStore,
      agentConfig: agentConfig,
      gateway: gateway,
      speech: _NoopSpeechBackend(),
      worker: worker,
      agentDirResolver: () async => '',
    );
    addTearDown(() async {
      await worker.dispose();
      chat.dispose();
      agentConfig.dispose();
      appStore.dispose();
    });

    await chat.sendMessage('你好，外脑默认模型通了吗？');

    expect(chat.errorMessage, isNull);
    expect(modelsRequests, 1);
    expect(chatRequests, hasLength(1));
    expect(chatRequests.first['model'], 'wainao-default-chat');
    expect(chat.messages.last.text, contains('已自动加载默认模型'));
  });

  test('选外脑但未登录时：提示去登录，不再误报“尚未配置对话模型端点”', () async {
    final tokens = await _buildSignedOutTokenStore();
    final providers = ModelProviderStore(secureStore: InMemorySecureStore());
    addTearDown(providers.dispose);
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: tokens,
        httpClient: MockClient((_) async => http.Response('{}', 401)),
      ),
      config: const ModelGatewayConfig(
        baseUrl: kStubApiBase,
        asrModel: '',
        refineModel: '',
      ),
      providers: providers,
    );
    final appStore = AppStore(loadPersistedState: false);
    final agentConfig = AgentConfigStore(store: InMemoryStore());
    await agentConfig.load();
    final chat = AgentChatController(
      appStore: appStore,
      agentConfig: agentConfig,
      gateway: gateway,
      speech: _NoopSpeechBackend(),
      worker: AgentHarnessWorker(
        complete: (msgs, {required model, temperature = 0.3, maxTokens = 2048}) =>
            gateway.chat(msgs, model: model),
        inProcess: true,
      ),
      agentDirResolver: () async => '',
    );
    addTearDown(() {
      chat.dispose();
      agentConfig.dispose();
      appStore.dispose();
    });

    await chat.sendMessage('试一下提问');

    expect(chat.errorMessage, contains('尚未登录云端账号'));
    expect(chat.errorMessage, isNot(contains('尚未配置对话模型端点')));
  });

  testWidgets('设置页外脑条目可展开查看默认端点、刷新模型目录，第三方连接后直接展示分场景高级配置', (
    tester,
  ) async {
    final tokens = await buildSignedInTokenStore();
    final providers = ModelProviderStore(
      secureStore: InMemorySecureStore(),
      clientFactory: () => MockClient((request) async {
        if (request.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'gpt-4o-mini'},
                {'id': 'gpt-4o'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(providers.dispose);

    var gwModelsCalls = 0;
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: tokens,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            gwModelsCalls++;
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': gwModelsCalls > 1 ? 'qwen-max' : 'deepseek-v3',
                    'capabilities': ['text'],
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      ),
      config: const ModelGatewayConfig(
        baseUrl: kStubApiBase,
        asrModel: '',
        refineModel: '',
      ),
      providers: providers,
    );
    await gateway.discoverModels();

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    await agentConfig.load();
    addTearDown(agentConfig.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: SettingSubPage(
          subId: 'cloud',
          agentConfig: agentConfig,
          modelProviders: providers,
          modelGateway: gateway,
          standalone: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认折叠，不破坏既有页面结构；点击外脑展开详情配置
    expect(find.byKey(const Key('cloud-wainao-endpoint')), findsNothing);
    await tester.tap(find.byKey(const Key('cloud-provider-wainao')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cloud-wainao-endpoint')), findsOneWidget);
    expect(find.textContaining('/api/model-gateway/v1'), findsOneWidget);
    expect(find.textContaining('已登录'), findsOneWidget);
    expect(find.textContaining('跟随后端默认（deepseek-v3）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cloud-wainao-refresh')));
    await tester.pumpAndSettle();
    expect(find.textContaining('跟随后端默认（qwen-max）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cloud-wainao-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-wainao-scene-agent')), findsOneWidget);
    expect(find.byKey(const Key('cloud-wainao-scene-polish')), findsOneWidget);

    // 切换到 OpenAI 并连接后：自动选中 gpt-4o-mini，激活按钮与分场景配置立即就绪
    final openAiRow = find.byKey(const Key('cloud-provider-openai'));
    await tester.ensureVisible(openAiRow);
    await tester.pumpAndSettle();
    await tester.tap(openAiRow);
    await tester.pumpAndSettle();
    final keyField = find.byKey(const Key('cloud-provider-key'));
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, 'sk-test-123');
    final connectBtn = find.byKey(const Key('cloud-provider-connect'));
    await tester.ensureVisible(connectBtn);
    await tester.tap(connectBtn);
    await tester.pumpAndSettle();

    expect(find.text('gpt-4o-mini'), findsOneWidget);
    final advBtn = find.byKey(const Key('cloud-provider-advanced'));
    await tester.ensureVisible(advBtn);
    await tester.tap(advBtn);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-provider-scene-agent')), findsOneWidget);
  });
}
