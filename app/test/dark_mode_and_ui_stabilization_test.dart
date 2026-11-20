import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/platform/crash_guard.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/rc_icons.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/privacy_page.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/services/auth/auth.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/memory/local_memory_index.dart';
import 'package:recording_card/services/memory/memory_indexer.dart';
import 'package:recording_card/services/memory/memory_search_scope.dart';
import 'package:recording_card/services/memory/memory_search_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/speaker_profile_store.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/system_speech_client.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/widgets/raw_audio_player.dart';
import 'package:recording_card/widgets/store_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

ThemeData _darkTestTheme() => buildRCDarkTheme().copyWith(
  pageTransitionsTheme: testTheme().pageTransitionsTheme,
);

class _NoopEngine implements SpeechEngine {
  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async =>
      const AsrResult(text: '', tokens: [], timestampsMs: [], audioMs: 0);

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<void> dispose() async {}
}

class _NoopModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => null;
}

class _StubSenseVoiceModels implements SpeechModelProvider {
  const _StubSenseVoiceModels(this.paths);
  final SpeechModelPaths paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

class _DelayedFirstWriteStore implements KeyValueStore {
  final Map<String, String> _values = {};
  int writeCount = 0;

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    final seq = ++writeCount;
    if (seq == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    _values[key] = value;
  }

  @override
  Future<bool?> getBool(String key) async {
    final v = _values['@bool:$key'];
    return v == null ? null : v == 'true';
  }

  @override
  Future<void> setBool(String key, bool value) async {
    _values['@bool:$key'] = value.toString();
  }

  @override
  Future<void> remove(String key) async {
    _values
      ..remove(key)
      ..remove('@bool:$key');
  }

  @override
  Future<bool> containsKey(String key) async =>
      _values.containsKey(key) || _values.containsKey('@bool:$key');
}

class _RecordingFakeSenseVoiceEngine extends _NoopEngine {
  String? loadedLanguage;
  int transcribeCalls = 0;
  final String replyText;

  _RecordingFakeSenseVoiceEngine(this.replyText);

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {
    loadedLanguage = language;
  }

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    transcribeCalls++;
    return AsrResult(
      text: replyText,
      tokens: const [],
      timestampsMs: const [],
      audioMs: 1000,
    );
  }
}

class _EchoWebAuthLauncher implements WebAuthLauncher {
  @override
  bool get isSupported => true;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    final state = authorizeUrl.queryParameters['state'] ?? '';
    return Uri.parse('recording-card://callback?code=test-code&state=$state');
  }
}

