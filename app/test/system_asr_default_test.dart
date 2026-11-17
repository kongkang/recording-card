import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/model_manager_controller.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/system_speech_client.dart';

import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _FakeModelInstaller extends ModelInstaller {
  _FakeModelInstaller({
    Directory? root,
    Set<String>? initiallyInstalled,
  }) : installedIds = {...?initiallyInstalled},
       _fakeRoot = root ?? Directory('/fake-models'),
       super(root: root ?? Directory('/fake-models'));

  final Directory _fakeRoot;
  final Set<String> installedIds;
  final List<String> installedFromCalls = [];
  final List<String> bundledCalls = [];
  final List<String> deletedCalls = [];

  @override
  Future<Directory> root() async => _fakeRoot;

  @override
  Future<String> filePath(ModelSpec spec, ModelFileSpec file) async =>
      '${_fakeRoot.path}/${spec.id}/${file.relPath}';

  @override
  Future<String?> resolve(ModelSpec spec, String relPath) async =>
      installedIds.contains(spec.id)
          ? '${_fakeRoot.path}/${spec.id}/$relPath'
          : null;

  @override
  Future<ModelStatus> status(ModelSpec spec) async {
    final ok = installedIds.contains(spec.id);
    return ModelStatus(
      spec: spec,
      installed: ok,
      presentBytes: ok ? spec.totalBytes : 0,
      missing: ok ? const [] : [for (final f in spec.files) f.relPath],
    );
  }

  @override
  Future<String> ensureBundled(ModelSpec spec) async {
    bundledCalls.add(spec.id);
    installedIds.add(spec.id);
    return filePath(spec, spec.files.first);
  }

  @override
  Future<void> installFrom(
    ModelSpec spec, {
    required Uri baseUri,
    void Function(double progress, String text)? onProgress,
    bool verify = true,
    bool Function()? isCancelled,
  }) async {
    installedFromCalls.add(spec.id);
    onProgress?.call(0.5, '下载 ${spec.displayName}');
    installedIds.add(spec.id);
    onProgress?.call(1.0, '完成');
  }

  @override
  Future<void> verifyInstalledFiles(ModelSpec spec) async {}

  @override
  Future<void> delete(ModelSpec spec) async {
    deletedCalls.add(spec.id);
    installedIds.remove(spec.id);
  }
}

class _StubVadAndSpkLocalEngine implements SpeechEngine {
  int localLoadCalls = 0;
  int localTranscribeCalls = 0;
  int vadLoadCalls = 0;
  int detectCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {
    localLoadCalls++;
  }

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    localTranscribeCalls++;
    return const AsrResult(
      text: '不应该走 SenseVoice',
      tokens: [],
      timestampsMs: [],
      audioMs: 1000,
    );
  }

  @override
  Future<void> loadVad(String vadPath) async {
    vadLoadCalls++;
  }

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    detectCalls++;
    return [SpeechSpan(0, samples.length)];
  }

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1, 0, 0];

  @override
  Future<void> dispose() async {}
}

