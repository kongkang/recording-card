import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/net/api_exception.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/net/model_provider_store.dart';
import 'package:recording_card/services/transcribe/byo_asr_client.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/system_speech_client.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _NoopLocalEngine implements SpeechEngine {
  int localTranscribeCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    localTranscribeCalls++;
    return const AsrResult(
      text: '不应该落入 SenseVoice',
      tokens: [],
      timestampsMs: [],
      audioMs: 1000,
    );
  }

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => [SpeechSpan(0, samples.length)];

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1.0, 0.0, 0.0];

  @override
  Future<void> dispose() async {}
}

class _ApFakeGateway extends FakeCardGateway {
  _ApFakeGateway({
    super.initialSnapshot,
    super.devices,
    super.deviceFiles,
    super.writeDownload,
  });

  @override
  Future<void> deleteFile(String name) async {
    await super.deleteFile(name);
    deviceFiles = deviceFiles.where((f) => f.name != name).toList();
  }
}

const _cardV2Dev = CardDevice(
  id: 'v2-batch2',
  name: 'DYJV2_BATCH2',
  rssi: -40,
);

const _dyjV1Dev = CardDevice(
  id: 'v1-batch2',
  name: 'DYJ_V1_002',
  rssi: -45,
  kind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

CardSnapshot _v2Snapshot({bool recording = false}) => CardSnapshot(
  batteryLevel: 85,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: _cardV2Dev.name,
  deviceId: _cardV2Dev.id,
  deviceKind: DeviceKind.cardV2,
  capabilities: HardwareCapabilities.cardV2,
);

CardSnapshot _v1Snapshot() => const CardSnapshot(
  batteryLevel: 90,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '0.8.14',
  fwVersionCode: 814,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_V1_002',
  deviceId: 'v1-batch2',
  deviceKind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

void main() {
  group('Batch 2 Confirmed Features', () {
    test('ByoAsrClient URL 校验与 RoutingSpeechEngine 路由 + 热词注入', () async {
      expect(
        ByoAsrClient.resolveTranscriptionsUri('http://192.168.1.20:8000/v1')
            .toString(),
        'http://192.168.1.20:8000/v1/audio/transcriptions',
      );
      expect(
        ByoAsrClient.resolveTranscriptionsUri('https://asr.corp.internal/')
            .toString(),
        'https://asr.corp.internal/v1/audio/transcriptions',
      );
      expect(
        () => ByoAsrClient.resolveTranscriptionsUri('ftp://bad.host'),
        throwsA(isA<AsrException>()),
      );

      final capturedBodies = <String>[];
      final capturedAuth = <String?>[];
      final capturedUrls = <Uri>[];
      final mockHttp = MockClient.streaming((request, bodyStream) async {
        capturedUrls.add(request.url);
        capturedAuth.add(request.headers['Authorization']);
        final raw = await bodyStream.toBytes();
        capturedBodies.add(utf8.decode(raw, allowMalformed: true));
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'text': '点一机录音卡测试通过'}))),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      addTearDown(cfg.dispose);
      await cfg.updateByoAsrConfig(
        url: 'http://192.168.1.50:8000/v1',
        model: 'Qwen3-ASR-0.6B',
        apiKey: 'secret-token',
        connected: true,
      );
      await cfg.addHotwordsFromRaw('点一机, 录音卡V2');

      final local = _NoopLocalEngine();
      final engine = RoutingSpeechEngine(
        localEngine: local,
        systemSpeech: SystemSpeechClient(),
        byoAsr: ByoAsrClient(httpClient: mockHttp),
        agentConfig: cfg,
      );
      await engine.load(
        modelPath: kByoCloudSentinelModelPath,
        tokensPath: '',
        language: 'zh',
      );
      final res = await engine.transcribe(Float32List(1600), sampleRate: 16000);
      expect(res.text, '点一机录音卡测试通过');
      expect(local.localTranscribeCalls, 0);
      expect(
        capturedUrls.single.toString(),
        'http://192.168.1.50:8000/v1/audio/transcriptions',
      );
      expect(capturedAuth.single, 'Bearer secret-token');
      expect(capturedBodies.single, contains('Qwen3-ASR-0.6B'));
      expect(capturedBodies.single, contains('点一机, 录音卡V2'));
      expect(capturedBodies.single, contains('audio.wav'));

      // 热词只附加到 effectivePromptFor，不污染 promptFor 编辑器绑定文本。
      final rawPolish = cfg.promptFor('polish');
      expect(rawPolish, isNot(contains('点一机')));
      expect(cfg.effectivePromptFor('polish'), contains('点一机、录音卡V2'));
      expect(cfg.effectivePromptFor('summary'), contains('点一机、录音卡V2'));
    });

    testWidgets('SettingSubPage(local): 自建服务配置与热词增删', (tester) async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      addTearDown(cfg.dispose);

      final mockByo = ByoAsrClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          await bodyStream.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'text': 'ok'}))),
            200,
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: SettingSubPage(
            subId: 'local',
            agentConfig: cfg,
            byoAsrClient: mockByo,
            standalone: true,
          ),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('asr-opt-byo-cloud')));
      await tester.tap(find.byKey(const Key('asr-opt-byo-cloud')));
      await tester.pump();
      expect(find.byKey(const Key('nc-byo-asr-card')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('byo-asr-url-inp')),
        'http://192.168.2.10:8080/v1',
      );
      await tester.enterText(
        find.byKey(const Key('byo-asr-model-inp')),
        'faster-whisper-large-v3',
      );
      await tester.ensureVisible(find.byKey(const Key('byo-asr-save-btn')));
      await tester.tap(find.byKey(const Key('byo-asr-save-btn')));
      await tester.pump();
      await tester.pump();

      expect(cfg.byoAsrConnected, isTrue);
      expect(cfg.preferredAsrEngine, 'byo_cloud');
      expect(find.byKey(const Key('byo-asr-status')), findsOneWidget);
      expect(find.text('已连接'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('hotword-inp')));
      await tester.enterText(
        find.byKey(const Key('hotword-inp')),
        '点一机, 声纹聚簇',
      );
      await tester.tap(find.byKey(const Key('hotword-add-btn')));
      await tester.pump();

      expect(cfg.hotwords, ['点一机', '声纹聚簇']);
      await tester.tap(find.byKey(const Key('hotword-del-0')));
      await tester.pump();
      expect(cfg.hotwords, ['声纹聚簇']);
    });

    testWidgets('仅本机模式: 开关不占 sw-4、拦截云端并阻断固件云同步', (tester) async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      addTearDown(cfg.dispose);
      final settings = SettingsStore(store: InMemoryStore());
      await settings.load();
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: SettingPage(settings: settings, agentConfig: cfg),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('sw-4')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('set-privacy-lock-row')),
        200,
      );
      await tester.tap(find.byKey(const Key('sw-privacy-lock')));
      await tester.pump();
      expect(cfg.localOnlyMode, isTrue);

      // 1) ModelGateway 在仅本机模式下阻断请求。
      final tokens = await buildSignedInTokenStore();
      final gw = ModelGateway(
        client: AuthorizedHttpClient(
          tokenStore: tokens,
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
        config: kStubModelConfig,
        localOnlyCheck: () => cfg.localOnlyMode,
      );
      expect(gw.isCloudEnabled, isFalse);
      expect(gw.readyFor(ModelScene.summary), isFalse);
      await expectLater(
        () => gw.chat([const ChatMessage.user('hi')]),
        throwsA(isA<ApiNotConfiguredException>()),
      );

      // 2) DeviceStore 阻止 STA 云上传，且切换 localOnlyMode 时通知已连 V2 设备。
      final cardGw = FakeCardGateway(initialSnapshot: _v2Snapshot());
      final devStore = DeviceStore(gateway: cardGw, agentConfig: cfg);
      addTearDown(devStore.dispose);
      await devStore.connectTo(_cardV2Dev);
      await devStore.syncNow();
      expect(cardGw.startSyncCalled, isFalse);
      expect(devStore.syncError, contains('仅本机模式'));

      await cfg.setLocalOnlyMode(false);
      await tester.pump();
      expect(cardGw.deviceConfigs['local_only'], '0');
      await cfg.setLocalOnlyMode(true);
      await tester.pump();
      expect(cardGw.deviceConfigs['local_only'], '1');
    });

    testWidgets('非 V2 设备主弹层隐藏热点快传与录音设置', (tester) async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      addTearDown(cfg.dispose);

      final v1Gw = FakeCardGateway(
        initialSnapshot: _v1Snapshot(),
        devices: const [_dyjV1Dev],
      );
      final v1Store = DeviceStore(gateway: v1Gw, agentConfig: cfg);
      await v1Store.connectTo(_dyjV1Dev);
      await pumpShell(
        tester,
        device: v1Store,
        store: AppStore(events: const [], loadPersistedState: false),
      );
      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('dev-main')), findsOneWidget);
      expect(find.byKey(const Key('card-v2-ap-fast-btn')), findsNothing);
      expect(find.byKey(const Key('card-v2-guard-row')), findsNothing);
      await tester.tap(find.byKey(const Key('sheet-close')));
      await tester.pump();
    });

    testWidgets('CardV2 热点快传、录音设置下发分片时长及连续静音自动停录', (tester) async {
      var now = DateTime(2026, 11, 26, 10, 0);
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      addTearDown(cfg.dispose);

      final v2Gw = _ApFakeGateway(
        initialSnapshot: _v2Snapshot(recording: false),
        devices: const [_cardV2Dev],
        deviceFiles: const [
          CardFile(name: 'REC_01.APM', size: 12000),
        ],
        writeDownload: true,
      );
      final v2Store = DeviceStore(
        gateway: v2Gw,
        agentConfig: cfg,
        now: () => now,
      );
      final appStore = AppStore(events: const [], loadPersistedState: false);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(v2Store.dispose);
      addTearDown(appStore.dispose);

      await v2Store.connectTo(_cardV2Dev);
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          scrollBehavior: const RCScrollBehavior(),
          home: AppShell(
            store: appStore,
            device: v2Store,
            agentConfig: cfg,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('card-v2-ap-fast-btn')), findsOneWidget);
      expect(find.byKey(const Key('card-v2-guard-row')), findsOneWidget);
      expect(find.text('待传 1 段'), findsOneWidget);

      await tester.tap(find.byKey(const Key('card-v2-ap-fast-btn')));
      await tester.pump();
      for (var i = 0; i < 40 && v2Store.apFastSyncBusy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      expect(v2Store.apFastSyncBusy, isFalse);
      expect(v2Store.apFastSyncError, isNull);
      expect(
        v2Gw.callLog,
        containsAllInOrder([
          'ap.start',
          'ap.files:192.168.4.1:80',
          'ap.download:REC_01.APM',
          'ap.stop',
        ]),
      );
      expect(v2Gw.displayShowCalls, isNotEmpty);
      expect(find.text('已同步'), findsOneWidget);

      await tester.tap(find.byKey(const Key('card-v2-guard-row')));
      await tester.pump();
      expect(find.byKey(const Key('dev-v2cfg')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-slice-opt-5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('card-silence-opt-30')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('v2cfg-back')));
      await tester.pump();
      expect(find.text('5 分钟 · 静音 30 分停'), findsOneWidget);

      await v2Store.toggleRecording();
      await tester.pump();
      expect(v2Gw.lastStartDurationSecs, 300);

      // 喂入静音 PCM 并在 31 分钟后触发自动停录
      final silentPcm = Uint8List(3200);
      v2Store.onRealtimePcmSamplesForSilenceCheck(silentPcm);
      now = now.add(const Duration(minutes: 31));
      v2Store.onRealtimePcmSamplesForSilenceCheck(silentPcm);
      await tester.pump();
      await tester.pump();

      expect(v2Store.isRecording, isFalse);
      expect(v2Store.silenceStopNotice, '静音满 30 分钟，已自动停录');
    });
  });
}
