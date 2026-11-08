// 远端 OAuth 登录门验收（TDD）—— 配置 OAuth 后隐藏密码、走系统授权；
// 本地账号密码不能绕过；失败行内提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/kv_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/login_page.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/oauth/oauth_client.dart';
import 'package:recording_card/services/oauth/oauth_login_coordinator.dart';
import 'package:recording_card/services/oauth/oauth_token_store.dart';
import 'package:recording_card/services/oauth/secure_store.dart';

class FakeOAuthSignIn implements OAuthSignIn {
  FakeOAuthSignIn({this.account = 'oauth@user', this.error});

  final String account;
  final Object? error;
  int calls = 0;
  String? lastLoginHint;

  @override
  Future<OAuthLoginResult> signIn({String? loginHint, String? prompt}) async {
    calls++;
    lastLoginHint = loginHint;
    final failure = error;
    if (failure != null) throw failure;
    return OAuthLoginResult(
      account: account,
      tokens: OAuthTokens(
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
        refreshExpiresAt: DateTime.now().add(const Duration(days: 1)),
      ),
      profile: const {'email': 'oauth@user'},
    );
  }
}

AuthService _auth(OAuthSignIn oauth) => AuthService(
      storage: MemoryKvStore(),
      oauthLogin: oauth,
      oauthTokens: OAuthTokenStore(MemorySecureStore()),
    );

void main() {
  testWidgets('OAuth 模式：隐藏密码，授权成功进入外壳', (tester) async {
    final oauth = FakeOAuthSignIn();
    final auth = _auth(oauth);
    await tester.pumpWidget(MaterialApp(home: _Gate(auth: auth)));
    await tester.pump();

    expect(find.byKey(const Key('login-password')), findsNothing);
    expect(find.text('使用账号登录'), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);

    await tester.enterText(find.byKey(const Key('login-account')), 'a@b.com');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    await tester.pump();

    expect(oauth.calls, 1);
    expect(oauth.lastLoginHint, 'a@b.com');
    expect(auth.session!.account, 'oauth@user');
    expect(find.byType(AppShell), findsOneWidget);
  });

  testWidgets('OAuth 失败：行内错误，不进入外壳', (tester) async {
    final auth = _auth(FakeOAuthSignIn(
        error: const OAuthException('access_denied', '授权被拒绝')));
    await tester.pumpWidget(MaterialApp(home: _Gate(auth: auth)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('login-error')), findsOneWidget);
    expect(find.text('授权被拒绝'), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
  });

  test('OAuth 模式下本地账号密码不能绕过', () {
    final auth = _auth(FakeOAuthSignIn());
    expect(auth.signIn('a', 'b'), '请使用系统授权登录');
    expect(auth.isSignedIn, isFalse);
  });
}

class _Gate extends StatefulWidget {
  const _Gate({required this.auth});

  final AuthService auth;

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  final _store = AppStore();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) => widget.auth.isSignedIn
          ? AppShell(store: _store)
          : LoginPage(auth: widget.auth, onSignedIn: () {}),
    );
  }
}