void main() {
  late InMemoryStore kv;
  late AgentConfigStore agentConfig;

  setUp(() async {
    kv = InMemoryStore();
    agentConfig = AgentConfigStore(store: kv);
    await agentConfig.load();
  });

  tearDown(() {
    agentConfig.dispose();
  });

  Widget wrap(Widget child) =>
      MaterialApp(theme: testTheme(), home: Scaffold(body: child));

  Future<void> flushAsync(WidgetTester tester) async {
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  group('iOS 26+ 默认系统内置免下载即用与 SenseVoice 按需切换', () {
    testWidgets(
      '(a) iOS 26+ autoEnsureInstalled 仅准备 VAD + CAM++，绝不下载 SenseVoice',
      (tester) async {
        final installer = _FakeModelInstaller();
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 26,
            supportsModernSystemAsr: true,
            authStatus: 'authorized',
          ),
        );
        final ctrl = ModelManagerController(
          installer: installer,
          systemSpeech: systemSpeech,
          agentConfig: agentConfig,
          baseUrl: 'https://models.example.test',
        );
        addTearDown(ctrl.dispose);

        await ctrl.autoEnsureInstalled();

        expect(installer.bundledCalls, [sileroVadSpec.id]);
        expect(installer.installedFromCalls, [campplusEmbeddingSpec.id]);
        expect(
          installer.installedFromCalls.contains(senseVoiceSpec.id),
          isFalse,
        );
        expect(ctrl.supportsSystemAsr, isTrue);
        expect(ctrl.selectedEngine, LocalAsrEngineMode.system);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(ctrl.asrReady, isFalse);
        expect(ctrl.speakerReady, isTrue);
        expect(ctrl.settingSummaryLabel, '系统内置 · 即用');
        expect(ctrl.statusFor(senseVoiceSpec)?.installed, isFalse);

        // 一级 Setting 页摘要校验
        final settings = SettingsStore(store: InMemoryStore());
        addTearDown(settings.dispose);
        await tester.pumpWidget(
          wrap(
            SettingPage(
              settings: settings,
              modelManager: ctrl,
              agentConfig: agentConfig,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final svLocal = tester.widget<Text>(find.byKey(const Key('sv-local')));
        expect(svLocal.data, '系统内置 · 即用');

        // 二级本地语音引擎页状态校验
        await tester.pumpWidget(
          wrap(
            SettingSubPage(
              subId: 'local',
              agentConfig: agentConfig,
              modelManager: ctrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('local-status-card')), findsOneWidget);
        expect(find.text('本地转写已就绪'), findsOneWidget);
        expect(find.text('系统内置生效中'), findsOneWidget);
        expect(find.byKey(const Key('model-install-all')), findsNothing);
        expect(find.byKey(const Key('asr-engine-group')), findsOneWidget);
        expect(find.byKey(const Key('asr-opt-system')), findsOneWidget);
        expect(find.byKey(const Key('asr-opt-sensevoice')), findsOneWidget);
        expect(find.byKey(const Key('model-dl-asr')), findsOneWidget);
        expect(find.text('下载并启用（~228 MB）'), findsOneWidget);
      },
    );

    testWidgets(
      '(b1) iOS 15-25 不自动下载 SenseVoice，引导手动下载并禁用系统选项',
      (tester) async {
        final installer = _FakeModelInstaller();
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 18,
            supportsModernSystemAsr: false,
            authStatus: 'notDetermined',
          ),
        );
        final ctrl = ModelManagerController(
          installer: installer,
          systemSpeech: systemSpeech,
          agentConfig: agentConfig,
          baseUrl: 'https://models.example.test',
        );
        addTearDown(ctrl.dispose);

        await ctrl.autoEnsureInstalled();

        expect(
          installer.installedFromCalls.contains(senseVoiceSpec.id),
          isFalse,
        );
        expect(ctrl.supportsSystemAsr, isFalse);
        expect(ctrl.effectiveAsrMode, 'pending');
        expect(ctrl.settingSummaryLabel, '推荐下载增强模型');

        await tester.pumpWidget(
          wrap(
            SettingSubPage(
              subId: 'local',
              agentConfig: agentConfig,
              modelManager: ctrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('待启用本地转写'), findsOneWidget);
        expect(find.text('当前环境不可用'), findsOneWidget);
        expect(find.textContaining('低于 iOS 26'), findsAtLeastNWidgets(1));

        // 点灰态系统选项不得切过去
        await tester.tap(find.byKey(const Key('asr-opt-system')));
        await tester.pumpAndSettle();
        expect(ctrl.effectiveAsrMode, 'pending');

        // 手动下载后立即启用 SenseVoice
        await tester.tap(find.byKey(const Key('model-install-all')));
        await flushAsync(tester);

        expect(installer.installedFromCalls, contains(senseVoiceSpec.id));
        expect(ctrl.effectiveAsrMode, 'sensevoice');
        expect(ctrl.settingSummaryLabel, 'SenseVoice · 已就绪');
        expect(find.text('SenseVoice 生效中'), findsOneWidget);
        expect(find.byKey(const Key('model-install-all')), findsNothing);
      },
    );

    testWidgets(
      '(b2) Android 同样不自动下载 SenseVoice，提示厂商内置评估中并引导手动下载',
      (tester) async {
        final installer = _FakeModelInstaller();
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'android',
            osMajorVersion: 14,
            supportsModernSystemAsr: false,
          ),
        );
        final ctrl = ModelManagerController(
          installer: installer,
          systemSpeech: systemSpeech,
          agentConfig: agentConfig,
          baseUrl: 'https://models.example.test',
        );
        addTearDown(ctrl.dispose);

        await ctrl.autoEnsureInstalled();
        expect(ctrl.effectiveAsrMode, 'pending');
        expect(ctrl.settingSummaryLabel, '推荐下载增强模型');

        await tester.pumpWidget(
          wrap(
            SettingSubPage(
              subId: 'local',
              agentConfig: agentConfig,
              modelManager: ctrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Android 各厂商内置离线接口'), findsAtLeastNWidgets(1));
        expect(find.text('推荐方案'), findsOneWidget);

        await tester.ensureVisible(find.byKey(const Key('model-dl-asr')));
        await tester.tap(find.byKey(const Key('model-dl-asr')));
        await flushAsync(tester);

        expect(ctrl.effectiveAsrMode, 'sensevoice');
        expect(ctrl.settingSummaryLabel, 'SenseVoice · 已就绪');
      },
    );

    testWidgets(
      '(c) iOS 26+ 双引擎切换持久化与删除 SenseVoice 自动回退系统默认',
      (tester) async {
        final installer = _FakeModelInstaller(
          initiallyInstalled: {sileroVadSpec.id, campplusEmbeddingSpec.id},
        );
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 26,
            supportsModernSystemAsr: true,
            authStatus: 'authorized',
          ),
        );
        final ctrl = ModelManagerController(
          installer: installer,
          systemSpeech: systemSpeech,
          agentConfig: agentConfig,
          baseUrl: 'https://models.example.test',
        );
        addTearDown(ctrl.dispose);
        await ctrl.refresh();

        await tester.pumpWidget(
          wrap(
            SettingSubPage(
              subId: 'local',
              agentConfig: agentConfig,
              modelManager: ctrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. 选 SenseVoice 触发按需下载并切为 SenseVoice + 持久化
        await tester.ensureVisible(find.byKey(const Key('asr-opt-sensevoice')));
        await tester.tap(find.byKey(const Key('asr-opt-sensevoice')));
        await flushAsync(tester);
        expect(installer.installedFromCalls, [senseVoiceSpec.id]);
        expect(ctrl.effectiveAsrMode, 'sensevoice');
        expect(agentConfig.preferredAsrEngine, 'sensevoice');

        final reloaded = AgentConfigStore(store: kv);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.preferredAsrEngine, 'sensevoice');

        // 2. 切回系统默认
        await tester.ensureVisible(find.byKey(const Key('asr-opt-system')));
        await tester.tap(find.byKey(const Key('asr-opt-system')));
        await flushAsync(tester);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(agentConfig.preferredAsrEngine, 'system');

        // 3. 再次点 SenseVoice（已下载，直接切换不再重复下载）
        await tester.ensureVisible(find.byKey(const Key('asr-opt-sensevoice')));
        await tester.tap(find.byKey(const Key('asr-opt-sensevoice')));
        await flushAsync(tester);
        expect(installer.installedFromCalls.length, 1);
        expect(ctrl.effectiveAsrMode, 'sensevoice');

        // 4. 删除 SenseVoice 后提示释放 228 MB 且自动回退系统内置
        final delBtn = find.byKey(const Key('model-delete-sensevoice-small-int8'));
        await tester.ensureVisible(delBtn);
        await tester.tap(delBtn);
        await tester.pumpAndSettle();

        final dialog = find.byKey(const Key('model-delete-confirm-dialog'));
        expect(dialog, findsOneWidget);
        expect(
          find.descendant(of: dialog, matching: find.textContaining('228 MB')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: dialog,
            matching: find.textContaining('系统默认模型'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('model-delete-confirm-btn')));
        await flushAsync(tester);

        expect(installer.deletedCalls, contains(senseVoiceSpec.id));
        expect(ctrl.statusFor(senseVoiceSpec)?.installed, isFalse);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(agentConfig.preferredAsrEngine, 'system');
        expect(ctrl.settingSummaryLabel, '系统内置 · 即用');
        expect(find.text('系统内置生效中'), findsOneWidget);
      },
    );
  });

  group('端到端免 SenseVoice 系统内置转写管线', () {
    test(
      '(d) 无 SenseVoice 文件时 InstalledSpeechModelProvider + RoutingSpeechEngine + RecordingPipeline 完整出稿',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final realRoot = await Directory.systemTemp.createTemp('rc-sys-asr-');
        addTearDown(() async {
          if (await realRoot.exists()) {
            await realRoot.delete(recursive: true);
          }
        });

        // 仅内置随包 Silero VAD，磁盘上没有任何 SenseVoice 文件
        final realInstaller = ModelInstaller(root: realRoot);
        await realInstaller.ensureBundled(sileroVadSpec);
        expect((await realInstaller.status(senseVoiceSpec)).installed, isFalse);

        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 26,
            supportsModernSystemAsr: true,
            authStatus: 'authorized',
          ),
          requestAuthOverride: () async => 'authorized',
          transcribeOverride: (samples, sampleRate, language) async {
            expect(samples, isNotEmpty);
            expect(sampleRate, 16000);
            return AsrResult(
              text: '今天先用系统内置模型直接转写',
              tokens: const ['今', '天', '转', '写'],
              timestampsMs: const [100, 300, 700, 1100],
              audioMs: samples.length * 1000 ~/ sampleRate,
              lang: 'zh-CN',
            );
          },
        );

        final controller = ModelManagerController(
          installer: realInstaller,
          systemSpeech: systemSpeech,
          agentConfig: agentConfig,
          baseUrl: '',
        );
        addTearDown(controller.dispose);
        await controller.refresh();
        expect(controller.effectiveAsrMode, 'system');

        final models = InstalledSpeechModelProvider(
          realInstaller,
          useSystemAsr: () async => controller.effectiveAsrMode == 'system',
        );
        final paths = await models.resolve();
        expect(paths, isNotNull);
        expect(paths!.usesSystemAsr, isTrue);
        expect(paths.canTranscribe, isTrue);
        expect(paths.asrModelPath, kSystemSpeechSentinelModelPath);

        final stubLocal = _StubVadAndSpkLocalEngine();
        final routingEngine = RoutingSpeechEngine(
          localEngine: stubLocal,
          systemSpeech: systemSpeech,
        );

        final gateway = FakeCardGateway()
          ..writeDownload = true
          ..transcodeSeconds = 6
          ..deviceFiles = [
            const CardFile(
              name: 'SYS001.APM',
              size: 1000,
              startAtSec: 1730000000,
              session: 'S1',
              seq: 1,
              synced: true,
            ),
          ];
        final recStore = RecordingStore(
          root: realRoot,
          jsonStore: JsonStore(store: InMemoryStore()),
        );
        final pipeline = RecordingPipeline(
          gateway: gateway,
          store: recStore,
          engine: routingEngine,
          models: models,
          agentConfig: agentConfig,
        );

        final report = await pipeline.sync();
        expect(report.failed, 0);
        expect(report.ready, 1);

        expect(routingEngine.activeIsSystem, isTrue);
        expect(stubLocal.vadLoadCalls, greaterThan(0));
        expect(stubLocal.detectCalls, greaterThan(0));
        expect(stubLocal.localLoadCalls, 0);
        expect(stubLocal.localTranscribeCalls, 0);

        final rec = (await recStore.loadAll(refresh: true)).single;
        expect(rec.stage, RecordingStage.ready);
        expect(rec.utterances, isNotEmpty);
        expect(rec.utterances.first.text, '今天先用系统内置模型直接转写');
      },
    );

    test('未授与系统语音识别权限时如实失败，不编造转写结果', () async {
      final installer = _FakeModelInstaller(
        initiallyInstalled: {sileroVadSpec.id},
      );
      final deniedClient = SystemSpeechClient(
        requestAuthOverride: () async => 'denied',
      );
      final routing = RoutingSpeechEngine(
        localEngine: _StubVadAndSpkLocalEngine(),
        systemSpeech: deniedClient,
      );

      final models = InstalledSpeechModelProvider(
        installer,
        useSystemAsr: () async => true,
      );
      final paths = await models.resolve();
      expect(paths, isNotNull);

      await expectLater(
        routing.load(modelPath: paths!.asrModelPath, tokensPath: paths.tokensPath),
        throwsA(
          isA<AsrException>().having(
            (e) => e.message,
            'message',
            contains('未开启系统语音识别权限'),
          ),
        ),
      );
    });
  });
}
