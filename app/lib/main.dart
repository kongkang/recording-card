library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/dev/dev_driver.dart';
import 'core/store/app_store.dart';
import 'core/store/app_backend.dart';
import 'core/models/record.dart';
import 'core/store/device_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';
import 'pages/login_page.dart';
import 'services/auth_service.dart';
import 'services/runtime/production_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProductionBootstrap());
}

class _ProductionBootstrap extends StatefulWidget {
  const _ProductionBootstrap();
  @override
  State<_ProductionBootstrap> createState() => _ProductionBootstrapState();
}

class _ProductionBootstrapState extends State<_ProductionBootstrap> {
  late Future<ProductionRuntime> _runtime = ProductionRuntime.create();
  @override
  void dispose() {
    unawaited(_runtime.then((r) => r.dispose()).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ProductionRuntime>(
    future: _runtime,
    builder: (context, snapshot) {
      final runtime = snapshot.data;
      if (runtime != null) {
        return RecordingCardApp(
          auth: runtime.auth,
          store: runtime.store,
          device: runtime.device,
        );
      }
      return MaterialApp(
        theme: buildRCTheme(),
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('本机服务初始化失败，请检查安全存储及应用数据。'),
                      TextButton(
                        onPressed: () => setState(() {
                          _runtime = ProductionRuntime.create();
                        }),
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

/// Integration injects C/D AppBackend and B/C DeviceBackend here. Unconfigured
/// defaults remain fail-closed; fixtures are never selected by production.
class RecordingCardApp extends StatelessWidget {
  const RecordingCardApp({
    super.key,
    this.auth,
    this.backend,
    this.deviceBackend,
    this.store,
    this.device,
    this.restoreAuth,
    this.authorize,
    this.recordUpdates,
  });
  final AuthService? auth;
  final AppBackend? backend;
  final DeviceBackend? deviceBackend;
  final AppStore? store;
  final DeviceStore? device;
  final Future<void> Function()? restoreAuth;
  final Future<void> Function()? authorize;
  final Stream<List<RecordEvent>>? recordUpdates;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '录音卡',
    debugShowCheckedModeBanner: false,
    theme: buildRCTheme(),
    home: _HomeGate(config: this),
  );
}

final GlobalKey _shotKey = GlobalKey();
final DevDriver? dev = kDebugMode ? DevDriver(_shotKey) : null;

class _HomeGate extends StatefulWidget {
  const _HomeGate({required this.config});
  final RecordingCardApp config;
  @override
  State<_HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<_HomeGate> {
  late final _auth = widget.config.auth ?? AuthService();
  late final _store =
      widget.config.store ??
      AppStore(
        backend: widget.config.backend,
        recordUpdates: widget.config.recordUpdates,
      );
  late final _device =
      widget.config.device ??
      DeviceStore(
        backend: widget.config.deviceBackend,
        policy: () => _store.policy,
        onSynced: _store.reloadEvents,
      );
  bool _restoring = true;
  bool _initialized = false;
  @override
  void initState() {
    super.initState();
    _auth.addListener(_authChanged);
    if (dev != null) {
      dev!
        ..store = _store
        ..device = _device
        ..auth = _auth;
    }
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      if (widget.config.restoreAuth != null) {
        await widget.config.restoreAuth!();
      } else {
        await _auth.restore();
      }
    } catch (_) {
      /* Login page will surface unavailable OAuth on user action. */
    }
    if (!mounted) return;
    setState(() => _restoring = false);
    _authChanged();
  }

  void _authChanged() {
    if (!_auth.isSignedIn) {
      _initialized = false;
      return;
    }
    if (_initialized) return;
    _initialized = true;
    unawaited(_store.initialize());
    unawaited(_device.initialize());
  }

  @override
  void dispose() {
    _auth.removeListener(_authChanged);
    if (widget.config.auth == null) _auth.dispose();
    if (widget.config.store == null) _store.dispose();
    if (widget.config.device == null) _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _shotKey,
    child: ListenableBuilder(
      listenable: _auth,
      builder: (context, _) => _restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _auth.isSignedIn
          ? AppShell(store: _store, device: _device)
          : LoginPage(
              auth: _auth,
              authorize: widget.config.authorize,
              onSignedIn: _authChanged,
            ),
    ),
  );
}
