import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/auth/authorized_http_client.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/model_gateway/model_gateway.dart';
import 'package:recording_card/services/runtime/runtime_config.dart';

import '../a_auth/support.dart';

Map<String, Object?> catalog(List<String> ids) => {
  'data': [
    for (final id in ids)
      {
        'id': id,
        'name': id,
        'capabilities': ['text'],
      },
  ],
};
final completion = {
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {'content': 'synthetic-output'},
    },
  ],
};

class AnalysisHarness {
  AnalysisHarness(this.analysis, this.tokens);
  final AuthorizedAnalysisGateway analysis;
  final OAuthTokenStore tokens;

  static Future<AnalysisHarness> create(
    Future<http.Response> Function(http.Request) respond, {
    String configuredModel = '',
    bool signedIn = true,
    bool bindEpoch = true,
  }) async {
    final client = MockClient(respond);
    final tokens = OAuthTokenStore(
      client: testOAuth(client),
      storage: MemoryTokenStorage(),
      clock: () => testTime,
    );
    if (signedIn) await seedTokens(tokens);
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: tokens,
        httpClient: client,
        trustedHosts: ['approved.test'],
      ),
      config: testConfig,
      defaultModel: configuredModel,
    );
    return AnalysisHarness(
      AuthorizedAnalysisGateway(
        gateway,
        sessionEpoch: bindEpoch ? () => tokens.userIdentityEpoch : null,
      ),
      tokens,
    );
  }
}

