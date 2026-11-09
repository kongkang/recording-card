import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';

Map<String, dynamic> coreReading() => {
  'battery': {'level': 52, 'isCharging': false},
  'state': {'wifiOpen': true},
  'record': {'isRecording': true, 'realtimeEnabled': false},
  'info': null,
  'wifi': null,
  'optionalErrors': {
    'info': {'code': 'sdk', 'message': 'not supported'},
    'wifi': {'code': 'timeout', 'message': 'optional chip did not reply'},
  },
};

void main() {
  test(
    'optional info/wifi failure preserves confirmed recording and battery',
    () {
      final snapshot = CardSnapshot.fromJson(coreReading());
      expect(snapshot.recording, true);
      expect(snapshot.batteryLevel, 52);
      expect(snapshot.wifiOpen, true);
      expect(snapshot.infoAvailable, false);
      expect(snapshot.wifiStatusAvailable, false);
      expect(snapshot.optionalErrors['wifi']['code'], 'timeout');
      expect(snapshot.fwVersion, isEmpty);
      expect(snapshot.deviceId, isEmpty);
      expect(
        snapshot.versionCode,
        0,
      ); // Unknown, not an installed version claim.
    },
  );

  test('required recording absence fails instead of inventing idle state', () {
    final json = coreReading()..remove('record');
    expect(
      () => CardSnapshot.fromJson(json),
      throwsA(isA<CardGatewayException>()),
    );
    json['record'] = {'realtimeEnabled': true};
    expect(
      () => CardSnapshot.fromJson(json),
      throwsA(isA<CardGatewayException>()),
    );
  });

  test('powered-off wifi is known while firmware version may be unknown', () {
    final json = coreReading()
      ..['state'] = {'wifiOpen': false}
      ..['wifi'] = {'status': 'off', 'connected': false};
    final snapshot = CardSnapshot.fromJson(json);
    expect(snapshot.wifiStatusAvailable, true);
    expect(snapshot.wifiConnected, false);
    expect(snapshot.infoAvailable, false);
  });

  test('malformed optional firmware and wifi types become unknown, not connection failure', () {
    final json = coreReading()
      ..['info'] = {'version': 9, 'versionCode': '309', 'deviceId': false}
      ..['wifi'] = {'version': false, 'connected': 'unknown', 'ssid': 7};
    final snapshot = CardSnapshot.fromJson(json);
    expect(snapshot.recording, true);
    expect(snapshot.infoAvailable, false);
    expect(snapshot.wifiStatusAvailable, false);
    expect(snapshot.fwVersion, isEmpty);
    expect(snapshot.versionCode, 0);
    expect(snapshot.wifiSsid, isNull);
  });

  test(
    'status recording and file requests submit FIFO without overlapping',
    () async {
      final lane = CardCommandLane();
      final firstFinal = Completer<void>();
      final calls = <String>[];
      var active = 0;
      var maxActive = 0;
      Future<String> invoke(String op) async {
        calls.add(op);
        active++;
        if (active > maxActive) maxActive = active;
        if (op == 'status') await firstFinal.future;
        active--;
        return op;
      }

      final status = lane.run(() => invoke('status'), operation: 'status');
      final record = lane.run(
        () => invoke('setRecording'),
        operation: 'setRecording',
      );
      final files = lane.run(() => invoke('listFiles'), operation: 'listFiles');
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['status']);
      firstFinal.complete();
      expect(await Future.wait([status, record, files]), [
        'status',
        'setRecording',
        'listFiles',
      ]);
      expect(maxActive, 1);
      expect(calls, ['status', 'setRecording', 'listFiles']);
    },
  );

  test(
    'observer timeout does not release lane until actual late native final',
    () async {
      final lane = CardCommandLane();
      final nativeFinal = Completer<void>();
      final sent = <String>[];
      final first = lane.run(
        () {
          sent.add('download');
          return nativeFinal.future;
        },
        operation: 'download',
        responseTimeout: const Duration(milliseconds: 1),
      );
      await expectLater(
        first,
        throwsA(
          isA<CardGatewayException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
      final queued = lane.run(
        () async {
          sent.add('record');
        },
        operation: 'record',
        queueWait: const Duration(milliseconds: 2),
      );
      await expectLater(
        queued,
        throwsA(
          isA<CardGatewayException>().having((e) => e.code, 'code', 'busy'),
        ),
      );
      expect(sent, ['download']);
      nativeFinal.complete();
      await lane.run(() async {
        sent.add('status');
      }, operation: 'status');
      expect(sent, [
        'download',
        'status',
      ]); // Expired record request was never sent.
    },
  );

  test(
    'native failure releases lane and cannot poison later commands',
    () async {
      final lane = CardCommandLane();
      await expectLater(
        lane.run(() async {
          throw const CardGatewayException('verification', 'not confirmed');
        }, operation: 'record'),
        throwsA(isA<CardGatewayException>()),
      );
      expect(await lane.run(() async => 52, operation: 'status'), 52);
    },
  );

  test('safe receipt preserves identity hash and reports legacy source deletion honestly', () {
    final receipt = CardDownload.fromJson({
      'path': '/private/card.apm',
      'bytes': 3,
      'originalName': 'a.apm',
      'sourceDeleted': false,
      'downloadId': '1:1',
      'deviceId': 'card1',
      'transportId': 'ble-id',
      'sha256': 'abc',
    });
    expect(receipt.downloadId, '1:1');
    expect(receipt.deviceId, 'card1');
    expect(receipt.sha256, 'abc');
    expect(receipt.sourceDeleted, false);
    final legacy = CardDownload.fromJson({
      'path': '/private/card.apm',
      'bytes': 3,
      'originalName': 'a.apm',
      'sourceDeleted': true,
    });
    expect(legacy.sourceDeleted, true);
    expect(legacy.downloadId, isNull);
  });

  test(
    'default unsupported safe move and deletion never manufacture success',
    () async {
      const gateway = UnavailableCardGateway();
      await expectLater(
        gateway.downloadFilePreservingSource(
          'a.apm',
          directory: '/private/local',
          expectedDeviceId: 'card1',
          expectedBytes: 3,
        ),
        throwsA(isA<CardGatewayException>()),
      );
      await expectLater(
        gateway.confirmDeleteFile(
          const CardDownload(
            path: '/private/local/a.apm',
            bytes: 3,
            originalName: 'a.apm',
            sourceDeleted: false,
          ),
          repositoryCommitted: true,
        ),
        throwsA(isA<CardGatewayException>()),
      );
    },
  );

  final library = Platform.environment['CARD_BRIDGE_TEST_LIBRARY'];
  group(
    'native ABI safe file seams without adapters or hardware',
    () {
      late RealCardGateway gateway;
      setUpAll(
        () =>
            gateway = RealCardGateway.forLibrary(DynamicLibrary.open(library!)),
      );
      test(
        'capabilities truthfully reject SDK BLE take as safe move',
        () async {
          final caps = await gateway.fileTransferCapabilities();
          expect(caps['safeBleDownload'], false);
          expect(caps['apDownloadPreservesSource'], true);
          expect(caps['minimumKeepFirmwareCode'], 309);
          await expectLater(
            gateway.downloadFilePreservingSource(
              'a.apm',
              directory: '/tmp',
              expectedDeviceId: 'never-connected',
              expectedBytes: 3,
            ),
            throwsA(
              isA<CardGatewayException>().having(
                (e) => e.code,
                'code',
                'safeBleUnavailable',
              ),
            ),
          );
        },
      );
      test(
        'uncommitted or legacy download cannot trigger native deletion',
        () async {
          const legacy = CardDownload(
            path: '/tmp/a.apm',
            bytes: 3,
            originalName: 'a.apm',
            sourceDeleted: true,
          );
          await expectLater(
            gateway.confirmDeleteFile(legacy, repositoryCommitted: true),
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
    },
    skip: library == null
        ? 'Set CARD_BRIDGE_TEST_LIBRARY to the host Rust build (no hardware).'
        : false,
  );
}
