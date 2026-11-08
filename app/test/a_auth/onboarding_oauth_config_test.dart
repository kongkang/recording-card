import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/services/auth/oauth_config.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/model_gateway/model_gateway.dart';
import 'package:recording_card/services/runtime/runtime_config.dart';

import 'support.dart';

ClientConfig compatibilityConfig({
  bool reuse = true,
  String clientId = ClientConfig.referencePublicClientId,
  String? redirect,
}) => ClientConfig(
  oauthClientId: clientId,
  oauthBaseUrl: 'https://approved.test',
  trustedHosts: const ['approved.test'],
  oauthReuseReferenceClient: reuse,
  oauthRedirectUri: redirect,
);

void main() {
  test('public build define controls static config without secrets', () {
    const enabled = bool.fromEnvironment('RC_OAUTH_REUSE_REFERENCE_CLIENT');
    const redirect = String.fromEnvironment(
      'RC_OAUTH_REDIRECT_URI',
      defaultValue: enabled
          ? ClientConfig.referenceOAuthRedirectUri
          : ClientConfig.independentOAuthRedirectUri,
    );
    expect(ClientConfig.instance.oauthReuseReferenceClient, enabled);
    expect(ClientConfig.instance.oauthRedirectUri, redirect);
  });

  test(
    'reference-client reuse is default off, normal callback is independent',
    () {
      const config = ClientConfig();
      expect(config.oauthReuseReferenceClient, isFalse);
      expect(config.oauthRedirectUri, 'recording-card://callback');
      expect(OAuthConfig(clientConfig: config).validate, returnsNormally);
      final rejected = OAuthConfig(
        clientConfig: compatibilityConfig(
          reuse: false,
          redirect: 'reai-mobile://callback',
        ),
      );
      expect(rejected.validate, throwsA(isA<AuthException>()));
    },
  );

  test('enabled reuse defaults to exact approved registered public tuple', () {
    final config = compatibilityConfig();
    expect(config.oauthReuseReferenceClient, isTrue);
    expect(config.oauthRedirectUri, ClientConfig.referenceOAuthRedirectUri);
    expect(config.oauthClientId, ClientConfig.referencePublicClientId);
    final oauth = OAuthConfig(clientConfig: config);
    expect(oauth.validate, returnsNormally);
    expect(oauth.callbackScheme, 'reai-mobile');
    expect(
      OAuthConfig(
        clientConfig: compatibilityConfig(
          redirect: 'recording-card://callback',
        ),
      ).validate,
      returnsNormally,
    );
    for (final clientId in [
      'different-public-client',
      '',
      ' ${ClientConfig.referencePublicClientId}',
      '${ClientConfig.referencePublicClientId} ',
    ]) {
      expect(
        OAuthConfig(clientConfig: compatibilityConfig(clientId: clientId))
            .validate,
        throwsA(isA<AuthException>()),
        reason: clientId,
      );
    }
  });

  test('reuse never permits web, arbitrary scheme, or nonexact callbacks', () {
    for (final redirect in [
      'http://callback',
      'https://callback',
      'other-app://callback',
      'reai-mobile://wrong',
      'reai-mobile://callback/',
      'reai-mobile://callback/path',
      'reai-mobile://user@callback',
      'reai-mobile://callback:80',
      'reai-mobile://callback?code=x',
      'reai-mobile://callback#x',
      'reai-mobile://callback?',
      'reai-mobile://callback#',
      'REAI-MOBILE://callback',
      'reai-mobile://CALLBACK',
      'reai-mobile://%63allback',
      'reai-mobile://callback ',
      'recording-card://callback/',
    ]) {
      expect(
        OAuthConfig(clientConfig: compatibilityConfig(redirect: redirect))
            .validate,
        throwsA(isA<AuthException>()),
        reason: redirect,
      );
    }
  });

  test('compatibility storage stays recording_card and never copies reference tokens', () async {
    final config = compatibilityConfig();
    final oauth = OAuthConfig(clientConfig: config);
    final normal = OAuthConfig(clientConfig: compatibilityConfig(reuse: false));
    expect(oauth.storageNamespace, startsWith('recording_card.oauth.v1.'));
    expect(oauth.storageNamespace, isNot(normal.storageNamespace));
    final storage = MemoryTokenStorage();
    storage.values['oauth.access_token'] = 'synthetic-reference-token';
    final http = MockClient((_) async => throw StateError('unexpected HTTP'));
    final tokens = OAuthTokenStore(
      client: testOAuth(http, config: config),
      storage: storage,
      clock: () => testTime,
    );
    await tokens.bootstrap();
    expect(tokens.accessToken, isNull);
    await seedTokens(tokens);
    expect(storage.writes, ['${oauth.storageNamespace}.bundle']);
    await tokens.clearTokens();
    expect(storage.deletes, everyElement(startsWith(oauth.storageNamespace)));
    expect(storage.values['oauth.access_token'], 'synthetic-reference-token');
  });

  test('synthetic first compatibility login retains S256 state and exact token redirect', () async {
    final config = compatibilityConfig();
    final launcher = CallbackLauncher();
    final requests = <String>[];
    final http = MockClient((request) async {
      requests.add(request.url.path);
      expect(request.followRedirects, isFalse);
      if (request.url.path == '/oauth/token') {
        expect(
          request.bodyFields['client_id'],
          ClientConfig.referencePublicClientId,
        );
        expect(request.bodyFields['redirect_uri'], 'reai-mobile://callback');
        expect(request.bodyFields.containsKey('client_secret'), isFalse);
        final verifier = request.bodyFields['code_verifier']!;
        expect(verifier.length, 64);
        expect(
          launcher.lastUrl!.queryParameters['code_challenge'],
          base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
        );
        return jsonResponse(tokenJson());
      }
      expect(request.headers['Authorization'], 'Bearer synthetic-access-1');
      if (request.url.path == '/api/model-gateway/v1/models') {
        expect(request.method, 'GET');
        return jsonResponse({
          'data': [
            {
              'id': 'authorized-first',
              'capabilities': ['text'],
            },
          ],
        });
      }
      if (request.url.path == '/api/model-gateway/v1/chat/completions') {
        expect(request.method, 'POST');
        expect(jsonDecode(request.body)['model'], 'authorized-first');
        return jsonResponse({
          'choices': [
            {
              'message': {'content': 'synthetic-analysis'},
            },
          ],
        });
      }
      expect(request.url.path, '/profile');
      return profileResponse();
    });
    final tokens = OAuthTokenStore(
      client: testOAuth(http, config: config),
      storage: MemoryTokenStorage(),
      clock: () => testTime,
    );
    final auth = AuthService(
      config: config,
      tokenStore: tokens,
      launcher: launcher,
      httpClient: http,
      clock: () => testTime,
    );
    addTearDown(auth.dispose);
    await auth.signInWithOAuth();
    expect(auth.isSignedIn, isTrue);
    expect(launcher.lastScheme, 'reai-mobile');
    expect(launcher.lastUrl!.queryParameters['code_challenge_method'], 'S256');
    expect(launcher.lastUrl!.queryParameters['state']!.length, 32);
    expect(await tokens.readPendingAuthorization(), isNull);
    expect(requests, ['/oauth/token', '/profile']);
    final analysis = AuthorizedAnalysisGateway(
      ModelGateway(auth: auth),
      sessionEpoch: () => auth.authorizedClient.tokenStore.userIdentityEpoch,
    );
    expect(
      await analysis.complete('user-triggered-analysis'),
      'synthetic-analysis',
    );
    expect(requests, [
      '/oauth/token',
      '/profile',
      '/api/model-gateway/v1/models',
      '/api/model-gateway/v1/models',
      '/api/model-gateway/v1/chat/completions',
    ]);
  });

  test(
    'compatibility login still rejects state, host and path before exchange',
    () async {
      for (final invalidCallback in [
        (Uri uri) => uri.replace(
          queryParameters: {'code': 'synthetic', 'state': 'wrong'},
        ),
        (Uri uri) => uri.replace(host: 'wrong'),
        (Uri uri) => uri.replace(path: '/extra'),
        (Uri uri) => uri.replace(scheme: 'recording-card'),
      ]) {
        var requests = 0;
        final config = compatibilityConfig();
        final http = MockClient((_) async {
          requests++;
          return jsonResponse(tokenJson());
        });
        final tokens = OAuthTokenStore(
          client: testOAuth(http, config: config),
          storage: MemoryTokenStorage(),
          clock: () => testTime,
        );
        final auth = AuthService(
          config: config,
          tokenStore: tokens,
          launcher: CallbackLauncher(
            callback: (url) => invalidCallback(successfulCallback(url)),
          ),
          httpClient: http,
          clock: () => testTime,
        );
        addTearDown(auth.dispose);
        await expectLater(
          auth.signInWithOAuth(),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'invalid_callback',
            ),
          ),
        );
        expect(auth.isSignedIn, isFalse);
        expect(requests, 0);
      }
    },
  );
}
