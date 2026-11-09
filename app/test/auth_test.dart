// 登录门验收：真实 OAuth2 授权码 + PKCE 全链路（浏览器授权由测试替身顶掉）。
//
// 这一轮登录页不再收集密码：账号框只是「登录提示」，真正的授权在系统浏览器完成，
// App 只接收回调 + 换 token + 拉 profile。因此这里断言的是：
// - 未配置登录服务时**不允许点击**且给出明确原因（不会静默假登录）；
// - 回调 state 校验、换码、拉 profile、落密钥库、建会话这条链路真的跑通；
// - state 不匹配 / 用户取消 / 组件不可用时都能如实反馈，且不产生会话。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/core/storage/secure_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/login_page.dart';
import 'package:recording_card/services/auth/auth.dart';
import 'package:recording_card/services/auth_service.dart';

import 'support/model_stub.dart';

/// 把授权回调里的 state 原样回传（真实场景由服务端重定向带回来）。
class _EchoLauncher implements WebAuthLauncher {
  _EchoLauncher({
    this.stateOverride,
    this.cancelled = false,
    this.supported = true,
    this.launchDelay = Duration.zero,
  });

  /// 非空时故意回一个错的 state（测 CSRF 校验）。
  final String? stateOverride;
  final bool cancelled;

  /// false = 当前构建没有浏览器授权组件（界面应禁用登录并说明原因）。
  final bool supported;

  /// > 0 时模拟「用户还在浏览器里操作」，用来断言登录中的忙碌态。
  final Duration launchDelay;

  Uri? lastAuthorizeUrl;
  String? lastCallbackScheme;

  @override
  bool get isSupported => supported;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    lastAuthorizeUrl = authorizeUrl;
    lastCallbackScheme = callbackScheme;
    if (launchDelay > Duration.zero) await Future<void>.delayed(launchDelay);
    if (!supported) throw const OAuthLauncherUnavailableException();
    if (cancelled) throw const OAuthCancelledException();
    final state = stateOverride ?? authorizeUrl.queryParameters['state'] ?? '';
    return Uri.parse('recording-card://callback?code=test-code&state=$state');
  }
}

/// 假服务端：token 端点 + profile 端点。返回的请求都留在 [requests] 里供断言。
class _FakeAuthServer {
  _FakeAuthServer({this.profileStatus = 200});

  final int profileStatus;
  final List<http.Request> requests = [];

