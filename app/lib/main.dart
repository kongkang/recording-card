library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/dev/dev_driver.dart';
import 'core/platform/crash_guard.dart';
import 'core/storage/storage.dart';
import 'core/store/agent_config_store.dart';
import 'core/store/app_store.dart';
import 'core/store/device_store.dart';
import 'core/store/settings_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';
import 'pages/login_page.dart';
import 'services/agent/agent_chat_controller.dart';
import 'services/ai/summary_generator.dart';
import 'services/analysis/chat_completion.dart';
import 'services/audio/recording_status.dart';
import 'services/auth_service.dart';
import 'services/health/health_signal_collector.dart';
import 'services/health/health_signal_controller.dart';
import 'services/health/health_signal_models.dart';
import 'services/health/health_signal_store.dart';
import 'services/memory/local_memory_index.dart';
import 'services/memory/memory_indexer.dart';
import 'services/memory/memory_search_service.dart';
import 'services/net/model_gateway.dart';
import 'services/net/model_provider_store.dart';
import 'services/polish/slice_polish_service.dart';
import 'services/recordings/multi_track_reconciler.dart';
import 'services/recordings/recording_pipeline.dart';
import 'services/recordings/recording_store.dart';
import 'services/schedule/cleaning_task_ids.dart';
import 'services/schedule/cleaning_tasks.dart';
import 'services/schedule/in_app_task_runner.dart';
import 'services/schedule/metered_chat.dart';
import 'services/schedule/organize_pass_service.dart';
import 'services/schedule/task_scheduler.dart';
import 'services/segment/fast_topic_segment_agent.dart';
import 'services/segment/rolling_clean_segment_service.dart';
import 'services/segment/segment_build_service.dart';
import 'services/transcribe/model_manager_controller.dart';
import 'services/transcribe/asr_models.dart';
import 'services/transcribe/local_asr_service.dart';
import 'services/transcribe/system_speech_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 崩溃兜底要在 runApp 之前装好，否则启动期异常会直接白屏且无迹可查
  installCrashHandlers();
  SettingsStore settings;
  AgentConfigStore agentConfig;
  try {
    final prefs = await PrefsStore.open();
    settings = SettingsStore(store: prefs);
    await settings.load();
    agentConfig = AgentConfigStore(store: prefs);
    await agentConfig.load();
  } catch (_) {
    // 平台通道不可用时用内存默认值，保证仍可启动
    settings = SettingsStore(store: InMemoryStore());
    agentConfig = AgentConfigStore(store: InMemoryStore());
  }
  final providers = ModelProviderStore.instance;
  try {
    await providers.load();
    final legacyBase = agentConfig.customApiBase;
    if (legacyBase.trim().isNotEmpty) {
      if (providers.activeProvider == ModelProvider.wainao) {
        await agentConfig.setCloudEnabled(false);
      }
      await providers.importLegacyDraft(
        legacyBase,
        summaryModel: agentConfig.userPickedCloudModel
            ? agentConfig.cloudModel
            : '',
      );
      await agentConfig.setCustomApiBase('');
    }
  } catch (_) {
    // 密钥库临时不可用时继续启动。请求层读取失败会如实返回，不能切回外脑。
  }
  runApp(RecordingCardApp(settings: settings, agentConfig: agentConfig));
}

class RecordingCardApp extends StatelessWidget {
  const RecordingCardApp({super.key, required this.settings, this.agentConfig});

  final SettingsStore settings;
  final AgentConfigStore? agentConfig;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '录音卡',
      debugShowCheckedModeBanner: false,
      theme: buildRCTheme(),
      darkTheme: buildRCDarkTheme(),
      themeMode: ThemeMode.system,
      scrollBehavior: const RCScrollBehavior(),
      // 产品当前只有简体中文：显式声明语言，系统组件（日期选择、复制粘贴菜单）才会走中文
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      locale: const Locale('zh', 'CN'),
      home: _HomeGate(settings: settings, agentConfig: agentConfig),
    );
  }
}

/// 截图锚点（dev 驱动取帧用；release 下无引用不产生开销）
final GlobalKey _shotKey = GlobalKey();

/// 开发期帧级自查驱动（详见 dev_driver.dart；release 恒为 null）
final DevDriver? dev = kDebugMode ? DevDriver(_shotKey) : null;

class _HomeGate extends StatefulWidget {
  const _HomeGate({required this.settings, this.agentConfig});

  final SettingsStore settings;
  final AgentConfigStore? agentConfig;

