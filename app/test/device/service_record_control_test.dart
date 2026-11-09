import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/service_backends.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

class RecordingGateway extends CardGateway {
  final commands = <bool>[];
  bool recording = false;
  bool reject = false;
  bool missingConfirmation = false;
  bool wrongStatus = false;
  int reads = 0;
  bool wifiOpen = false;
  bool failWifiClose = false;
  final wifiCommands = <bool>[];
  Completer<void>? gate;
  @override
  bool get available => true;
  @override
  Future<CardSnapshot> connect(String id) => status();
  @override
  Future<void> disconnect() async {}
  @override
  Future<CardSnapshot> status() async {
    reads++;
    return CardSnapshot(
      batteryLevel: 68,
      isCharging: false,
      wifiOpen: wifiOpen,
      recording: wrongStatus ? !recording : recording,
      fwVersion: '0.3.8',
      wifiVersion: '',
      deviceId: 'card',
      // A session ID is not a duration clock.
      recordingSession: 'ABCD1234',
    );
  }

  @override
  Future<void> setWifiEnabled(bool enabled) async {
    wifiCommands.add(enabled);
    if (!failWifiClose) wifiOpen = enabled;
  }

  @override
  Future<Map<String, dynamic>> setRecording(bool enabled) async {
    commands.add(enabled);
    if (gate != null) await gate!.future;
    if (reject) throw StateError('SD卡未挂载');
    if (!missingConfirmation) recording = enabled;
    return missingConfirmation ? {} : {'isRecording': enabled};
  }
}

void main() {
  late RecordingGateway gateway;
  late ServiceDeviceBackend service;
  setUp(() {
    gateway = RecordingGateway();
    service = ServiceDeviceBackend(
      gateway: gateway,
      settingsRepository: SettingsRepository(
        directory: Directory('/tmp/record-control-unused'),
      ),
    );
  });

  test(
    'service commands require connection and return real confirmed readings',
    () async {
      await expectLater(service.startRecording(), throwsStateError);
      expect(gateway.commands, isEmpty);
      await service.connect('transport');
      final started = await service.startRecording();
      expect(started.snapshot.recording, isTrue);
      expect(started.recordedSeconds, isNull);
      expect(started.id, 'transport');
      expect(started.targetId, 'card');
      final stopped = await service.stopRecording();
      expect(stopped.snapshot.recording, isFalse);
      expect(stopped.recordedSeconds, isNull);
      expect(gateway.commands, [true, false]);
      expect(gateway.reads, 4);
      await service.disconnect();
      await expectLater(service.stopRecording(), throwsStateError);
      expect(gateway.commands, [true, false]);
    },
  );

  test('command ACK alone cannot manufacture RECORD_STATUS', () async {
    await service.connect('transport');
    gateway.missingConfirmation = true;
    await expectLater(service.startRecording(), throwsStateError);
    expect(gateway.commands, [true]);
    expect(gateway.recording, isFalse);
    expect(gateway.reads, 2);
  });

  test('post-command status disagreement is rejected', () async {
    await service.connect('transport');
    gateway.wrongStatus = true;
    await expectLater(service.startRecording(), throwsStateError);
    expect(gateway.commands, [true]);
    expect(gateway.reads, 3);
  });

  test('ordinary recording returns SD from Wi-Fi and verifies state before starting', () async {
    gateway.wifiOpen = true;
    await service.connect('transport');
    expect((await service.startRecording()).snapshot.recording, isTrue);
    expect(gateway.wifiCommands, [false]);
    expect(gateway.wifiOpen, isFalse);
    expect(gateway.commands, [true]);
  });

  test(
    'Wi-Fi close ACK without actual SD release cannot start recording',
    () async {
      gateway.wifiOpen = true;
      gateway.failWifiClose = true;
      await service.connect('transport');
      await expectLater(service.startRecording(), throwsStateError);
      expect(gateway.commands, isEmpty);
      expect(gateway.wifiCommands, [false]);
    },
  );

  test('explicit stop does not change Wi-Fi or implicitly restart', () async {
    await service.connect('transport');
    await service.stopRecording();
    expect(gateway.wifiCommands, isEmpty);
    expect(gateway.commands, [false]);
  });

  test(
    'SDK error is propagated without implicit reversal or realtime capture',
    () async {
      await service.connect('transport');
      gateway.reject = true;
      await expectLater(service.startRecording(), throwsStateError);
      expect(gateway.commands, [true]);
      gateway.reject = false;
      expect((await service.startRecording()).snapshot.recording, isTrue);
      expect(gateway.commands, [true, true]);
    },
  );

  test(
    'service rejects overlapping control and unlocks after failure',
    () async {
      await service.connect('transport');
      gateway.gate = Completer<void>();
      final first = service.startRecording();
      await expectLater(service.stopRecording(), throwsStateError);
      expect(gateway.commands, [true]);
      gateway.gate!.complete();
      await first;
      gateway.gate = null;
      await service.stopRecording();
      expect(gateway.commands, [true, false]);
    },
  );

  test(
    'default gateway adapter has explicit start/stop with SDK confirmation',
    () async {
      final DeviceBackend adapter = GatewayDeviceBackend(gateway);
      final started = await adapter.startRecording();
      expect(started.snapshot.recording, isTrue);
      expect(started.recordedSeconds, isNull);
      final stopped = await adapter.stopRecording();
      expect(stopped.snapshot.recording, isFalse);
      expect(gateway.commands, [true, false]);
    },
  );
}
