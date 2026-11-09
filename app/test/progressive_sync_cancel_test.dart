import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/service_backends.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';
import 'package:recording_card/services/runtime/card_download_adapter.dart';
import 'package:recording_card/services/runtime/production_runtime.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

import 'controller_integration_test.dart' as controller_fixture;
import 'runtime_repair_test.dart' as fixture;
import 'verify_narrow_test.dart' as ui_fixture;
import 'fixtures/accessory_hotspot_fixture.dart';

class TicketGateway extends fixture.GatewaySpy {
  TicketGateway() {
    recording = false;
    expectedTransport = CardTransfer.ap;
    files.addAll({'one.wav': fixture.wav30(), 'two.wav': fixture.wav30()});
  }
  bool wifi = true;
  final secondStarted = Completer<void>();
  final nativeFinal = Completer<void>();
  final cleanupStarted = Completer<void>();
  final cleanupFinal = Completer<void>();
  final cancelAck = Completer<void>();
  final log = <String>[];
  @override
  Future<CardSnapshot> status() async => CardSnapshot(
    batteryLevel: 80,
    isCharging: false,
    wifiOpen: wifi,
    recording: false,
    fwVersion: 'fixture',
    wifiVersion: 'fixture',
    deviceId: 'card:真实:device',
  );
  @override
  Future<CardDownload> downloadFilePreservingSource(
    String name, {
    required String directory,
    required String expectedDeviceId,
    required int expectedBytes,
    CardTransfer transport = CardTransfer.ble,
    void Function(CardProgress)? onProgress,
  }) async {
    log.add('keep:$name');
    if (name == 'two.wav') {
      secondStarted.complete();
      await nativeFinal.future;
      log.add('native-final');
    }
    return super.downloadFilePreservingSource(
      name,
      directory: directory,
      expectedDeviceId: expectedDeviceId,
      expectedBytes: expectedBytes,
      transport: transport,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> cancelFileTransfer() async {
    log.add('cancel-ticket-ack');
    cancelAck.complete(); // ACK does not release nativeFinal
  }

  @override
  Future<void> setWifiEnabled(bool enabled) async {
    log.add('wifi:$enabled');
    if (!enabled) {
      cleanupStarted.complete();
      await cleanupFinal.future;
    }
    wifi = enabled;
  }
}

class PreflightGateway extends TicketGateway {
  bool holdStatus = false;
  final preflightStarted = Completer<void>();
  final preflightFinal = Completer<void>();
  @override
  Future<CardSnapshot> status() async {
    if (holdStatus) {
      if (!preflightStarted.isCompleted) preflightStarted.complete();
      await preflightFinal.future;
    }
    return super.status();
  }
}

class FailedCleanupGateway extends CardGateway {
  @override
  Future<void> setWifiEnabled(bool enabled) async {
    throw StateError('hotspot shutdown not confirmed');
  }
}

class ProgressBackend extends controller_fixture.FeedbackBackend {
  final transfer = Completer<void>();
  ProgressSink? sink;
  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress) async {
    sink = onProgress;
    onProgress(const TaskProgress('设备正在传输', percent: 25));
    await transfer.future;
  }
}

class CancelableProgressBackend extends ProgressBackend
    implements CancelableSyncDeviceBackend {
  bool requested = false;
  @override
  Future<void> cancelSync() async {
    requested =
        true; // Optional fake reports request ACK only; store still waits.
  }

  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress) async {
    await super.sync(policy, onProgress);
    if (requested) throw const RecordingSyncCancelled();
  }
}

Widget sheet(DeviceStore store) => MaterialApp(
  home: Scaffold(
    body: Stack(children: [StatusSheetOverlay(store: store)]),
  ),
);

