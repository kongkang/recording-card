import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/auth_service.dart';

import 'support.dart';

void main() {
  test('empty secure storage restores signed out without HTTP', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return profileResponse();
    });
    final auth = AuthService(
      tokenStore: OAuthTokenStore(
        client: testOAuth(client),
        storage: MemoryTokenStorage(),
        clock: () => testTime,
      ),
      httpClient: client,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    expect(requests, 0);
    expect(auth.session, isNull);
    expect(auth.isSignedIn, isFalse);
  });

  test('expired persisted access restores only after refresh and validated profile', () async {
    var now = testTime;
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/oauth/token') {
        expect(request.bodyFields['grant_type'], 'refresh_token');
        return jsonResponse(
          tokenJson(
            access: 'synthetic-access-2',
            refresh: 'synthetic-refresh-2',
          ),
        );
      }
      expect(request.headers['Authorization'], 'Bearer synthetic-access-2');
      return profileResponse();
    });
    final storage = MemoryTokenStorage();
    final oldStore = OAuthTokenStore(
      client: testOAuth(client),
      storage: storage,
      clock: () => now,
    );
    await seedTokens(oldStore, expires: 30);
    now = now.add(const Duration(minutes: 2));
    final newStore = OAuthTokenStore(
      client: testOAuth(client),
      storage: storage,
      clock: () => now,
    );
    final auth = AuthService(
      tokenStore: newStore,
      httpClient: client,
      clock: () => now,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    expect(paths, ['/oauth/token', '/profile']);
    expect(auth.session!.userId, 'test-user-1');
    expect(newStore.refreshToken, 'synthetic-refresh-2');
    expect(auth.session!.issuedAt, testTime);
  });

  test(
    'profile 401 with invalid_grant refresh clears restored session',
    () async {
      final client = MockClient(
        (request) async => request.url.path == '/oauth/token'
            ? jsonResponse({'error': 'invalid_grant'}, status: 400)
            : jsonResponse({}, status: 401),
      );
      final storage = MemoryTokenStorage();
      final seed = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => testTime,
      );
      await seedTokens(seed);
      final auth = AuthService(
        tokenStore: OAuthTokenStore(
          client: testOAuth(client),
          storage: storage,
          clock: () => testTime,
        ),
        httpClient: client,
      );
      addTearDown(auth.dispose);
      await expectLater(auth.restore(), throwsA(isA<AuthRequiredException>()));
      expect(auth.isSignedIn, isFalse);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'startup network failure is visible and preserves bundle for retry',
    () async {
      var fail = true;
      final client = MockClient((_) async {
        if (fail) {
          throw http.ClientException('synthetic-sensitive-network-error');
        }
        return profileResponse();
      });
      final storage = MemoryTokenStorage();
      final seed = OAuthTokenStore(
        client: testOAuth(client),
        storage: storage,
        clock: () => testTime,
      );
      await seedTokens(seed);
      final auth = AuthService(
        tokenStore: OAuthTokenStore(
          client: testOAuth(client),
          storage: storage,
          clock: () => testTime,
        ),
        httpClient: client,
      );
      addTearDown(auth.dispose);
      await expectLater(
        auth.restore(),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'network')),
      );
      expect(auth.isSignedIn, isFalse);
      expect(storage.values.length, 1);
      fail = false;
      await auth.restore();
      expect(auth.isSignedIn, isTrue);
    },
  );

  test('bootstrap treats deleted bundle as signed out instead of keeping stale memory', () async {
    final client = testOAuth(MockClient((_) async => profileResponse()));
    final storage = MemoryTokenStorage();
    final store = OAuthTokenStore(
      client: client,
      storage: storage,
      clock: () => testTime,
    );
    await seedTokens(store);
    storage.values
        .clear(); // Explicit test fixture; never production deleteAll.
    await store.bootstrap();
    expect(store.accessToken, isNull);
    expect(store.hasUsableSession, isFalse);
  });
}
