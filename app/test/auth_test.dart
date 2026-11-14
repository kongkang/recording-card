// 登录门验收：真实 OAuth2 授权码 + PKCE 全链路（浏览器授权由测试替身顶掉）。
//
// 这一轮登录页不再收集密码：账号框只是「登录提示」，真正的授权在系统浏览器完成，
// App 只接收回调 + 换 token + 拉 profile。因此这里断言的是：
// - 未配置登录服务时**不允许点击**且给出明确原因（不会静默假登录）；
// - 回调 state 校验、换码、拉 profile、落密钥库、建会话这条链路真的跑通；
// - state 不匹配 / 用户取消 / 组件不可用时都能如实反馈，且不产生会话。
library;

import 'dart:async';
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
import 'package:recording_card/services/wechat_login/wechat_login_service.dart';

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

/// 假服务端：token 端点 + profile 端点 + social providers 端点。返回的请求都留在 [requests] 里供断言。
class _FakeAuthServer {
  _FakeAuthServer({
    this.profileStatus = 200,
    this.wechatTokenError,
    this.socialProviders,
    this.socialProvidersStatus = 200,
  });

  final int profileStatus;

  /// 非空时，微信扩展 grant 的 /oauth/token 请求回 400 {error: <该值>}。
  final String? wechatTokenError;

  /// 非空时，`/auth/social/providers` 返回该列表。
  final List<String>? socialProviders;

  /// `/auth/social/providers` 响应状态码。
  final int socialProvidersStatus;

  final List<http.Request> requests = [];

  MockClient get client => MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('/auth/social/providers')) {
      if (socialProvidersStatus != 200) {
        return http.Response('{}', socialProvidersStatus);
      }
      if (socialProviders != null) {
        return _json({'providers': socialProviders});
      }
    }
    if (request.url.path.endsWith('/oauth/token')) {
      final body = Uri.splitQueryString(request.body);
      final isWechatGrant = body['grant_type'] == OAuthConfig.wechatGrantType;
      if (isWechatGrant && wechatTokenError != null) {
        return http.Response(
          '{"error":"$wechatTokenError","error_description":"not enabled"}',
          400,
        );
      }
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
  List<String>? socialProviders,
  int socialProvidersStatus = 200,
  Set<String>? initialSocialProviders,
}) {
  final server = _FakeAuthServer(
    profileStatus: profileStatus,
    socialProviders: socialProviders,
    socialProvidersStatus: socialProvidersStatus,
  );
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
    initialSocialProviders: initialSocialProviders,
  );
  return (auth: auth, server: server, launcher: launcher, secure: secure);
}

/// 微信网关替身：authorize 行为可注入（挂起 / 抛错 / 返回 code）。
class _FakeWechatGateway implements WechatLoginGateway {
  _FakeWechatGateway({
    bool configured = true,
    bool? installed,
    this.onAuthorize,
  })  : isConfigured = configured,
        cachedIsInstalled = installed;

  @override
  final bool isConfigured;

  /// 三态安装缓存（null = 未探测）。
  @override
  bool? cachedIsInstalled;

  int initializeCalls = 0;
  int authorizeCalls = 0;
  int cancelCalls = 0;

  /// authorize 的行为；缺省返回固定 code。
  final Future<WechatAuthorizationCode> Function(
      _FakeWechatGateway gateway)? onAuthorize;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    cachedIsInstalled ??= true;
  }

  @override
  Future<WechatAuthorizationCode> authorize() {
    authorizeCalls++;
    final handler = onAuthorize;
    if (handler == null) {
      return Future.value(
        const WechatAuthorizationCode(code: 'wx-code-1', lang: 'zh_CN'),
      );
    }
    return handler(this);
  }

  @override
  void cancelPendingAuthorization() {
    cancelCalls++;
  }
}