void main() {
  test('cancel during AP preflight waits preparation final then cleanup, never opens a Native transfer', () async {
    final h = fixture.Harness(
      await Directory.systemTemp.createTemp('progressive-preflight-'),
    );
    final gateway = PreflightGateway();
    final hotspot = fixtureHotspot(gateway);
    final adapter = CardDownloadAdapter(
      gateway,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
      cancelTransfer: gateway.cancelFileTransfer,
    );
    final coordinator = SyncCoordinator(
      repository: h.repo,
      settingsRepository: SettingsRepository(directory: h.root),
      gateway: adapter,
    );
    final delegate = ServiceDeviceBackend(
      gateway: gateway,
      settingsRepository: SettingsRepository(directory: h.root),
      fastSyncCoordinator: coordinator,
      hotspotSession: hotspot,
    );
    await delegate.connect('transport');
    await delegate.prepareFastTransfer();
    gateway.log.clear();
    gateway.holdStatus = true;
    final running = delegate.fastSync(const RecordingPolicy(), (_) {});
    final assertion = expectLater(
      running,
      throwsA(isA<RecordingSyncCancelled>()),
    );
    await gateway.preflightStarted.future;
    var returned = false;
    final cancelling = delegate.cancelSync().then((_) => returned = true);
    await Future<void>.delayed(Duration.zero);
    expect(returned, isFalse);
    expect(gateway.log, isEmpty);
    gateway.preflightFinal.complete();
    await gateway.cleanupStarted.future;
    expect(returned, isFalse);
    expect(gateway.log, ['wifi:false']);
    expect(adapter.wifiSessionActive, isTrue);
    await expectLater(
      delegate.fastSync(const RecordingPolicy(), (_) {}),
      throwsStateError,
    );
    gateway.cleanupFinal.complete();
    await assertion;
    await cancelling;
    expect(adapter.wifiSessionActive, isFalse);
    expect((await h.repo.load()).index, isEmpty);
    await coordinator.dispose();
    await h.pipeline.dispose();
    await h.gateway.stream.close();
    await gateway.stream.close();
    await h.root.delete(recursive: true);
  });

  test(
    'failed AP cleanup keeps final-processing localOnly guard enabled',
    () async {
      final adapter = CardDownloadAdapter(
        FailedCleanupGateway(),
        transport: CardTransfer.ap,
        restoreWifiAfterSession: true,
      );
      await expectLater(adapter.closeSession('card'), throwsStateError);
      expect(adapter.wifiSessionActive, isTrue);
    },
  );

  test('Service -> Runtime -> Store cancel waits original Native final, AP cleanup and final publication', () async {
    final h = fixture.Harness(
      await Directory.systemTemp.createTemp('progressive-cancel-'),
    );
    final gateway = TicketGateway();
    h.pipeline.policy = const RecordingPolicy(
      autoClean: false,
      inferSpeakers: false,
    );
    final hotspot = fixtureHotspot(gateway);
    final adapter = CardDownloadAdapter(
      gateway,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
      cancelTransfer: gateway.cancelFileTransfer,
    );
    final coordinator = SyncCoordinator(
      repository: h.repo,
      settingsRepository: SettingsRepository(directory: h.root),
      gateway: adapter,
      onImported: (_) => h.pipeline.processPending(localOnly: true),
    );
    final delegate = ServiceDeviceBackend(
      gateway: gateway,
      settingsRepository: SettingsRepository(directory: h.root),
      fastSyncCoordinator: coordinator,
      hotspotSession: hotspot,
    );
    final runtime = RuntimeDeviceBackend(delegate, h.pipeline, gateway);
    final published = Completer<void>();
    final publishFinal = Completer<void>();
    final store = DeviceStore(
      backend: runtime,
      persistence: MemoryStorePersistence(),
      policy: () => h.pipeline.policy,
      onSynced: () async {
        published.complete();
        await publishFinal.future;
        await h.pipeline.publish();
      },
    );
    await runtime.connect('transport');
    await runtime.prepareFastTransfer();
    gateway.log.clear();
    store.fastTransferPrepared = true;
    final running = store.syncNow(fast: true);
    await gateway.secondStarted.future;
    final first = (await h.repo.load()).events.single;
    expect(first.originalTranscript, fixture.speech.text);
    var cancelReturned = false;
    final cancelling = store.cancelSync().then((_) => cancelReturned = true);
    await gateway.cancelAck.future;
    expect(store.syncState, SyncState.busy);
    expect(store.syncCancelling, isTrue);
    expect(cancelReturned, isFalse);
    expect(gateway.log, isNot(contains('wifi:false')));
    await store.cancelFastTransfer();
    expect(gateway.log, isNot(contains('wifi:false')));
    await expectLater(
      delegate.fastSync(h.pipeline.policy, (_) {}),
      throwsStateError,
    );

    gateway.nativeFinal.complete();
    await gateway.cleanupStarted.future;
    expect(
      gateway.log.indexOf('native-final'),
      lessThan(gateway.log.indexOf('wifi:false')),
    );
    expect(store.syncState, SyncState.busy);
    expect(cancelReturned, isFalse);
    gateway.cleanupFinal.complete();
    await published.future;
    expect(store.syncState, SyncState.busy);
    expect(cancelReturned, isFalse);
    expect(adapter.wifiSessionActive, isFalse);
    publishFinal.complete();
    await running;
    await cancelling;
    expect(store.syncState, SyncState.cancelled);
    expect(store.syncText, contains('已保存文件保留'));
    expect(store.lastSync, isNull);
    final state = await h.repo.load();
    expect(state.events.single.originalTranscript, fixture.speech.text);
    expect(state.index, hasLength(1));
    expect(gateway.files, hasLength(2));
    expect(gateway.recordingCommands, 0);
    expect(h.gateway.stops, 0);
    expect(h.cloud.prompts, isEmpty);
    await coordinator.dispose();
    store.dispose();
    await h.pipeline.dispose();
    await h.gateway.stream.close();
    await gateway.stream.close();
    await h.root.delete(recursive: true);
  });

  testWidgets(
    'known percentage displays in sync row; unknown total clears it and old Fake has no cancel action',
    (tester) async {
      final backend = ProgressBackend();
      final store = DeviceStore(
        backend: backend,
        persistence: MemoryStorePersistence(),
      )..sheetOpen = true;
      final running = store.syncNow();
      await tester.pumpWidget(sheet(store));
      expect(find.textContaining('已收 25%'), findsOneWidget);
      expect(find.byKey(const Key('cancel-sync')), findsNothing);
      backend.sink!(const TaskProgress('设备继续传输'));
      await tester.pump();
      expect(find.textContaining('%'), findsNothing);
      backend.transfer.complete();
      await running;
      store.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'explicit cancel confirmation preserves busy until original final and refresh',
    (tester) async {
      final backend = CancelableProgressBackend();
      final refresh = Completer<void>();
      final store = DeviceStore(
        backend: backend,
        persistence: MemoryStorePersistence(),
        onSynced: () => refresh.future,
      )..sheetOpen = true;
      final running = store.syncNow();
      await tester.pumpWidget(sheet(store));
      await tester.tap(find.byKey(const Key('cancel-sync')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('登录、已保存音频与原文都会保留'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel-sync')));
      await tester.pump();
      expect(backend.requested, isTrue);
      expect(store.syncState, SyncState.busy);
      expect(find.text('正在取消…'), findsOneWidget);
      backend.transfer.complete();
      await tester.pump();
      expect(store.syncState, SyncState.busy);
      refresh.complete();
      await running;
      await tester.pump();
      expect(store.syncState, SyncState.cancelled);
      expect(find.byKey(const Key('sync-ico-cancelled')), findsOneWidget);
      store.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Timeline truthfully shows saved raw waiting for Internet analysis',
    (tester) async {
      final (store, _) = await ui_fixture.boot(tester);
      final event = store.events.first.copyWith(
        originalTranscript: '原文已保存',
        transcriptionStatus: 'analysis_pending',
      );
      store.events
        ..clear()
        ..add(event);
      store.tapCard(event.id, isSummary: false);
      await tester.pump();
      expect(find.text('原文已保存 · 等待联网润色或分析'), findsOneWidget);
    },
  );
}
