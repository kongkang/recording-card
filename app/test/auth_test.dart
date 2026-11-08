// 登录门验收：生产密码入口拒绝，OAuth夹具只在测试注入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/login_page.dart';
import 'package:recording_card/services/auth_service.dart';

import 'fixtures/legacy_ui_fixture.dart';

void main() {
  group('client_config', () {
    test('未配置端点：保持公开OAuth配置，无隐式请求', () {
      expect(ClientConfig.instance.apiBase, isNull);
      expect(ClientConfig.instance.hasRemoteBackend, isFalse);
      expect(ClientConfig.instance.oauthClientId, isNotEmpty);
      expect(
        ClientConfig.instance.oauthRedirectUri,
        'recording-card://callback',
      );
    });
  });
  group('auth_service', () {
    test('空账号 / 空密码返回错误文案，不建立会话', () {
      final auth = AuthService();
      addTearDown(auth.dispose);
      expect(auth.signIn('', 'x'), '请输入账号');
      expect(auth.signIn(' ', 'x'), '请输入账号');
      expect(auth.signIn('kong', ''), '请输入密码');
      expect(auth.isSignedIn, isFalse);
      expect(auth.signIn('kong', 'secret'), contains('OAuth'));
      expect(auth.isSignedIn, isFalse);
    });
    test('OAuth夹具建立会话并通知，生产不接受本地密码', () async {
      final auth = fixtureAuth();
      addTearDown(auth.dispose);
      final states = <bool>[];
      auth.addListener(() => states.add(auth.isSignedIn));
      expect(auth.signIn('kong', 'secret'), contains('OAuth'));
      expect(auth.isSignedIn, isFalse);
      await auth.signInWithOAuth();
      expect(auth.isSignedIn, isTrue);
      expect(auth.session!.account, 'test-user-1@example.test');
      expect(states, [false, true]);
      await auth.signOut();
      expect(auth.isSignedIn, isFalse);
      expect(states, [false, true, false]);
    });
  });
  testWidgets('login-gate：行内错误 → 登录成功进入应用外壳', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = fixtureAuth();
    addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home: _GateHarness(auth: auth)));
    await tester.pump();
    expect(find.byKey(const Key('login-title')), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.byKey(const Key('login-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byKey(const Key('app-title')), findsOneWidget);
  });
}

class _GateHarness extends StatefulWidget {
  const _GateHarness({required this.auth});
  final AuthService auth;
  @override
  State<_GateHarness> createState() => _GateHarnessState();
}

class _GateHarnessState extends State<_GateHarness> {
  final AppStore _store = legacyAppFixture();
  bool _first = true;
  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) => widget.auth.isSignedIn
        ? AppShell(store: _store)
        : LoginPage(
            auth: widget.auth,
            onSignedIn: () {},
            authorize: () async {
              if (_first) {
                _first = false;
                throw StateError('测试授权取消');
              }
              await widget.auth.signInWithOAuth();
            },
          ),
  );
}
