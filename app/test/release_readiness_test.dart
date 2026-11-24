library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/platform/crash_guard.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/auth/auth.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/health/health_signal_bucket.dart';
import 'package:recording_card/services/health/health_signal_collector.dart';
import 'package:recording_card/services/health/health_signal_controller.dart';
import 'package:recording_card/services/health/health_signal_models.dart';
import 'package:recording_card/services/health/health_signal_store.dart';
import 'package:recording_card/services/memory/local_memory_index.dart';
import 'package:recording_card/services/memory/memory_indexer.dart';
import 'package:recording_card/services/memory/memory_search_service.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _NoopSpeechEngine implements SpeechEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const AsrResult(
        text: '',
        tokens: [],
        timestampsMs: [],
        audioMs: 0,
      );
}

class _NoopModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => null;
}

class _StubHealthCollector implements HealthSignalCollector {
  @override
  Stream<void> get updates => const Stream.empty();

  @override
  Future<HealthPlatformInfo> info() async => const HealthPlatformInfo(
        platform: 'ios',
        available: true,
      );

  @override
  Future<HealthAccessResult> requestAccess() async => const HealthAccessResult(
        available: true,
        requestedTypeCount: 1,
      );

  @override
  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<List<HealthSignalDraft>> drainSpool() async => const [];
}

class _NoopLauncher implements WebAuthLauncher {
  @override
  bool get isSupported => true;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async =>
      throw const OAuthCancelledException();
}

