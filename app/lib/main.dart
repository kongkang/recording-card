import 'package:flutter/material.dart';

import 'core/store/app_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';

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
      home: const AppGate(),
    );
  }
}

/// 启动入口：恢复会话（路由栈 + 已生成总结，同标签页级别）后进入外壳。
/// OAuth 登录门（借鉴 reai_mobile_app）在 auth 阶段接入。
class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  late final AppStore _store = AppStore();

  @override
  Widget build(BuildContext context) => AppShell(store: _store);
}
