import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/auth/authorized_http_client.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/model_gateway/model_gateway.dart';

import 'support.dart';

final textCatalog = {
  'data': [
    {
      'id': 'text-model',
      'name': 'Authorized Text',
      'capabilities': ['text'],
    },
    {
      'id': 'asr-model',
      'capabilities': ['asr'],
    },
    {
      'id': 'denied-model',
      'capabilities': ['text'],
      'authorized': false,
    },
    {
      'id': 'disabled-model',
      'capabilities': ['text'],
      'enabled': false,
    },
    {'id': 'unknown-capability'},
  ],
};

void main() {
  Future<ModelGateway> gateway(
    http.Client client, {
    String? model,
    String? base,
  }) async {
    final store = OAuthTokenStore(
      client: testOAuth(client),
      storage: MemoryTokenStorage(),
      clock: () => testTime,
    );
    await seedTokens(store);
    return ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: store,
        httpClient: client,
        trustedHosts: ['approved.test'],
      ),
      config: testConfig,
      defaultModel: model,
      baseUrl: base,
    );
  }

  test('real /models catalog keeps only granted text capabilities', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://approved.test/api/model-gateway/v1/models',
      );
      expect(request.headers['Authorization'], 'Bearer synthetic-access-1');
      return jsonResponse(textCatalog);
    });
    final models = await (await gateway(client)).listTextModels();
    expect(models.map((m) => m.id), ['text-model']);
    expect(models.single.name, 'Authorized Text');
    expect(models.single.supportsText, isTrue);
    expect(() => models.clear(), throwsUnsupportedError);
  });

  test(
    'complete checks catalog then posts exact authorized ID and prompt',
    () async {
      final seen = <String>[];
      final client = MockClient((request) async {
        seen.add(request.url.path);
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer synthetic-access-1');
        if (request.method == 'GET') return jsonResponse(textCatalog);
        expect(request.method, 'POST');
        expect(
          request.headers['Content-Type']?.split(';').first,
          'application/json',
        );
        final body = jsonDecode(request.body);
        expect(body['model'], 'text-model');
        expect(body['stream'], isFalse);
        expect(body['messages'], [
          {'role': 'user', 'content': '测试真实请求协议'},
        ]);
        expect(body.containsKey('api_key'), isFalse);
        return jsonResponse({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'content': ' 已收到服务端文本 '},
            },
          ],
        });
      });
      final result = await (await gateway(client))
          .complete('测试真实请求协议', model: 'text-model');
      expect(result, '已收到服务端文本');
      expect(seen, [
        '/api/model-gateway/v1/models',
        '/api/model-gateway/v1/chat/completions',
      ]);
    },
  );

  test(
    'empty model/prompt fail before network and never select another model',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return jsonResponse(textCatalog);
      });
      final service = await gateway(client);
      await expectLater(
        service.complete('prompt'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.code,
            'code',
            'model_not_configured',
          ),
        ),
      );
      final configured = await gateway(client, model: 'text-model');
      await expectLater(
        configured.complete('prompt', model: ' '),
        throwsA(isA<GatewayException>()),
      );
      await expectLater(
        configured.complete(' '),
        throwsA(isA<GatewayException>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'model outside granted text catalog never causes billable completion',
    () async {
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') posts++;
        return jsonResponse(textCatalog);
      });
      final service = await gateway(client);
      for (final model in ['unknown-model', 'denied-model', 'asr-model']) {
        await expectLater(
          service.complete('prompt', model: model),
          throwsA(
            isA<GatewayException>().having(
              (e) => e.code,
              'code',
              'model_not_authorized',
            ),
          ),
        );
      }
      expect(posts, 0);
    },
  );

  test(
    'configured model is explicit default, not a catalog fallback',
    () async {
      var selected = '';
      final client = MockClient((request) async {
        if (request.method == 'GET') return jsonResponse(textCatalog);
        selected = jsonDecode(request.body)['model'] as String;
        return jsonResponse({
          'choices': [
            {
              'message': {'content': 'server-output'},
            },
          ],
        });
      });
      expect(
        await (await gateway(client, model: 'text-model')).complete('prompt'),
        'server-output',
      );
      expect(selected, 'text-model');
    },
  );

  test(
    '401 refreshes once; 401 remains an error rather than fabricated content',
    () async {
      var posts = 0, refreshes = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/oauth/token') {
          refreshes++;
          return jsonResponse(tokenJson(access: 'synthetic-access-2'));
        }
        if (request.method == 'GET') return jsonResponse(textCatalog);
        posts++;
        return jsonResponse({}, status: 401);
      });
      await expectLater(
        (await gateway(client, model: 'text-model')).complete('prompt'),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(posts, 2);
      expect(refreshes, 1);
    },
  );

  test('malformed/no-text catalog and HTTP errors are explicit', () async {
    for (final body in [
      <String, dynamic>{},
      {'data': []},
      {
        'data': [
          {
            'id': 'only-asr',
            'capabilities': ['asr'],
          },
        ],
      },
      {
        'data': [42],
      },
    ]) {
      final client = MockClient((_) async => jsonResponse(body));
      await expectLater(
        (await gateway(client)).listTextModels(),
        throwsA(isA<GatewayException>()),
      );
    }
    final denied = MockClient(
      (_) async => jsonResponse({
        'error': {'message': 'do-not-log'},
      }, status: 403),
    );
    await expectLater(
      (await gateway(denied)).listTextModels(),
      throwsA(
        isA<GatewayException>()
            .having((e) => e.statusCode, 'HTTP status', 403)
            .having(
              (e) => e.toString(),
              'redacted',
              isNot(contains('do-not-log')),
            ),
      ),
    );
  });

  test('empty/malformed/truncated completion and server failure never return raw prompt', () async {
    for (final body in [
      <String, dynamic>{},
      {'choices': []},
      {
        'choices': [
          {
            'message': {'content': ''},
          },
        ],
      },
      {
        'choices': [
          {
            'finish_reason': 'length',
            'message': {'content': 'partial'},
          },
        ],
      },
    ]) {
      final client = MockClient(
        (request) async =>
            jsonResponse(request.method == 'GET' ? textCatalog : body),
      );
      await expectLater(
        (await gateway(
          client,
          model: 'text-model',
        )).complete('sensitive-prompt'),
        throwsA(isA<GatewayException>()),
      );
    }
    final failing = MockClient(
      (request) async => request.method == 'GET'
          ? jsonResponse(textCatalog)
          : http.Response('untrusted-sensitive-server-body', 500),
    );
    await expectLater(
      (await gateway(
        failing,
        model: 'text-model',
      )).complete('sensitive-prompt'),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.toString(),
          'redacted',
          isNot(contains('sensitive')),
        ),
      ),
    );
  });

  test('unapproved model gateway host fails before bearer or HTTP', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return jsonResponse(textCatalog);
    });
    await expectLater(
      (await gateway(client, base: 'https://evil.test/v1')).listTextModels(),
      throwsA(isA<GatewayException>()),
    );
    expect(calls, 0);
  });
}
