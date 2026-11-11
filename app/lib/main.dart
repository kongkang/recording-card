library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/dev/dev_driver.dart';
import 'core/platform/crash_guard.dart';
import 'core/storage/storage.dart';
import 'core/store/app_store.dart';
import 'core/store/device_store.dart';
import 'core/store/settings_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';
import 'pages/login_page.dart';
import 'services/ai/summary_generator.dart';
import 'services/analysis/chat_completion.dart';
import 'services/audio/recording_status.dart';
import 'services/auth_service.dart';
import 'services/net/model_gateway.dart';
import 'services/polish/slice_polish_service.dart';
import 'services/recordings/recording_pipeline.dart';
import 'services/recordings/recording_store.dart';
import 'services/segment/segment_build_service.dart';
import 'services/transcribe/model_manager_controller.dart';
import 'services/transcribe/asr_models.dart';
import 'services/transcribe/local_asr_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 崩溃兜底要在 runApp 之前装好，否则启动期异常会直接白屏且无迹可查
  installCrashHandlers();
  SettingsStore settings;
  try {
    settings = SettingsStore(store: await PrefsStore.open());
    await settings.load();
  } catch (_) {
    // 平台通道不可用时用内存默认值，保证仍可启动
    settings = SettingsStore(store: InMemoryStore());
  }
  runApp(RecordingCardApp(settings: settings));
}

class RecordingCardApp extends StatelessWidget {
  const RecordingCardApp({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '录音卡',
      debugShowCheckedModeBanner: false,
      theme: buildRCTheme(),
      darkTheme: buildRCDarkTheme(),
      themeMode: ThemeMode.system,
      // 产品当前只有简体中文：显式声明语言，系统组件（日期选择、复制粘贴菜单）才会走中文
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      locale: const Locale('zh', 'CN'),
      home: _HomeGate(settings: settings),
    );
  }
}

/// 截图锚点（dev 驱动取帧用；release 下无引用不产生开销）
final GlobalKey _shotKey = GlobalKey();

/// 开发期帧级自查驱动（详见 dev_driver.dart；release 恒为 null）
final DevDriver? dev = kDebugMode ? DevDriver(_shotKey) : null;

class _HomeGate extends StatefulWidget {
  const _HomeGate({required this.settings});

  final SettingsStore settings;

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

  late final ModelGateway _modelGateway;
  late final ModelInstaller _installer;
  late final InstalledSpeechModelProvider _models;
  late final LocalAsrService _asr;
  late final RecordingStore _recordingStore;
  late final RecordingPipeline _pipeline;
  late final ModelManagerController _modelManager;
  late final SummaryGenerator _summaries;
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    _modelGateway = ModelGateway(client: _auth.apiClient);
    _summaries = SummaryGenerator(gateway: _modelGateway);

    // 本地转写/润色/分段流水线（离线优先；云端未配置/未登录时自动降级）
    _installer = ModelInstaller();
    _models = InstalledSpeechModelProvider(_installer);
    _modelManager = ModelManagerController(
      installer: _installer,
      onInstalled: () => _store.processPendingRecordings(),
    );
    _asr = LocalAsrService();
    _recordingStore = RecordingStore();
    final chat = ModelGatewayChatCompletion(_modelGateway);
    _pipeline = RecordingPipeline(
      gateway: _device.gateway,
      store: _recordingStore,
      engine: _asr,
      models: _models,
      settings: _settings,
      polish: SlicePolishService(
        chat: chat,
        model: _modelGateway.textModel,
        ready: () => _modelGateway.ready,
      ),
      segments: SegmentBuildService(
        chat: chat,
        model: _modelGateway.textModel,
        ready: () => _modelGateway.ready,
      ),
    );
    _store.attachPipeline(
      pipeline: _pipeline,
      store: _recordingStore,
      generator: _summaries,
      status: _recordingStatus,
    );
    _device.onManualBleSync = () => _store.syncRecordings();
    unawaited(_boot());
    if (dev != null) {
      dev!
        ..store = _store
        ..device = _device
        ..auth = _auth;
    }
  }

  /// 启动装载：等鉴权恢复 → 载入历史状态与本地录音 → 登录态就绪时探测模型目录。
  Future<void> _boot() async {
    await _auth.ready;
    if (_auth.isSignedIn) unawaited(_modelGateway.discoverModels());
    await _store.init();
    if (mounted) setState(() => _booted = true);
    // 有本地未完成的录音就继续处理（不访问设备）；模型未装时只下载/转码排队
    unawaited(_store.processPendingRecordings());
  }

  @override
  void dispose() {
    _device.dispose();
    _store.dispose();
    _recordingStatus.dispose();
    _modelManager.dispose();
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
            );
          }
          return LoginPage(
            auth: _auth,
            onSignedIn: () => unawaited(_modelGateway.discoverModels()),
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
