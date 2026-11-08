// OAuth2 PKCE 验收（TDD）—— 纯客户端协议/存储/刷新，不依赖真实后端。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/oauth_config.dart';
import 'package:recording_card/services/oauth/authorized_http_client.dart';
import 'package:recording_card/services/oauth/oauth_client.dart';
import 'package:recording_card/services/oauth/oauth_token_store.dart';
import 'package:recording_card/services/oauth/secure_store.dart';

const _config = OAuthConfig(
  baseUrl: 'https://auth.example.com',
  clientId: 'client-1',
  redirectUri: 'recordingcard://oauth/callback',
  scope: 'profile:read offline_access',
);

OAuthTokens _tokens({
  String access = 'access-1',
  String? refresh = 'refresh-1',
  DateTime? accessExpiresAt,
}) =>
    OAuthTokens(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt:
          accessExpiresAt ?? DateTime.now().add(const Duration(hours: 1)),
      refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
    );

void main() {
  group('OAuthConfig', () {
    test('https + client id 才算已配置', () {
      expect(_config.isConfigured, isTrue);
      expect(
          const OAuthConfig(
            baseUrl: '',
            clientId: 'c',
            redirectUri: 'r',
            scope: 's',
          ).isConfigured,
          isFalse);
      expect(
          const OAuthConfig(
            baseUrl: 'http://auth.example.com',
            clientId: 'c',
            redirectUri: 'r',
            scope: 's',
          ).isConfigured,
          isFalse);
    });

    test('端点路径正确', () {
      expect(_config.authorizeUri.toString(),
          'https://auth.example.com/oauth/authorize');
      expect(_config.tokenUri.toString(),
          'https://auth.example.com/oauth/token');
    });
  });

  group('OAuthClient PKCE', () {
    test('RFC 7636 S256 测试向量', () {
      expect(
        OAuthClient.codeChallengeS256(
            'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('授权 URL 含 state/verifier/challenge 与精确 redirect', () {
      final client = OAuthClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      final request = client.createAuthorizationRequest(
          loginHint: 'a@b.com', prompt: 'login');

      expect(request.state.length, 32);
      expect(request.codeVerifier.length, 64);
      expect(
          request.url.queryParameters['code_challenge'],
          OAuthClient.codeChallengeS256(request.codeVerifier));
      expect(request.url.queryParameters['code_challenge_method'], 'S256');
      expect(request.url.queryParameters['redirect_uri'],
          'recordingcard://oauth/callback');
      expect(request.url.queryParameters['client_id'], 'client-1');
      expect(request.url.queryParameters['response_type'], 'code');
      expect(request.url.queryParameters['login_hint'], 'a@b.com');
      expect(request.url.queryParameters['prompt'], 'login');
    });

    test('换票：form-urlencoded + 解析 token', () async {
      late http.Request seen;
      final client = OAuthClient(
        config: _config,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'access_token': 'a1',
              'refresh_token': 'r1',
              'expires_in': 3600,
              'refresh_expires_in': 7200,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final tokens = await client.exchangeCode(
          code: 'code-1', codeVerifier: 'verifier-1');

      expect(seen.url.path, '/oauth/token');
      expect(seen.headers['content-type'],
          startsWith('application/x-www-form-urlencoded'));
      final form = Uri.splitQueryString(seen.body);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'code-1');
      expect(form['code_verifier'], 'verifier-1');
      expect(form['redirect_uri'], 'recordingcard://oauth/callback');
      expect(tokens.accessToken, 'a1');
      expect(tokens.refreshToken, 'r1');
      expect(tokens.accessExpiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('错误响应转 OAuthException', () async {
      final client = OAuthClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({'error': 'invalid_grant'}), 400,
            headers: {'content-type': 'application/json'})),
      );
      await expectLater(
        client.exchangeCode(code: 'bad', codeVerifier: 'v'),
        throwsA(isA<OAuthException>()
            .having((e) => e.code, 'code', 'invalid_grant')),
      );
    });

    test('refresh 用 grant_type=refresh_token', () async {
      late http.Request seen;
      final client = OAuthClient(
        config: _config,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
              jsonEncode({
                'access_token': 'a2',
                'refresh_token': 'r2',
                'expires_in': 3600,
              }),
              200,
              headers: {'content-type': 'application/json'});
        }),
      );
      final tokens = await client.refresh(refreshToken: 'r1');
      final form = Uri.splitQueryString(seen.body);
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], 'r1');
      expect(form['client_id'], 'client-1');
      expect(tokens.accessToken, 'a2');
      expect(tokens.refreshToken, 'r2');
    });
  });

  group('OAuthTokenStore', () {
    test('保存/读取/清除', () async {
      final store = OAuthTokenStore(MemorySecureStore());
      expect(await store.read(), isNull);
      await store.save(_tokens());
      final read = await store.read();
      expect(read!.accessToken, 'access-1');
      expect(read.refreshToken, 'refresh-1');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('损坏 JSON 返回 null，不崩溃', () async {
      final raw = MemorySecureStore();
      await raw.write(OAuthTokenStore.storageKey, '{bad');
      expect(await OAuthTokenStore(raw).read(), isNull);
    });
  });

  group('AuthorizedHttpClient', () {
    test('无 token 拒绝请求', () async {
      final oauth = _FakeOAuth(_tokens());
      final client = AuthorizedHttpClient(
        client: MockClient((_) async => http.Response('', 200)),
        oauth: oauth,
        tokens: OAuthTokenStore(MemorySecureStore()),
      );
      await expectLater(
        client.get(Uri.parse('https://api.example.com/x')),
        throwsA(isA<OAuthException>()
            .having((e) => e.code, 'code', 'not_authenticated')),
      );
    });

    test('401 时 refresh 一次并重试成功', () async {
      final secure = MemorySecureStore();
      final tokenStore = OAuthTokenStore(secure);
      await tokenStore.save(
          _tokens(accessExpiresAt: DateTime.now().add(const Duration(hours: 1))));
      final oauth = _FakeOAuth(_tokens(access: 'new-access', refresh: 'r2'));
      var resourceCalls = 0;
      final client = AuthorizedHttpClient(
        client: MockClient((request) async {
          resourceCalls++;
          if (resourceCalls == 1) {
            expect(request.headers['authorization'], 'Bearer access-1');
            return http.Response('', 401);
          }
          expect(request.headers['authorization'], 'Bearer new-access');
          return http.Response('ok', 200);
        }),
        oauth: oauth,
        tokens: tokenStore,
      );

      final response =
          await client.get(Uri.parse('https://api.example.com/x'));
      expect(response.statusCode, 200);
      expect(oauth.refreshCalls, 1);
      expect(resourceCalls, 2);
      expect((await tokenStore.read())!.accessToken, 'new-access');
    });

    test('重试仍 401 则抛错，不无限刷新', () async {
      final secure = MemorySecureStore();
      final tokenStore = OAuthTokenStore(secure);
      await tokenStore.save(_tokens());
      final oauth = _FakeOAuth(_tokens(access: 'new-access'));
      final client = AuthorizedHttpClient(
        client: MockClient((_) async => http.Response('', 401)),
        oauth: oauth,
        tokens: tokenStore,
      );

      await expectLater(
        client.get(Uri.parse('https://api.example.com/x')),
        throwsA(isA<OAuthException>()
            .having((e) => e.code, 'code', 'unauthorized')),
      );
      expect(oauth.refreshCalls, 1);
    });
  });
}

class _FakeOAuth extends OAuthClient {
  _FakeOAuth(this._next)
      : super(
          config: _config,
          httpClient: MockClient((_) async => http.Response('', 500)),
        );

  final OAuthTokens _next;
  int refreshCalls = 0;

  @override
  Future<OAuthTokens> refresh({required String refreshToken}) async {
    refreshCalls++;
    return _next;
  }
}