  @override
  State<_HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<_HomeGate> {
  final _auth = AuthService();
  final _store = AppStore();
  // autoStart：启动即核对链路并开心跳（测试里传 false，避免悬挂定时器）
  final _device = DeviceStore(autoStart: true);
  final _recordingStatus = RecordingStatusController();
  late final SettingsStore _settings = widget.settings;
  late final AgentConfigStore _agentConfig =
      widget.agentConfig ?? AgentConfigStore(store: InMemoryStore());

  final _modelProviders = ModelProviderStore.instance;
  late final ModelGateway _modelGateway;
  late final ModelInstaller _installer;
  late final SystemSpeechClient _systemSpeech;
  late final InstalledSpeechModelProvider _models;
  late final RoutingSpeechEngine _asr;
  late final RecordingStore _recordingStore;
  late final HealthSignalController _healthSignals;
  late final RecordingPipeline _pipeline;
  late final ModelManagerController _modelManager;
  late final SummaryGenerator _summaries;
  late final MeteredChatCompletion _meteredChat;
  late (ModelProvider, ModelProviderProfile?, bool) _cloudSelection;
  TaskScheduler? _scheduler;
  InAppTaskRunner? _taskRunner;
  late final AgentChatController _agentChat;
  late final MemorySearchService _memorySearch;
  bool _booted = false;
  bool _wasSignedIn = false;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _modelGateway = ModelGateway(
      client: _auth.apiClient,
      enabledCheck: () => _agentConfig.cloudEnabled,
      providers: _modelProviders,
    );
    _summaries = SummaryGenerator(
      gateway: _modelGateway,
      agentConfig: _agentConfig,
    );

    // 本地转写/润色/分段流水线（离线优先；iOS 26+ 默认系统内置免下载，按需可切 SenseVoice）
    _installer = ModelInstaller();
    _systemSpeech = SystemSpeechClient();
    _modelManager = ModelManagerController(
      installer: _installer,
      systemSpeech: _systemSpeech,
      agentConfig: _agentConfig,
      onInstalled: () => _store.processPendingRecordings(),
    );
    _models = InstalledSpeechModelProvider(
      _installer,
      useSystemAsr: () async {
        if (!_modelManager.hasStatuses) {
          await _modelManager.refresh();
        }
        return _modelManager.effectiveAsrMode == 'system';
      },
    );
    _asr = RoutingSpeechEngine(
      localEngine: LocalAsrService(),
      systemSpeech: _systemSpeech,
    );
    _recordingStore = RecordingStore();
    _healthSignals = HealthSignalController(
      store: HealthSignalStore(),
      collector: createPlatformHealthCollector(),
      config: _agentConfig,
      recordingSpans: () async {
        final files = await _recordingStore.loadAll();
        return [
          for (final file in files)
            if (file.startAtMs > 0 && file.durationMs > 0)
              RecordingSpan(
                id: file.id,
                startMs: file.startAtMs,
                endMs: file.startAtMs + file.durationMs,
              ),
        ];
      },
    );
    unawaited(_healthSignals.start());
    _meteredChat = MeteredChatCompletion(
      ModelGatewayChatCompletion(_modelGateway, scene: ModelScene.polish),
    );
    final segmentChat = _meteredChat.withInner(
      ModelGatewayChatCompletion(_modelGateway, scene: ModelScene.segmentation),
    );

    _pipeline = RecordingPipeline(
      gateway: _device.gateway,
      store: _recordingStore,
      engine: _asr,
      models: _models,
      settings: _settings,
      agentConfig: _agentConfig,
      polish: SlicePolishService(
        chat: _meteredChat,
        modelResolver: () => _modelGateway.modelFor(ModelScene.polish),
        ready: () => _modelGateway.readyFor(ModelScene.polish),
      ),
      segments: SegmentBuildService(
        chat: segmentChat,
        modelResolver: () => _modelGateway.modelFor(ModelScene.segmentation),
        ready: () => _modelGateway.readyFor(ModelScene.segmentation),
      ),
      topicAgent: FastTopicSegmentAgent(
        chat: segmentChat,
        modelResolver: () => _modelGateway.modelFor(ModelScene.segmentation),
        ready: () => _modelGateway.readyFor(ModelScene.segmentation),
      ),
      rollingCleaner: RollingCleanSegmentService(
        chat: _meteredChat,
        modelResolver: () => _modelGateway.modelFor(ModelScene.polish),
        ready: () => _modelGateway.readyFor(ModelScene.polish),
        resolveRoot: _recordingStore.root,
        voiceprintStore: _store.voiceprintStore,
        agentConfig: _agentConfig,
      ),
      voiceprintStore: _store.voiceprintStore,
      multiTrackReconciler: MultiTrackReconciler(
        chat: _meteredChat,
        modelResolver: () => _modelGateway.modelFor(ModelScene.polish),
        ready: () => _modelGateway.readyFor(ModelScene.polish),
      ),
      bleDeviceLabelResolver: () => _device.activeRecordingDeviceLabel,
    );
    _store.attachPipeline(
      pipeline: _pipeline,
      store: _recordingStore,
      generator: _summaries,
      status: _recordingStatus,
    );
    _agentChat = AgentChatController(
      appStore: _store,
      agentConfig: _agentConfig,
      gateway: _modelGateway,
      healthStore: _healthSignals.store,
    );
    _memorySearch = MemorySearchService(
      index: LocalMemoryIndex(),
      corpus: () => MemoryCorpus(
        events: _store.eventsWithResolvedSpeakers(),
        summaries: _store.summariesWithResolvedSpeakers(),
      ),
      chat: (turns) => _modelGateway.chat([
        for (final turn in turns)
          ChatMessage(role: turn.role, content: turn.content),
      ], scene: ModelScene.agent),
    );
    _store.photoSyncEnabled = () => _agentConfig.photoLinkEnabled;
    _store.deviceGateway = () => _device.gateway;
    _device.onManualBleSync = () => _store.syncRecordings();
    _device.onBleReconnectedNeedSync = (_) => _store.syncAfterBleReconnect(
      flushWatch: _device.flushWatchRecordingSlice,
      flushPhone: _device.flushPhoneRecordingSlice,
      pullBleFiles: _device.activeCapabilities.hasFileSync,
    );
    unawaited(_device.setWatchLinkEnabled(_agentConfig.watchLinkEnabled));
    unawaited(
      _device.setExtHardwareEnabled(
        omi: _agentConfig.omiLinkEnabled,
        feishu: _agentConfig.feishuLinkEnabled,
      ),
    );
    _cloudSelection = _currentCloudSelection;
    _modelProviders.addListener(_onCloudSelectionChanged);
    _agentConfig.addListener(_onCloudSelectionChanged);
    unawaited(_boot());
    if (dev != null) {
      dev!
        ..store = _store
        ..device = _device
        ..auth = _auth;
    }
  }

