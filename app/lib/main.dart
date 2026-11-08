library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/dev/dev_driver.dart';
import 'core/platform/crash_guard.dart';
import 'core/store/app_store.dart';
import 'core/store/device_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';
import 'pages/login_page.dart';
import 'services/ai/summary_generator.dart';
import 'services/auth_service.dart';
import 'services/net/model_gateway.dart';
import 'services/recordings/recording_sync_service.dart';

void main() {
  // 崩溃兜底要在 runApp 之前装好，否则启动期异常会直接白屏且无迹可查
  installCrashHandlers();
  runApp(const RecordingCardApp());
}

class RecordingCardApp extends StatelessWidget {
  const RecordingCardApp({super.key});

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
      home: const _HomeGate(),
    );
  }
}

/// 截图锚点（dev 驱动取帧用；release 下无引用不产生开销）
final GlobalKey _shotKey = GlobalKey();

/// 开发期帧级自查驱动（详见 dev_driver.dart；release 恒为 null）
final DevDriver? dev = kDebugMode ? DevDriver(_shotKey) : null;

class _HomeGate extends StatefulWidget {
  const _HomeGate();

  @override
  State<_HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<_HomeGate> {
  final _auth = AuthService();
  final _store = AppStore();
  // autoStart：启动即核对链路并开心跳（测试里传 false，避免悬挂定时器）
  final _device = DeviceStore(autoStart: true);

  late final ModelGateway _modelGateway;
  late final RecordingSyncService _recordings;
  late final SummaryGenerator _summaries;
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    _modelGateway = ModelGateway(client: _auth.apiClient);
    _recordings = RecordingSyncService(
      gateway: _device.gateway,
      model: _modelGateway,
    );
    _summaries = SummaryGenerator(gateway: _modelGateway);
    _store.attachServices(recordings: _recordings, generator: _summaries);
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
  }

  @override
  void dispose() {
    _device.dispose();
    _store.dispose();
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
            return AppShell(store: _store, device: _device);
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
