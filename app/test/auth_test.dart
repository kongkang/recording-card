// 登录门验收：OAuth 架构（借鉴 reai_mobile_app）+ 本地会话回落（未配置端点不发起网络请求）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/login_page.dart';
import 'package:recording_card/services/auth_service.dart';

void main() {
  group('client_config', () {
    test('未配置端点：本地会话模式，不发起网络请求', () {
      expect(ClientConfig.instance.apiBase, isNull, reason: '测试进程无 RC_API_BASE');
      expect(ClientConfig.instance.hasRemoteBackend, isFalse);
      expect(ClientConfig.instance.oauthClientId, isNotEmpty);
    });
  });

  group('auth_service', () {
    test('空账号 / 空密码返回错误文案，不建立会话', () {
      final auth = AuthService();
      expect(auth.signIn('', 'x'), '请输入账号');
      expect(auth.signIn(' ', 'x'), '请输入账号');
      expect(auth.signIn('kong', ''), '请输入密码');
      expect(auth.isSignedIn, isFalse);
    });

    test('有效凭据建立本地会话并通知', () {
      final auth = AuthService();
      var notified = 0;
      auth.addListener(() => notified++);
      expect(auth.signIn('kong', 'secret'), isNull);
      expect(auth.isSignedIn, isTrue);
      expect(auth.session!.account, 'kong');
      expect(notified, 1);
      auth.signOut();
      expect(auth.isSignedIn, isFalse);
      expect(notified, 2);
    });
  });

  testWidgets('login-gate：行内错误 → 登录成功进入应用外壳', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = AuthService();
    await tester.pumpWidget(MaterialApp(home: _GateHarness(auth: auth)));
    await tester.pump();

    expect(find.byKey(const Key('login-title')), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);

    // 空提交 → 行内错误
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.byKey(const Key('login-error')), findsOneWidget);

    // 有效提交 → 进入外壳
    await tester.enterText(find.byKey(const Key('login-account')), 'kong');
    await tester.enterText(find.byKey(const Key('login-password')), 'secret');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byKey(const Key('app-title')), findsOneWidget);
  });
}

/// 登录门等价装配（与 main.AppGate 同构）
class _GateHarness extends StatefulWidget {
  const _GateHarness({required this.auth});
  final AuthService auth;

  @override
  State<_GateHarness> createState() => _GateHarnessState();
}

class _GateHarnessState extends State<_GateHarness> {
  final _store = AppStore();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) => widget.auth.isSignedIn
          ? AppShell(store: _store)
          : LoginPage(
              auth: widget.auth,
              onSignedIn: () {},
            ),
    );
  }
}
