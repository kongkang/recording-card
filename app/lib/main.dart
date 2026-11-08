library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/dev/dev_driver.dart';
import 'core/store/app_store.dart';
import 'core/store/device_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';
import 'pages/login_page.dart';
import 'services/auth_service.dart';

void main() {
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
  final _device = DeviceStore();

  @override
  void initState() {
    super.initState();
    if (dev != null) {
      dev!
        ..store = _store
        ..device = _device
        ..auth = _auth;
    }
  }

  @override
  void dispose() {
    _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _shotKey,
      child: ListenableBuilder(
        listenable: _auth,
        builder: (context, _) => _auth.isSignedIn
            ? AppShell(store: _store, device: _device)
            : LoginPage(auth: _auth, onSignedIn: () {}),
      ),
    );
  }
}