  (ModelProvider, ModelProviderProfile?, bool) get _currentCloudSelection {
    final provider = _modelProviders.activeProvider;
    return (
      provider,
      provider == ModelProvider.wainao
          ? null
          : _modelProviders.profileFor(provider),
      _agentConfig.cloudEnabled,
    );
  }

  void _onCloudSelectionChanged() {
    final selection = _currentCloudSelection;
    if (_cloudSelection == selection) return;
    _cloudSelection = selection;
    if (!_booted || !_auth.isSignedIn || !selection.$3) return;
    if (selection.$1 == ModelProvider.wainao) {
      unawaited(_continuePendingAfterModels(_discoverAndSyncModels()));
    } else {
      unawaited(_store.processPendingRecordings());
    }
  }

  Future<void> _discoverAndSyncModels() async {
    if (_modelGateway.usesExternalProvider) return;
    await _modelGateway.discoverModels();
    _agentConfig.syncGatewayModels(
      _modelGateway.discoveredTextModels,
      primaryTextModel: _modelGateway.textModel,
    );
  }

  /// 启动装载：等鉴权恢复 → 并行拉取模型目录与本地历史 → 等模型目录就绪后继续处理未完录音。
  Future<void> _boot() async {
    await _auth.ready;
    _wasSignedIn = _auth.isSignedIn;
    // 无论是否已登录，后台自动检查并补齐端侧语音模型（iOS Apple-Hosted / RC_MODEL_BASE）。
    unawaited(_modelManager.autoEnsureInstalled());
    Future<void>? discoverFuture;
    if (_auth.isSignedIn) {
      discoverFuture = _discoverAndSyncModels();
      // 已登录用户后台预热微信 SDK 与社会化渠道（决定设置页/登出后入口可用性），不阻塞启动。
      unawaited(_auth.prewarmWechat());
      unawaited(_auth.prewarmSocialProviders());
    } else {
      // 未登录：并行预热微信 SDK 与线上可用社会化渠道（均内部吞异常 + 短超时），不卡住 Splash。
      await Future.wait([
        _auth.prewarmWechat(),
        _auth.prewarmSocialProviders(),
      ]);
    }
    await _store.init();
    await _startScheduler();
    if (mounted) setState(() => _booted = true);
    // 有本地未完成的录音就继续处理（不访问设备）；等模型目录探测完再触发云端清洗
    unawaited(_continuePendingAfterModels(discoverFuture));
  }

  Future<String> _transcribeSliceForAgent(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    return transcribeVoiceCommandWithDualFallback(
      samples,
      sampleRate: sampleRate,
      systemSpeech: _systemSpeech,
      localAsr: _asr.localEngine,
      installer: _installer,
      modelProvider: _models,
      preferSenseVoice: _agentConfig.preferredAsrEngine == 'sensevoice',
    );
  }