void main() {
  test(
    'construction and empty prompt never fetch catalog or request a model',
    () async {
      var requests = 0;
      final harness = await AnalysisHarness.create((_) async {
        requests++;
        return jsonResponse(catalog(['first']));
      });
      expect(requests, 0);
      await expectLater(
        harness.analysis.complete(' '),
        throwsA(
          isA<GatewayException>().having((e) => e.code, 'code', 'empty_prompt'),
        ),
      );
      expect(requests, 0);
    },
  );

  test(
    'empty default fails closed when owning session epoch is not wired',
    () async {
      var requests = 0;
      final harness = await AnalysisHarness.create((_) async {
        requests++;
        return jsonResponse(catalog(['first']));
      }, bindEpoch: false);
      await expectLater(
        harness.analysis.complete('prompt'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.code,
            'code',
            'session_epoch_required',
          ),
        ),
      );
      expect(requests, 0);
    },
  );

  test('automatic choice never bypasses OAuth authentication', () async {
    var requests = 0;
    final harness = await AnalysisHarness.create((_) async {
      requests++;
      return jsonResponse(catalog(['first']));
    }, signedIn: false);
    await expectLater(
      harness.analysis.complete('prompt'),
      throwsA(isA<AuthRequiredException>()),
    );
    expect(requests, 0);
  });

  test('first choice uses server directory order and sends only resolved granted text ID', () async {
    final paths = <String>[];
    final posted = <String>[];
    final harness = await AnalysisHarness.create((request) async {
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer synthetic-access-1');
      paths.add(request.url.path);
      if (request.method == 'GET') {
        return jsonResponse({
          'data': [
            {
              'id': 'denied',
              'capabilities': ['text'],
              'authorized': false,
            },
            {
              'id': 'asr',
              'capabilities': ['asr'],
            },
            {
              'id': 'unavailable',
              'capabilities': ['text'],
              'available': false,
            },
            {
              'id': 'disabled',
              'capabilities': ['text'],
              'enabled': false,
            },
            {'id': 'unknown'},
            {
              'id': 'z-first',
              'capabilities': ['text'],
            },
            {
              'id': 'a-second',
              'capabilities': ['text'],
            },
          ],
        });
      }
      final body = jsonDecode(request.body) as Map;
      posted.add(body['model'] as String);
      expect(body['messages'], [
        {'role': 'user', 'content': 'user-analysis'},
      ]);
      expect(body['stream'], isFalse);
      expect(body.containsKey('api_key'), isFalse);
      return jsonResponse(completion);
    });
    expect(
      await harness.analysis.complete('user-analysis'),
      'synthetic-output',
    );
    expect(
      AuthorizedAnalysisGateway.firstChoicePolicy,
      'first_authorized_text_in_server_catalog_order',
    );
    expect(posted, ['z-first']);
    expect(paths, [
      '/api/model-gateway/v1/models',
      '/api/model-gateway/v1/models',
      '/api/model-gateway/v1/chat/completions',
    ]);
  });

  test(
    'empty or no-text authorized directory fails without completion',
    () async {
      for (final data in [
        catalog([]),
        {
          'data': [
            {
              'id': 'asr',
              'capabilities': ['asr'],
            },
          ],
        },
        {
          'data': [
            {
              'id': 'denied',
              'capabilities': ['text'],
              'authorized': false,
            },
          ],
        },
      ]) {
        var gets = 0, posts = 0;
        final harness = await AnalysisHarness.create((request) async {
          if (request.method == 'GET') gets++;
          if (request.method == 'POST') posts++;
          return jsonResponse(data);
        });
        await expectLater(
          harness.analysis.complete('prompt'),
          throwsA(
            isA<GatewayException>().having(
              (e) => e.code,
              'code',
              'no_text_models',
            ),
          ),
        );
        expect(gets, 1);
        expect(posts, 0);
      }
    },
  );

  test('specified/configured invalid ID fails strictly and never selects first model', () async {
    for (final configured in ['', 'invalid-configured']) {
      var gets = 0, posts = 0;
      final harness = await AnalysisHarness.create((request) async {
        if (request.method == 'GET') gets++;
        if (request.method == 'POST') posts++;
        return jsonResponse(catalog(['valid-first']));
      }, configuredModel: configured);
      await expectLater(
        harness.analysis.complete(
          'prompt',
          model: configured.isEmpty ? 'invalid-explicit' : null,
        ),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.code,
            'code',
            'model_not_authorized',
          ),
        ),
      );
      expect(gets, 1);
      expect(posts, 0);
    }
  });

  test('valid configured or explicit override sends exact ID without automatic lookup', () async {
    var gets = 0;
    final posted = <String>[];
    final harness = await AnalysisHarness.create(
      (request) async {
        if (request.method == 'GET') {
          gets++;
          return jsonResponse(
            catalog(['catalog-first', 'configured', 'explicit']),
          );
        }
        posted.add(jsonDecode(request.body)['model'] as String);
        return jsonResponse(completion);
      },
      configuredModel: 'configured',
      bindEpoch: false,
    );
    await harness.analysis.complete('prompt');
    await harness.analysis.complete('prompt', model: 'explicit');
    expect(gets, 2);
    expect(posted, ['configured', 'explicit']);
  });

  test('explicit empty model is an error even when an automatic or configured ID is available', () async {
    var requests = 0;
    final harness = await AnalysisHarness.create((_) async {
      requests++;
      return jsonResponse(catalog(['configured']));
    }, configuredModel: 'configured');
    await expectLater(
      harness.analysis.complete('prompt', model: ' '),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.code,
          'code',
          'model_not_configured',
        ),
      ),
    );
    expect(requests, 0);
  });

  test('first chosen model is stable through directory reorder within the same session', () async {
    var gets = 0;
    final posted = <String>[];
    final harness = await AnalysisHarness.create((request) async {
      if (request.method == 'GET') {
        gets++;
        return jsonResponse(
          catalog(gets == 1 ? ['first', 'second'] : ['second', 'first']),
        );
      }
      posted.add(jsonDecode(request.body)['model'] as String);
      return jsonResponse(completion);
    });
    await harness.analysis.complete('first-prompt');
    await harness.analysis.complete('second-prompt');
    expect(
      gets,
      3,
    ); // One initial lookup; fresh permission check before each POST.
    expect(posted, ['first', 'first']);
  });

  test('removed first choice fails on fresh directory and is not replaced on retry', () async {
    var gets = 0;
    final posted = <String>[];
    final harness = await AnalysisHarness.create((request) async {
      if (request.method == 'GET') {
        gets++;
        return jsonResponse(
          catalog(gets <= 2 ? ['first', 'second'] : ['second']),
        );
      }
      posted.add(jsonDecode(request.body)['model'] as String);
      return jsonResponse(completion);
    });
    await harness.analysis.complete('first-prompt');
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        harness.analysis.complete('later-prompt'),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.code,
            'code',
            'model_not_authorized',
          ),
        ),
      );
    }
    expect(posted, ['first']);
    expect(gets, 4);
  });

  test(
    'failed completion never retries or switches to another paid model',
    () async {
      var gets = 0;
      final posted = <String>[];
      final harness = await AnalysisHarness.create((request) async {
        if (request.method == 'GET') {
          gets++;
          return jsonResponse(
            catalog(gets == 1 ? ['first', 'second'] : ['second', 'first']),
          );
        }
        posted.add(jsonDecode(request.body)['model'] as String);
        return jsonResponse({}, status: 500);
      });
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          harness.analysis.complete('prompt'),
          throwsA(isA<GatewayException>()),
        );
      }
      expect(posted, ['first', 'first']);
      expect(gets, 3);
    },
  );

  test('logout and same-account relogin invalidate first-choice cache by identity epoch', () async {
    var secondSession = false;
    final posted = <String>[];
    final harness = await AnalysisHarness.create((request) async {
      if (request.method == 'GET') {
        return jsonResponse(
          catalog(secondSession ? ['second', 'first'] : ['first', 'second']),
        );
      }
      expect(
        request.headers['Authorization'],
        secondSession
            ? 'Bearer synthetic-access-2'
            : 'Bearer synthetic-access-1',
      );
      posted.add(jsonDecode(request.body)['model'] as String);
      return jsonResponse(completion);
    });
    await harness.analysis.complete('prompt');
    final firstEpoch = harness.tokens.userIdentityEpoch;
    await harness.tokens.clearTokens();
    await expectLater(
      harness.analysis.complete('signed-out-prompt'),
      throwsA(isA<AuthRequiredException>()),
    );
    await seedTokens(harness.tokens, access: 'synthetic-access-2');
    secondSession = true;
    expect(harness.tokens.userIdentityEpoch, greaterThan(firstEpoch));
    await harness.analysis.complete('prompt');
    expect(posted, ['first', 'second']);
  });

  test(
    'token refresh preserves identity epoch and the original choice',
    () async {
      var refreshed = false;
      final posted = <String>[];
      final harness = await AnalysisHarness.create((request) async {
        if (request.url.path == '/oauth/token') {
          expect(request.bodyFields['grant_type'], 'refresh_token');
          refreshed = true;
          return jsonResponse(tokenJson(access: 'synthetic-access-2'));
        }
        if (request.method == 'GET') {
          return jsonResponse(
            catalog(refreshed ? ['second', 'first'] : ['first', 'second']),
          );
        }
        posted.add(jsonDecode(request.body)['model'] as String);
        expect(
          request.headers['Authorization'],
          refreshed ? 'Bearer synthetic-access-2' : 'Bearer synthetic-access-1',
        );
        return jsonResponse(completion);
      });
      await harness.analysis.complete('first-prompt');
      final epoch = harness.tokens.userIdentityEpoch;
      await harness.tokens.refresh();
      expect(harness.tokens.userIdentityEpoch, epoch);
      await harness.analysis.complete('second-prompt');
      expect(posted, ['first', 'first']);
    },
  );

  test(
    'parallel first analyses share initial catalog choice and keep one ID',
    () async {
      final firstGet = Completer<void>();
      final release = Completer<void>();
      var gets = 0;
      final posted = <String>[];
      final harness = await AnalysisHarness.create((request) async {
        if (request.method == 'GET') {
          gets++;
          if (gets == 1) {
            firstGet.complete();
            await release.future;
            return jsonResponse(catalog(['first', 'second']));
          }
          return jsonResponse(catalog(['second', 'first']));
        }
        posted.add(jsonDecode(request.body)['model'] as String);
        return jsonResponse(completion);
      });
      final a = harness.analysis.complete('a');
      await firstGet.future;
      final b = harness.analysis.complete('b');
      release.complete();
      expect(await Future.wait([a, b]), [
        'synthetic-output',
        'synthetic-output',
      ]);
      expect(gets, 3);
      expect(posted, ['first', 'first']);
    },
  );

  test(
    'session changes during initial catalog cannot post or cache old choice',
    () async {
      var gets = 0;
      final posted = <String>[];
      late AnalysisHarness harness;
      harness = await AnalysisHarness.create((request) async {
        if (request.method == 'GET') {
          gets++;
          if (gets == 1) {
            await harness.tokens.clearTokens();
            await seedTokens(harness.tokens, access: 'synthetic-access-2');
            return jsonResponse(catalog(['old-session']));
          }
          return jsonResponse(catalog(['new-session']));
        }
        posted.add(jsonDecode(request.body)['model'] as String);
        return jsonResponse(completion);
      });
      await expectLater(
        harness.analysis.complete('old-prompt'),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(posted, isEmpty);
      await harness.analysis.complete('new-prompt');
      expect(posted, ['new-session']);
    },
  );

  test(
    'session changes during pre-POST permission check abort paid request',
    () async {
      var gets = 0, posts = 0;
      late AnalysisHarness harness;
      harness = await AnalysisHarness.create((request) async {
        if (request.method == 'GET') {
          gets++;
          if (gets == 2) {
            await harness.tokens.clearTokens();
            await seedTokens(harness.tokens, access: 'synthetic-access-2');
          }
          return jsonResponse(catalog(['first']));
        }
        posts++;
        return jsonResponse(completion);
      });
      await expectLater(
        harness.analysis.complete('prompt'),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(gets, 2);
      expect(posts, 0);
    },
  );
}