Future<({AuthService auth, InMemorySecureStore secure})>
_createSignedInAuth() async {
  final secure = InMemorySecureStore();
  final authHttp = MockClient((req) async {
    if (req.url.path.endsWith('/oauth/token')) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'access_token': 'access-1',
            'refresh_token': 'refresh-1',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'refresh_expires_in': 2592000,
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (req.url.path.endsWith('/profile')) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'user_id': 'u-del',
            'display_name': '测试用户',
            'email': 'u@example.com',
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (req.url.path.endsWith('/oauth/revoke')) {
      return http.Response('', 200);
    }
    return http.Response('{}', 200);
  });
  final oauthClient = OAuthClient(
    config: kStubOAuthConfig,
    httpClient: authHttp,
  );
  final auth = AuthService(
    oauthConfig: kStubOAuthConfig,
    oauthClient: oauthClient,
    launcher: _EchoWebAuthLauncher(),
    secureStore: secure,
  );
  await auth.ready;
  final err = await auth.signInWithOAuth();
  expect(err, isNull);
  expect(auth.isSignedIn, isTrue);
  return (auth: auth, secure: secure);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });
  testWidgets(
    '1. Dark Mode semantic colors across AppShell, Timeline, Detail, UnclassifiedPhotos, Privacy & RawAudioPlayer',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('rc_dark_test_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final wavFile = File('${tmp.path}/sample.wav')
        ..writeAsBytesSync(encodeWav(Float32List(16000), sampleRate: 16000));

      final model = SummaryModel();
      const ev = RecordEvent(
        id: 'ev-dark',
        dayOffset: 0,
        title: '深色模式验收记录',
        brief: '检查深色下所有表面与气泡不出现白底白字',
        longText: '一段完整的深色模式阶段概述文本，验证卡片底色语义化。',
        time: '14:20',
        dur: '5分00秒',
        speakers: '1 / 2',
        mark: '重点',
        srcMap: '来源 14:20—14:25',
        dialog: [
          TurnLine('1', '深色模式下气泡应当使用深色卡片背景。', '来源 14:20—14:22'),
          TurnLine('2', '原始数据气泡也必须使用深色语义底色。', '来源 14:22—14:25'),
        ],
        raw: [TurnLine('1', '深色模式下气泡应当使用深色卡片背景。', '00:05')],
        photos: [EventPhoto(id: 'p-excl', time: '14:21', excluded: true)],
      );
      final sum = SummaryCard(
        id: 'sum-dark',
        time: '14:30',
        state: SummaryState.done,
      )
        ..srcIds = [ev.id]
        ..title = '深色总结卡'
        ..overview = '深色概览';

      final store = AppStore(
        events: [ev],
        generator: await model.generator(),
        loadPersistedState: false,
      )..summaries = [sum];
      final dev = DeviceStore(gateway: FakeCardGateway());
      addTearDown(dev.dispose);
      addTearDown(store.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          darkTheme: _darkTestTheme(),
          themeMode: ThemeMode.dark,
          home: AppShell(store: store, device: dev),
        ),
      );
      await tester.pumpAndSettle();

      final headerBox =
          tester.widget<Container>(find.byKey(const Key('app-header')));
      final headerDeco = headerBox.decoration! as BoxDecoration;
      expect(headerDeco.color, RCColorScheme.dark.bg);

      final navBox =
          tester.widget<Container>(find.byKey(const Key('bottom-nav')));
      final navDeco = navBox.decoration! as BoxDecoration;
      expect(navDeco.color, RCColorScheme.dark.bg);

      final sumBox =
          tester.widget<Container>(find.byKey(const Key('sumcard-sum-dark')));
      final sumDeco = sumBox.decoration! as BoxDecoration;
      expect(sumDeco.color, RCColorScheme.dark.card);

      await tester.tap(find.byKey(const Key('card-unc-0')));
      await tester.pumpAndSettle();
      final uncBox = tester.widget<ColoredBox>(find.byKey(const Key('p-unc')));
      expect(uncBox.color, RCColorScheme.dark.bg);
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('card-ev-dark')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detail-ev-dark')));
      await tester.pumpAndSettle();

      final dlgPara = tester.widget<Container>(
        find.byKey(const Key('turn-para-ev-dark-0')),
      );
      expect((dlgPara.decoration! as BoxDecoration).color, RCColorScheme.dark.card);

      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pumpAndSettle();
      final rawMat = tester.widget<Material>(
        find.ancestor(
          of: find.byKey(const Key('raw-utt-0')),
          matching: find.byType(Material),
        ).first,
      );
      expect(rawMat.color, isNot(const Color(0xFFF6F6F2)));
      expect(rawMat.color, isNot(RCColors.card));

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          darkTheme: _darkTestTheme(),
          themeMode: ThemeMode.dark,
          home: const PrivacyPage(),
        ),
      );
      await tester.pumpAndSettle();
      final privScaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(privScaffold.backgroundColor, RCColorScheme.dark.bg);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          darkTheme: _darkTestTheme(),
          themeMode: ThemeMode.dark,
          home: Scaffold(
            body: RawAudioPlayer(
              fileKey: 'dark.wav',
              wavPath: wavFile.path,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final playerContainer = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('raw-audio-player')),
          matching: find.byType(Container),
        ).first,
      );
      expect(
        (playerContainer.decoration! as BoxDecoration).color,
        RCColorScheme.dark.card,
      );
    },
  );

  testWidgets(
    '1c. StatusSheetOverlay in Dark Mode has zero hardcoded RCColors.label/ink/card/bg or light hex fills across all views',
    (tester) async {
      expect(
        buildRCDarkTheme().colorScheme.onPrimary,
        RCColorScheme.dark.onLabel,
      );

      final model = SummaryModel();
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      final gw = FakeCardGateway(
        devices: const [
          CardDevice(
            id: 'dev-v2',
            name: 'DYJV2_001',
            rssi: -45,
          ),
        ],
        connectResult: const CardSnapshot(
          batteryLevel: 85,
          isCharging: false,
          wifiOpen: false,
          recording: false,
          fwVersion: '2.1.0',
          fwVersionCode: 21,
          wifiVersion: '1.4.0',
          wifiVersionCode: 14,
          deviceName: 'DYJV2_001',
          deviceId: 'dev-v2',
          deviceKind: DeviceKind.dyjV1,
          capabilities: HardwareCapabilities(
            realtimeAudio: true,
            hasOnboardStorage: true,
            hasFileSync: true,
            hasWifiConfig: true,
            hasCameraMedia: true,
            hasPhysicalRecordToggle: false,
            hasRemoteRecordControl: true,
            hasMarkButton: true,
            hasConfigurableButtons: true,
            otaMode: 'dual',
          ),
        ),
        wifiCredentials: const [CardWifiCredential(ssid: 'Office_2.4G')],
        wifiNetworks: const [
          CardWifiNetwork(ssid: 'Office_2.4G', rssi: -50, secured: true),
          CardWifiNetwork(ssid: 'Guest_2.4G', rssi: -68, secured: true),
        ],
        mainOta: const CardOtaInfo(
          version: '2.3.0',
          versionCode: 23,
          url: 'https://example.test/fw.bin',
        ),
      );
      final dev = DeviceStore(gateway: gw);
      final agentCfg = AgentConfigStore(store: InMemoryStore());
      addTearDown(agentCfg.dispose);
      addTearDown(dev.dispose);
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          darkTheme: _darkTestTheme(),
          themeMode: ThemeMode.dark,
          home: AppShell(store: store, device: dev, agentConfig: agentCfg),
        ),
      );
      await tester.pumpAndSettle();

      void assertSheetDarkClean(String viewName) {
        final sheetFinder = find.byKey(const Key('sheet-card'));
        expect(sheetFinder, findsOneWidget, reason: '$viewName sheet visible');
        final forbiddenFg = <Color>{RCColors.label, RCColors.ink};
        final forbiddenBg = <Color>{
          RCColors.card,
          RCColors.bg,
          const Color(0xFFF0F0EC),
          const Color(0xFFF5F5F2),
          const Color(0xFFE8F5EA),
        };
        for (final t in tester.widgetList<Text>(
          find.descendant(of: sheetFinder, matching: find.byType(Text)),
        )) {
          final col = t.style?.color;
          if (col != null) {
            expect(
              forbiddenFg.contains(col),
              isFalse,
              reason: '$viewName Text "${t.data}" uses dark-hostile $col',
            );
          }
        }
        for (final ico in tester.widgetList<RCIcon>(
          find.descendant(of: sheetFinder, matching: find.byType(RCIcon)),
        )) {
          expect(
            forbiddenFg.contains(ico.color),
            isFalse,
            reason: '$viewName RCIcon ${ico.kind} uses dark-hostile ${ico.color}',
          );
        }
        for (final cnt in tester.widgetList<Container>(
          find.descendant(of: sheetFinder, matching: find.byType(Container)),
        )) {
          final dec = cnt.decoration;
          final bg = cnt.color ?? (dec is BoxDecoration ? dec.color : null);
          if (bg != null) {
            expect(
              forbiddenBg.contains(bg),
              isFalse,
              reason: '$viewName Container uses hardcoded light surface $bg',
            );
          }
        }
      }

      // 1) _ConnectView（未连接扫描态）
      dev.openSheet();
      await tester.pumpAndSettle();
      assertSheetDarkClean('_ConnectView');

      // 2) _MainView（已连接主视图）
      await dev.connectTo(gw.devices.first);
      await tester.pumpAndSettle();
      assertSheetDarkClean('_MainView');

      // 3) _WifiView（Wi-Fi 配网视图 + 展开密码输入框）
      dev.showView(DeviceView.wifi);
      await tester.pumpAndSettle();
      dev.wifiPick('Guest_2.4G');
      await tester.pumpAndSettle();
      assertSheetDarkClean('_WifiView');

      // 4) _FirmwareView（固件更新视图）
      dev.showView(DeviceView.upg);
      await tester.pumpAndSettle();
      assertSheetDarkClean('_FirmwareView');

      // 5) _ButtonConfigView（按键行为配置视图）
      dev.showView(DeviceView.btn);
      await tester.pumpAndSettle();
      assertSheetDarkClean('_ButtonConfigView');
    },
  );

  testWidgets('1b. WideLayout respects top & bottom MediaQuery SafeArea insets', (
    tester,
  ) async {
    final model = SummaryModel();
    final store = AppStore(
      events: seedEvents,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    final dev = DeviceStore(gateway: FakeCardGateway());
    addTearDown(dev.dispose);
    addTearDown(store.dispose);

    tester.view.physicalSize = const Size(960, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 20),
          ),
          child: child!,
        ),
        home: AppShell(store: store, device: dev),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('app-header'))).height,
      RCDims.wideChrome + 24,
    );
    expect(
      tester.getSize(find.byKey(const Key('bottom-nav'))).height,
      RCDims.wideChrome + 20,
    );
  });

  testWidgets(
    '2a. RawAudioPlayer two-step delete confirmation & sibling segment audio sync',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('rc_raw_del_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final wavPath = '${tmp.path}/shared.wav';
      File(wavPath).writeAsBytesSync(
        encodeWav(Float32List(32000), sampleRate: 16000),
      );

      final recStore = RecordingStore(
        root: Directory('${tmp.path}/recordings'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final nowMs = DateTime(2026, 11, 19, 14, 0).millisecondsSinceEpoch;
      final sharedFile = RecordingFile(
        deviceName: 'SHARED_001.WAV',
        session: 'ses-shared',
        seq: 1,
        startAtMs: nowMs,
        apmPath: '',
        wavPath: wavPath,
        durationMs: 90000,
        stage: RecordingStage.ready,
        turns: const [
          PolishedTurn(
            id: 't1',
            startMs: 0,
            endMs: 9000,
            speakerLabel: '1',
            text: '第一话题内容。',
            srcUtteranceIds: ['u1'],
          ),
          PolishedTurn(
            id: 't2',
            startMs: 75000,
            endMs: 85000,
            speakerLabel: '2',
            text: '第二话题内容。',
            srcUtteranceIds: ['u2'],
          ),
        ],
        utterances: const [
          RawUtterance(
            id: 'u1',
            sliceId: 's1',
            startMs: 0,
            endMs: 9000,
            text: '第一话题内容。',
          ),
          RawUtterance(
            id: 'u2',
            sliceId: 's1',
            startMs: 75000,
            endMs: 85000,
            text: '第二话题内容。',
          ),
        ],
        segments: [
          SegmentRecord(
            id: 'seg-1',
            sessionId: 'ses-shared',
            index: 0,
            startAtMs: nowMs,
            endAtMs: nowMs + 9500,
            title: '第一话题',
            brief: '第一话题摘要',
            longText: '第一话题摘要',
            status: SegmentStatus.closed,
            turnIds: const ['t1'],
          ),
          SegmentRecord(
            id: 'seg-2',
            sessionId: 'ses-shared',
            index: 1,
            startAtMs: nowMs + 75000,
            endAtMs: nowMs + 85000,
            title: '第二话题',
            brief: '第二话题摘要',
            longText: '第二话题摘要',
            status: SegmentStatus.closed,
            turnIds: const ['t2'],
          ),
        ],
        createdAtMs: nowMs,
      );
      final model = SummaryModel();
      final store = AppStore(loadPersistedState: false);
      store.attachPipeline(
        pipeline: RecordingPipeline(
          gateway: FakeCardGateway(),
          store: recStore,
          engine: _NoopEngine(),
          models: _NoopModels(),
        ),
        store: recStore,
        generator: await model.generator(),
      );
      await tester.runAsync(() async {
        await recStore.save(sharedFile);
        await store.refreshFromStore();
      });
      final dev = DeviceStore(gateway: FakeCardGateway());
      addTearDown(dev.dispose);
      addTearDown(store.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(store: store, device: dev),
        ),
      );
      await tester.pumpAndSettle();

      store.openDetail('seg-1', fresh: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('raw-audio-player')), findsOneWidget);
      await tester.tap(find.byKey(const Key('raw-audio-delete')));
      await tester.pump();
      expect(find.byKey(const Key('raw-audio-delete-confirm')), findsOneWidget);
      expect(find.byKey(const Key('raw-audio-delete-cancel')), findsOneWidget);
      expect(File(wavPath).existsSync(), isTrue);

      await tester.tap(find.byKey(const Key('raw-audio-delete-cancel')));
      await tester.pump();
      expect(find.byKey(const Key('raw-audio-delete-confirm')), findsNothing);
      expect(File(wavPath).existsSync(), isTrue);

      expect(store.segmentViewFor('seg-2')?.file.wavPath, wavPath);
      await tester.tap(find.byKey(const Key('raw-audio-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('raw-audio-delete-confirm')));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
        if (find.byKey(const Key('raw-audio-cleared')).evaluate().isNotEmpty &&
            store.segmentViewFor('seg-2')?.file.wavPath == null) {
          break;
        }
      }
      await tester.pumpAndSettle();

      expect(File(wavPath).existsSync(), isFalse);
      expect(find.byKey(const Key('raw-audio-cleared')), findsOneWidget);
      expect(store.segmentViewFor('seg-2')?.file.wavPath, isNull);
    },
  );

  testWidgets('2b. Cross-midnight 23:50–00:15 dialogue sorting stays chronological', (
    tester,
  ) async {
    final model = SummaryModel();
    const crossEv = RecordEvent(
      id: 'ev-midnight',
      dayOffset: 1,
      title: '跨零点复盘通话',
      brief: '从深夜聊到次日凌晨',
      longText: '',
      time: '23:50',
      dur: '25分00秒',
      speakers: '1 / 2',
      mark: '',
      srcMap: '来源 23:50—00:15',
      dialog: [
        TurnLine('1', '深夜十一点五十二分先对齐上线清单。', '来源 23:52—23:58'),
        TurnLine('2', '零点零五分监控指标全部正常。', '来源 00:05—00:12'),
      ],
      raw: [],
      photos: [EventPhoto(id: 'ph-midnight', time: '00:02')],
    );
    final store = AppStore(
      events: [crossEv],
      generator: await model.generator(),
      loadPersistedState: false,
    )..openDetail('ev-midnight', fresh: true);
    final dev = DeviceStore(gateway: FakeCardGateway());
    addTearDown(dev.dispose);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(store: store, device: dev),
      ),
    );
    await tester.pumpAndSettle();

    final firstTop = tester
        .getTopLeft(find.textContaining('深夜十一点五十二分'))
        .dy;
    final photoTop = tester
        .getTopLeft(find.byKey(const Key('dphoto-thumb-ev-midnight-0')))
        .dy;
    final secondTop = tester
        .getTopLeft(find.textContaining('零点零五分监控指标'))
        .dy;
    expect(firstTop, lessThan(photoTop));
    expect(photoTop, lessThan(secondTop));

    // 验证 AppShell 跨午夜恢复前台（didChangeAppLifecycleState(resumed)）后，昨日卡片自动滚入「昨天」
    store.goBack();
    var mockNow = DateTime(2026, 11, 19, 23, 59);
    const todayEv = RecordEvent(
      id: 'ev-rollover',
      dayOffset: 0,
      title: '睡前最后一条记录',
      brief: '零点前记录',
      longText: '',
      time: '23:55',
      dur: '2分00秒',
      speakers: '1',
      mark: '',
      srcMap: '来源 23:55—23:57',
      dialog: [TurnLine('1', '准备休息了。', '来源 23:55—23:57')],
      raw: [],
    );
    store.events = [todayEv];
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(store: store, device: dev, clock: () => mockNow),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsNothing);

    mockNow = DateTime(2026, 11, 20, 0, 5);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('今天'), findsNothing);
  });

  testWidgets(
    '2c. Merged multi-turn bubble rename without batch keeps bubble unified & retroactive voiceprint updates historical session',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('rc_vp_retro_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final recStore = RecordingStore(
        root: Directory('${tmp.path}/recordings'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final oldMs = DateTime.now()
          .subtract(const Duration(days: 1, hours: 2))
          .millisecondsSinceEpoch;
      final curMs = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;

      final model = SummaryModel();
      final store = AppStore(loadPersistedState: false);
      store.attachPipeline(
        pipeline: RecordingPipeline(
          gateway: FakeCardGateway(),
          store: recStore,
          engine: _NoopEngine(),
          models: _NoopModels(),
        ),
        store: recStore,
        generator: await model.generator(),
      );

      await tester.runAsync(() async {
        await recStore.save(
          RecordingFile(
            deviceName: 'HIST_001.WAV',
            session: 'ses-hist',
            seq: 1,
            startAtMs: oldMs,
            apmPath: '',
            durationMs: 60000,
            stage: RecordingStage.ready,
            turns: const [
              PolishedTurn(
                id: 'ht1',
                startMs: 0,
                endMs: 5000,
                speakerLabel: '说话人 2',
                text: '昨天我也提过这个茶很香。',
                srcUtteranceIds: ['hu1'],
              ),
            ],
            utterances: const [
              RawUtterance(
                id: 'hu1',
                sliceId: 'hs1',
                startMs: 0,
                endMs: 5000,
                speakerLabel: '说话人 2',
                text: '昨天我也提过这个茶很香。',
              ),
            ],
            segments: [
              SegmentRecord(
                id: 'seg-hist',
                sessionId: 'ses-hist',
                index: 0,
                startAtMs: oldMs,
                endAtMs: oldMs + 60000,
                title: '昨日下午茶闲聊',
                brief: '聊茶叶香气',
                longText: '聊茶叶香气',
                status: SegmentStatus.closed,
                speakerCount: 1,
                speakerLabels: const ['说话人 2'],
                turnIds: const ['ht1'],
              ),
            ],
            createdAtMs: oldMs,
          ),
        );
        await recStore.save(
          RecordingFile(
            deviceName: 'CUR_001.WAV',
            session: 'ses-cur',
            seq: 1,
            startAtMs: curMs,
            apmPath: '',
            durationMs: 120000,
            stage: RecordingStage.ready,
            turns: const [
              PolishedTurn(
                id: 'ct0',
                startMs: 0,
                endMs: 10000,
                speakerLabel: '说话人 2',
                text: '第一句连续发言。',
                srcUtteranceIds: ['cu0'],
              ),
              PolishedTurn(
                id: 'ct1',
                startMs: 12000,
                endMs: 22000,
                speakerLabel: '说话人 2',
                text: '第二句仍在同一合并气泡里。',
                srcUtteranceIds: ['cu1'],
              ),
              PolishedTurn(
                id: 'ct2',
                startMs: 25000,
                endMs: 35000,
                speakerLabel: '说话人 1',
                text: '好的我记下了。',
                srcUtteranceIds: ['cu2'],
              ),
              PolishedTurn(
                id: 'ct3',
                startMs: 40000,
                endMs: 50000,
                speakerLabel: '说话人 2',
                text: '后面单独另一处发言。',
                srcUtteranceIds: ['cu3'],
              ),
            ],
            utterances: const [],
            segments: [
              SegmentRecord(
                id: 'seg-cur',
                sessionId: 'ses-cur',
                index: 0,
                startAtMs: curMs,
                endAtMs: curMs + 120000,
                title: '今日客户沟通',
                brief: '连续发言合并测试',
                longText: '连续发言合并测试',
                status: SegmentStatus.closed,
                speakerCount: 2,
                speakerLabels: const ['说话人 1', '说话人 2'],
                turnIds: const ['ct0', 'ct1', 'ct2', 'ct3'],
              ),
            ],
            createdAtMs: curMs,
          ),
        );
        final pStore = SpeakerProfileStore(root: await recStore.root());
        await pStore.save(
          const SpeakerProfileSet(
            session: 'ses-hist',
            profiles: [
              SpeakerProfile(
                index: 1,
                centroid: [0.98, 0.20, 0.0, 0.0],
                speechMs: 5000,
              ),
            ],
          ),
        );
        await pStore.save(
          const SpeakerProfileSet(
            session: 'ses-cur',
            profiles: [
              SpeakerProfile(
                index: 1,
                centroid: [1.0, 0.0, 0.0, 0.0],
                speechMs: 15000,
              ),
            ],
          ),
        );
        await store.refreshFromStore();
      });

      final dev = DeviceStore(gateway: FakeCardGateway());
      addTearDown(dev.dispose);
      addTearDown(store.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(store: store, device: dev),
        ),
      );
      await tester.pumpAndSettle();

      store.openDetail('seg-cur', fresh: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('turn-spk-0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('qspk-chk-batch')));
      await tester.tap(find.byKey(const Key('qspk-chk-batch')));
      await tester.enterText(find.byKey(const Key('qspk-name-inp')), '老陈');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('qspk-save-btn')));
      await tester.tap(find.byKey(const Key('qspk-save-btn')));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
        if (store
            .displaySpeakersSummary(store.eventByIdOrNull('seg-hist')!)
            .contains('老陈')) {
          break;
        }
      }
      await tester.pumpAndSettle();

      final curEvent = store.eventByIdOrNull('seg-cur')!;
      expect(store.displayTurnSpeaker(curEvent, 0, '说话人 2'), '老陈');
      expect(store.displayTurnSpeaker(curEvent, 1, '说话人 2'), '老陈');
      expect(store.displayTurnSpeaker(curEvent, 3, '说话人 2'), '说话人 2（推测）');
      expect(find.byKey(const Key('turn-para-seg-cur-0')), findsOneWidget);
      expect(find.byKey(const Key('turn-para-seg-cur-1')), findsNothing);

      final histEvent = store.eventByIdOrNull('seg-hist')!;
      expect(store.displaySpeakersSummary(histEvent), contains('老陈'));
    },
  );

  testWidgets(
    '2d. Summary silent exclusion, 320px/1.3x RangeBar no-overflow, genEtaText, single-source subDesc & serialized _persist',
    (tester) async {
      final slowKv = _DelayedFirstWriteStore();
      final model = SummaryModel(autoReply: false);
      const silentEv = RecordEvent(
        id: 'ev-silent',
        dayOffset: 0,
        title: '未识别到语音',
        brief: '',
        longText: '',
        time: '11:00',
        dur: '5分00秒',
        speakers: '无语音',
        mark: '',
        srcMap: '来源 11:00—11:05',
        dialog: [],
        raw: [],
      );
      const realEv = RecordEvent(
        id: 'ev-real',
        dayOffset: 0,
        title: '真实项目讨论',
        brief: '讨论核心排期',
        longText: '讨论核心排期',
        time: '14:20',
        dur: '10分00秒',
        speakers: '1 / 2',
        mark: '',
        srcMap: '来源 14:20—14:30',
        dialog: [TurnLine('1', '确定周五发布。', '来源 14:20—14:25')],
        raw: [],
      );

      final store = AppStore(
        events: [silentEv, realEv],
        generator: await model.generator(),
        jsonStore: JsonStore(store: slowKv),
        loadPersistedState: true,
      );
      final dev = DeviceStore(gateway: FakeCardGateway());
      addTearDown(dev.dispose);
      addTearDown(store.dispose);

      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: AppShell(store: store, device: dev),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('summary-start')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('chip-today')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(store.activeQuickRange, 'today');
      expect(store.selIds, {'ev-real'});
      expect(store.selIds.contains('ev-silent'), isFalse);

      // 恢复常规手机宽度后进入总结生成页（SummaryResultPage 不属于本模块文件范围）
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();

      await tester.tap(find.byKey(const Key('generate-summary')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(store.genEtaText(), '正在收尾整理…');

      model.release();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final doneCard = store.summaries.first;
      expect(doneCard.state, SummaryState.done);
      expect(doneCard.subDesc, isNot(contains('14:20–14:20')));
      expect(doneCard.subDesc, contains('14:20'));

      store.openDetail('ev-real', fresh: true);
      store.go(RootTab.setting);
      await tester.pump(const Duration(milliseconds: 100));
      final persisted = await JsonStore(store: slowKv).read('route');
      expect((persisted?['stack'] as List?) ?? const [], isEmpty);

      // 验证在途总结取消：调用 cancelGeneratingSummary 后立即移除生成态卡片，在途完成回调不会复活总结卡
      final cancelModel = SummaryModel(autoReply: false);
      final cancelStore = AppStore(
        events: [realEv],
        generator: await cancelModel.generator(),
        loadPersistedState: false,
      );
      addTearDown(cancelStore.dispose);
      cancelStore.startSummary();
      cancelStore.selRange('today');
      cancelStore.genSummary();
      await tester.pump();
      final genId = cancelStore.summaries.first.id;
      expect(cancelStore.summaries.first.state, SummaryState.generating);
      cancelStore.cancelGeneratingSummary(genId);
      await tester.pump();
      expect(cancelStore.summaryById(genId), isNull);
      cancelModel.release();
      await tester.pump(const Duration(milliseconds: 50));
      expect(cancelStore.summaryById(genId), isNull);

      // 验证经 dismissFailed(card.id) 取消在途生成卡片时：同样停止计时器并加入 _cancelledSummaryIds，完成回调不篡改状态或落盘
      final dismissModel = SummaryModel(autoReply: false);
      final dismissKv = InMemoryStore();
      final dismissStore = AppStore(
        events: [realEv],
        generator: await dismissModel.generator(),
        jsonStore: JsonStore(store: dismissKv),
        loadPersistedState: false,
      );
      addTearDown(dismissStore.dispose);
      dismissStore.startSummary();
      dismissStore.selRange('today');
      dismissStore.genSummary();
      await tester.pump();
      final generatingCard = dismissStore.summaries.first;
      expect(generatingCard.state, SummaryState.generating);
      // 模拟 SummaryResultPage 移除该在途卡片并调用 dismissFailed
      dismissStore.summaries = const [];
      dismissStore.dismissFailed(generatingCard.id);
      await tester.pump();
      final elapsedAfterDismiss = dismissStore.genElapsedSeconds;
      await tester.pump(const Duration(seconds: 4));
      expect(dismissStore.genElapsedSeconds, elapsedAfterDismiss);
      dismissModel.release();
      await tester.pump(const Duration(milliseconds: 50));
      expect(generatingCard.state, SummaryState.generating);
      expect(dismissStore.summaryById(generatingCard.id), isNull);
    },
  );

  test(
    '2e. Dual-ASR fallback (SystemSpeechClient -> SenseVoice auto) & resolved speaker alias in MemorySearchService',
    () async {
      final tmp = Directory.systemTemp.createTempSync('rc_dual_asr_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final svDir = Directory('${tmp.path}/models/${senseVoiceSpec.id}')
        ..createSync(recursive: true);
      final modelFile = File('${svDir.path}/model.int8.onnx')
        ..writeAsBytesSync([1, 2, 3]);
      final tokensFile = File('${svDir.path}/tokens.txt')
        ..writeAsStringSync('a 1\n');
      final svModels = _StubSenseVoiceModels(
        SpeechModelPaths(
          asrModelPath: modelFile.path,
          tokensPath: tokensFile.path,
          vadPath: '${svDir.path}/silero_vad.onnx',
        ),
      );

      final fakeSenseVoice = _RecordingFakeSenseVoiceEngine('前天看的电影叫黄金眼');
      final failingSys = SystemSpeechClient(
        requestAuthOverride: () async => 'authorized',
        transcribeOverride: (_, _, _) async =>
            throw const AsrException('系统语音识别暂不可用'),
      );
      final samples = Float32List.fromList(List<double>.filled(1600, 0.1));

      final textOnThrow = await transcribeVoiceCommandWithDualFallback(
        samples,
        systemSpeech: failingSys,
        localAsr: fakeSenseVoice,
        modelProvider: svModels,
      );
      expect(textOnThrow, '前天看的电影叫黄金眼');
      expect(fakeSenseVoice.loadedLanguage, 'auto');
      expect(fakeSenseVoice.transcribeCalls, 1);

      final emptySys = SystemSpeechClient(
        requestAuthOverride: () async => 'authorized',
        transcribeOverride: (_, _, _) async => const AsrResult(
          text: '   ',
          tokens: [],
          timestampsMs: [],
          audioMs: 100,
        ),
      );
      final textOnEmpty = await transcribeVoiceCommandWithDualFallback(
        samples,
        systemSpeech: emptySys,
        localAsr: fakeSenseVoice,
        modelProvider: svModels,
      );
      expect(textOnEmpty, '前天看的电影叫黄金眼');
      expect(fakeSenseVoice.transcribeCalls, 2);

      // 验证用户命名说话人「老陈」后，本机记忆检索索引可按「老陈」直接搜到对应对话记录
      const namedEv = RecordEvent(
        id: 'ev-chen',
        dayOffset: 0,
        title: '下午茶沟通',
        brief: '讨论数据库索引方案',
        longText: '讨论数据库索引方案',
        time: '15:10',
        dur: '8分00秒',
        speakers: '说话人 1 / 说话人 2',
        mark: '',
        srcMap: '来源 15:10—15:18',
        dialog: [
          TurnLine('说话人 1', '我建议把检索走本地 SQLite FTS。', '来源 15:10—15:14'),
        ],
        raw: [],
      );
      final store = AppStore(events: [namedEv], loadPersistedState: false);
      addTearDown(store.dispose);
      await store.applyQuickSpeakerNaming(
        event: namedEv,
        turnIndex: 0,
        rawSpeaker: '说话人 1',
        newName: '老陈',
        rememberVoiceprint: false,
        applyToOtherMatching: true,
      );

      final memIndex = LocalMemoryIndex(
        factory: databaseFactoryFfi,
        path: () async => '${tmp.path}/mem_alias_test.db',
      );
      final memService = MemorySearchService(
        index: memIndex,
        corpus: () => MemoryCorpus(
          events: store.eventsWithResolvedSpeakers(),
          summaries: store.summariesWithResolvedSpeakers(),
        ),
        chat: (_) async => '老陈建议用本地 SQLite FTS。',
      );
      addTearDown(memService.close);

      await memService.reindex();
      final hits = await memService.search('老陈');
      expect(hits, isNotEmpty);
      expect(hits.first.sourceId, 'ev-chen');
      expect(hits.first.snippet, contains('老陈'));
    },
  );

  testWidgets(
    '3b. Setting 关于录音卡 displays readLastCrash() diagnostic summary & 注销账号 handles 404 honestly then wipes on 200',
    (tester) async {
      sqfliteFfiInit();
      final tmp = Directory.systemTemp.createTempSync('rc_acct_wipe_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final recDir = Directory('${tmp.path}/recordings')
        ..createSync(recursive: true);
      final liveAudioDir = Directory('${tmp.path}/live_audio');
      final liveSessionDir = Directory('${liveAudioDir.path}/ses-live-1')
        ..createSync(recursive: true);
      final liveWavFile = File('${liveSessionDir.path}/audio.wav')
        ..writeAsBytesSync(encodeWav(Float32List(1600), sampleRate: 16000));
      File('${liveSessionDir.path}/session.json')
          .writeAsStringSync('{"id":"ses-live-1"}');

      final dbDir = Directory('${tmp.path}/databases')
        ..createSync(recursive: true);
      final memDbPath = '${dbDir.path}/memory_index.db';
      final healthDbFile = File('${dbDir.path}/health_signals.db')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final healthWalFile = File('${dbDir.path}/health_signals.db-wal')
        ..writeAsBytesSync([5, 6]);

      final kv = InMemoryStore();
      await kv.setString(
        lastCrashKey,
        '{"t":"2026-11-19T12:00:00.000","kind":"FlutterError","message":"RenderFlex overflowed"}',
      );

      final signedIn = await tester.runAsync(_createSignedInAuth);
      final auth = signedIn!.auth;
      addTearDown(auth.dispose);

      final recStore = RecordingStore(
        root: recDir,
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final recSubDir = Directory('${recDir.path}/WIPE_001.WAV')
        ..createSync(recursive: true);
      final recWavFile = File('${recSubDir.path}/audio.wav')
        ..writeAsBytesSync(encodeWav(Float32List(1600), sampleRate: 16000));
      final nowMs = DateTime(2026, 11, 19, 10, 0).millisecondsSinceEpoch;
      final model = SummaryModel();
      final appStore = AppStore(loadPersistedState: false);
      appStore.attachPipeline(
        pipeline: RecordingPipeline(
          gateway: FakeCardGateway(),
          store: recStore,
          engine: _NoopEngine(),
          models: _NoopModels(),
        ),
        store: recStore,
        generator: await model.generator(),
      );
      addTearDown(appStore.dispose);

      late MemorySearchService memService;
      await tester.runAsync(() async {
        await recStore.save(
          RecordingFile(
            deviceName: 'WIPE_001.WAV',
            session: 'ses-wipe',
            seq: 1,
            startAtMs: nowMs,
            apmPath: '',
            wavPath: recWavFile.path,
            durationMs: 5000,
            stage: RecordingStage.ready,
            turns: const [
              PolishedTurn(
                id: 'wt1',
                startMs: 0,
                endMs: 4000,
                speakerLabel: '1',
                text: '敏感本地对话测试内容',
                srcUtteranceIds: ['wu1'],
              ),
            ],
            utterances: const [
              RawUtterance(
                id: 'wu1',
                sliceId: 'ws1',
                startMs: 0,
                endMs: 4000,
                text: '敏感本地对话测试内容',
              ),
            ],
            segments: [
              SegmentRecord(
                id: 'ev-to-wipe',
                sessionId: 'ses-wipe',
                index: 0,
                startAtMs: nowMs,
                endAtMs: nowMs + 5000,
                title: '待注销清理记录',
                brief: '敏感本地对话测试内容',
                longText: '敏感本地对话测试内容',
                status: SegmentStatus.closed,
                turnIds: const ['wt1'],
              ),
            ],
            createdAtMs: nowMs,
          ),
        );
        await appStore.refreshFromStore();

        memService = MemorySearchService(
          index: LocalMemoryIndex(
            factory: databaseFactoryFfi,
            path: () async => memDbPath,
          ),
          corpus: () => MemoryCorpus(
            events: appStore.eventsWithResolvedSpeakers(),
            summaries: appStore.summariesWithResolvedSpeakers(),
          ),
          chat: (_) async => '',
        );
        await memService.reindex();
        final preHits = await memService.search('敏感本地对话');
        expect(preHits, isNotEmpty);
      });
      addTearDown(() => tester.runAsync(memService.close));

      var nextStatus = 404;
      final deleteRequests = <http.Request>[];
      final accountClient = MockClient((req) async {
        deleteRequests.add(req);
        return http.Response('{"status":"handled"}', nextStatus);
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: StoreScope(
            store: appStore,
            child: MemorySearchScope(
              service: memService,
              child: Scaffold(
                body: SettingPage(
                  agentConfig: AgentConfigStore(store: InMemoryStore()),
                  authService: auth,
                  crashStore: kv,
                  accountHttpClient: accountClient,
                  apiBaseOverride: 'https://api.example.test',
                  liveAudioDir: liveAudioDir,
                  databasesDirOverride: dbDir,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('account-delete-entry')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account-delete-entry')), findsOneWidget);
      expect(find.byKey(const Key('setting-last-crash')), findsOneWidget);
      expect(find.textContaining('RenderFlex overflowed'), findsOneWidget);

      // 清除最近异常诊断摘要
      await tester.tap(find.byKey(const Key('setting-last-crash-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setting-last-crash')), findsNothing);

      // 第一次点击注销账号：服务端返回 404，绝不能伪造云端已注销（保持已登录与本地记录未删）
      await tester.tap(find.byKey(const Key('account-delete-entry')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account-delete-confirm-dialog')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('account-delete-confirm-btn')));
      await tester.pumpAndSettle();

      expect(deleteRequests.length, 1);
      expect(deleteRequests.single.method, 'DELETE');
      expect(deleteRequests.single.url.toString(), 'https://api.example.test/api/account');
      expect(
        deleteRequests.single.headers['Authorization'],
        'Bearer access-1',
      );
      expect(
        find.byKey(const Key('account-delete-error-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('HTTP 404'), findsOneWidget);
      expect(find.textContaining('privacy@reai.chat'), findsOneWidget);
      expect(auth.isSignedIn, isTrue);
      expect(appStore.events, isNotEmpty);
      expect(liveWavFile.existsSync(), isTrue);
      expect(healthDbFile.existsSync(), isTrue);

      // 点击「重试」且服务端返回 200：擦除 OAuth 令牌并清空本机全部记录、SQLite 库与 live_audio WAV
      nextStatus = 200;
      await tester.tap(find.byKey(const Key('account-delete-retry')));
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (!auth.isSignedIn && !healthWalFile.existsSync()) break;
      }
      await tester.pumpAndSettle();

      expect(deleteRequests.length, 2);
      expect(auth.isSignedIn, isFalse);
      expect(appStore.events, isEmpty);
      expect(recWavFile.existsSync(), isFalse);
      expect(liveWavFile.existsSync(), isFalse);
      expect(File(memDbPath).existsSync(), isFalse);
      expect(healthDbFile.existsSync(), isFalse);
      expect(healthWalFile.existsSync(), isFalse);
      final postHits = await tester.runAsync(
        () => memService.search('敏感本地对话'),
      );
      expect(postHits, isEmpty);
    },
  );
}