  Future<String?> _lookupExistingTranscript(int startMs, int endMs) async {
    final files = await _recordingStore.loadAll();
    for (final file in files) {
      if (file.startAtMs <= 0 || file.durationMs <= 0) continue;
      final fileEndMs = file.startAtMs + file.durationMs;
      if (fileEndMs < endMs - 500 || file.startAtMs > endMs) continue;
      final texts = <String>[];
      if (file.turns.isNotEmpty) {
        for (final t in file.turns) {
          final absStart = file.startAtMs + t.startMs;
          final absEnd = file.startAtMs + t.endMs;
          if (absEnd > startMs &&
              absStart < endMs &&
              t.text.trim().isNotEmpty) {
            texts.add(t.text.trim());
          }
        }
      } else {
        for (final u in file.utterances) {
          final absStart = file.startAtMs + u.startMs;
          final absEnd = file.startAtMs + u.endMs;
          if (absEnd > startMs &&
              absStart < endMs &&
              u.text.trim().isNotEmpty) {
            texts.add(u.text.trim());
          }
        }
      }
      final joined = texts.join(' ').trim();
      if (joined.isNotEmpty) return joined;
    }
    return null;
  }

  Future<void> _startScheduler() async {
    KeyValueStore backing;
    try {
      backing = await PrefsStore.open();
    } catch (_) {
      backing = InMemoryStore();
    }
    final scheduler = TaskScheduler(store: JsonStore(store: backing));
    await scheduler.load();
    final organize = OrganizePassService(
      chat: _meteredChat.withInner(
        ModelGatewayChatCompletion(_modelGateway, scene: ModelScene.organize),
      ),
      modelResolver: () => _modelGateway.modelFor(ModelScene.organize),
      ready: () => _modelGateway.readyFor(ModelScene.organize),
    );
    registerCleaningHandlers(
      scheduler: scheduler,
      store: _store,
      pipeline: _pipeline,
      meter: _meteredChat,
      organize: organize,
      agentConfig: _agentConfig,
    );
    await scheduler.ensureTasks(
      defaultCleaningTasks(shortMinutes: _agentConfig.cleanCycleMinutes),
    );
    final short = scheduler.taskById(CleaningTaskIds.short);
    if (short != null &&
        short.schedule.mode == 'interval' &&
        short.schedule.everyMinutes != _agentConfig.cleanCycleMinutes) {
      await _agentConfig.setCleanCycleMinutes(short.schedule.everyMinutes);
    }
    bindCleaningCycle(scheduler, _agentConfig);
    _scheduler = scheduler;
    _store.attachTaskScheduler(scheduler);
    final runner = InAppTaskRunner(scheduler);
    _taskRunner = runner;
    runner.start();
  }

  Future<void> _continuePendingAfterModels(Future<void>? discoverFuture) async {
    if (discoverFuture != null) {
      await discoverFuture.timeout(
        const Duration(seconds: 6),
        onTimeout: () {},
      );
    }
    await _store.processPendingRecordings();
  }

  void _onAuthChanged() {
    final signedIn = _auth.isSignedIn;
    if (_wasSignedIn && !signedIn) {
      unawaited(_device.stopAllRecordingsForSignOut());
      _device.closeSheet();
      _store.go(RootTab.timeline);
    } else if (!_wasSignedIn && signedIn) {
      unawaited(
        _discoverAndSyncModels().then((_) => _store.processPendingRecordings()),
      );
    }
    _wasSignedIn = signedIn;
  }

  @override
  void dispose() {
    _taskRunner?.stop();
    _scheduler?.dispose();
    _auth.removeListener(_onAuthChanged);
    _modelProviders.removeListener(_onCloudSelectionChanged);
    _agentConfig.removeListener(_onCloudSelectionChanged);
    _device.dispose();
    _store.dispose();
    _recordingStatus.dispose();
    _agentChat.dispose();
    unawaited(_memorySearch.close());
    _healthSignals.dispose();
    _modelManager.dispose();
    if (widget.agentConfig == null) _agentConfig.dispose();
    unawaited(_asr.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _shotKey,
      child: ListenableBuilder(
        listenable: _auth,
        builder: (context, _) {
          if (!_booted) {
            return const _Splash();
          }
          if (_auth.isSignedIn) {
            return AppShell(
              store: _store,
              device: _device,
              recordingStatus: _recordingStatus,
              modelManager: _modelManager,
              settings: _settings,
              agentConfig: _agentConfig,
              authService: _auth,
              healthSignals: _healthSignals,
              memorySearch: _memorySearch,
              agentChat: _agentChat,
              transcribeSamples: _transcribeSliceForAgent,
              lookupExistingTranscript: _lookupExistingTranscript,
            );
          }
          return LoginPage(
            auth: _auth,
            onSignedIn: () => unawaited(_discoverAndSyncModels()),
          );
        },
      ),
    );
  }
}

/// 启动态：等鉴权恢复与本地数据装载，避免"登录页闪一下又进主页"。
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: const Center(
        key: Key('app-splash'),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
