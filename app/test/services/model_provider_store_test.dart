import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/services/net/api_exception.dart';
import 'package:recording_card/services/net/model_provider_store.dart';

void main() {
  test(
    'keeps credentials with their endpoint and restores scene selections',
    () async {
      final secure = InMemorySecureStore();
      var requests = 0;
      final store = ModelProviderStore(
        secureStore: secure,
        clientFactory: () => MockClient((request) async {
          requests++;
          expect(request.url.toString(), 'https://api.openai.com/v1/models');
          expect(request.headers['authorization'], 'Bearer user-key');
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'summary-model'},
                {'id': 'chat-model'},
              ],
            }),
            200,
          );
        }),
      );
      final profile = await store.connect(
        ModelProvider.openai,
        apiKey: 'user-key',
        baseUrl: '',
      );
      expect(store.activeProvider, ModelProvider.wainao);
      await store.saveProfile(
        ModelProvider.openai,
        profile.copyWith(
          summaryModel: 'summary-model',
          sceneModels: {ModelScene.agent: 'chat-model'},
        ),
      );
      await store.selectProvider(ModelProvider.openai);
      final reopened = ModelProviderStore(secureStore: secure);
      final agent = await reopened.activeRoute(ModelScene.agent);
      final summary = await reopened.activeRoute(ModelScene.summary);
      expect(agent?.model, 'chat-model');
      expect(summary?.model, 'summary-model');
      expect(agent?.apiKey, 'user-key');
      expect(agent?.endpoint('chat/completions').host, 'api.openai.com');

      await expectLater(
        store.connect(
          ModelProvider.openai,
          apiKey: '',
          baseUrl: 'https://another.example/v1',
        ),
        throwsA(isA<ApiNotConfiguredException>()),
      );
      expect(requests, 1);
    },
  );

  test('legacy URL stays as a draft without a Wainao credential', () async {
    final store = ModelProviderStore(secureStore: InMemorySecureStore());
    await store.importLegacyDraft(
      'https://model.example/v1/chat/completions',
      summaryModel: 'old-model',
    );
    expect(await store.activeRoute(ModelScene.summary), isNull);
    expect(
      store.profileFor(ModelProvider.custom).baseUrl,
      'https://model.example/v1',
    );
    expect(await store.hasApiKey(ModelProvider.custom), isFalse);
    await expectLater(
      store.selectProvider(ModelProvider.custom),
      throwsA(isA<ApiNotConfiguredException>()),
    );
  });

  test('validates a manual model and never follows redirects', () async {
    var allow = false;
    final store = ModelProviderStore(
      secureStore: InMemorySecureStore(),
      clientFactory: () => MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://host.example/v1/chat/completions',
        );
        expect(request.followRedirects, isFalse);
        expect((jsonDecode(request.body) as Map)['model'], 'intranet-model');
        if (!allow) {
          return http.Response(
            '',
            307,
            headers: {'location': 'https://unrelated.example'},
          );
        }
        return http.Response('{"choices":[{"message":{"content":"OK"}}]}', 200);
      }),
    );
    Future<ModelProviderProfile> connect() => store.connect(
      ModelProvider.custom,
      apiKey: 'user-key',
      baseUrl: 'https://host.example/v1/chat/completions/',
      manualModel: 'intranet-model',
    );
    await expectLater(connect(), throwsA(isA<ApiHttpException>()));
    expect(await store.hasApiKey(ModelProvider.custom), isFalse);
    allow = true;
    expect((await connect()).models, ['intranet-model']);
    expect(await store.hasApiKey(ModelProvider.custom), isTrue);
  });
}