  MockClient get client => MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('/oauth/token')) {
      return _json({
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'refresh_expires_in': 2592000,
      });
    }
    if (request.url.path.endsWith('/profile')) {
      if (profileStatus != 200) {
        return http.Response('{}', profileStatus);
      }
      return _json({
        'user_id': 'u-1',
        'display_name': '康康',
        'email': 'k@example.com',
      });
    }
    if (request.url.path.endsWith('/oauth/revoke')) {
      return http.Response('', 200);
    }
    return http.Response('{}', 404);
  });

  static http.Response _json(Map<String, dynamic> body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

/// 组装一个「登录服务已配置」的 AuthService（网络与浏览器都换成替身）。
({AuthService auth, _FakeAuthServer server, _EchoLauncher launcher, InMemorySecureStore secure})
_buildAuth({
  String? stateOverride,
  bool cancelled = false,
  bool launcherSupported = true,
  Duration launchDelay = Duration.zero,
  int profileStatus = 200,
}) {
  final server = _FakeAuthServer(profileStatus: profileStatus);
  final launcher = _EchoLauncher(
    stateOverride: stateOverride,
    cancelled: cancelled,
    supported: launcherSupported,
    launchDelay: launchDelay,
  );
  final secure = InMemorySecureStore();
  final client = OAuthClient(
    config: kStubOAuthConfig,
    httpClient: server.client,
  );
  final auth = AuthService(
    oauthConfig: kStubOAuthConfig,
    oauthClient: client,
    launcher: launcher,
    secureStore: secure,
  );
  return (auth: auth, server: server, launcher: launcher, secure: secure);
}

void main() {
  group('client_config（编译默认即远端模式）', () {
    test('API 主机的编译默认是自有网关，正常构建恒有远端后端', () {
      expect(ClientConfig.instance.apiBase, ClientConfig.defaultApiBase);
      expect(
        ClientConfig.instance.hasRemoteBackend,
        isTrue,
        reason: '正式版默认走真实后端，不再有「本地假会话」模式',
      );
    });

    test('编译默认复用 reai_mobile_app 的 OAuth public client（owner 决定先共用）', () {
      expect(
        ClientConfig.instance.normalizedOAuthClientId,
        ClientConfig.defaultOAuthClientId,
      );
      final auth = AuthService();
      expect(auth.isOAuthConfigured, isTrue, reason: '默认构建应当可以直接登录');
      expect(auth.signInBlockedReason, isNull);
    });

    test('显式清空 client id（RC_OAUTH_CLIENT_ID=）→ 登录服务未配置，登录前就讲清原因', () {
      // 通过注入一个 client id 为空的配置来模拟「运维决定关闭登录」
      final auth = AuthService(
        oauthConfig: OAuthConfig.fromEnvironment(
          clientConfig: const ClientConfig.forTesting(
            hasApiBaseDefine: false,
            apiBaseDefineValue: '',
            oauthClientId: '',
          ),
        ),
      );
      expect(auth.signInBlockedReason, '未配置登录服务，暂时无法登录');
      expect(auth.isOAuthConfigured, isFalse);
    });
  });

  group('AuthService（真实 OAuth 链路）', () {
    test('未配置登录服务时 signIn 直接返回原因，不发起任何流程', () {
      final auth = AuthService(
        oauthConfig: OAuthConfig.fromEnvironment(
          clientConfig: const ClientConfig.forTesting(
            hasApiBaseDefine: false,
            apiBaseDefineValue: '',
            oauthClientId: '',
          ),
        ),
      );
      expect(auth.signIn('kong', 'x'), '未配置登录服务，暂时无法登录');
      expect(auth.isSignedIn, isFalse);
      expect(auth.isBusy, isFalse);
    });

    test('空账号 → 「请输入账号」', () {
      final auth = AuthService();
      expect(auth.signIn('', 'x'), '请输入账号');
      expect(auth.signIn('  ', 'x'), '请输入账号');
    });

    test('成功：拉授权页 → 校验 state → 换码 → 拉 profile → 落密钥库 → 建会话', () async {
      final env = _buildAuth();
      addTearDown(env.auth.dispose);

      final error = await env.auth.signInWithOAuth(loginHint: 'k@example.com');
      expect(error, isNull, reason: '整条链路走通应该没有错误');
      expect(env.auth.isSignedIn, isTrue);
      expect(env.auth.session!.account, '康康');
      expect(env.auth.session!.userId, 'u-1');

      // 授权页参数：PKCE + 回调 + 提示
      final url = env.launcher.lastAuthorizeUrl!;
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'test-client');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['login_hint'], 'k@example.com');
      expect(env.launcher.lastCallbackScheme, 'recording-card');

      // 换码请求带 grant_type=authorization_code + verifier
      final tokenReq = env.server.requests.firstWhere(
        (r) => r.url.path.endsWith('/oauth/token'),
      );
      final tokenBody = Uri.splitQueryString(tokenReq.body);

      // 服务端明确只接受 S256（plain 会被 400 拒绝）：challenge 必须是
      // verifier 的 SHA-256 摘要，而不是 verifier 本身
      final challenge = url.queryParameters['code_challenge']!;
      expect(challenge, isNot(equals(tokenBody['code_verifier'])),
          reason: 'S256 下 challenge 不能等于 verifier');
      expect(challenge, hasLength(43), reason: 'S256 摘要 base64url 无 padding 为 43 字符');

      expect(tokenBody['grant_type'], 'authorization_code');
      expect(tokenBody['code'], 'test-code');
      expect(tokenBody['code_verifier'], isNotEmpty);

      // profile 请求带 access token
      final profileReq = env.server.requests.firstWhere(
        (r) => r.url.path.endsWith('/profile'),
      );
      expect(profileReq.headers['Authorization'], 'Bearer access-1');

      // token 落进密钥库（冷启动能恢复）
      expect(
        env.secure.snapshot.keys,
        contains('rc_oauth_token_bundle'),
      );
      expect(env.secure.snapshot['rc_oauth_token_bundle'], contains('access-1'));
    });

    test('回调 state 不匹配 → 明确报错，不建立会话', () async {
      final env = _buildAuth(stateOverride: 'tampered-state');
      addTearDown(env.auth.dispose);

      final error = await env.auth.signInWithOAuth();
      expect(error, isNotNull);
      expect(env.auth.isSignedIn, isFalse);
      expect(env.auth.lastError, error);
      // 没有拿到 token 就不会去换码
      expect(
        env.server.requests.any((r) => r.url.path.endsWith('/oauth/token')),
        isFalse,
      );
    });

    test('构建里没有浏览器授权组件 → 登录前就禁用并说明原因', () async {
      final env = _buildAuth(launcherSupported: false);
      addTearDown(env.auth.dispose);

      expect(env.auth.isWebAuthAvailable, isFalse);
      expect(env.auth.signInBlockedReason, '当前构建未内置浏览器授权组件，暂时无法完成登录');
      await expectLater(
        env.auth.signInWithOAuth(),
        completion('当前构建未内置浏览器授权组件，暂时无法完成登录'),
      );
      expect(env.auth.isSignedIn, isFalse);
      expect(env.launcher.lastAuthorizeUrl, isNull, reason: '不会去拉起浏览器');
    });

    test('用户在浏览器里取消 → 不报错、不建会话（不当成失败打扰用户）', () async {
      final env = _buildAuth(cancelled: true);
      addTearDown(env.auth.dispose);

      expect(await env.auth.signInWithOAuth(), isNull);
      expect(env.auth.isSignedIn, isFalse);
      expect(env.auth.lastError, isNull);
    });

    test('profile 拉不到（HTTP 500）→ 报错且不建立会话', () async {
      final env = _buildAuth(profileStatus: 500);
      addTearDown(env.auth.dispose);

      final error = await env.auth.signInWithOAuth();
      expect(error, isNotNull);
      expect(env.auth.isSignedIn, isFalse);
      expect(env.secure.snapshot.keys, isNot(contains('rc_oauth_token_bundle')));
    });

    test('登出：会话清空 + 密钥库删除 + 后台撤销 token', () async {
      final env = _buildAuth();
      addTearDown(env.auth.dispose);
      await env.auth.signInWithOAuth();
      expect(env.auth.isSignedIn, isTrue);

      var notified = 0;
      env.auth.addListener(() => notified++);
      env.auth.signOut();

      expect(env.auth.isSignedIn, isFalse);
      expect(env.auth.session, isNull);
      expect(notified, greaterThanOrEqualTo(1));
      // 撤销是「尽力而为」的后台动作：给事件队列一点时间
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        env.server.requests.any((r) => r.url.path.endsWith('/oauth/revoke')),
        isTrue,
      );
      expect(env.secure.snapshot.keys, isNot(contains('rc_oauth_token_bundle')));
    });
  });

  group('登录页（浏览器授权，无密码框）', () {
    Future<void> pumpLogin(
      WidgetTester tester,
      AuthService auth, {
      VoidCallback? onSignedIn,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: _GateHarness(auth: auth, onSignedIn: onSignedIn)),
      );
      await tester.pump();
    }

    testWidgets('未配置登录服务：按钮禁用 + 顶部讲明原因，没有密码框', (tester) async {
      // 显式注入「client id 为空」的配置，模拟运维关闭登录能力的构建
      final auth = AuthService(
        oauthConfig: OAuthConfig.fromEnvironment(
          clientConfig: const ClientConfig.forTesting(
            hasApiBaseDefine: false,
            apiBaseDefineValue: '',
            oauthClientId: '',
          ),
        ),
      );
      addTearDown(auth.dispose);
      await pumpLogin(tester, auth);

      expect(find.byKey(const Key('login-title')), findsOneWidget);
      expect(find.byKey(const Key('login-account')), findsOneWidget);
      expect(
        find.byKey(const Key('login-password')),
        findsNothing,
        reason: '密码只在服务方授权页输入，App 不收集',
      );
      expect(find.byKey(const Key('login-blocked')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('login-blocked'))).data,
        '未配置登录服务，暂时无法登录',
      );
      final submit = find.byKey(const Key('login-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(find.byType(AppShell), findsNothing);
    });

    testWidgets('配置齐全：点登录 → 走完授权 → 进入应用外壳', (tester) async {
      final env = _buildAuth();
      addTearDown(env.auth.dispose);
      var signedIn = 0;
      await pumpLogin(tester, env.auth, onSignedIn: () => signedIn++);

      expect(find.byKey(const Key('login-blocked')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('login-account')),
        'k@example.com',
      );
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pump();
      await tester.pump();

      expect(env.auth.isSignedIn, isTrue);
      expect(signedIn, 1);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byKey(const Key('app-title')), findsOneWidget);
    });

    testWidgets('登录中：按钮转忙碌态，完成后进入外壳', (tester) async {
      final env = _buildAuth(launchDelay: const Duration(milliseconds: 400));
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pump();
      expect(find.byKey(const Key('login-busy')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('login-submit'))).onPressed,
        isNull,
        reason: '授权进行中不允许重复点击',
      );
      expect(find.byType(AppShell), findsNothing);

      // 浏览器回调回来 → 换码 → 建会话
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(env.auth.isSignedIn, isTrue);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('授权失败：行内错误就地展示，仍留在登录页', (tester) async {
      final env = _buildAuth(stateOverride: 'tampered-state');
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('login-error')), findsOneWidget);
      expect(env.auth.isSignedIn, isFalse);
      expect(find.byType(AppShell), findsNothing);
    });
  });
}

/// 登录门等价装配（与 main.AppGate 同构）。
class _GateHarness extends StatefulWidget {
  const _GateHarness({required this.auth, this.onSignedIn});
  final AuthService auth;
  final VoidCallback? onSignedIn;

  @override
  State<_GateHarness> createState() => _GateHarnessState();
}

class _GateHarnessState extends State<_GateHarness> {
  final _store = AppStore(events: seedEvents, loadPersistedState: false);

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) => widget.auth.isSignedIn
          ? AppShell(store: _store)
          : LoginPage(
              auth: widget.auth,
              onSignedIn: () => widget.onSignedIn?.call(),
            ),
    );
  }
}
