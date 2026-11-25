import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/model_gateway_config.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/agent/hardware_agent_task_coordinator.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/net/api_exception.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_catalog.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/net/model_provider_store.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';

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

class _NoopChatCompletion implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ModelCatalog.fetch 过滤不可用模型与不可用 chat 通道、识别 thinking.supports_off 且跳过纯生图模型', () async {
    final tokens = await buildSignedInTokenStore();
    final client = AuthorizedHttpClient(
      tokenStore: tokens,
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith('/models'));
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'broken-vision-model',
                'capabilities': ['text', 'vision'],
                'availability': {
                  'available': false,
                  'reasons': ['upstream_down'],
                },
              },
              {
                'id': 'pure-image-gen',
                'capabilities': ['image', 'image-generation'],
                'availability': {'available': true},
              },
              {
                'id': 'chat-disabled-vision',
                'capabilities': ['text', 'vision'],
                'availability': {'available': true},
                'operations': [
                  {
                    'id': 'chat',
                    'availability': {
                      'available': false,
                      'reasons': ['price_invalid'],
                    },
                  },
                ],
              },
              {
                'id': 'deepseek-v4-flash',
                'capabilities': ['text', 'tools'],
                'availability': {'available': true},
                'thinking': {'supported': true, 'supports_off': true},
              },
              {
                'id': 'kimi-k2-6',
                'capabilities': ['text', 'vision'],
                'availability': {'available': true},
                'operations': [
                  {
                    'id': 'chat',
                    'availability': {'available': true, 'reasons': []},
                  },
                ],
                'thinking': {'supported': true, 'supports_off': true},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final catalog = await ModelCatalog.fetch(
      client,
      gatewayBaseUrl: '$kStubApiBase/api/model-gateway/v1',
    );

    expect(catalog.byId('broken-vision-model')?.isChatAvailable, isFalse);
    expect(catalog.byId('chat-disabled-vision')?.isChatAvailable, isFalse);
    expect(catalog.byId('kimi-k2-6')?.thinkingSupportsOff, isTrue);
    expect(catalog.textModel, 'deepseek-v4-flash');
    expect(catalog.visionModel, 'kimi-k2-6');
    expect(catalog.availableVisionModels, ['kimi-k2-6']);
  });

  test('ModelGateway.chat 识图场景携带 thinking:disabled、保底 2048 tokens 且在主候选失败时自动回退次选视觉模型', () async {
    final tokens = await buildSignedInTokenStore();
    final providers = ModelProviderStore(secureStore: InMemorySecureStore());
    addTearDown(providers.dispose);
    await providers.selectProvider(ModelProvider.wainao);

    final chatBodies = <Map<String, dynamic>>[];
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: tokens,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'vision-primary',
                    'capabilities': ['text', 'vision'],
                    'availability': {'available': true},
                    'thinking': {'supported': true, 'supports_off': true},
                  },
                  {
                    'id': 'vision-fallback',
                    'capabilities': ['text', 'vision'],
                    'availability': {'available': true},
                    'thinking': {'supported': true, 'supports_off': true},
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/chat/completions')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            chatBodies.add(body);
            if (body['model'] == 'vision-primary') {
              return http.Response(
                jsonEncode({
                  'error': {
                    'message': 'no available multimodal route',
                    'type': 'not_found_error',
                  },
                }),
                404,
              );
            }
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'role': 'assistant',
                        'content': '桌面上有一台点一机设备。',
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

    final reply = await gateway.chat(
      [
        const ChatMessage.userWithImage(
          '识别照片',
          imageDataUrl: 'data:image/jpeg;base64,/9j/4AAQ',
        ),
      ],
      scene: ModelScene.vision,
      maxTokens: 1024,
    );

    expect(reply, '桌面上有一台点一机设备。');
    expect(chatBodies, hasLength(2));
    expect(chatBodies[0]['model'], 'vision-primary');
    expect(chatBodies[0]['thinking'], {'type': 'disabled'});
    expect(chatBodies[0]['max_tokens'], 2048);
    expect(chatBodies[1]['model'], 'vision-fallback');
    expect(chatBodies[1]['thinking'], {'type': 'disabled'});
    expect(chatBodies[1]['max_tokens'], 2048);
  });

  test('AgentChatController 识图失败时不将孤立「📷 [拍照识别]」写入历史，写入脱敏 error_logs.jsonl 且不污染下一轮文本对话', () async {
    final dir = await Directory.systemTemp.createTemp('rc_vision_err_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final agentDir = '${dir.path}/agent';

    final appStore = AppStore(loadPersistedState: false);
    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    final sentHistories = <List<String>>[];
    final worker = AgentHarnessWorker(
      complete: (msgs, {required model, temperature = 0.3, maxTokens = 2048}) async {
        sentHistories.add([for (final m in msgs) '${m.role}:${m.content}']);
        return jsonEncode({'react': '👌', 'reply': '目前还没有录音记录。'});
      },
      inProcess: true,
    );
    final speech = _NoopSpeechBackend();
    final chat = AgentChatController(
      appStore: appStore,
      agentConfig: cfg,
      speech: speech,
      completion: _NoopChatCompletion(),
      worker: worker,
      visionCompletion: (msgs, {String? model}) async {
        throw const ApiHttpException(
          '识图失败：no available multimodal route',
          statusCode: 404,
          code: 'no_available_route',
        );
      },
      agentDirResolver: () async => agentDir,
    );
    addTearDown(() async {
      await worker.dispose();
      chat.dispose();
      cfg.dispose();
      appStore.dispose();
      await speech.dispose();
    });

    await chat.sendPhotoRecognitionMessage(
      jpegBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
    );

    expect(chat.errorMessage, contains('no available multimodal route'));
    expect(chat.messages, isEmpty);

    final logs = await chat.readRecentErrorLogs();
    expect(logs, hasLength(1));
    expect(logs.first['action'], 'photo_recognize');
    expect(logs.first['statusCode'], 404);
    expect(logs.first['code'], 'no_available_route');

    final sessionsDir = Directory('$agentDir/sessions');
    final sessionFiles = sessionsDir.existsSync()
        ? sessionsDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.jsonl'))
              .toList()
        : const <File>[];
    for (final f in sessionFiles) {
      expect(await f.readAsString(), isNot(contains('📷 [拍照识别]')));
    }

    await chat.sendMessage('现在有多少录音内容？');
    expect(sentHistories, hasLength(1));
    expect(
      sentHistories.single.join('\n'),
      isNot(contains('📷 [拍照识别]')),
    );
    expect(chat.messages.last.text, '目前还没有录音记录。');
  });

  test('HardwareAgentTaskCoordinator 拍照识图报错时将 statusIsError 置为 true 供 UI 完整展示', () async {
    final dir = await Directory.systemTemp.createTemp('rc_coord_err_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    final appStore = AppStore(loadPersistedState: false);
    final gw = FakeCardGateway(
      initialSnapshot: const CardSnapshot(
        batteryLevel: 85,
        isCharging: false,
        wifiOpen: true,
        recording: false,
        fwVersion: '1.1.0',
        fwVersionCode: 815,
        wifiVersion: '',
        wifiVersionCode: 0,
        deviceName: 'DYJ_Q2M34R',
        deviceId: 'dyj-test-1',
        deviceKind: DeviceKind.dyjV1,
        capabilities: HardwareCapabilities.dyjV1,
      ),
      fakeCapturedPhotoBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
    )..dyjTtsSupported = false;
    final device = DeviceStore(gateway: gw);
    await device.restoreLink();
    final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);
    final speech = _NoopSpeechBackend();
    final chat = AgentChatController(
      appStore: appStore,
      agentConfig: cfg,
      speech: speech,
      visionCompletion: (msgs, {String? model}) async {
        throw const ApiHttpException('识图失败：网关无可用多模态模型', statusCode: 404);
      },
      agentDirResolver: () async => '${dir.path}/agent',
    );
    final coord = HardwareAgentTaskCoordinator(
      device: device,
      agentConfig: cfg,
      agentChat: chat,
      liveAudio: liveAudio,
      tempDirResolver: () async => dir,
      postSettleDelay: Duration.zero,
      transientStatusDuration: Duration.zero,
      maxVoiceTaskDuration: Duration.zero,
      transcribeSamples: (samples, {sampleRate = 16000}) async => '',
    );
    addTearDown(() async {
      coord.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      await speech.dispose();
    });

    gw.pushButtonEvent(gesture: 'double_click', receivedAtMs: 10000);
    await device.pollEventsNow();
    await coord.idle;
    await Future<void>.delayed(Duration.zero);

    expect(coord.statusIsError, isTrue);
    expect(coord.statusText, contains('网关无可用多模态模型'));
  });
}
