import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/service_backends.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/services/runtime/production_runtime.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

import 'runtime_repair_test.dart' as fixture;

class CountingService extends ServiceDeviceBackend {
  CountingService(fixture.Harness h)
    : spy = h.gateway,
      super(
        gateway: h.gateway,
        settingsRepository: SettingsRepository(directory: h.root),
      );
  final fixture.GatewaySpy spy;
  int starts = 0, stops = 0;
  @override
  Future<DeviceReading> startRecording() async {
    starts++;
    spy.recording = true;
    return DeviceReading(await spy.status());
  }

  @override
  Future<DeviceReading> stopRecording() async {
    stops++;
    spy.recording = false;
    return DeviceReading(await spy.status());
  }
}

class FeedbackBackend extends CallbackDeviceBackend
    implements FileTransferDeviceBackend {
  FeedbackBackend()
    : super(
        isAvailable: () => true,
        scanDevices: () async => [],
        connectDevice: (_) async => reading,
        readStatus: () async => reading,
        disconnectDevice: () async {},
        listSavedWifi: () async => [],
        checkFirmware: () async => null,
      );
  static const reading = DeviceReading(
    CardSnapshot(
      batteryLevel: 80,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: 'fixture-main',
      wifiVersion: '',
      deviceId: 'fixture-device',
    ),
  );
  bool fail = false;
  @override
  DeviceSyncOutcome? lastSyncOutcome = const DeviceSyncOutcome(
    savedCount: 1,
    retainedSourceCount: 2,
  );
  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress) async {
    onProgress(const TaskProgress('本机已保存'));
    if (fail) throw StateError('第二个文件传输中断');
  }

  @override
  Future<void> fastSync(RecordingPolicy policy, ProgressSink onProgress) =>
      sync(policy, onProgress);
  @override
  Future<void> prepareFastTransfer() async {}
  @override
  Future<void> cancelFastTransfer() async {}
}

void main() {
  test('production wrapper dispatches recording capability through DeviceBackend, never live capture', () async {
    final root = await Directory.systemTemp.createTemp('rc-controller-test-');
    final h = fixture.Harness(root);
    final service = CountingService(h);
    final DeviceBackend backend = RuntimeDeviceBackend(
      service,
      h.pipeline,
      h.gateway,
    );
    expect(backend, isA<RecordingDeviceBackend>());
    await backend.startRecording();
    await backend.status();
    await backend.stopRecording();
    expect(service.starts, 1);
    expect(service.stops, 1);
    expect(h.gateway.started, isNull);
    expect(h.gateway.stops, 0);
    expect(h.gateway.recordingCommands, 0);
    await h.pipeline.dispose();
    await h.gateway.stream.close();
    await root.delete(recursive: true);
  });

  test(
    'saved audio with source retained is not green move success or latest sync',
    () async {
      var refreshed = 0;
      final store = DeviceStore(
        backend: FeedbackBackend(),
        persistence: MemoryStorePersistence(),
        onSynced: () async {
          refreshed++;
        },
      );
      await store.syncNow();
      expect(store.sourceRetained, isTrue);
      expect(store.syncText, contains('卡端保留 2 项'));
      expect(store.lastSync, isNull);
      expect(refreshed, 1);
      store.dispose();
    },
  );

  test('partial failure still refreshes durable imports and preserves actual error', () async {
    var refreshed = 0;
    final backend = FeedbackBackend()..fail = true;
    final store = DeviceStore(
      backend: backend,
      persistence: MemoryStorePersistence(),
      onSynced: () async {
        refreshed++;
      },
    );
    await store.syncNow();
    expect(refreshed, 1);
    expect(store.syncState, SyncState.failed);
    expect(store.syncError, contains('第二个文件传输中断'));
    store.dispose();
  });

  test(
    'no firmware offer shows typed unconfigured reason and no target arrow',
    () async {
      final store = DeviceStore(
        backend: FeedbackBackend(),
        persistence: MemoryStorePersistence(),
        firmwareStatusMessage: () => '未配置升级清单',
      );
      store.connected = true;
      store.reading = FeedbackBackend.reading;
      await store.checkFirmware();
      expect(store.fwHasError, isFalse);
      expect(store.fwStateText, '未配置升级清单');
      expect(store.mainVersionText, 'fixture-main');
      expect(store.wifiVersionText, '未知');
      store.dispose();
    },
  );

  test('record processing retry invokes pipeline callback and preserves specific failure', () async {
    var calls = 0;
    final store = AppStore(
      persistence: MemoryStorePersistence(),
      retryRecordProcessing: () async {
        calls++;
        throw StateError('model_missing: 本机模型尚未准备好');
      },
    );
    await store.retryRecords();
    expect(calls, 1);
    expect(store.error, contains('model_missing'));
    store.dispose();
  });
}
