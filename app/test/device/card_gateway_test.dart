import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';

void main() {
  const fixture = CardSnapshot(
    batteryLevel: 52,
    isCharging: false,
    wifiOpen: false,
    recording: true,
    fwVersion: '0.3.9',
    wifiVersion: '0.1.3',
  );
  test(
    'unavailable facade never silently manufactures status or lists',
    () async {
      const gateway = UnavailableCardGateway();
      expect(gateway.available, false);
      await expectLater(gateway.status(), throwsA(isA<CardGatewayException>()));
      await expectLater(
        gateway.listFiles(),
        throwsA(isA<CardGatewayException>()),
      );
      await expectLater(
        const MockCardGateway().status(),
        throwsA(isA<CardGatewayException>()),
      );
    },
  );
  test(
    'test gateway requires explicit snapshot and discovery fixture',
    () async {
      const gateway = MockCardGateway(
        snapshot: fixture,
        devices: [CardDevice(id: 'test-card', name: 'DYJV2_TEST')],
      );
      expect((await gateway.scan()).single.id, 'test-card');
      expect((await gateway.connect('test-card')).recording, true);
      await expectLater(
        gateway.connect('missing'),
        throwsA(isA<CardGatewayException>()),
      );
    },
  );
  test(
    'recording is real RECORD_STATUS, not the realtime-enabled preference',
    () {
      final s = CardSnapshot.fromJson({
        'battery': {'level': 37, 'isCharging': true},
        'state': {'wifiOpen': false, 'recordRealtimeEnabled': true},
        'info': {
          'version': '0.3.9',
          'versionCode': 309,
          'deviceId': 'card1',
          'wifiVersion': '0.1.3',
        },
        'record': {
          'isRecording': false,
          'realtimeEnabled': true,
          'session': 'ABCDEF12',
        },
        'wifi': {'connected': false},
      });
      expect(s.recording, false);
      expect(s.realtimeEnabled, true);
      expect(s.deviceId, 'card1');
      expect(s.batteryLevel, 37);
    },
  );
  test(
    'snapshot missing required response throws rather than projecting zeros',
    () {
      expect(
        () => CardSnapshot.fromJson({}),
        throwsA(isA<CardGatewayException>()),
      );
    },
  );
  test('file timestamps and session identity retain uncertainty', () {
    final f = CardFile.fromJson({
      'name': '001.APM',
      'size': 8,
      'session': 'ABCDEF12',
      'seq': 2,
      'startAt': 42,
      'synced': false,
      'transport': 'ble',
    });
    expect(f.clockSynced, false);
    expect(f.startAt, 42);
    expect(f.sequence, 2);
    expect(f.transport, CardTransfer.ble);
  });
  test(
    'audio chunk exposes received offsets and discontinuity, not absolute timestamps',
    () {
      final chunk = CardAudioChunk.fromJson({
        'taskId': 't',
        'path': '/private/t.wav',
        'index': 2,
        'samples': 160,
        'receivedSampleOffset': 160,
        'discontinuous': true,
        'droppedChunks': 4,
        'isFinal': false,
        'interrupted': false,
      });
      expect(chunk.discontinuous, true);
      expect(chunk.receivedSampleOffset, 160);
    },
  );

  final library = Platform.environment['CARD_BRIDGE_TEST_LIBRARY'];
  group(
    'real Rust dynamic library / async NativeCallable.listener',
    () {
      late RealCardGateway gateway;
      setUpAll(() {
        gateway = RealCardGateway.forLibrary(DynamicLibrary.open(library!));
      });
      test(
        '100 asynchronous error strings survive worker return and are freed',
        () async {
          // This does NOT scan, connect hardware, invoke models or send credentials.
          await Future.wait(
            List.generate(100, (_) async {
              await expectLater(
                gateway.status(),
                throwsA(isA<CardGatewayException>()),
              );
            }),
          );
        },
      );
      test(
        'BLE take and OTA lack of consent reject without native device access',
        () async {
          await expectLater(
            gateway.downloadFile(
              'a.apm',
              directory: '/tmp',
              transport: CardTransfer.ble,
            ),
            throwsA(
              isA<CardGatewayException>().having(
                (e) => e.code,
                'code',
                'destructive',
              ),
            ),
          );
          const plan = CardFirmwarePlan(
            module: 'main',
            transportId: 'never-connected',
            deviceId: 'card1',
            installedVersionCode: 1,
            targetVersionCode: 2,
            targetVersion: '0.0.2',
            packagePath: '/no-package.zip',
            sha256: '',
          );
          await expectLater(
            gateway.updateFirmware(plan, userConfirmed: false),
            throwsA(
              isA<CardGatewayException>().having(
                (e) => e.code,
                'code',
                'confirmation',
              ),
            ),
          );
        },
      );
      test(
        'real PCM bytes convert through Rust to an actual WAV file',
        () async {
          final dir = await Directory.systemTemp.createTemp('card-ffi-');
          try {
            final source = File('${dir.path}/input.pcm');
            await source.writeAsBytes([0, 0, 1, 0, 255, 255]);
            final output = await gateway.convertAudio(
              source.path,
              destination: '${dir.path}/output.wav',
              format: 'pcm',
            );
            final bytes = await File(output).readAsBytes();
            expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
            expect(bytes.length, 50);
          } finally {
            await dir.delete(recursive: true);
          }
        },
      );
      test(
        'disconnect is actual idempotent native cleanup while never connected',
        () async {
          await gateway.disconnect();
          await gateway.disconnect();
        },
      );
    },
    skip: library == null
        ? 'Set CARD_BRIDGE_TEST_LIBRARY after cargo build to exercise the real FFI.'
        : false,
  );
}
