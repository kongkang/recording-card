import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/store_persistence.dart';

DeviceReading sample(bool recording, {int? seconds, bool known = true}) =>
    DeviceReading(
      CardSnapshot(
        batteryLevel: 65,
        isCharging: false,
        wifiOpen: false,
        recording: recording,
        fwVersion: '0.3.8',
        wifiVersion: '',
        deviceId: 'card',
      ),
      id: 'transport',
      targetId: 'card',
      recordedSeconds: seconds,
      recordingKnown: known,
    );

CallbackDeviceBackend backend({
  Future<DeviceReading> Function()? status,
  Future<DeviceReading> Function()? start,
  Future<DeviceReading> Function()? stop,
  Future<void> Function(RecordingPolicy, ProgressSink)? sync,
  bool initiallyRecording = false,
}) => CallbackDeviceBackend(
  isAvailable: () => true,
  scanDevices: () async => const [DeviceChoice('transport', 'card')],
  connectDevice: (_) async => sample(initiallyRecording),
  disconnectDevice: () async {},
  readStatus: status ?? () async => sample(initiallyRecording),
  beginRecording: start,
  endRecording: stop,
  synchronize: sync,
  listSavedWifi: () async => [],
  checkFirmware: () async => null,
);

DeviceStore storeFor(DeviceBackend backend) {
  final store = DeviceStore(
    backend: backend,
    persistence: MemoryStorePersistence(),
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  test(
    'start and stop remain last confirmed until SDK reading resolves',
    () async {
      final start = Completer<DeviceReading>();
      final stop = Completer<DeviceReading>();
      var starts = 0;
      var stops = 0;
      final store = storeFor(
        backend(
          start: () {
            starts++;
            return start.future;
          },
          stop: () {
            stops++;
            return stop.future;
          },
        ),
      );
      await store.connectDevice('transport');
      final starting = store.startRecording();
      expect(store.recordingBusy, isTrue);
      expect(store.isRecording, isFalse);
      expect(store.canControlRecording, isFalse);
      await store.startRecording();
      await store.stopRecording();
      expect(starts, 1);
      expect(stops, 0);
      start.complete(sample(true));
      await starting;
      expect(store.recordingBusy, isFalse);
      expect(store.isRecording, isTrue);
      expect(store.recordingError, isNull);
      expect(store.recClockText, '—:——:——');
      final stopping = store.stopRecording();
      expect(store.isRecording, isTrue);
      stop.complete(sample(false));
      await stopping;
      expect(store.isRecording, isFalse);
      expect(stops, 1);
      expect(store.recClockText, '—:——:——');
    },
  );

  test(
    'disconnected and other busy task never send recording commands',
    () async {
      var commands = 0;
      final syncing = Completer<void>();
      final store = storeFor(
        backend(
          start: () async {
            commands++;
            return sample(true);
          },
          sync: (_, _) => syncing.future,
        ),
      );
      await store.startRecording();
      expect(commands, 0);
      expect(store.recordingError, contains('未连接'));
      await store.connectDevice('transport');
      final sync = store.syncNow();
      await store.startRecording();
      expect(commands, 0);
      expect(store.recordingError, contains('正在运行'));
      syncing.complete();
      await sync;
    },
  );

  test(
    'record control blocks status polling and all conflicting tasks',
    () async {
      final gate = Completer<DeviceReading>();
      var reads = 0;
      var scans = 0;
      var syncs = 0;
      final store = storeFor(
        CallbackDeviceBackend(
          isAvailable: () => true,
          scanDevices: () async {
            scans++;
            return [];
          },
          connectDevice: (_) async => sample(false),
          readStatus: () async {
            reads++;
            return sample(false);
          },
          disconnectDevice: () async {},
          beginRecording: () => gate.future,
          synchronize: (_, _) async {
            syncs++;
          },
        ),
      );
      await store.connectDevice('transport');
      final recording = store.startRecording();
      await store.refreshFromDevice();
      await store.syncNow();
      await store.scanDevices();
      await store.wifiScan();
      await store.checkFirmware();
      expect(reads, 0);
      expect(scans, 0);
      expect(syncs, 0);
      gate.complete(sample(true));
      await recording;
    },
  );

  test('command rejection rolls back without a compensating stop', () async {
    var stops = 0;
    final store = storeFor(
      backend(
        start: () async => throw StateError('SD卡未挂载'),
        stop: () async {
          stops++;
          return sample(false);
        },
      ),
    );
    await store.connectDevice('transport');
    final old = store.reading;
    await store.startRecording();
    expect(store.recordingBusy, isFalse);
    expect(store.connected, isTrue);
    expect(store.reading, same(old));
    expect(store.isRecording, isFalse);
    expect(store.recordingError, contains('SD卡未挂载'));
    expect(store.statusStale, isTrue);
    expect(store.recordingText, '状态待确认');
    expect(stops, 0);
    await store.refreshFromDevice();
    expect(store.recordingKnown, isTrue);
    expect(store.recordingError, isNull);
  });

  test(
    'wrong or unknown RECORD_STATUS never claims recording success',
    () async {
      for (final reading in [sample(false), sample(true, known: false)]) {
        final store = storeFor(backend(start: () async => reading));
        await store.connectDevice('transport');
        await store.startRecording();
        expect(store.isRecording, isFalse);
        expect(store.recordingError, contains('未确认'));
        expect(store.devStateIsError, isTrue);
      }
    },
  );

  test('stop failure preserves last confirmed recording and battery', () async {
    final store = storeFor(
      backend(
        initiallyRecording: true,
        stop: () async => throw TimeoutException('确认超时'),
      ),
    );
    await store.connectDevice('transport');
    await store.stopRecording();
    expect(store.connected, isTrue);
    expect(store.isRecording, isTrue);
    expect(store.battery, 65);
    expect(store.batteryKnown, isTrue);
    expect(store.recordingBusy, isFalse);
    expect(store.recordingError, contains('停止录音失败'));
  });

  test('temporary status failure retains connection and last battery; retry recovers', () async {
    var failing = true;
    final store = storeFor(
      backend(
        status: () async {
          if (failing) throw const CardGatewayException('timeout', '固件查询超时');
          return sample(true);
        },
      ),
    );
    await store.connectDevice('transport');
    final old = store.reading;
    await store.refreshFromDevice();
    expect(store.connected, isTrue);
    expect(store.reading, same(old));
    expect(store.batteryKnown, isTrue);
    expect(store.battery, 65);
    expect(store.statusStale, isTrue);
    expect(store.connectionText, '已连接 · 蓝牙');
    expect(store.recordingText, '状态待确认');
    expect(store.canControlRecording, isFalse);
    failing = false;
    await store.refreshFromDevice();
    expect(store.statusStale, isFalse);
    expect(store.statusError, isNull);
    expect(store.isRecording, isTrue);
    expect(store.devStateIsError, isFalse);
  });

  test(
    'only explicit disconnected error clears confirmed connection',
    () async {
      final store = storeFor(
        backend(
          status: () async =>
              throw const CardGatewayException('disconnected', '录音卡已断开'),
        ),
      );
      await store.connectDevice('transport');
      await store.refreshFromDevice();
      expect(store.connected, isFalse);
      expect(store.reading, isNull);
      expect(store.batteryKnown, isFalse);
    },
  );

  test('disposed recording result cannot resurrect the device', () async {
    final gate = Completer<DeviceReading>();
    final store = DeviceStore(
      backend: backend(start: () => gate.future),
      persistence: MemoryStorePersistence(),
    );
    await store.connectDevice('transport');
    final operation = store.startRecording();
    store.dispose();
    gate.complete(sample(true));
    await operation;
    expect(store.isRecording, isFalse);
  });

  test(
    'old DeviceBackend fake and optional callbacks fail explicitly',
    () async {
      final DeviceBackend old = OldDeviceBackend();
      await expectLater(old.startRecording(), throwsStateError);
      await expectLater(old.stopRecording(), throwsStateError);
      final DeviceBackend callback = backend();
      await expectLater(callback.startRecording(), throwsStateError);
      await expectLater(callback.stopRecording(), throwsStateError);
    },
  );

  test(
    'invalid battery and unknown recording do not render known states',
    () async {
      final store = storeFor(
        backend(
          status: () async => DeviceReading(
            const CardSnapshot(
              batteryLevel: -1,
              isCharging: false,
              wifiOpen: false,
              recording: false,
              fwVersion: '',
              wifiVersion: '',
            ),
            batteryKnown: false,
            recordingKnown: false,
            recordedSeconds: -1,
          ),
        ),
      );
      await store.refreshFromDevice();
      expect(store.connected, isTrue);
      expect(store.batteryKnown, isFalse);
      expect(store.recordingKnown, isFalse);
      expect(store.recordingText, '状态待确认');
      expect(store.recClockText, '—:——:——');
      expect(store.canControlRecording, isFalse);
    },
  );

  testWidgets(
    'only a verified duration anchor advances, never connection time',
    (tester) async {
      var duration = false;
      final store = storeFor(
        backend(
          status: () async => sample(true, seconds: duration ? 120 : null),
        ),
      );
      await store.refreshFromDevice();
      await tester.pump(const Duration(seconds: 8));
      expect(store.recClockText, '—:——:——');
      duration = true;
      await store.refreshFromDevice();
      expect(store.recClockText, '0:02:00');
      // Stopwatch is a monotonic real clock, not a guessed device start timestamp.
      expect(store.recSeconds, greaterThanOrEqualTo(120));
    },
  );
}

/// Explicitly implements only the pre-control API (no noSuchMethod escape hatch).
class OldDeviceBackend implements DeviceBackend {
  @override
  bool get available => false;
  @override
  Future<List<DeviceChoice>> scan() async => [];
  @override
  Future<DeviceReading> connect(String id) async => sample(false);
  @override
  Future<void> disconnect() async {}
  @override
  Future<DeviceReading> status() async => sample(false);
  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress) async {}
  @override
  Future<List<SavedWifi>> savedWifi() async => [];
  @override
  Future<List<WifiNet>> scanWifi() async => [];
  @override
  Future<void> connectSavedWifi(String name) async {}
  @override
  Future<void> joinWifi(String name, String password) async {}
  @override
  Future<FirmwareOffer?> firmwareOffer() async => null;
  @override
  Future<void> updateFirmware(
    FirmwareOffer offer,
    FirmwareConsent consent,
    ProgressSink onProgress,
  ) async {}
}
