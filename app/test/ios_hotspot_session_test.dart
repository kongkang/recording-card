import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/service_backends.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/analysis/analysis_service.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';
import 'package:recording_card/services/runtime/accessory_hotspot_session.dart';
import 'package:recording_card/services/runtime/card_download_adapter.dart';
import 'package:recording_card/services/runtime/production_runtime.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

import 'runtime_repair_test.dart' as fixture;

const cardId = 'card:真实:device';

class LocalHttpOverrides extends HttpOverrides {}

class HotspotCard extends fixture.GatewaySpy {
  HotspotCard() {
    recording = false;
    expectedTransport = CardTransfer.ap;
  }
  bool realtime = false;
  bool failWifiClose = false;
  final log = <String>[];
  Completer<void>? wifiOpenFinal;
  @override
  Future<CardSnapshot> status() async {
    if (failStatus) throw StateError('status unavailable');
    return CardSnapshot(
      batteryLevel: 80,
      isCharging: false,
      wifiOpen: wifiOpen,
      recording: recording,
      realtimeEnabled: realtime,
      fwVersion: 'fixture',
      wifiVersion: 'fixture',
      deviceId: cardId,
    );
  }

  @override
  Future<void> setWifiEnabled(bool enabled) async {
    log.add('card:$enabled');
    if (enabled) await wifiOpenFinal?.future;
    if (!enabled && failWifiClose) throw StateError('card close unconfirmed');
    await super.setWifiEnabled(enabled);
  }
}

class HotspotOps {
  final log = <String>[];
  Completer<void>? joinFinal;
  Completer<void>? phoneCloseFinal;
  Completer<bool>? probeFinal;
  PlatformException? joinError;
  bool failPhoneClose = false;
  bool probeOk = true;
  final joined = Completer<void>();
  final probed = Completer<void>();
  final closed = Completer<void>();
  AccessoryHotspotSession session(HotspotCard card) => AccessoryHotspotSession(
    card,
    isIos: () => true,
    join: () async {
      log.add('join');
      if (!joined.isCompleted) joined.complete();
      await joinFinal?.future;
      if (joinError != null) throw joinError!;
    },
    closePhoneConfiguration: () async {
      log.add('phone-close');
      if (!closed.isCompleted) closed.complete();
      await phoneCloseFinal?.future;
      if (failPhoneClose) throw StateError('phone close unconfirmed');
    },
    probe: (uri, timeout) async {
      expect(uri, AccessoryHotspotSession.filesUri);
      expect(timeout, lessThanOrEqualTo(const Duration(milliseconds: 20)));
      log.add('probe');
      if (!probed.isCompleted) probed.complete();
      return await probeFinal?.future ?? probeOk;
    },
    readyTimeout: const Duration(milliseconds: 40),
    probeTimeout: const Duration(milliseconds: 20),
    probeInterval: const Duration(milliseconds: 1),
  );
}

class NeverInternet extends RecordingNetworkPolicy {
  int checks = 0;
  @override
  Future<void> requireTransfer(AppSettings settings) async {
    checks++;
    throw StateError('must not require Internet');
  }
}

Widget sheet(DeviceStore store) => MaterialApp(
  home: Scaffold(
    body: Stack(children: [StatusSheetOverlay(store: store)]),
  ),
);