/// 组装「微信已配置」的 AuthService（网络 / 浏览器 / 微信网关全部替身）。
({AuthService auth, _FakeAuthServer server, _EchoLauncher launcher, InMemorySecureStore secure, _FakeWechatGateway wechat})
_buildWechatAuth({
  String? wechatTokenError,
  _FakeWechatGateway? wechatGateway,
  String oauthClientId = 'test-client',
  Duration launchDelay = Duration.zero,
  List<String>? socialProviders,
  Set<String>? initialSocialProviders,
}) {
  final server = _FakeAuthServer(
    wechatTokenError: wechatTokenError,
    socialProviders: socialProviders,
  );
  final launcher = _EchoLauncher(launchDelay: launchDelay);
  final secure = InMemorySecureStore();
  final config = oauthClientId == 'test-client'
      ? kStubOAuthConfig.copyWith(wechatAppId: 'wxtest1234567890abcd')
      : kStubOAuthConfig.copyWith(
          clientId: oauthClientId, wechatAppId: 'wxtest1234567890abcd');
  final client = OAuthClient(config: config, httpClient: server.client);
  final wechat = wechatGateway ?? _FakeWechatGateway();
  final auth = AuthService(
    oauthConfig: config,
    oauthClient: client,
    launcher: launcher,
    wechatGateway: wechat,
    secureStore: secure,
    initialSocialProviders: initialSocialProviders,
  );
  return (
    auth: auth,
    server: server,
    launcher: launcher,
    secure: secure,
    wechat: wechat,
  );
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
      expect(
        find.byKey(const Key('login-account')),
        findsNothing,
        reason: '已移除无用的可选账号输入框',
      );
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
      expect(find.byKey(const Key('login-account')), findsNothing);
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

  group('AuthService（微信原生登录链路）', () {
    test('成功：authorize → 微信扩展 grant 换 token → 拉 profile → 落库 → 建会话', () async {
      final env = _buildWechatAuth();
      addTearDown(env.auth.dispose);

      final error = await env.auth.signInWithWechat();
      expect(error, isNull);
      expect(env.auth.isSignedIn, isTrue);
      expect(env.auth.session!.account, '康康');

      final tokenReq = env.server.requests.firstWhere(
        (r) => r.url.path.endsWith('/oauth/token'),
      );
      final body = Uri.splitQueryString(tokenReq.body);
      expect(body['grant_type'], OAuthConfig.wechatGrantType);
      expect(body['client_id'], 'test-client');
      expect(body['code'], 'wx-code-1');
      expect(body['app_type'], 'app');
      expect(body['scope'], 'mobile:full profile:read');
      expect(body['lang'], 'zh_CN');
      expect(body['wechat_app_id'], 'wxtest1234567890abcd',
          reason: '多微信应用路由字段：配置了合法 AppID 必须上送');
      expect(env.secure.snapshot['rc_oauth_token_bundle'], contains('access-1'));
    });

    test('用户在微信内取消 → 返回 null、无会话、无错误文案（静默）', () async {
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(
          onAuthorize: (_) =>
              throw const WechatLoginException(WechatLoginFailureKind.cancelled),
        ),
      );
      addTearDown(env.auth.dispose);

      expect(await env.auth.signInWithWechat(), isNull);
      expect(env.auth.isSignedIn, isFalse);
      expect(env.auth.lastError, isNull);
      expect(env.auth.isBusy, isFalse);
      expect(env.auth.activeChannel, AuthChannel.none);
    });

    test('微信拒绝（-4）→ 明确中文文案，不建会话', () async {
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(
          onAuthorize: (_) =>
              throw const WechatLoginException(WechatLoginFailureKind.denied),
        ),
      );
      addTearDown(env.auth.dispose);

      expect(await env.auth.signInWithWechat(), '微信授权已拒绝，请重试或使用上方方式登录');
      expect(env.auth.isSignedIn, isFalse);
    });

    test('未安装微信 → 「未检测到微信」文案（不说「请先安装微信」）', () async {
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(
          onAuthorize: (_) => throw const WechatLoginException(
              WechatLoginFailureKind.notInstalled),
        ),
      );
      addTearDown(env.auth.dispose);

      expect(await env.auth.signInWithWechat(), '未检测到微信，请使用上方方式登录');
    });

    test('后端未放行微信 grant（unsupported_grant_type）→ 中文兜底文案', () async {
      final env = _buildWechatAuth(wechatTokenError: 'unsupported_grant_type');
      addTearDown(env.auth.dispose);

      expect(await env.auth.signInWithWechat(), '当前客户端未开通微信登录');
      expect(env.auth.isSignedIn, isFalse);
    });

    test('authorize 挂起期间登出 → 迟到 code 被代次拦截，不换 token、不复活会话', () async {
      final pending = Completer<WechatAuthorizationCode>();
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(onAuthorize: (_) => pending.future),
      );
      addTearDown(env.auth.dispose);

      final inFlight = env.auth.signInWithWechat();
      await Future<void>.delayed(Duration.zero);
      expect(env.auth.isBusy, isTrue);

      env.auth.signOut();
      pending.complete(
        const WechatAuthorizationCode(code: 'late-code', lang: 'zh_CN'),
      );

      expect(await inFlight, isNull);
      expect(env.auth.isSignedIn, isFalse);
      expect(
        env.server.requests.any((r) => r.url.path.endsWith('/oauth/token')),
        isFalse,
        reason: '登出后到期的授权码不得再去换 token',
      );
    });

    test('微信授权在途时发起浏览器登录 → 被统一 busy 拒绝（防双通道并发）', () async {
      final pending = Completer<WechatAuthorizationCode>();
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(onAuthorize: (_) => pending.future),
      );
      addTearDown(env.auth.dispose);

      final inFlight = env.auth.signInWithWechat();
      await Future<void>.delayed(Duration.zero);

      expect(await env.auth.signInWithOAuth(), '登录正在进行中，请稍候');
      expect(env.launcher.lastAuthorizeUrl, isNull, reason: '不得拉起浏览器授权');
      expect(env.auth.activeChannel, AuthChannel.wechat);

      pending.complete(
        const WechatAuthorizationCode(code: 'wx-code-1', lang: 'zh_CN'),
      );
      expect(await inFlight, isNull);
      expect(env.auth.isSignedIn, isTrue);
    });

    test('OAuth 服务整体未配置（client id 空）→ 微信入口也被连坐禁用', () async {
      final env = _buildWechatAuth(oauthClientId: '');
      addTearDown(env.auth.dispose);

      expect(env.auth.signInBlockedReason, '未配置登录服务，暂时无法登录');
      expect(env.auth.wechatSignInBlockedReason, '未配置登录服务，暂时无法登录');
      expect(await env.auth.signInWithWechat(), '未配置登录服务，暂时无法登录');
    });

    test('prewarmWechat：预热调 gateway.initialize 并刷新显隐依据，异常不外泄', () async {
      final gateway = _FakeWechatGateway(installed: false);
      final env = _buildWechatAuth(wechatGateway: gateway);
      addTearDown(env.auth.dispose);

      await env.auth.prewarmWechat();
      expect(gateway.initializeCalls, 1);
      expect(env.auth.shouldShowWechatSignIn, isFalse,
          reason: '明确未装微信 → 登录页隐藏微信按钮');

      // 未配置的网关：预热 no-op，不触达 SDK
      final off = _FakeWechatGateway(configured: false);
      final envOff = _buildWechatAuth(wechatGateway: off);
      addTearDown(envOff.auth.dispose);
      await envOff.auth.prewarmWechat();
      expect(off.initializeCalls, 0);
    });

    test('真实 WechatLoginService 挂起期间登出 → 立即重置单飞锁，再次登录可正常完成', () async {
      final sdk = _TestWechatSdkAdapter();
      final service = WechatLoginService(
        sdk: sdk,
        wechatAppId: 'wxtest1234567890abcd',
        timeout: const Duration(minutes: 2),
      );
      final server = _FakeAuthServer();
      final secure = InMemorySecureStore();
      final config = kStubOAuthConfig.copyWith(
        wechatAppId: 'wxtest1234567890abcd',
      );
      final auth = AuthService(
        oauthConfig: config,
        oauthClient: OAuthClient(config: config, httpClient: server.client),
        launcher: _EchoLauncher(),
        wechatGateway: service,
        secureStore: secure,
      );
      addTearDown(auth.dispose);

      final first = auth.signInWithWechat();
      await Future<void>.delayed(Duration.zero);
      expect(auth.isBusy, isTrue);
      expect(sdk.listeners, hasLength(1));

      auth.signOut();
      expect(await first, isNull);
      expect(auth.isBusy, isFalse);
      expect(sdk.listeners, isEmpty);

      // 不等 2 分钟超时，立即发起第二次微信登录必须能拉起并成功建会话
      final second = auth.signInWithWechat();
      await Future<void>.delayed(Duration.zero);
      expect(sdk.listeners, hasLength(1));
      sdk.emit(
        WechatSdkAuthResponse(
          errorCode: 0,
          code: 'wx-code-2',
          state: sdk.lastState,
          lang: 'zh_CN',
        ),
      );
      expect(await second, isNull);
      expect(auth.isSignedIn, isTrue);
      expect(auth.session!.account, '康康');
    });

    test('浏览器登录在途时误触微信登录 → 返回提示但不写脏 lastError；随后取消浏览器登录仍保持静默', () async {
      final server = _FakeAuthServer();
      final launcher = _EchoLauncher(
        cancelled: true,
        launchDelay: const Duration(milliseconds: 20),
      );
      final config = kStubOAuthConfig.copyWith(
        wechatAppId: 'wxtest1234567890abcd',
      );
      final auth = AuthService(
        oauthConfig: config,
        oauthClient: OAuthClient(config: config, httpClient: server.client),
        launcher: launcher,
        wechatGateway: _FakeWechatGateway(),
        secureStore: InMemorySecureStore(),
      );
      addTearDown(auth.dispose);

      final oauthFuture = auth.signInWithOAuth();
      await Future<void>.delayed(Duration.zero);
      expect(auth.isBusy, isTrue);

      expect(await auth.signInWithWechat(), '登录正在进行中，请稍候');
      expect(auth.lastError, isNull, reason: '在途并发拦截不得写脏 lastError');

      expect(await oauthFuture, isNull);
      expect(auth.lastError, isNull);
      expect(auth.isBusy, isFalse);
    });

    test('挂起流程在 signOut 之后抛错 → 旧代次异常被忽略，不写脏 lastError', () async {
      final pending = Completer<WechatAuthorizationCode>();
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(onAuthorize: (_) => pending.future),
      );
      addTearDown(env.auth.dispose);

      final inFlight = env.auth.signInWithWechat();
      await Future<void>.delayed(Duration.zero);

      env.auth.signOut();
      expect(env.wechat.cancelCalls, 1);
      pending.completeError(const WechatLoginException(WechatLoginFailureKind.timedOut));

      expect(await inFlight, isNull);
      expect(env.auth.lastError, isNull, reason: '旧代次超时不得污染已登出后的 lastError');
      expect(env.auth.isSignedIn, isFalse);
    });
  });

  group('登录页（微信入口显隐与并发）', () {
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

    testWidgets('默认构建（审核未通过未配微信 AppID / 社会化渠道未启用）→ 按钮可见但保持 disabled，底部文案不提微信', (tester) async {
      final env = _buildAuth(); // 未注入微信网关（AppID 为空），且未预热开启 Apple/Google
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      final wechatBtn = find.byKey(const Key('login-wechat'));
      final appleBtn = find.byKey(const Key('login-apple'));
      final googleBtn = find.byKey(const Key('login-google'));
      expect(wechatBtn, findsOneWidget, reason: '审核通过前微信按钮仍展示，但保持 disabled');
      expect(appleBtn, findsOneWidget, reason: '未开启时 Apple 按钮仍展示，但保持 disabled');
      expect(googleBtn, findsOneWidget, reason: '未开启时 Google 按钮仍展示，但保持 disabled');
      expect(tester.widget<OutlinedButton>(wechatBtn).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(appleBtn).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(googleBtn).onPressed, isNull);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('login-submit'))).onPressed,
        isNotNull,
        reason: '外脑主登录按钮正常可用',
      );
      expect(
        find.text('登录将在系统浏览器中完成，App 不会获取你的密码。'),
        findsOneWidget,
      );
    });

    testWidgets('微信已配置（缓存未探测）→ 按钮可见且可点击，底部文案含微信', (tester) async {
      final env = _buildWechatAuth();
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      final wechatBtn = find.byKey(const Key('login-wechat'));
      expect(wechatBtn, findsOneWidget);
      expect(tester.widget<OutlinedButton>(wechatBtn).onPressed, isNotNull);
      expect(
        find.text('授权将在系统浏览器或微信中完成，App 不会获取你的密码。'),
        findsOneWidget,
      );
    });

    testWidgets('明确未安装微信（缓存 false）→ 按钮隐藏（App Store 4.2.3）', (tester) async {
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(installed: false),
      );
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      expect(find.byKey(const Key('login-wechat')), findsNothing);
      expect(
        find.text('登录将在系统浏览器中完成，App 不会获取你的密码。'),
        findsOneWidget,
      );
    });

    testWidgets('登录服务关闭（client id 空）→ 浏览器与微信按钮双双禁用', (tester) async {
      final env = _buildWechatAuth(oauthClientId: '');
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      expect(
        tester.widget<FilledButton>(find.byKey(const Key('login-submit'))).onPressed,
        isNull,
      );
      final wechat = find.byKey(const Key('login-wechat'));
      expect(wechat, findsOneWidget, reason: '微信网关本身已配置 → 按钮可见但禁用');
      expect(
        tester.widget<OutlinedButton>(wechat).onPressed,
        isNull,
        reason: '换 token 走同一端点/client_id，OAuth 未配置必须连坐禁用',
      );
      expect(find.byKey(const Key('login-blocked')), findsOneWidget);
    });

    testWidgets('微信授权在途 → 微信按钮转圈、浏览器/Apple/Google 按钮禁用且不拉浏览器', (tester) async {
      final pending = Completer<WechatAuthorizationCode>();
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(onAuthorize: (_) => pending.future),
        initialSocialProviders: const {'apple', 'google'},
      );
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      await tester.tap(find.byKey(const Key('login-wechat')));
      await tester.pump();

      expect(find.byKey(const Key('login-wechat-busy')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('login-submit'))).onPressed,
        isNull,
        reason: '微信授权期间浏览器登录必须禁用',
      );
      expect(
        tester.widget<OutlinedButton>(find.byKey(const Key('login-apple'))).onPressed,
        isNull,
        reason: '微信授权期间 Apple 按钮必须禁用',
      );
      expect(
        tester.widget<OutlinedButton>(find.byKey(const Key('login-google'))).onPressed,
        isNull,
        reason: '微信授权期间 Google 按钮必须禁用',
      );
      expect(env.launcher.lastAuthorizeUrl, isNull);

      pending.complete(
        const WechatAuthorizationCode(code: 'wx-code-1', lang: 'zh_CN'),
      );
      await tester.pump();
      await tester.pump();
      expect(env.auth.isSignedIn, isTrue);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('微信登录成功 → 进入应用外壳（onSignedIn 以会话建立为准）', (tester) async {
      final env = _buildWechatAuth();
      addTearDown(env.auth.dispose);
      var signedIn = 0;
      await pumpLogin(tester, env.auth, onSignedIn: () => signedIn++);

      await tester.tap(find.byKey(const Key('login-wechat')));
      await tester.pump();
      await tester.pump();

      expect(env.auth.isSignedIn, isTrue);
      expect(signedIn, 1);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('先报错再取消：错误文案展示后取消登录 → 旧错清空、按钮恢复可点', (tester) async {
      var call = 0;
      final env = _buildWechatAuth(
        wechatGateway: _FakeWechatGateway(onAuthorize: (_) {
          call++;
          if (call == 1) {
            throw const WechatLoginException(WechatLoginFailureKind.denied);
          }
          throw const WechatLoginException(WechatLoginFailureKind.cancelled);
        }),
      );
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      // 第一发：拒绝 → 显示错误
      await tester.tap(find.byKey(const Key('login-wechat')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('login-error')), findsOneWidget);

      // 第二发：取消 → 静默，旧错误被清空，按钮回到可点
      await tester.tap(find.byKey(const Key('login-wechat')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('login-error')), findsNothing);
      expect(env.auth.lastError, isNull);
      expect(
        tester.widget<OutlinedButton>(find.byKey(const Key('login-wechat'))).onPressed,
        isNotNull,
      );
      expect(env.auth.isSignedIn, isFalse);
    });
  });

  group('OAuthClient（login_type 与 /auth/social/providers）', () {
    test('createAuthorizationRequest：支持透传合法 login_type 并拒绝未知值', () {
      final client = OAuthClient(
        config: kStubOAuthConfig,
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      );
      addTearDown(client.close);

      final appleReq = client.createAuthorizationRequest(loginType: 'apple');
      expect(appleReq.url.queryParameters['login_type'], 'apple');

      final multiReq = client.createAuthorizationRequest(loginType: ' wechat , google ');
      expect(multiReq.url.queryParameters['login_type'], 'wechat,google');

      expect(
        () => client.createAuthorizationRequest(loginType: 'unknown_provider'),
        throwsArgumentError,
      );
    });

    test('fetchSocialProviders：过滤合法白名单并规范化错误响应', () async {
      final okClient = OAuthClient(
        config: kStubOAuthConfig,
        httpClient: MockClient(
          (_) async => http.Response(
            '{"providers":["Apple","google","unknown_x","alipay"]}',
            200,
          ),
        ),
      );
      addTearDown(okClient.close);
      expect(
        await okClient.fetchSocialProviders(),
        equals({'apple', 'google', 'alipay'}),
      );

      final errClient = OAuthClient(
        config: kStubOAuthConfig,
        httpClient: MockClient((_) async => http.Response('fail', 503)),
      );
      addTearDown(errClient.close);
      await expectLater(
        errClient.fetchSocialProviders(),
        throwsA(isA<OAuthServerException>()),
      );

      final badJsonClient = OAuthClient(
        config: kStubOAuthConfig,
        httpClient: MockClient((_) async => http.Response('not-json', 200)),
      );
      addTearDown(badJsonClient.close);
      await expectLater(
        badJsonClient.fetchSocialProviders(),
        throwsA(isA<OAuthServerException>()),
      );
    });
  });

  group('AuthService（Apple / Google 原生入口与渠道预热）', () {
    test('prewarmSocialProviders：未开通前按钮可见但 disabled，按服务端返回点亮 enabled，异常不外泄', () async {
      final env = _buildAuth(socialProviders: ['apple', 'github']);
      addTearDown(env.auth.dispose);

      expect(env.auth.shouldShowAppleSignIn, isTrue);
      expect(env.auth.shouldShowGoogleSignIn, isTrue);
      expect(env.auth.isAppleSignInEnabled, isFalse);
      expect(env.auth.isGoogleSignInEnabled, isFalse);

      await env.auth.prewarmSocialProviders();
      expect(env.auth.cachedSocialProviders, equals({'apple', 'github'}));
      expect(env.auth.isAppleSignInEnabled, isTrue);
      expect(env.auth.isGoogleSignInEnabled, isFalse);

      // 异常场景：服务端 500 静默吞错、不污染 lastError，按钮保持 disabled
      final failEnv = _buildAuth(socialProviders: const ['apple'], socialProvidersStatus: 500);
      addTearDown(failEnv.auth.dispose);
      await failEnv.auth.prewarmSocialProviders();
      expect(failEnv.auth.cachedSocialProviders, isNull);
      expect(failEnv.auth.lastError, isNull);
      expect(failEnv.auth.shouldShowAppleSignIn, isTrue);
      expect(failEnv.auth.isAppleSignInEnabled, isFalse);
    });

    test('socialProvidersOverride 优先于网络探测，不发请求', () async {
      final server = _FakeAuthServer(socialProviders: const ['github']);
      final client = OAuthClient(
        config: kStubOAuthConfig.copyWith(
          socialProvidersOverride: const {'apple', 'google'},
        ),
        httpClient: server.client,
      );
      final auth = AuthService(
        oauthConfig: kStubOAuthConfig.copyWith(
          socialProvidersOverride: const {'apple', 'google'},
        ),
        oauthClient: client,
        launcher: _EchoLauncher(),
        secureStore: InMemorySecureStore(),
      );
      addTearDown(auth.dispose);

      expect(auth.shouldShowAppleSignIn, isTrue);
      expect(auth.shouldShowGoogleSignIn, isTrue);
      expect(auth.isAppleSignInEnabled, isTrue);
      expect(auth.isGoogleSignInEnabled, isTrue);
      await auth.prewarmSocialProviders();
      expect(
        server.requests.where((r) => r.url.path.endsWith('/auth/social/providers')),
        isEmpty,
      );
    });

    test('signInWithApple / signInWithGoogle：透传 login_type、通道追踪与互斥代次拦截', () async {
      final env = _buildAuth(
        launchDelay: const Duration(milliseconds: 20),
        initialSocialProviders: const {'apple', 'google'},
      );
      addTearDown(env.auth.dispose);

      final appleFuture = env.auth.signInWithApple();
      await Future<void>.delayed(Duration.zero);
      expect(env.auth.isBusy, isTrue);
      expect(env.auth.activeChannel, AuthChannel.apple);
      expect(await env.auth.signInWithGoogle(), '登录正在进行中，请稍候');
      expect(await env.auth.signInWithOAuth(), '登录正在进行中，请稍候');

      expect(await appleFuture, isNull);
      expect(env.auth.isSignedIn, isTrue);
      expect(env.launcher.lastAuthorizeUrl?.queryParameters['login_type'], 'apple');

      // 登出后测 Google，并在途调用 signOut 验证代次作废
      env.auth.signOut();
      expect(env.auth.isSignedIn, isFalse);

      final googleFuture = env.auth.signInWithGoogle();
      await Future<void>.delayed(Duration.zero);
      expect(env.auth.activeChannel, AuthChannel.google);
      env.auth.signOut();
      expect(await googleFuture, isNull);
      expect(env.auth.isSignedIn, isFalse);

      // 正常完成一次 Google 登录
      expect(await env.auth.signInWithGoogle(), isNull);
      expect(env.auth.isSignedIn, isTrue);
      expect(env.launcher.lastAuthorizeUrl?.queryParameters['login_type'], 'google');
    });
  });

  group('登录页（四通道重构与端到端交互流）', () {
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

    testWidgets('四通道全配齐：无账号输入框，主入口与三个原生入口同时展示', (tester) async {
      final env = _buildWechatAuth(
        initialSocialProviders: const {'apple', 'google'},
      );
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      expect(find.byKey(const Key('login-account')), findsNothing);
      expect(find.text('使用外脑账号登录'), findsOneWidget);
      expect(find.text('其他登录方式'), findsOneWidget);
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
      expect(find.byKey(const Key('login-wechat')), findsOneWidget);
      expect(find.byKey(const Key('login-apple')), findsOneWidget);
      expect(find.byKey(const Key('login-google')), findsOneWidget);
    });

    testWidgets('Apple / Google 点击忙碌态独立转圈，并在途禁用其余三按钮', (tester) async {
      final env = _buildWechatAuth(
        launchDelay: const Duration(milliseconds: 300),
        initialSocialProviders: const {'apple', 'google'},
      );
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      // 1) 点 Apple
      await tester.tap(find.byKey(const Key('login-apple')));
      await tester.pump();
      expect(find.byKey(const Key('login-apple-busy')), findsOneWidget);
      expect(find.byKey(const Key('login-google-busy')), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const Key('login-submit'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('login-wechat'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('login-google'))).onPressed, isNull);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(env.auth.isSignedIn, isTrue);
      expect(env.launcher.lastAuthorizeUrl?.queryParameters['login_type'], 'apple');

      // 2) 登出回到登录页，再点 Google
      env.auth.signOut();
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-google')));
      await tester.pump();
      expect(find.byKey(const Key('login-google-busy')), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('login-apple'))).onPressed, isNull);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(env.auth.isSignedIn, isTrue);
      expect(env.launcher.lastAuthorizeUrl?.queryParameters['login_type'], 'google');
    });

    testWidgets('端到端闭环：未登录 → Apple 登录进 AppShell → 登出回登录页 → 微信登录进 AppShell', (tester) async {
      final env = _buildWechatAuth(
        socialProviders: const ['apple', 'google'],
      );
      addTearDown(env.auth.dispose);
      await env.auth.prewarmSocialProviders();
      var signedInCount = 0;
      await pumpLogin(tester, env.auth, onSignedIn: () => signedInCount++);

      // Step 1: Apple 登录 → AppShell
      await tester.tap(find.byKey(const Key('login-apple')));
      await tester.pump();
      await tester.pump();
      expect(env.auth.isSignedIn, isTrue);
      expect(signedInCount, 1);
      expect(find.byType(AppShell), findsOneWidget);
      expect(env.launcher.lastAuthorizeUrl?.queryParameters['login_type'], 'apple');

      // Step 2: 登出回到登录页
      env.auth.signOut();
      await tester.pump();
      expect(find.byType(AppShell), findsNothing);
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
      expect(find.byKey(const Key('login-wechat')), findsOneWidget);

      // Step 3: 微信登录 → 再次进入 AppShell
      await tester.tap(find.byKey(const Key('login-wechat')));
      await tester.pump();
      await tester.pump();
      expect(env.auth.isSignedIn, isTrue);
      expect(signedInCount, 2);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('OAuth 服务关闭（clientId 空）→ 四通道按钮全部禁用', (tester) async {
      final env = _buildWechatAuth(
        oauthClientId: '',
        initialSocialProviders: const {'apple', 'google'},
      );
      addTearDown(env.auth.dispose);
      await pumpLogin(tester, env.auth);

      expect(tester.widget<FilledButton>(find.byKey(const Key('login-submit'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('login-wechat'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('login-apple'))).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('login-google'))).onPressed, isNull);
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

class _TestWechatSdkAdapter implements WechatSdkAdapter {
  String? lastState;
  final List<void Function(WechatSdkAuthResponse)> listeners = [];

  void emit(WechatSdkAuthResponse response) {
    for (final listener in listeners.toList()) {
      listener(response);
    }
  }

  @override
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  }) async =>
      true;

  @override
  Future<bool> get isInstalled async => true;

  @override
  Future<bool> requestAuth({
    required String scope,
    required String state,
  }) async {
    lastState = state;
    return true;
  }

  @override
  void addResponseListener(void Function(WechatSdkAuthResponse) listener) {
    listeners.add(listener);
  }

  @override
  void removeResponseListener(void Function(WechatSdkAuthResponse) listener) {
    listeners.remove(listener);
  }
}