Future<({
  AuthService auth,
  List<http.Request> requests,
})> _signedInAuthForDelete(int deleteStatusCode) async {
  final requests = <http.Request>[];
  final httpClient = MockClient((req) async {
    requests.add(req);
    if (req.url.path == '/account' && req.method == 'DELETE') {
      return http.Response(
        deleteStatusCode == 500 ? '{"message":"服务端维护中"}' : '{}',
        deleteStatusCode,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path == '/profile' && req.method == 'GET') {
      return http.Response(
        jsonEncode({
          'user_id': 'u-1',
          'name': '正式测试用户',
          'email': 'release@reai.chat',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path == '/oauth/revoke') {
      return http.Response('{}', 200);
    }
    return http.Response('{}', 200);
  });

  final expires = DateTime.now().add(const Duration(hours: 1));
  final refreshExpires = DateTime.now().add(const Duration(days: 30));
  final secure = InMemorySecureStore({
    OAuthTokenStore.bundleKey: jsonEncode({
      'access_token': 'acc-token-1',
      'refresh_token': 'ref-token-1',
      'expires_at': expires.toIso8601String(),
      'refresh_expires_at': refreshExpires.toIso8601String(),
      'token_type': 'Bearer',
      'account': {
        'user_id': 'u-1',
        'name': '正式测试用户',
        'email': 'release@reai.chat',
      },
    }),
  });
  final stubConfig = kStubOAuthConfig.copyWith(
    deleteAccountUrl: '$kStubApiBase/account',
  );
  final oauthClient = OAuthClient(config: stubConfig, httpClient: httpClient);
  final tokenStore = OAuthTokenStore(
    secure: secure,
    client: oauthClient,
    config: stubConfig,
  );
  final auth = AuthService(
    oauthConfig: stubConfig,
    oauthClient: oauthClient,
    tokenStore: tokenStore,
    launcher: _NoopLauncher(),
    secureStore: secure,
  );
  await auth.ready;
  return (auth: auth, requests: requests);
}

Future<void> _pumpRealAsyncUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxSteps = 150,
}) async {
  for (var i = 0; i < maxSteps && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<({
  Directory rootDir,
  Directory recordingsDir,
  Directory modelsDir,
  RecordingStore recordingStore,
  HealthSignalStore healthStore,
  HealthSignalController healthController,
  MemorySearchService memorySearch,
  AppStore appStore,
  AgentConfigStore agentConfig,
  DeviceStore device,
})> _createPopulatedStores() async {
  final rootDir = await Directory.systemTemp.createTemp('rc-release-ready-');
  final recordingsDir = Directory('${rootDir.path}/recordings')..createSync();
  final modelsDir = Directory('${rootDir.path}/models')..createSync();
  File('${modelsDir.path}/keep.onnx').writeAsStringSync('keep-model');

  final jsonStore = JsonStore(store: InMemoryStore());
  final recordingStore = RecordingStore(
    root: recordingsDir,
    jsonStore: jsonStore,
  );
  await recordingStore.save(
    RecordingFile(
      deviceName: 'REC_001.APM',
      session: 'sess-1',
      seq: 1,
      startAtMs: DateTime(2026, 11, 24, 10, 0).millisecondsSinceEpoch,
      apmPath: '${recordingsDir.path}/REC_001.APM/REC_001.APM',
      durationMs: 60000,
      createdAtMs: DateTime(2026, 11, 24, 10, 0).millisecondsSinceEpoch,
      stage: RecordingStage.ready,
      segments: [
        SegmentRecord(
          id: 'seg-1',
          sessionId: 'sess-1',
          index: 0,
          startAtMs: DateTime(2026, 11, 24, 10, 0).millisecondsSinceEpoch,
          endAtMs: DateTime(2026, 11, 24, 10, 1).millisecondsSinceEpoch,
          title: '发布前检查会议',
          brief: '核对隐私清单和注销账号流程',
          longText: '核对隐私清单和注销账号流程',
          status: SegmentStatus.closed,
          turnIds: const ['t-1'],
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 't-1',
          startMs: 0,
          endMs: 10000,
          speakerLabel: '说话人 1（推测）',
          text: '核对隐私清单和注销账号流程',
          srcUtteranceIds: ['u-1'],
        ),
      ],
    ),
  );
  File('${recordingsDir.path}/REC_001.APM/REC_001.APM').writeAsStringSync('fake-audio');

  final agentConfig = AgentConfigStore(store: InMemoryStore());
  await agentConfig.load();

  final healthStore = HealthSignalStore(
    factory: databaseFactoryFfi,
    path: () async => '${rootDir.path}/health.db',
  );
  await healthStore.upsertAll([
    HealthSignalSample(
      id: 'h-1',
      type: 'heart_rate',
      startMs: 1000,
      endMs: 2000,
      valueNum: 72,
      unit: 'bpm',
      ingestedAtMs: 3000,
    ),
  ]);
  final healthController = HealthSignalController(
    store: healthStore,
    collector: _StubHealthCollector(),
    config: agentConfig,
  );
  await healthController.refreshPresentation();

  final memIndex = LocalMemoryIndex(
    factory: databaseFactoryFfi,
    path: () async => '${rootDir.path}/memory.db',
  );
  late AppStore appStore;
  final memorySearch = MemorySearchService(
    index: memIndex,
    corpus: () => MemoryCorpus(
      events: appStore.events,
      summaries: appStore.summaries,
    ),
  );

  final pipeline = RecordingPipeline(
    gateway: FakeCardGateway(),
    store: recordingStore,
    engine: _NoopSpeechEngine(),
    models: _NoopModels(),
    settings: SettingsStore(store: InMemoryStore()),
    agentConfig: agentConfig,
  );
  final stubTokens = await buildSignedInTokenStore();
  final generator = SummaryGenerator(
    gateway: ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: stubTokens,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
    ),
    agentConfig: agentConfig,
  );
  appStore = AppStore(jsonStore: jsonStore, loadPersistedState: true)
    ..attachPipeline(
      pipeline: pipeline,
      store: recordingStore,
      generator: generator,
    );
  await appStore.refreshFromStore();
  appStore.summaries = [
    SummaryCard(id: 'sum-1', time: '10:05', state: SummaryState.done)
      ..title = '检查总结'
      ..overview = '已核对所有上架检查项',
  ];
  appStore.eventPhotos['seg-1'] = [
    const EventPhoto(
      id: 'p-1',
      time: '10:00:30',
      path: '/tmp/p1.jpg',
      capturedAtMs: 1700000000000,
    ),
  ];
  await memorySearch.reindex();

  final device = DeviceStore(gateway: FakeCardGateway());
  return (
    rootDir: rootDir,
    recordingsDir: recordingsDir,
    modelsDir: modelsDir,
    recordingStore: recordingStore,
    healthStore: healthStore,
    healthController: healthController,
    memorySearch: memorySearch,
    appStore: appStore,
    agentConfig: agentConfig,
    device: device,
  );
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetCrashGuardForTest();
  });

  tearDown(resetCrashGuardForTest);

  testWidgets('设置页默认隐藏开发者设置，连点版本号 7 次后才显示', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    addTearDown(agentConfig.dispose);
    final store = AppStore(events: seedEvents, loadPersistedState: false);
    addTearDown(store.dispose);
    final device = DeviceStore(gateway: FakeCardGateway());
    addTearDown(device.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: store,
          device: device,
          agentConfig: agentConfig,
          settings: SettingsStore(store: InMemoryStore()),
          recordingStatus: RecordingStatusController(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();

    expect(find.byKey(const Key('set-developer')), findsNothing);
    expect(find.byKey(const Key('set-data-management')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('setting-version')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('account-delete-entry')), findsOneWidget);

    for (var i = 0; i < 7; i++) {
      await tester.tap(find.byKey(const Key('setting-version')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(agentConfig.developerMode, isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-data-management')),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-developer')),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('set-developer')), findsOneWidget);
  });

  testWidgets('设置 → 数据管理 → 清空本机全部数据：清理录音/健康/记忆并保留模型目录', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final env = _createPopulatedStores();
    final ctx = await tester.runAsync(() => env);
    addTearDown(() => tester.runAsync(() async {
          await ctx!.healthStore.close();
          await ctx.memorySearch.close();
          ctx.healthController.dispose();
          ctx.appStore.dispose();
          ctx.agentConfig.dispose();
          ctx.device.dispose();
          if (ctx.rootDir.existsSync()) {
            await ctx.rootDir.delete(recursive: true);
          }
        }));

    final authRes = await tester.runAsync(() => _signedInAuthForDelete(200));
    final auth = authRes!.auth;
    addTearDown(auth.dispose);

    expect(ctx!.appStore.events, isNotEmpty);
    expect(ctx.healthController.sampleCount, 1);
    final hitsBefore = await tester.runAsync(() => ctx.memorySearch.search('隐私清单'));
    expect(hitsBefore, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: ctx.appStore,
          device: ctx.device,
          agentConfig: ctx.agentConfig,
          settings: SettingsStore(store: InMemoryStore()),
          authService: auth,
          healthSignals: ctx.healthController,
          memorySearch: ctx.memorySearch,
          recordingStatus: RecordingStatusController(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const Key('set-data-management')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('set-data-management')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('clear-local-data-btn')), findsOneWidget);
    await tester.tap(find.byKey(const Key('clear-local-data-btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('clear-local-data-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear-local-data-confirm')));
    await _pumpRealAsyncUntil(
      tester,
      () =>
          ctx.appStore.events.isEmpty &&
          ctx.healthController.sampleCount == 0 &&
          !Directory('${ctx.recordingsDir.path}/REC_001.APM').existsSync(),
    );

    expect(ctx.appStore.events, isEmpty);
    expect(ctx.appStore.summaries, isEmpty);
    expect(ctx.appStore.eventPhotos, isEmpty);
    expect(ctx.healthController.sampleCount, 0);
    expect(Directory('${ctx.recordingsDir.path}/REC_001.APM').existsSync(), isFalse);
    expect(File('${ctx.recordingsDir.path}/REC_001.APM/REC_001.APM').existsSync(), isFalse);
    expect(File('${ctx.modelsDir.path}/keep.onnx').existsSync(), isTrue);
    final hitsAfter = await tester.runAsync(() => ctx.memorySearch.search('隐私清单'));
    expect(hitsAfter, isEmpty);
    expect(auth.isSignedIn, isTrue);
  });

  group('设置 → 关于录音卡 → 注销账号（诚实后端分支）', () {
    testWidgets('DELETE /account 返回 200 → 清空本机数据并退出登录', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx = await tester.runAsync(_createPopulatedStores);
      addTearDown(() => tester.runAsync(() async {
            await ctx!.healthStore.close();
            await ctx.memorySearch.close();
            ctx.healthController.dispose();
            ctx.appStore.dispose();
            ctx.agentConfig.dispose();
            ctx.device.dispose();
            if (ctx.rootDir.existsSync()) {
              await ctx.rootDir.delete(recursive: true);
            }
          }));

      final authRes = await tester.runAsync(() => _signedInAuthForDelete(200));
      final auth = authRes!.auth;
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: ctx!.appStore,
            device: ctx.device,
            agentConfig: ctx.agentConfig,
            settings: SettingsStore(store: InMemoryStore()),
            authService: auth,
            healthSignals: ctx.healthController,
            memorySearch: ctx.memorySearch,
            recordingStatus: RecordingStatusController(),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('set-data-management')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('set-data-management')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-account-btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-account-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('delete-account-confirm')));
      await _pumpRealAsyncUntil(
        tester,
        () =>
            !auth.isSignedIn &&
            ctx.appStore.events.isEmpty &&
            ctx.healthController.sampleCount == 0,
      );

      expect(
        authRes.requests.any((r) => r.method == 'DELETE' && r.url.path == '/account'),
        isTrue,
      );
      expect(ctx.appStore.events, isEmpty);
      expect(ctx.healthController.sampleCount, 0);
      expect(auth.isSignedIn, isFalse);
    });

    testWidgets('DELETE /account 返回 404 → 不撒谎，弹出兜底指引且点「仅清空本机数据并退出」生效', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx = await tester.runAsync(_createPopulatedStores);
      addTearDown(() => tester.runAsync(() async {
            await ctx!.healthStore.close();
            await ctx.memorySearch.close();
            ctx.healthController.dispose();
            ctx.appStore.dispose();
            ctx.agentConfig.dispose();
            ctx.device.dispose();
            if (ctx.rootDir.existsSync()) {
              await ctx.rootDir.delete(recursive: true);
            }
          }));

      final authRes = await tester.runAsync(() => _signedInAuthForDelete(404));
      final auth = authRes!.auth;
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: ctx!.appStore,
            device: ctx.device,
            agentConfig: ctx.agentConfig,
            settings: SettingsStore(store: InMemoryStore()),
            authService: auth,
            healthSignals: ctx.healthController,
            memorySearch: ctx.memorySearch,
            recordingStatus: RecordingStatusController(),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('set-data-management')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('set-data-management')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-account-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-account-confirm')));
      await _pumpRealAsyncUntil(
        tester,
        () => find
            .byKey(const Key('delete-account-unavailable-dialog'))
            .evaluate()
            .isNotEmpty,
      );

      expect(find.byKey(const Key('delete-account-unavailable-dialog')), findsOneWidget);
      expect(auth.isSignedIn, isTrue);
      expect(ctx.appStore.events, isNotEmpty);

      await tester.tap(find.byKey(const Key('delete-account-local-fallback')));
      await _pumpRealAsyncUntil(
        tester,
        () =>
            !auth.isSignedIn &&
            ctx.appStore.events.isEmpty &&
            ctx.healthController.sampleCount == 0,
      );

      expect(ctx.appStore.events, isEmpty);
      expect(ctx.healthController.sampleCount, 0);
      expect(auth.isSignedIn, isFalse);
    });

    testWidgets('DELETE /account 返回 500 → 明确提示错误，不误删本地数据或登出', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx = await tester.runAsync(_createPopulatedStores);
      addTearDown(() => tester.runAsync(() async {
            await ctx!.healthStore.close();
            await ctx.memorySearch.close();
            ctx.healthController.dispose();
            ctx.appStore.dispose();
            ctx.agentConfig.dispose();
            ctx.device.dispose();
            if (ctx.rootDir.existsSync()) {
              await ctx.rootDir.delete(recursive: true);
            }
          }));

      final authRes = await tester.runAsync(() => _signedInAuthForDelete(500));
      final auth = authRes!.auth;
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: ctx!.appStore,
            device: ctx.device,
            agentConfig: ctx.agentConfig,
            settings: SettingsStore(store: InMemoryStore()),
            authService: auth,
            healthSignals: ctx.healthController,
            memorySearch: ctx.memorySearch,
            recordingStatus: RecordingStatusController(),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('set-data-management')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('set-data-management')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-account-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-account-confirm')));
      await _pumpRealAsyncUntil(
        tester,
        () => find
            .byKey(const Key('delete-account-error-dialog'))
            .evaluate()
            .isNotEmpty,
      );

      expect(find.byKey(const Key('delete-account-error-dialog')), findsOneWidget);
      expect(find.text('服务端暂时不可用，请稍后重试'), findsOneWidget);
      expect(auth.isSignedIn, isTrue);
      expect(ctx.appStore.events, isNotEmpty);
      expect(ctx.healthController.sampleCount, 1);
    });
  });
}
