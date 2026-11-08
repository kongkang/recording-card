import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/auth/auth_exception.dart';
import 'package:recording_card/services/auth/authorized_http_client.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';

import 'support.dart';

void main() {
  final url = Uri.parse('https://approved.test/resource');
  AuthorizedHttpClient authorized(OAuthTokenStore store, http.Client client) =>
      AuthorizedHttpClient(
        tokenStore: store,
        httpClient: client,
        trustedHosts: ['approved.test'],
      );

  test(
    'expired access refreshes and atomically persists rotated refresh token',
    () async {
      var now = testTime;
      var refreshes = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/oauth/token') {
          refreshes++;
          expect(request.bodyFields['refresh_token'], 'synthetic-refresh-1');
          return jsonResponse(
            tokenJson(
              access: 'synthetic-access-2',
              refresh: 'synthetic-refresh-2',
            ),
          );
        }
        expect(request.headers['Authorization'], 'Bearer synthetic-access-2');
        return jsonResponse({'ok': true});
      });
      final storage = MemoryTokenStorage();
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => now,
      );
      await seedTokens(store, expires: 30);
      now = now.add(const Duration(seconds: 31));
      final response = await authorized(store, client).get(url);
      expect(response.statusCode, 200);
      expect(refreshes, 1);
      expect(store.refreshToken, 'synthetic-refresh-2');
      expect(storage.values.length, 1);
      final bundle = jsonDecode(storage.values.values.single);
      expect(bundle['access_token'], 'synthetic-access-2');
      expect(bundle['refresh_token'], 'synthetic-refresh-2');
      final restart = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => now,
      );
      await restart.bootstrap();
      expect(restart.refreshToken, 'synthetic-refresh-2');
    },
  );

  test(
    'omitted rotation refresh token preserves previous token and expiry',
    () async {
      final client = MockClient(
        (_) async => jsonResponse(
          tokenJson(access: 'synthetic-access-2', refresh: null),
        ),
      );
      final storage = MemoryTokenStorage();
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => testTime,
      );
      await seedTokens(store);
      final before = jsonDecode(
        storage.values.values.single,
      )['refresh_expires_at'];
      await store.refresh();
      expect(store.refreshToken, 'synthetic-refresh-1');
      expect(
        jsonDecode(storage.values.values.single)['refresh_expires_at'],
        before,
      );
    },
  );

  test(
    'parallel 401 requests deduplicate refresh and replay each exactly once',
    () async {
      var refreshes = 0, firsts = 0, retries = 0;
      final both401 = Completer<void>();
      final client = MockClient((request) async {
        if (request.url.path == '/oauth/token') {
          refreshes++;
          return jsonResponse(
            tokenJson(
              access: 'synthetic-access-2',
              refresh: 'synthetic-refresh-2',
            ),
          );
        }
        if (request.headers['Authorization'] == 'Bearer synthetic-access-1') {
          firsts++;
          if (firsts == 2) both401.complete();
          await both401.future;
          return jsonResponse({}, status: 401);
        }
        retries++;
        return jsonResponse({'ok': true});
      });
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: MemoryTokenStorage(),
        clock: () => testTime,
      );
      await seedTokens(store);
      final auth = authorized(store, client);
      final results = await Future.wait([auth.get(url), auth.get(url)]);
      expect(results.map((r) => r.statusCode), [200, 200]);
      expect(refreshes, 1);
      expect(firsts, 2);
      expect(retries, 2);
    },
  );

  test('staggered 401 after another refresh reuses new token without second refresh', () async {
    var refreshes = 0, oldRequests = 0;
    final delayed401 = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/oauth/token') {
        refreshes++;
        return jsonResponse(
          tokenJson(
            access: 'synthetic-access-2',
            refresh: 'synthetic-refresh-2',
          ),
        );
      }
      if (request.headers['Authorization'] == 'Bearer synthetic-access-1') {
        oldRequests++;
        if (oldRequests == 2) await delayed401.future;
        return jsonResponse({}, status: 401);
      }
      return jsonResponse({'ok': true});
    });
    final store = OAuthTokenStore(
      client: testOAuth(client),
      storage: MemoryTokenStorage(),
      clock: () => testTime,
    );
    await seedTokens(store);
    final auth = authorized(store, client);
    final first = auth.get(url), second = auth.get(url);
    await first;
    delayed401.complete();
    await second;
    expect(refreshes, 1);
  });

  test(
    'second 401 throws rather than looping or returning fake response',
    () async {
      var refreshes = 0, requests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/oauth/token') {
          refreshes++;
          return jsonResponse(tokenJson(access: 'synthetic-access-2'));
        }
        requests++;
        return jsonResponse({}, status: 401);
      });
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: MemoryTokenStorage(),
        clock: () => testTime,
      );
      await seedTokens(store);
      await expectLater(
        authorized(store, client).get(url),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(refreshes, 1);
      expect(requests, 2);
    },
  );

  test('invalid_grant clears session; transient network errors preserve token bundle', () async {
    for (final networkFailure in [false, true]) {
      final client = MockClient((_) async {
        if (networkFailure) {
          throw http.ClientException('synthetic-sensitive-error');
        }
        return jsonResponse({'error': 'invalid_grant'}, status: 400);
      });
      final storage = MemoryTokenStorage();
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => testTime,
      );
      await seedTokens(store);
      var invalidated = 0;
      store.onSessionInvalidated = () => invalidated++;
      await expectLater(store.refresh(), throwsA(isA<AuthException>()));
      expect(invalidated, networkFailure ? 0 : 1);
      expect(
        store.refreshToken,
        networkFailure ? 'synthetic-refresh-1' : isNull,
      );
      expect(storage.values.isEmpty, !networkFailure);
    }
  });

  test(
    'logout during refresh response cannot resurrect persisted tokens',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final client = MockClient((_) {
        started.complete();
        return response.future;
      });
      final storage = MemoryTokenStorage();
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => testTime,
      );
      await seedTokens(store);
      final refreshing = store.refresh();
      final check = expectLater(
        refreshing,
        throwsA(isA<AuthRequiredException>()),
      );
      await started.future;
      await store.clearTokens();
      response.complete(jsonResponse(tokenJson(access: 'synthetic-access-2')));
      await check;
      expect(store.accessToken, isNull);
      expect(storage.values, isEmpty);
    },
  );

  test('logout during a storage write followed by new login never deletes new bundle', () async {
    final writing = Completer<void>(), release = Completer<void>();
    final client = MockClient(
      (_) async => jsonResponse(tokenJson(access: 'synthetic-access-2')),
    );
    final storage = MemoryTokenStorage();
    final store = OAuthTokenStore(
      client: testOAuth(client),
      storage: storage,
      clock: () => testTime,
    );
    await seedTokens(store);
    storage.beforeWrite = (key, value) async {
      if (value.contains('synthetic-access-2')) {
        writing.complete();
        await release.future;
      }
    };
    final refreshing = store.refresh();
    final check = expectLater(
      refreshing,
      throwsA(isA<AuthRequiredException>()),
    );
    await writing.future;
    final clearing = store.clearTokens();
    final signing = seedTokens(
      store,
      access: 'new-user-access',
      refresh: 'new-user-refresh',
    );
    release.complete();
    await Future.wait([check, clearing, signing]);
    expect(store.accessToken, 'new-user-access');
    final persisted = jsonDecode(storage.values.values.single);
    expect(persisted['access_token'], 'new-user-access');
  });

  test(
    'old account request cannot be replayed or returned to new account',
    () async {
      final started = Completer<void>(), released = Completer<void>();
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        started.complete();
        await released.future;
        return jsonResponse({}, status: 401);
      });
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: MemoryTokenStorage(),
        clock: () => testTime,
      );
      await seedTokens(store);
      final request = authorized(store, client).get(url);
      final check = expectLater(request, throwsA(isA<AuthRequiredException>()));
      await started.future;
      await store.clearTokens();
      await seedTokens(
        store,
        access: 'new-user-access',
        refresh: 'new-user-refresh',
      );
      released.complete();
      await check;
      expect(calls, 1);
    },
  );

  test(
    'untrusted hosts/http/empty allowlist fail before any network or bearer',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return jsonResponse({});
      });
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: MemoryTokenStorage(),
        clock: () => testTime,
      );
      await seedTokens(store);
      final auth = authorized(store, client);
      for (final bad in [
        'https://evil.test/x',
        'https://approved.test.evil.test/x',
        'https://child.approved.test/x',
        'http://approved.test/x',
      ]) {
        await expectLater(
          auth.get(Uri.parse(bad)),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'untrusted_endpoint',
            ),
          ),
        );
      }
      final empty = AuthorizedHttpClient(
        tokenStore: store,
        httpClient: client,
        trustedHosts: [],
      );
      await expectLater(empty.get(url), throwsA(isA<AuthException>()));
      expect(calls, 0);
    },
  );

  test(
    'redirect disabled prevents token leakage; caller cannot override bearer',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer synthetic-access-1');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.test'},
        );
      });
      final store = OAuthTokenStore(
        client: testOAuth(client),
        storage: MemoryTokenStorage(),
        clock: () => testTime,
      );
      await seedTokens(store);
      await expectLater(
        authorized(
          store,
          client,
        ).get(url, headers: {'Authorization': 'Bearer injected-token'}),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'redirect_refused',
          ),
        ),
      );
      expect(calls, 1);
    },
  );

  test('pending expiry and corruption clean only current namespace', () async {
    var now = testTime;
    final client = testOAuth(MockClient((_) async => jsonResponse({})));
    final storage = MemoryTokenStorage()
      ..values['other.key'] = 'synthetic-other';
    final store = OAuthTokenStore(
      client: client,
      storage: storage,
      clock: () => now,
    );
    await store.savePendingAuthorization(client.createAuthorizationRequest());
    expect(await store.readPendingAuthorization(), isNotNull);
    now = now.add(const Duration(minutes: 11));
    expect(await store.readPendingAuthorization(), isNull);
    storage.values['${client.config.storageNamespace}.bundle'] = 'invalid-json';
    await store.bootstrap();
    expect(store.accessToken, isNull);
    expect(storage.values, {'other.key': 'synthetic-other'});
  });
}