Future<void> nextTurn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HotspotCard card;
  late HotspotOps ops;
  late AccessoryHotspotSession session;
  setUp(() {
    card = HotspotCard();
    ops = HotspotOps();
    session = ops.session(card);
  });
  tearDown(() async {
    await card.stream.close();
  });

  test('failed cleanup keeps Service and Store busy; no new sync or recording until explicit retry', () async {
    final root = await Directory.systemTemp.createTemp('ios-ap-busy-');
    final service = ServiceDeviceBackend(
      gateway: card,
      settingsRepository: SettingsRepository(directory: root),
      hotspotSession: session,
    );
    final store = DeviceStore(
      backend: service,
      persistence: MemoryStorePersistence(),
      fastTransferActive: () => session.active,
    );
    addTearDown(() async {
      store.dispose();
      await root.delete(recursive: true);
    });
    await store.connectDevice('transport');
    expect(await store.prepareFastTransfer(), isTrue);
    ops.failPhoneClose = true;
    card.failWifiClose = true;
    await store.cancelFastTransfer();
    expect(store.deviceBusy, isTrue);
    expect(store.fastTransferPrepared, isTrue);
    final priorCard = List.of(card.log);
    final priorPhone = List.of(ops.log);
    await expectLater(
      service.fastSync(const RecordingPolicy(), (_) {}),
      throwsStateError,
    );
    await expectLater(
      service.sync(const RecordingPolicy(), (_) {}),
      throwsStateError,
    );
    await expectLater(service.startRecording(), throwsStateError);
    expect(card.log, priorCard);
    expect(ops.log, priorPhone);
    expect(card.recordingCommands, 0);
    ops.failPhoneClose = false;
    card.failWifiClose = false;
    await store.cancelFastTransfer();
    expect(store.deviceBusy, isFalse);
    expect(store.fastTransferPrepared, isFalse);
  });

  test(
    'system accepted is not HTTP ready; shared AP adapter cannot open early',
    () async {
      ops.probeFinal = Completer<bool>();
      final preparing = session.prepare(cardId);
      await ops.probed.future;
      expect(session.active, isTrue);
      expect(session.ready, isFalse);
      final adapter = CardDownloadAdapter(
        card,
        transport: CardTransfer.ap,
        hotspotSession: session,
      );
      await expectLater(adapter.openSession(cardId), throwsStateError);
      ops.probeFinal!.complete(true);
      await preparing;
      expect(session.ready, isTrue);
      await adapter.openSession(cardId);
      expect(adapter.usesNetwork, isFalse);
      await adapter.closeSession(cardId);
      await adapter.closeSession(cardId);
      expect(session.active, isFalse);
      expect(card.log, ['card:true', 'card:false']);
      expect(ops.log, ['join', 'probe', 'phone-close']);
      expect(card.recordingCommands, 0);
    },
  );

  test('native non-final timeout cannot settle prepare until close confirms late apply final', () async {
    ops.joinError = PlatformException(
      code: 'hotspot_timeout',
      details: {'nativeFinal': false},
    );
    ops.phoneCloseFinal = Completer<void>();
    var settled = false;
    final preparing = session
        .prepare(cardId)
        .whenComplete(() => settled = true);
    final assertion = expectLater(
      preparing,
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'hotspot_timeout',
        ),
      ),
    );
    await ops.closed.future;
    await nextTurn();
    expect(settled, isFalse);
    expect(session.active, isTrue);
    expect(card.log, ['card:true']);
    await expectLater(session.prepare(cardId), throwsStateError);
    ops.phoneCloseFinal!.complete();
    await assertion;
    expect(session.active, isFalse);
    expect(card.log, ['card:true', 'card:false']);
  });

  test(
    'local cancel maps native early cancelled reply only after close final',
    () async {
      ops.joinFinal = Completer<void>();
      ops.phoneCloseFinal = Completer<void>();
      ops.joinError = PlatformException(
        code: 'hotspot_cancelled',
        details: {'nativeFinal': false},
      );
      final preparing = session.prepare(cardId);
      final assertion = expectLater(
        preparing,
        throwsA(isA<RecordingSyncCancelled>()),
      );
      await ops.joined.future;
      final closing = session.close();
      await ops.closed.future;
      ops.joinFinal!.complete();
      await nextTurn();
      expect(session.active, isTrue);
      expect(card.log, ['card:true']);
      ops.phoneCloseFinal!.complete();
      await assertion;
      await closing;
      expect(session.active, isFalse);
      expect(ops.log, ['join', 'phone-close']);
    },
  );

  test('AP prepare blocks new cloud work and drains existing request before WIFI_OPEN', () async {
    final cloudFinal = Completer<String>();
    var calls = 0;
    late final AccessoryHotspotSession guardedSession;
    final cloud = LocalOnlyAnalysisGateway(
      CallbackAnalysisGateway((_, {model}) {
        calls++;
        return cloudFinal.future;
      }),
      localOnly: () => guardedSession.active,
    );
    guardedSession = AccessoryHotspotSession(
      card,
      isIos: () => true,
      join: () async {},
      closePhoneConfiguration: () async {},
      probe: (_, _) async => true,
      beforeWifiOpen: () => cloud.drained,
    );
    final existing = cloud.complete('existing');
    final preparing = guardedSession.prepare(cardId);
    await nextTurn();
    expect(card.log, isEmpty);
    await expectLater(cloud.complete('new'), throwsA(isA<AnalysisException>()));
    expect(calls, 1);
    cloudFinal.complete('actual response');
    expect(await existing, 'actual response');
    await preparing;
    expect(card.log, ['card:true']);
    await guardedSession.close();
    expect(await cloud.complete('after cleanup'), 'actual response');
    expect(calls, 2);
  });

  test('cancel ACK cannot release lane; late join success drains before card shutdown', () async {
    ops.joinFinal = Completer<void>();
    final preparing = session.prepare(cardId);
    final assertion = expectLater(
      preparing,
      throwsA(isA<RecordingSyncCancelled>()),
    );
    await ops.joined.future;
    var cancelled = false;
    final cancelling = session.close().then((_) => cancelled = true);
    await ops.closed.future;
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isFalse);
    expect(session.active, isTrue);
    expect(card.log, ['card:true']);
    await expectLater(session.prepare(cardId), throwsStateError);
    ops.joinFinal!.complete();
    await assertion;
    await cancelling;
    expect(session.ready, isFalse);
    expect(session.active, isFalse);
    expect(ops.log, ['join', 'phone-close']);
    expect(card.log, ['card:true', 'card:false']);
  });

  test(
    'cancel during WIFI_OPEN waits command final and never starts join',
    () async {
      card.wifiOpenFinal = Completer<void>();
      final preparing = session.prepare(cardId);
      final assertion = expectLater(
        preparing,
        throwsA(isA<RecordingSyncCancelled>()),
      );
      while (card.log.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      var cancelled = false;
      final cancelling = session.close().then((_) => cancelled = true);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isFalse);
      card.wifiOpenFinal!.complete();
      await assertion;
      await cancelling;
      expect(ops.log, isNot(contains('join')));
      expect(card.log, ['card:true', 'card:false']);
      expect(session.active, isFalse);
    },
  );

  test(
    'user denial and identifiable native errors propagate, both sides clean up',
    () async {
      for (final code in ['hotspot_denied', 'hotspot_missing_entitlement']) {
        ops.joinError = PlatformException(
          code: code,
          message: 'native failure',
        );
        await expectLater(
          session.prepare(cardId),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
        );
        expect(session.active, isFalse);
        expect(card.wifiOpen, isFalse);
      }
      expect(ops.log.where((e) => e == 'phone-close'), hasLength(2));
    },
  );

  test('HTTP not ready is bounded and always closes phone and card', () async {
    ops.probeOk = false;
    await expectLater(session.prepare(cardId), throwsStateError);
    expect(session.active, isFalse);
    expect(card.log, ['card:true', 'card:false']);
    expect(ops.log.last, 'phone-close');
  });

  test(
    'recording, realtime and unsupported platform never silently stop or join',
    () async {
      card.recording = true;
      await expectLater(session.prepare(cardId), throwsStateError);
      card.recording = false;
      card.realtime = true;
      await expectLater(session.prepare(cardId), throwsStateError);
      final unsupported = AccessoryHotspotSession(card, isIos: () => false);
      await expectLater(unsupported.prepare(cardId), throwsStateError);
      expect(card.recordingCommands, 0);
      expect(card.wifiCommands, isEmpty);
      expect(ops.log, isEmpty);
    },
  );

  test('cleanup failure attempts both sides and retains localOnly/busy until confirmed retry', () async {
    await session.prepare(cardId);
    ops.failPhoneClose = true;
    card.failWifiClose = true;
    await expectLater(session.close(), throwsStateError);
    expect(ops.log.last, 'phone-close');
    expect(card.log.last, 'card:false');
    expect(session.active, isTrue);
    expect(session.ready, isFalse);
    await expectLater(session.prepare(cardId), throwsStateError);
    ops.failPhoneClose = false;
    card.failWifiClose = false;
    await session.close();
    expect(session.active, isFalse);
  });

  test(
    'cleanup command ACK without verified card state does not clear localOnly',
    () async {
      await session.prepare(cardId);
      card.failStatus = true;
      await expectLater(session.close(), throwsStateError);
      expect(card.wifiOpen, isFalse);
      expect(session.active, isTrue);
      card.failStatus = false;
      await session.close();
      expect(session.active, isFalse);
    },
  );

  test('frozen MethodChannel only sends argument-free join/close; accepted needs probe', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AccessoryHotspotSession.channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'join' ? {'accepted': true} : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AccessoryHotspotSession.channel,
        null,
      ),
    );
    final native = AccessoryHotspotSession(
      card,
      isIos: () => true,
      probe: (_, _) async => true,
    );
    await native.prepare(cardId);
    await native.close();
    expect(calls.map((c) => c.method), ['join', 'close']);
    expect(calls.every((c) => c.arguments == null), isTrue);
  });

  test('actual bounded HTTP probe rejects redirects, errors and HTML; reads JSON files service', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final subscription = server.listen((request) async {
      switch (request.uri.path) {
        case '/ok':
          request.response.write('{"files":[]}');
        case '/redirect':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/ok');
        case '/html':
          request.response.write('<html>Internet portal</html>');
        case '/error':
          request.response.statusCode = 503;
        case '/body-hangs':
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"files":');
          await request.response.flush();
          return;
      }
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    for (final path in ['ok', 'redirect', 'html', 'error', 'body-hangs']) {
      final uri = Uri.parse('http://127.0.0.1:${server.port}/$path');
      final ready = await HttpOverrides.runWithHttpOverrides(
        () => AccessoryHotspotSession.probeFileService(
          uri,
          const Duration(milliseconds: 100),
        ),
        LocalHttpOverrides(),
      );
      expect(ready, path == 'ok', reason: path);
    }
  });

  test('Service and AP Adapter same session transfer locally without network precheck and retain source', () async {
    final h = fixture.Harness(
      await Directory.systemTemp.createTemp('ios-ap-local-'),
    );
    addTearDown(() async {
      await h.pipeline.dispose();
      await h.gateway.stream.close();
      await h.root.delete(recursive: true);
    });
    card.files['one.wav'] = fixture.wav30();
    final internet = NeverInternet();
    final adapter = CardDownloadAdapter(
      card,
      transport: CardTransfer.ap,
      hotspotSession: session,
    );
    final sync = SyncCoordinator(
      repository: h.repo,
      settingsRepository: SettingsRepository(directory: h.root),
      gateway: adapter,
      networkPolicy: internet,
      onImported: (_) => h.pipeline.processPending(localOnly: true),
    );
    addTearDown(sync.dispose);
    final service = ServiceDeviceBackend(
      gateway: card,
      settingsRepository: SettingsRepository(directory: h.root),
      fastSyncCoordinator: sync,
      hotspotSession: session,
    );
    await service.connect('transport');
    await service.prepareFastTransfer();
    await service.fastSync(const RecordingPolicy(), (_) {});
    expect(internet.checks, 0);
    expect(session.active, isFalse);
    expect(h.cloud.prompts, isEmpty);
    expect(
      (await h.repo.load()).events.single.originalTranscript,
      fixture.speech.text,
    );
    expect(card.files, hasLength(1));
    expect(service.lastSyncOutcome!.retainedSourceCount, 1);
    expect(card.recordingCommands, 0);
  });

  test(
    'sync preflight failure closes prepared session; ordinary BLE never joins',
    () async {
      final root = await Directory.systemTemp.createTemp('ios-ap-preflight-');
      addTearDown(() => root.delete(recursive: true));
      final service = ServiceDeviceBackend(
        gateway: card,
        settingsRepository: SettingsRepository(directory: root),
        hotspotSession: session,
      );
      await service.connect('transport');
      await service.prepareFastTransfer();
      await expectLater(
        service.fastSync(const RecordingPolicy(), (_) {}),
        throwsStateError,
      );
      expect(session.active, isFalse);
      final before = List.of(ops.log);
      await expectLater(
        service.sync(const RecordingPolicy(), (_) {}),
        throwsStateError,
      );
      expect(ops.log, before);
    },
  );

  test('Runtime summary and policy pending processing respect active AP localOnly guard', () async {
    final h = fixture.Harness(
      await Directory.systemTemp.createTemp('ios-ap-policy-'),
    );
    addTearDown(() async {
      await h.pipeline.dispose();
      await h.gateway.stream.close();
      await h.root.delete(recursive: true);
    });
    final event = await h.import();
    await session.prepare(cardId);
    final backend = RuntimeAppBackend(
      recordingRepository: h.repo,
      settingsRepository: SettingsRepository(directory: h.root),
      analysisService: AnalysisService(gateway: h.cloud),
      pipeline: h.pipeline,
      localOnly: () => session.active,
    );
    await expectLater(
      backend.generateSummary(
        [event],
        target: SummaryCard(id: 's', time: '00:00'),
        policy: const RecordingPolicy(),
        onProgress: (_) {},
      ),
      throwsStateError,
    );
    await backend.applyPolicy(const RecordingPolicy());
    await h.pipeline.drained;
    expect(h.cloud.prompts, isEmpty);
    await session.close();
  });

  testWidgets(
    'UI explains system join, no manual settings/connected confirmation; preparing cancel waits cleanup',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('ios-ap-ui-');
      final service = ServiceDeviceBackend(
        gateway: card,
        settingsRepository: SettingsRepository(directory: root),
        hotspotSession: session,
      );
      final store = DeviceStore(
        backend: service,
        persistence: MemoryStorePersistence(),
        fastTransferActive: () => session.active,
      );
      addTearDown(() async {
        store.dispose();
        root.deleteSync(recursive: true);
      });
      await store.connectDevice('transport');
      store.sheetOpen = true;
      await tester.pumpWidget(sheet(store));
      await tester.tap(find.byKey(const Key('transfer-mode')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('录音卡快传 · 系统确认加入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('App 将调起系统加入录音卡热点确认'), findsOneWidget);
      expect(find.textContaining('手机设置'), findsNothing);
      expect(find.textContaining('已连接，开始快传'), findsNothing);
      ops.joinFinal = Completer<void>();
      ops.phoneCloseFinal = Completer<void>();
      await tester.tap(find.byKey(const Key('start-fast-transfer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.fastTransferPreparing, isTrue);
      expect(store.deviceBusy, isTrue);
      await tester.tap(find.byKey(const Key('cancel-fast-transfer')));
      await tester.pump();
      expect(store.fastTransferCancelling, isTrue);
      expect(store.deviceBusy, isTrue);
      ops.phoneCloseFinal!.complete();
      await tester.pump();
      expect(store.deviceBusy, isTrue);
      ops.joinFinal!.complete();
      await tester.pump();
      await tester.pump();
      expect(session.active, isFalse);
      expect(store.fastTransferPreparing, isFalse);
      expect(store.fastTransferCancelling, isFalse);
      expect(store.deviceBusy, isFalse);
      expect(card.downloads, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
