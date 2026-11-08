// OAuth 登录编排验收（TDD）—— 授权 URL → 系统浏览器回调 → state 校验 →
// 换票 → profile → token 落安全存储；失败不建会话。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/oauth_config.dart';
import 'package:recording_card/services/oauth/auth_launcher.dart';
import 'package:recording_card/services/oauth/oauth_client.dart';
import 'package:recording_card/services/oauth/oauth_login_coordinator.dart';
import 'package:recording_card/services/oauth/oauth_token_store.dart';
import 'package:recording_card/services/oauth/secure_store.dart';

const _config = OAuthConfig(
  baseUrl: 'https://auth.example.com',
  clientId: 'client-1',
  redirectUri: 'recordingcard://oauth/callback',
  scope: 'profile:read',
);

class FakeLauncher implements AuthLauncher {
  FakeLauncher(this.callback);

  String callback;
  Uri? lastUrl;
  String? lastScheme;
  Object? error;

  @override
  Future<String> launch(Uri url, String callbackScheme) async {
    lastUrl = url;
    lastScheme = callbackScheme;
    final failure = error;
    if (failure != null) throw failure;
    // 用授权 URL 里的 state 回填，模拟服务端回调
    final state = url.queryParameters['state']!;
    return callback.replaceAll('{state}', state);
  }
}

OAuthClient _client({http.Response? profileResponse}) => OAuthClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/oauth/token') {
          return http.Response(
            jsonEncode({
              'access_token': 'access-1',
              'refresh_token': 'refresh-1',
              'expires_in': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/oauth/profile') {
          return profileResponse ??
              http.Response(
                jsonEncode({'email': 'a@b.com', 'name': 'Kong'}),
                200,
                headers: {'content-type': 'application/json'},
              );
        }
        return http.Response('not found', 404);
      }),
    );

void main() {
  test('成功：state 校验 → 换票 → profile → 保存 token', () async {
    final launcher = FakeLauncher(
        'recordingcard://oauth/callback?code=code-1&state={state}');
    final tokens = OAuthTokenStore(MemorySecureStore());
    final coordinator = OAuthLoginCoordinator(
      oauth: _client(),
      tokens: tokens,
      launcher: launcher,
      callbackScheme: 'recordingcard',
    );

    final result = await coordinator.signIn(loginHint: 'a@b.com');

    expect(launcher.lastScheme, 'recordingcard');
    expect(launcher.lastUrl!.queryParameters['code_challenge_method'], 'S256');
    expect(result.account, 'a@b.com');
    expect(result.tokens.accessToken, 'access-1');
    expect((await tokens.read())!.refreshToken, 'refresh-1');
  });

  test('state 不匹配：拒绝换票', () async {
    final launcher = FakeLauncher(
        'recordingcard://oauth/callback?code=code-1&state=wrong');
    final coordinator = OAuthLoginCoordinator(
      oauth: _client(),
      tokens: OAuthTokenStore(MemorySecureStore()),
      launcher: launcher,
      callbackScheme: 'recordingcard',
    );

    await expectLater(
      coordinator.signIn(),
      throwsA(isA<OAuthException>()
          .having((e) => e.code, 'code', 'state_mismatch')),
    );
  });

  test('授权回调 error：转 OAuthException，不换票', () async {
    final launcher = FakeLauncher(
        'recordingcard://oauth/callback?error=access_denied&state={state}');
    final coordinator = OAuthLoginCoordinator(
      oauth: _client(),
      tokens: OAuthTokenStore(MemorySecureStore()),
      launcher: launcher,
      callbackScheme: 'recordingcard',
    );

    await expectLater(
      coordinator.signIn(),
      throwsA(isA<OAuthException>()
          .having((e) => e.code, 'code', 'access_denied')),
    );
  });

  test('回调缺 code：抛错', () async {
    final launcher = FakeLauncher(
        'recordingcard://oauth/callback?state={state}');
    final coordinator = OAuthLoginCoordinator(
      oauth: _client(),
      tokens: OAuthTokenStore(MemorySecureStore()),
      launcher: launcher,
      callbackScheme: 'recordingcard',
    );

    await expectLater(
      coordinator.signIn(),
      throwsA(isA<OAuthException>()
          .having((e) => e.code, 'code', 'missing_code')),
    );
  });

  test('profile 无账号标识：抛错，不建会话', () async {
    final launcher = FakeLauncher(
        'recordingcard://oauth/callback?code=code-1&state={state}');
    final tokens = OAuthTokenStore(MemorySecureStore());
    final coordinator = OAuthLoginCoordinator(
      oauth: _client(profileResponse: http.Response(jsonEncode({}), 200,
          headers: {'content-type': 'application/json'})),
      tokens: tokens,
      launcher: launcher,
      callbackScheme: 'recordingcard',
    );

    await expectLater(
      coordinator.signIn(),
      throwsA(isA<OAuthException>()
          .having((e) => e.code, 'code', 'invalid_profile')),
    );
  });
}
