import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  void expectNoCrossPlatformText(
    WidgetTester tester, {
    required List<String> forbidden,
  }) {
    final texts = <String>[];
    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      final raw = w.data ?? w.textSpan?.toPlainText() ?? '';
      if (raw.isNotEmpty) texts.add(raw);
    }
    for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
      final raw = w.text.toPlainText();
      if (raw.isNotEmpty) texts.add(raw);
    }
    final joined = texts.join('\n');
    for (final bad in forbidden) {
      expect(
        joined,
        isNot(contains(bad)),
        reason: '界面不应跨平台出现 "$bad"，实际文本：\n$joined',
      );
    }
  }

  group('系统内置 ASR 默认策略、Android 多品牌检测与平台隔离 UI', () {
    testWidgets(
      '(a) iOS 26+ autoEnsureInstalled 仅准备 VAD + CAM++，绝不下载 SenseVoice',
      (tester) async {
        final installer = _FakeModelInstaller();
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 26,
            brandId: 'apple',
            deviceSummary: 'iPhone · iOS 26',
            engineName: 'iOS 系统内置模型（SpeechAnalyzer）',
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
        expect(svLocal.data, '系统转写');

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
        expect(find.textContaining('SpeechAnalyzer'), findsNothing);
        await tester.tap(find.byKey(const Key('local-engine-help')));
        await tester.pumpAndSettle();
        expect(find.textContaining('SpeechAnalyzer'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('本地转写已就绪'), findsOneWidget);
        expect(find.byKey(const Key('model-install-all')), findsNothing);
        expect(find.byKey(const Key('asr-engine-group')), findsOneWidget);
        expect(find.byKey(const Key('asr-opt-system')), findsOneWidget);
        expect(find.byKey(const Key('asr-opt-sensevoice')), findsOneWidget);
        expect(find.byKey(const Key('model-dl-asr')), findsOneWidget);
        expect(find.text('下载并启用'), findsOneWidget);
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['Android', 'Bixby', 'HyperOS'],
        );
      },
    );

    testWidgets(
      '(b1) iOS 15-25 隐藏不可用的系统模型选项，引导手动下载并保持平台纯净',
      (tester) async {
        final installer = _FakeModelInstaller();
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 18,
            brandId: 'apple',
            deviceSummary: 'iPhone · iOS 18',
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

        expect(find.text('等待下载转写模型'), findsOneWidget);
        expect(find.byKey(const Key('asr-opt-system')), findsNothing);
        expect(find.byKey(const Key('asr-opt-sensevoice')), findsOneWidget);
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['Android', 'Bixby', 'HyperOS'],
        );

        // 手动下载后立即启用 SenseVoice
        await tester.tap(find.byKey(const Key('model-install-all')));
        await flushAsync(tester);

        expect(installer.installedFromCalls, contains(senseVoiceSpec.id));
        expect(ctrl.effectiveAsrMode, 'sensevoice');
        expect(ctrl.settingSummaryLabel, 'SenseVoice · 已就绪');
        expect(find.text('本地转写已就绪'), findsOneWidget);
        expect(find.byKey(const Key('model-install-all')), findsNothing);
      },
    );

    testWidgets(
      '(b2) Android 13+ GMS 机型默认启用系统端侧引擎，支持拉取中文语言包与双引擎切换回退且零 iOS 文案',
      (tester) async {
        final installer = _FakeModelInstaller();
        var packInstalled = false;
        final downloadCalls = <String>[];
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => SystemSpeechCapabilities(
            platform: 'android',
            osMajorVersion: 15,
            sdkInt: 35,
            brandId: 'pixel',
            deviceSummary: 'Google Pixel 9 · Android 15',
            engineName: 'Google 端侧离线语音引擎',
            onDeviceServicePackage: 'com.google.android.tts',
            supportsModernSystemAsr: true,
            offlinePackInstalled: packInstalled,
            canDownloadOfflinePack: !packInstalled,
            authStatus: 'granted',
          ),
          downloadModelOverride: (lang) async {
            downloadCalls.add(lang);
            packInstalled = true;
            return true;
          },
        );
        final ctrl = ModelManagerController(
          installer: installer,
          systemSpeech: systemSpeech,
          agentConfig: agentConfig,
          baseUrl: 'https://models.example.test',
        );
        addTearDown(ctrl.dispose);

        await ctrl.autoEnsureInstalled();

        expect(installer.installedFromCalls, [campplusEmbeddingSpec.id]);
        expect(ctrl.supportsSystemAsr, isTrue);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(ctrl.settingSummaryLabel, '系统内置 · 即用');

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

        expect(find.textContaining('Google Pixel 9'), findsNothing);
        expect(find.byKey(const Key('asr-opt-system')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('asr-opt-system')),
            matching: find.text('系统转写'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('model-dl-sys-pack')), findsOneWidget);
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['iOS', 'SpeechAnalyzer', 'iPhone'],
        );

        // 点击拉取系统中文离线包后，按钮消失
        await tester.tap(find.byKey(const Key('model-dl-sys-pack')));
        await flushAsync(tester);
        expect(downloadCalls, ['zh']);
        expect(find.byKey(const Key('model-dl-sys-pack')), findsNothing);

        // 切换并按需下载 SenseVoice，再删除 SenseVoice 自动回退为 Google 端侧离线语音引擎
        await tester.ensureVisible(find.byKey(const Key('asr-opt-sensevoice')));
        await tester.tap(find.byKey(const Key('asr-opt-sensevoice')));
        await flushAsync(tester);
        expect(ctrl.effectiveAsrMode, 'sensevoice');

        final delBtn = find.byKey(const Key('model-delete-sensevoice-small-int8'));
        await tester.ensureVisible(delBtn);
        await tester.tap(delBtn);
        await tester.pumpAndSettle();

        final dialog = find.byKey(const Key('model-delete-confirm-dialog'));
        expect(
          find.descendant(
            of: dialog,
            matching: find.textContaining('使用系统转写'),
          ),
          findsOneWidget,
        );
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['iOS', 'SpeechAnalyzer', 'iPhone'],
        );

        await tester.tap(find.byKey(const Key('model-delete-confirm-btn')));
        await flushAsync(tester);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(ctrl.settingSummaryLabel, '系统内置 · 即用');
      },
    );

    testWidgets(
      '(b2-compat) Android 兼容方案层（三星 Galaxy 默认 Bixby 但本机存在 Google 端侧服务）优先显示兼容方案且零 iOS 文案',
      (tester) async {
        final installer = _FakeModelInstaller();
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'android',
            osMajorVersion: 15,
            sdkInt: 35,
            brandId: 'samsung',
            deviceSummary: '三星 Galaxy S24 · One UI',
            engineName: '三星 Galaxy 兼容方案（直连 Google 端侧语音）',
            onDeviceServicePackage: 'com.google.android.tts',
            resolutionStrategy: 'compat_service',
            compatServiceComponent:
                'com.google.android.tts/com.google.android.apps.speech.tts.googletts.service.GoogleTTSRecognitionService',
            compatDescription:
                '已绕开三星 Bixby 语音组件，直连本机已安装的 Google 端侧离线语音服务，免下载 228 MB 模型即可离线转写。',
            detectedServices: ['com.google.android.tts', 'com.samsung.android.bixby.agent'],
            supportsModernSystemAsr: true,
            offlinePackInstalled: true,
            canDownloadOfflinePack: false,
            authStatus: 'granted',
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

        expect(installer.installedFromCalls, [campplusEmbeddingSpec.id]);
        expect(ctrl.supportsSystemAsr, isTrue);
        expect(ctrl.systemCapabilities.isCompatService, isTrue);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(ctrl.settingSummaryLabel, '兼容方案 · 即用');

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

        expect(find.byKey(const Key('asr-opt-system')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('asr-opt-system')),
            matching: find.text('系统转写'),
          ),
          findsOneWidget,
        );
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['iOS', 'SpeechAnalyzer', 'iPhone'],
        );

        // 下载 SenseVoice 后再删除，确认弹窗与回退仍保留该兼容方案
        await tester.ensureVisible(find.byKey(const Key('asr-opt-sensevoice')));
        await tester.tap(find.byKey(const Key('asr-opt-sensevoice')));
        await flushAsync(tester);
        expect(ctrl.effectiveAsrMode, 'sensevoice');

        final delBtn = find.byKey(const Key('model-delete-sensevoice-small-int8'));
        await tester.ensureVisible(delBtn);
        await tester.tap(delBtn);
        await tester.pumpAndSettle();

        final dialog = find.byKey(const Key('model-delete-confirm-dialog'));
        expect(
          find.descendant(
            of: dialog,
            matching: find.textContaining('使用系统转写'),
          ),
          findsOneWidget,
        );
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['iOS', 'SpeechAnalyzer', 'iPhone'],
        );

        await tester.tap(find.byKey(const Key('model-delete-confirm-btn')));
        await flushAsync(tester);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(ctrl.settingSummaryLabel, '兼容方案 · 即用');
      },
    );

    testWidgets(
      '(b3) Android 各不支持品牌/ROM（小米/OPPO/vivo/荣耀/华为/三星 Bixby）隐藏系统选项，仅显示 SenseVoice 且绝不出现 iOS 文案',
      (tester) async {
        final unsupportedProfiles = <({
          SystemSpeechCapabilities caps,
          List<String> mustContain,
        })>[
          (
            caps: const SystemSpeechCapabilities(
              platform: 'android',
              osMajorVersion: 15,
              sdkInt: 35,
              brandId: 'xiaomi',
              deviceSummary: '小米 24129PN74C · 澎湃 HyperOS 2.0',
              onDeviceServicePackage: 'com.miui.voiceassistant',
              supportsModernSystemAsr: false,
              unsupportedReason:
                  '已识别本机为 小米（澎湃 HyperOS 2.0），当前未开放免签名端侧音频文件转写服务；音频不上传小爱云端，请下载 SenseVoice 增强模型。',
            ),
            mustContain: const ['小米', 'HyperOS'],
          ),
          (
            caps: const SystemSpeechCapabilities(
              platform: 'android',
              osMajorVersion: 15,
              sdkInt: 35,
              brandId: 'oppo',
              deviceSummary: 'OPPO Find X8 · ColorOS 15',
              supportsModernSystemAsr: false,
              unsupportedReason:
                  '已识别本机为 OPPO（ColorOS 15），当前未开启 Google 端侧语音且 ColorOS AIUnit 需系统白名单；请下载 SenseVoice 增强模型。',
            ),
            mustContain: const ['OPPO', 'AIUnit'],
          ),
          (
            caps: const SystemSpeechCapabilities(
              platform: 'android',
              osMajorVersion: 15,
              sdkInt: 35,
              brandId: 'vivo',
              deviceSummary: 'vivo X200 · OriginOS',
              supportsModernSystemAsr: false,
              unsupportedReason:
                  '已识别本机为 vivo（OriginOS），OriginOS 离线识别接口未向第三方开放标准文件流；请下载 SenseVoice 增强模型。',
            ),
            mustContain: const ['vivo', 'OriginOS'],
          ),
          (
            caps: const SystemSpeechCapabilities(
              platform: 'android',
              osMajorVersion: 15,
              sdkInt: 35,
              brandId: 'honor',
              deviceSummary: '荣耀 HONOR Magic7 · MagicOS 9.0',
              supportsModernSystemAsr: false,
              unsupportedReason:
                  '已识别本机为 荣耀 HONOR（MagicOS 9.0），当前设备未启用标准端侧识别服务，请下载 SenseVoice 增强模型。',
            ),
            mustContain: const ['MagicOS'],
          ),
          (
            caps: const SystemSpeechCapabilities(
              platform: 'android',
              osMajorVersion: 12,
              sdkInt: 31,
              brandId: 'huawei',
              deviceSummary: '华为 HUAWEI Mate 70 · HarmonyOS 4.3',
              supportsModernSystemAsr: false,
              unsupportedReason:
                  '已识别本机为 华为 HUAWEI（Android 12），系统版本低于 Android 13，不支持音频文件级端侧转写；请下载纯端侧 SenseVoice 增强模型。',
            ),
            mustContain: const ['华为', 'SenseVoice'],
          ),
          (
            caps: const SystemSpeechCapabilities(
              platform: 'android',
              osMajorVersion: 14,
              sdkInt: 34,
              brandId: 'samsung',
              deviceSummary: '三星 Galaxy S24 · One UI',
              onDeviceServicePackage: 'com.samsung.android.bixby.agent',
              supportsModernSystemAsr: false,
              unsupportedReason:
                  '已识别本机为 三星 Galaxy（Bixby 语音组件），三星 Bixby 端侧接口会忽略离线音频文件并误开手机麦克风；为防串音与隐私风险，请下载 SenseVoice 增强模型。',
            ),
            mustContain: const ['Bixby', '麦克风'],
          ),
        ];

        ModelManagerController? lastCtrl;
        for (final entry in unsupportedProfiles) {
          final localKv = InMemoryStore();
          final localAgentCfg = AgentConfigStore(store: localKv);
          await localAgentCfg.load();
          addTearDown(localAgentCfg.dispose);

          final installer = _FakeModelInstaller(
            initiallyInstalled: {sileroVadSpec.id, campplusEmbeddingSpec.id},
          );
          final systemSpeech = SystemSpeechClient(
            capabilitiesOverride: () async => entry.caps,
          );
          final ctrl = ModelManagerController(
            installer: installer,
            systemSpeech: systemSpeech,
            agentConfig: localAgentCfg,
            baseUrl: 'https://models.example.test',
          );
          addTearDown(ctrl.dispose);
          lastCtrl = ctrl;

          await ctrl.refresh();
          expect(ctrl.supportsSystemAsr, isFalse);
          expect(ctrl.effectiveAsrMode, 'pending');
          expect(ctrl.settingSummaryLabel, '推荐下载增强模型');

          await tester.pumpWidget(
            wrap(
              SettingSubPage(
                subId: 'local',
                agentConfig: localAgentCfg,
                modelManager: ctrl,
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('asr-opt-system')), findsNothing);
          expect(find.byKey(const Key('asr-opt-sensevoice')), findsOneWidget);
            expect(find.textContaining(entry.caps.deviceSummary), findsNothing);
          for (final kw in entry.mustContain) {
            expect(find.textContaining(kw), findsNothing);
          }
          expectNoCrossPlatformText(
            tester,
            forbidden: const ['iOS', 'SpeechAnalyzer', 'iPhone'],
          );
        }

        // 下载后可转写，删除前说明暂停转写的影响。
        await tester.ensureVisible(find.byKey(const Key('model-dl-asr')));
        await tester.tap(find.byKey(const Key('model-dl-asr')));
        await flushAsync(tester);

        expect(lastCtrl!.effectiveAsrMode, 'sensevoice');
        expect(lastCtrl.settingSummaryLabel, 'SenseVoice · 已就绪');

        final delBtn = find.byKey(const Key('model-delete-sensevoice-small-int8'));
        await tester.ensureVisible(delBtn);
        await tester.tap(delBtn);
        await tester.pumpAndSettle();

        final dialog = find.byKey(const Key('model-delete-confirm-dialog'));
        expect(
          find.descendant(
            of: dialog,
            matching: find.textContaining('暂停本地转写'),
          ),
          findsOneWidget,
        );
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['iOS', 'SpeechAnalyzer', 'iPhone'],
        );
      },
    );

    testWidgets(
      '(c) iOS 26+ 双引擎切换持久化与删除 SenseVoice 自动回退系统内置',
      (tester) async {
        final installer = _FakeModelInstaller(
          initiallyInstalled: {sileroVadSpec.id, campplusEmbeddingSpec.id},
        );
        final systemSpeech = SystemSpeechClient(
          capabilitiesOverride: () async => const SystemSpeechCapabilities(
            platform: 'ios',
            osMajorVersion: 26,
            brandId: 'apple',
            deviceSummary: 'iPhone · iOS 26',
            engineName: 'iOS 系统内置模型（SpeechAnalyzer）',
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

        // 4. 删除增强转写后自动回退系统转写
        final delBtn = find.byKey(const Key('model-delete-sensevoice-small-int8'));
        await tester.ensureVisible(delBtn);
        await tester.tap(delBtn);
        await tester.pumpAndSettle();

        final dialog = find.byKey(const Key('model-delete-confirm-dialog'));
        expect(dialog, findsOneWidget);
        expect(
          find.descendant(
            of: dialog,
            matching: find.textContaining('使用系统转写'),
          ),
          findsOneWidget,
        );
        expectNoCrossPlatformText(
          tester,
          forbidden: const ['Android', 'Bixby', 'HyperOS'],
        );

        await tester.tap(find.byKey(const Key('model-delete-confirm-btn')));
        await flushAsync(tester);

        expect(installer.deletedCalls, contains(senseVoiceSpec.id));
        expect(ctrl.statusFor(senseVoiceSpec)?.installed, isFalse);
        expect(ctrl.effectiveAsrMode, 'system');
        expect(agentConfig.preferredAsrEngine, 'system');
        expect(ctrl.settingSummaryLabel, '系统内置 · 即用');
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

    test(
      '(d2) Android MethodChannel 通道协议 + 临时 WAV 清理 + RecordingPipeline 全流程出稿',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('com.reai.recordingcard/system_speech');
        String? capturedWavPath;
        String? capturedHeaderRiff;
        String? capturedHeaderWave;
        final invokedMethods = <String>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              invokedMethods.add(call.method);
              switch (call.method) {
                case 'capabilities':
                  return <Object?, Object?>{
                    'platform': 'android',
                    'osMajorVersion': 15,
                    'sdkInt': 35,
                    'brandId': 'samsung',
                    'deviceSummary': '三星 Galaxy S24 · One UI',
                    'engineName': '三星 Galaxy 兼容方案（直连 Google 端侧语音）',
                    'onDeviceServicePackage': 'com.google.android.tts',
                    'resolutionStrategy': 'compat_service',
                    'compatServiceComponent':
                        'com.google.android.tts/com.google.android.apps.speech.tts.googletts.service.GoogleTTSRecognitionService',
                    'compatDescription': '直连 Google 端侧离线语音服务，免下载 228 MB 模型即可离线转写。',
                    'detectedServices': const ['com.google.android.tts'],
                    'supportsModernSystemAsr': true,
                    'offlinePackInstalled': false,
                    'canDownloadOfflinePack': true,
                    'unsupportedReason': '',
                    'authStatus': 'granted',
                  };
                case 'requestAuthorization':
                  return 'granted';
                case 'downloadSystemModel':
                  return true;
                case 'transcribeWav':
                  final args = call.arguments as Map<Object?, Object?>;
                  final path = args['wavPath'] as String;
                  capturedWavPath = path;
                  final wavBytes = File(path).readAsBytesSync();
                  capturedHeaderRiff = String.fromCharCodes(
                    wavBytes.sublist(0, 4),
                  );
                  capturedHeaderWave = String.fromCharCodes(
                    wavBytes.sublist(8, 12),
                  );
                  return <Object?, Object?>{
                    'text': 'Android 端侧内置模型离线转写成功',
                    'tokens': const ['A', 'n', 'd'],
                    'timestampsMs': const [100, 250, 400],
                    'lang': 'zh-CN',
                  };
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final realRoot = await Directory.systemTemp.createTemp('rc-and-asr-');
        addTearDown(() async {
          if (await realRoot.exists()) {
            await realRoot.delete(recursive: true);
          }
        });

        final realInstaller = ModelInstaller(root: realRoot);
        await realInstaller.ensureBundled(sileroVadSpec);

        final androidSpeech = SystemSpeechClient(
          channel: channel,
          debugForceNativePlatform: true,
        );

        final caps = await androidSpeech.capabilities();
        expect(caps.isAndroid, isTrue);
        expect(caps.sdkInt, 35);
        expect(caps.brandId, 'samsung');
        expect(caps.isCompatService, isTrue);
        expect(caps.resolutionStrategy, 'compat_service');
        expect(
          caps.compatServiceComponent,
          'com.google.android.tts/com.google.android.apps.speech.tts.googletts.service.GoogleTTSRecognitionService',
        );
        expect(caps.compatDescription, contains('Google 端侧离线语音服务'));
        expect(caps.detectedServices, ['com.google.android.tts']);
        expect(caps.supportsModernSystemAsr, isTrue);
        expect(caps.offlinePackInstalled, isFalse);
        expect(caps.canDownloadOfflinePack, isTrue);

        expect(await androidSpeech.triggerSystemModelDownload(), isTrue);

        final controller = ModelManagerController(
          installer: realInstaller,
          systemSpeech: androidSpeech,
          agentConfig: agentConfig,
          baseUrl: '',
        );
        addTearDown(controller.dispose);
        await controller.refresh();
        expect(controller.effectiveAsrMode, 'system');
        expect(controller.settingSummaryLabel, '兼容方案 · 缺声纹');

        final models = InstalledSpeechModelProvider(
          realInstaller,
          useSystemAsr: () async => controller.effectiveAsrMode == 'system',
        );
        final stubLocal = _StubVadAndSpkLocalEngine();
        final routingEngine = RoutingSpeechEngine(
          localEngine: stubLocal,
          systemSpeech: androidSpeech,
        );

        final gateway = FakeCardGateway()
          ..writeDownload = true
          ..transcodeSeconds = 4
          ..deviceFiles = [
            const CardFile(
              name: 'AND001.APM',
              size: 1000,
              startAtSec: 1730000100,
              session: 'A1',
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

        expect(
          invokedMethods,
          containsAll([
            'capabilities',
            'downloadSystemModel',
            'requestAuthorization',
            'transcribeWav',
          ]),
        );
        expect(capturedWavPath, isNotNull);
        expect(capturedHeaderRiff, 'RIFF');
        expect(capturedHeaderWave, 'WAVE');
        expect(File(capturedWavPath!).existsSync(), isFalse);
        expect(stubLocal.localTranscribeCalls, 0);

        final rec = (await recStore.loadAll(refresh: true)).single;
        expect(rec.stage, RecordingStage.ready);
        expect(rec.utterances.first.text, 'Android 端侧内置模型离线转写成功');
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
