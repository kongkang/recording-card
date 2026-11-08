import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/core/config/remote/endpoint_resolver.dart';
import 'package:recording_card/services/auth/oauth_client.dart';
import 'package:recording_card/services/auth/oauth_config.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/auth_service.dart';

import 'support.dart';

void main() {
  group('configuration fail closed', () {
    test('exact approved HTTPS hosts; empty allowlist is never a bypass', () {
      expect(kTrustedEndpointHosts, isNotEmpty);
      for (final bad in [
        'http://approved.test',
        'https://evil.test',
        'https://approved.test.evil.test',
        'https://child.approved.test',
        'https://user:pass@approved.test',
        'https://approved.test:444',
        'https://approved.test?token=x',
        'https://approved.test#fragment',
      ]) {
        expect(
          sanitizeTrustedEndpoint(bad, trustedHosts: ['approved.test']),
          isNull,
          reason: bad,
        );
      }
      expect(
        sanitizeTrustedEndpoint('https://approved.test', trustedHosts: []),
        isNull,
      );
      expect(
        sanitizeTrustedEndpoint(
          'https://approved.test/api/',
          trustedHosts: ['approved.test'],
        ),
        'https://approved.test/api',
      );
    });
    test(
      'RC_API_BASE remains compatible but invalid override never uses default',
      () {
        expect(ClientConfig.instance.apiBase, isNull);
        const c = ClientConfig(
          hasApiBaseDefine: true,
          apiBaseDefineValue: 'https://approved.test',
          trustedHosts: ['approved.test'],
        );
        expect(c.apiBase, 'https://approved.test');
        expect(c.effectiveOAuthBaseUrl, 'https://approved.test');
        expect(
          c.effectiveModelGatewayBaseUrl,
          'https://approved.test/api/model-gateway/v1',
        );
        expect(
          resolveEndpoint(
            hasDartDefine: true,
            dartDefineValue: '',
            compileDefault: 'https://approved.test',
          ),
          isNull,
        );
        final invalid = OAuthConfig(
          clientConfig: const ClientConfig(
            hasApiBaseDefine: true,
            apiBaseDefineValue: 'https://evil.test',
          ),
        );
        expect(invalid.validate, throwsA(isA<AuthException>()));
      },
    );
    test(
      'callback must be isolated and exact; config changes isolate tokens',
      () {
        final base = OAuthConfig(clientConfig: testConfig);
        expect(base.callbackScheme, 'recording-card');
        expect(base.storageNamespace, startsWith('recording_card.oauth.v1.'));
        for (final redirect in [
          'reai-mobile://callback',
          'https://approved.test/cb',
          'recording-card://wrong',
          'recording-card://callback/path',
          'recording-card://callback?x=y',
        ]) {
          final config = OAuthConfig(
            clientConfig: ClientConfig(
              oauthBaseUrl: 'https://approved.test',
              trustedHosts: ['approved.test'],
              oauthRedirectUri: redirect,
            ),
          );
          expect(config.validate, throwsA(isA<AuthException>()));
        }
        final changed = OAuthConfig(
          clientConfig: const ClientConfig(
            oauthClientId: 'different',
            oauthBaseUrl: 'https://approved.test',
            trustedHosts: ['approved.test'],
          ),
        );
        expect(base.storageNamespace, isNot(changed.storageNamespace));
      },
    );
  });

  test(
    'PKCE is S256 with 64-char verifier, fresh 32-char state; no secret',
    () {
      final client = OAuthClient(
        config: OAuthConfig(clientConfig: testConfig),
        random: Random(42),
        httpClient: MockClient((_) async => jsonResponse({})),
      );
      final request = client.createAuthorizationRequest(
        loginHint: ' user@example.test ',
      );
      expect(request.codeVerifier.length, 64);
      expect(request.codeVerifier, matches(RegExp(r'^[a-zA-Z0-9._~-]+$')));
      expect(request.state.length, 32);
      expect(
        request.codeChallenge,
        base64UrlEncode(
          sha256.convert(utf8.encode(request.codeVerifier)).bytes,
        ).replaceAll('=', ''),
      );
      expect(request.url.queryParameters['code_challenge_method'], 'S256');
      expect(request.url.queryParameters['client_id'], 'test-public-client');
      expect(
        request.url.queryParameters['redirect_uri'],
        'recording-card://callback',
      );
      expect(request.url.queryParameters['login_hint'], 'user@example.test');
      expect(request.url.queryParameters.containsKey('client_secret'), isFalse);
      expect(client.createAuthorizationRequest().state, isNot(request.state));
    },
  );

  group('AuthService real protocol', () {
    test('arbitrary nonempty password cannot authenticate or notify', () {
      final auth = AuthService();
      addTearDown(auth.dispose);
      var notices = 0;
      auth.addListener(() => notices++);
      expect(auth.signIn('', 'x'), '请输入账号');
      expect(auth.signIn('a', ''), '请输入密码');
      expect(auth.signIn('a', 'anything'), isNotNull);
      expect(auth.session, isNull);
      expect(auth.isSignedIn, isFalse);
      expect(notices, 0);
    });

    test(
      'OAuth persists pending before launch, consumes code, validates profile and restores',
      () async {
        final storage = MemoryTokenStorage();
        final launcher = CallbackLauncher();
        final requests = <String>[];
        late OAuthTokenStore store;
        final http = MockClient((request) async {
          requests.add(request.url.path);
          expect(request.followRedirects, isFalse);
          if (request.url.path == '/oauth/token') {
            expect(request.headers.containsKey('Authorization'), isFalse);
            final body = request.bodyFields;
            expect(body['grant_type'], 'authorization_code');
            expect(body['code'], 'synthetic-code');
            expect(body['code_verifier']!.length, 64);
            expect(body['redirect_uri'], 'recording-card://callback');
            expect(body.containsKey('client_secret'), isFalse);
            expect(await store.readPendingAuthorization(), isNull);
            return jsonResponse(tokenJson());
          }
          expect(request.url.path, '/profile');
          expect(request.headers['Authorization'], 'Bearer synthetic-access-1');
          return profileResponse();
        });
        final oauth = testOAuth(http);
        store = OAuthTokenStore(
          client: oauth,
          storage: storage,
          clock: () => testTime,
        );
        launcher.callback = (url) async {
          final pending = await store.readPendingAuthorization();
          expect(pending!.state, url.queryParameters['state']);
          return successfulCallback(url);
        };
        final auth = AuthService(
          tokenStore: store,
          launcher: launcher,
          httpClient: http,
          clock: () => testTime,
        );
        addTearDown(auth.dispose);
        final session = await auth.signInWithOAuth();
        expect(session.userId, 'test-user-1');
        expect(session.account, 'test-user-1@example.test');
        expect(auth.isSignedIn, isTrue);
        expect(session.issuedAt, testTime);
        expect(launcher.lastScheme, 'recording-card');
        expect(requests, ['/oauth/token', '/profile']);
        expect(
          storage.values.keys,
          everyElement(startsWith('recording_card.oauth.v1.')),
        );
        expect(storage.values.length, 1);
        final restartStore = OAuthTokenStore(
          client: oauth,
          storage: storage,
          clock: () => testTime,
        );
        final restart = AuthService(
          tokenStore: restartStore,
          launcher: CallbackLauncher(),
          httpClient: http,
          clock: () => testTime,
        );
        addTearDown(restart.dispose);
        expect(restart.isSignedIn, isFalse);
        await restart.restore();
        expect(restart.isSignedIn, isTrue);
        expect(requests.last, '/profile');
      },
    );

    test(
      'invalid state, duplicate code/state, wrong callback never exchange tokens',
      () async {
        for (final variant in [
          'state',
          'code',
          'duplicate-state',
          'host',
          'scheme',
          'fragment',
        ]) {
          var calls = 0;
          final http = MockClient((_) async {
            calls++;
            return jsonResponse(tokenJson());
          });
          final oauth = testOAuth(http);
          final storage = MemoryTokenStorage();
          final store = OAuthTokenStore(
            client: oauth,
            storage: storage,
            clock: () => testTime,
          );
          final launcher = CallbackLauncher(
            callback: (url) {
              final cb = successfulCallback(url);
              switch (variant) {
                case 'state':
                  return cb.replace(
                    queryParameters: {'code': 'x', 'state': 'invalid'},
                  );
                case 'code':
                  return cb.replace(query: '${cb.query}&code=another');
                case 'duplicate-state':
                  return cb.replace(query: '${cb.query}&state=another');
                case 'host':
                  return cb.replace(host: 'wrong');
                case 'scheme':
                  return cb.replace(scheme: 'reai-mobile');
                default:
                  return cb.replace(fragment: 'extra');
              }
            },
          );
          final auth = AuthService(
            tokenStore: store,
            launcher: launcher,
            httpClient: http,
          );
          await expectLater(
            auth.signInWithOAuth(),
            throwsA(isA<AuthException>()),
          );
          expect(calls, 0, reason: variant);
          expect(auth.isSignedIn, isFalse);
          expect(storage.values, isEmpty);
          auth.dispose();
        }
      },
    );

    test(
      'authorization cancellation/denial clears pending without fake session',
      () async {
        final http = MockClient((_) async => throw StateError('must not call'));
        final storage = MemoryTokenStorage();
        final store = OAuthTokenStore(
          client: testOAuth(http),
          storage: storage,
          clock: () => testTime,
        );
        final launcher = CallbackLauncher(
          callback: (_) => throw const AuthCancelledException(),
        );
        final auth = AuthService(
          tokenStore: store,
          launcher: launcher,
          httpClient: http,
        );
        addTearDown(auth.dispose);
        await expectLater(
          auth.signInWithOAuth(),
          throwsA(isA<AuthCancelledException>()),
        );
        expect(storage.values, isEmpty);
        launcher.callback = (url) => successfulCallback(url).replace(
          queryParameters: {
            'state': url.queryParameters['state']!,
            'error': 'access_denied',
          },
        );
        await expectLater(
          auth.signInWithOAuth(),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'authorization_denied',
            ),
          ),
        );
        expect(auth.isSignedIn, isFalse);
      },
    );

    test(
      'missing/invalid profile and failed persistence cannot authenticate',
      () async {
        for (final failStorage in [false, true]) {
          final http = MockClient(
            (request) async => request.url.path == '/oauth/token'
                ? jsonResponse(tokenJson())
                : jsonResponse({
                    'data': {'email': 'a@example.test'},
                  }),
          );
          final storage = MemoryTokenStorage();
          final launcher = CallbackLauncher(
            callback: (url) {
              if (failStorage) {
                storage.beforeWrite = (key, _) async {
                  if (key.endsWith('.bundle')) {
                    throw StateError('test storage failure');
                  }
                };
              }
              return successfulCallback(url);
            },
          );
          final auth = AuthService(
            tokenStore: OAuthTokenStore(
              client: testOAuth(http),
              storage: storage,
              clock: () => testTime,
            ),
            launcher: launcher,
            httpClient: http,
          );
          await expectLater(auth.signInWithOAuth(), throwsA(anything));
          expect(auth.isSignedIn, isFalse);
          expect(storage.values, isEmpty);
          auth.dispose();
        }
      },
    );

    test(
      'signed out during browser callback cannot exchange or resurrect',
      () async {
        final callback = Completer<Uri>();
        final opened = Completer<Uri>();
        var calls = 0;
        final http = MockClient((_) async {
          calls++;
          return jsonResponse(tokenJson());
        });
        final storage = MemoryTokenStorage();
        final auth = AuthService(
          tokenStore: OAuthTokenStore(
            client: testOAuth(http),
            storage: storage,
            clock: () => testTime,
          ),
          httpClient: http,
          launcher: CallbackLauncher(
            callback: (url) {
              opened.complete(url);
              return callback.future;
            },
          ),
        );
        addTearDown(auth.dispose);
        final signing = auth.signInWithOAuth();
        final signingCheck = expectLater(
          signing,
          throwsA(isA<AuthRequiredException>()),
        );
        final url = await opened.future;
        await auth.signOut();
        callback.complete(successfulCallback(url));
        await signingCheck;
        expect(calls, 0);
        expect(storage.values, isEmpty);
        expect(auth.isSignedIn, isFalse);
      },
    );

    test(
      'logout deletes only own namespace even when remote revoke fails',
      () async {
        var failRevocation = false;
        final http = MockClient((request) async {
          if (request.url.path == '/oauth/revoke') {
            expect(request.bodyFields['client_id'], 'test-public-client');
            expect(request.followRedirects, isFalse);
            return jsonResponse({
              'error': 'server_error',
            }, status: failRevocation ? 500 : 200);
          }
          return request.url.path == '/oauth/token'
              ? jsonResponse(tokenJson())
              : profileResponse();
        });
        final storage = MemoryTokenStorage()
          ..values['unrelated.app.token'] = 'synthetic-unrelated';
        final auth = AuthService(
          tokenStore: OAuthTokenStore(
            client: testOAuth(http),
            storage: storage,
            clock: () => testTime,
          ),
          launcher: CallbackLauncher(),
          httpClient: http,
        );
        addTearDown(auth.dispose);
        await auth.signInWithOAuth();
        failRevocation = true;
        await expectLater(
          auth.signOut(),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'revocation_failed',
            ),
          ),
        );
        expect(auth.isSignedIn, isFalse);
        expect(storage.values, {'unrelated.app.token': 'synthetic-unrelated'});
      },
    );

    test('concurrent sign-ins start exactly one browser/exchange', () async {
      final http = MockClient(
        (r) async => r.url.path == '/oauth/token'
            ? jsonResponse(tokenJson())
            : profileResponse(),
      );
      final launcher = CallbackLauncher();
      final auth = AuthService(
        tokenStore: OAuthTokenStore(
          client: testOAuth(http),
          storage: MemoryTokenStorage(),
          clock: () => testTime,
        ),
        httpClient: http,
        launcher: launcher,
      );
      addTearDown(auth.dispose);
      final result = await Future.wait([
        auth.signInWithOAuth(),
        auth.signInWithOAuth(),
      ]);
      expect(result[0].userId, result[1].userId);
      expect(launcher.calls, 1);
    });
  });

  test(
    'OAuth errors are redacted and token response validity is enforced',
    () async {
      final http = MockClient(
        (_) async => jsonResponse({
          'error': 'invalid_grant',
          'error_description': 'synthetic-secret-do-not-log',
        }, status: 400),
      );
      final oauth = testOAuth(http);
      await expectLater(
        oauth.refreshAccessToken('synthetic-refresh'),
        throwsA(
          isA<AuthException>()
              .having((e) => e.code, 'code', 'invalid_grant')
              .having(
                (e) => e.toString(),
                'redacted',
                isNot(contains('do-not-log')),
              ),
        ),
      );
      for (final invalid in <Map<String, dynamic>>[
        {},
        {...tokenJson(), 'token_type': 'Basic'},
        {...tokenJson(), 'access_token': ''},
        {...tokenJson(), 'expires_in': 0},
      ]) {
        expect(
          () => OAuthTokenResponse.fromJson(invalid),
          throwsA(isA<AuthException>()),
        );
      }
    },
  );
}
