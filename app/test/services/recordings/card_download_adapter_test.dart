import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/settings/settings_repository.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/runtime/card_download_adapter.dart';

import '../../runtime_repair_test.dart' show GatewaySpy;
import '../../fixtures/accessory_hotspot_fixture.dart';

class EarlyDeleteGateway extends GatewaySpy {
  @override
  Future<CardDownload> downloadFile(
    String name, {
    required String directory,
    int? expectedBytes,
    CardTransfer transport = CardTransfer.ap,
    bool allowDestructive = false,
    void Function(CardProgress)? onProgress,
  }) async {
    final result = await super.downloadFile(
      name,
      directory: directory,
      expectedBytes: expectedBytes,
      transport: transport,
      allowDestructive: allowDestructive,
      onProgress: onProgress,
    );
    return CardDownload(
      path: result.path,
      bytes: result.bytes,
      originalName: result.originalName,
      sourceDeleted: true,
    );
  }
}

class ReceiptGateway extends GatewaySpy {
  final deletes = <String>[];
  bool failAudioOnce = false;
  Future<void> Function(CardDownload, String)? beforeDelete;
  @override
  Future<CardDownload> downloadFilePreservingSource(
    String name, {
    required String directory,
    required String expectedDeviceId,
    required int expectedBytes,
    CardTransfer transport = CardTransfer.ble,
    void Function(CardProgress)? onProgress,
  }) async {
    final result = await super.downloadFilePreservingSource(
      name,
      directory: directory,
      expectedDeviceId: expectedDeviceId,
      expectedBytes: expectedBytes,
      transport: transport,
      onProgress: onProgress,
    );
    return CardDownload(
      path: result.path,
      bytes: result.bytes,
      originalName: result.originalName,
      sourceDeleted: false,
      downloadId: 'receipt:$name:${downloads.length}',
      deviceId: expectedDeviceId,
      sha256: sha256.convert(await File(result.path).readAsBytes()).toString(),
    );
  }

  @override
  Future<void> confirmDeleteFile(
    CardDownload receipt, {
    required bool repositoryCommitted,
    String? verifiedPath,
  }) async {
    expect(repositoryCommitted, isTrue);
    expect(verifiedPath, isNotNull);
    expect(
      sha256.convert(await File(verifiedPath!).readAsBytes()).toString(),
      receipt.sha256,
    );
    await beforeDelete?.call(receipt, verifiedPath);
    if (failAudioOnce && receipt.originalName.endsWith('.APM')) {
      failAudioOnce = false;
      throw const CardGatewayException('timeout', '音频删源确认超时');
    }
    deletes.add(receipt.originalName);
    files.remove(receipt.originalName);
  }
}

void main() {
  late Directory root;
  late GatewaySpy gateway;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('card-file-adapter-');
    gateway = GatewaySpy()..files['REC.APM'] = [1, 2, 3];
  });
  tearDown(() async {
    await gateway.stream.close();
    await root.delete(recursive: true);
  });

  test('ordinary BLE transfers closed files while SD recording continues, no wifi or realtime', () async {
    final adapter = CardDownloadAdapter(gateway);
    expect(adapter.transport, CardTransfer.ble);
    expect(adapter.usesNetwork, isFalse);
    await adapter.openSession('card:真实:device');
    final remote = (await adapter.listRecordings('card:真实:device')).single;
    final local = await adapter.downloadRecording(
      'card:真实:device',
      remote,
      destinationPath: '${root.path}/local.apm',
      allowDestructive: false,
    );
    expect(await File(local.audioPath).readAsBytes(), [1, 2, 3]);
    await adapter.closeSession('card:真实:device');
    expect(gateway.recording, isTrue);
    expect(gateway.recordingCommands, 0);
    expect(gateway.started, isNull);
    expect(gateway.wifiCommands, isEmpty);
  });

  test('explicit AP choice opens/closes wifi but does not require Internet or stop recording', () async {
    gateway.recording = false;
    gateway.expectedTransport = CardTransfer.ap;
    final hotspot = fixtureHotspot(gateway);
    await hotspot.prepare('card:真实:device');
    final adapter = CardDownloadAdapter(
      gateway,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
    );
    expect(adapter.usesNetwork, isFalse);
    await adapter.openSession('card:真实:device');
    final remote = (await adapter.listRecordings('card:真实:device')).single;
    await adapter.downloadRecording(
      'card:真实:device',
      remote,
      destinationPath: '${root.path}/local.apm',
      allowDestructive: false,
    );
    await adapter.closeSession('card:真实:device');
    await adapter.closeSession('card:真实:device');
    expect(gateway.wifiCommands, [true, false]);
    expect(gateway.recordingCommands, 0);
  });

  test('AP while recording gives exact error and never silently stops user recording', () async {
    final adapter = CardDownloadAdapter(gateway, transport: CardTransfer.ap);
    await expectLater(adapter.openSession('card:真实:device'), throwsStateError);
    await adapter.closeSession('card:真实:device');
    expect(gateway.recording, isTrue);
    expect(gateway.recordingCommands, 0);
    expect(gateway.wifiCommands, isEmpty);
    expect(gateway.downloads, isEmpty);
  });

  test(
    'wrong target device is rejected before reading or confirming source',
    () async {
      final adapter = CardDownloadAdapter(gateway);
      await expectLater(adapter.openSession('other-device'), throwsStateError);
      await adapter.closeSession('other-device');
      expect(gateway.downloads, isEmpty);
      await adapter.openSession('card:真实:device');
      await expectLater(
        adapter.listRecordings('other-device'),
        throwsStateError,
      );
      await adapter.closeSession('card:真实:device');
    },
  );

  test(
    'premature native deletion is never reported as a safe local move',
    () async {
      final early = EarlyDeleteGateway()..files['REC.APM'] = [1, 2, 3];
      addTearDown(early.stream.close);
      final adapter = CardDownloadAdapter(early);
      await adapter.openSession('card:真实:device');
      final remote = (await adapter.listRecordings('card:真实:device')).single;
      await expectLater(
        adapter.downloadRecording(
          'card:真实:device',
          remote,
          destinationPath: '${root.path}/local.apm',
          allowDestructive: false,
        ),
        throwsA(predicate((e) => e.toString().contains('提前删源'))),
      );
      await adapter.closeSession('card:真实:device');
    },
  );

  test('invalid filename cannot escape private download directory', () async {
    gateway.files.clear();
    gateway.files['../REC.APM'] = [1];
    final adapter = CardDownloadAdapter(gateway);
    await adapter.openSession('card:真实:device');
    await expectLater(
      adapter.listRecordings('card:真实:device'),
      throwsFormatException,
    );
    expect(gateway.downloads, isEmpty);
    await adapter.closeSession('card:真实:device');
  });

  test(
    'zero-length TXT is downloaded and kept as real paired sidecar',
    () async {
      gateway.files['REC.TXT'] = [];
      final adapter = CardDownloadAdapter(gateway);
      await adapter.openSession('card:真实:device');
      final remote = (await adapter.listRecordings('card:真实:device')).single;
      final local = await adapter.downloadRecording(
        'card:真实:device',
        remote,
        destinationPath: '${root.path}/local.apm',
        allowDestructive: false,
      );
      expect(local.metadataPath, isNotNull);
      expect(await File(local.metadataPath!).length(), 0);
      expect(gateway.downloads, ['REC.APM', 'REC.TXT']);
      await adapter.closeSession('card:真实:device');
    },
  );

  test(
    'cancel prevents source confirmation; missing callback retains card source',
    () async {
      var confirms = 0, cancels = 0;
      final adapter = CardDownloadAdapter(
        gateway,
        confirmSource: (_, _, _) async {
          confirms++;
          return true;
        },
        cancelTransfer: () async {
          cancels++;
        },
      );
      await adapter.openSession('card:真实:device');
      final remote = (await adapter.listRecordings('card:真实:device')).single;
      final receipt = RecordingSourceReceipt(
        repositoryKey: 'key',
        audioPath: '/local/managed.apm',
        sizeBytes: 3,
        contentHash: 'a' * 64,
      );
      await adapter.cancelActive();
      await expectLater(
        adapter.confirmImportedRecording('card:真实:device', remote, receipt),
        throwsA(isA<RecordingSyncCancelled>()),
      );
      expect(confirms, 0);
      expect(cancels, 1);
      await adapter.closeSession('card:真实:device');
      final copyOnly = CardDownloadAdapter(gateway);
      await copyOnly.openSession('card:真实:device');
      expect(
        await copyOnly.confirmImportedRecording(
          'card:真实:device',
          remote,
          receipt,
        ),
        isFalse,
      );
      await copyOnly.closeSession('card:真实:device');
    },
  );
  test('AP Native receipts delete sidecars then audio only after durable repository verification', () async {
    final native = ReceiptGateway()
      ..recording = false
      ..expectedTransport = CardTransfer.ap;
    native.files.addAll({
      'REC.APM': [1, 2, 3],
      'REC.TXT': [4],
      'REC.MRK': [],
    });
    addTearDown(native.stream.close);
    final repository = RecordingRepository(
      directory: Directory('${root.path}/repository'),
    );
    final hotspot = fixtureHotspot(native);
    await hotspot.prepare('card:真实:device');
    final adapter = CardDownloadAdapter(
      native,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
    );
    final coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: SettingsRepository(directory: root),
      gateway: adapter,
    );
    addTearDown(coordinator.dispose);
    native.beforeDelete = (_, path) async {
      final reopened = RecordingRepository(directory: repository.directory);
      final state = await reopened.load();
      expect(
        await reopened.verifyRecording(state.index.single.key),
        RecordingIntegrity.valid,
      );
      expect(path, startsWith('${repository.directory.path}/audio/'));
    };
    final result = await coordinator.sync('card:真实:device');
    expect(native.deletes, ['REC.MRK', 'REC.TXT', 'REC.APM']);
    expect(native.files, isEmpty);
    expect(result.isMoveComplete, isTrue);
    expect(result.uploaded, isEmpty);
  });

  test('partial Native source ack retry keeps durable sidecars and canonical original text', () async {
    final native = ReceiptGateway()
      ..recording = false
      ..expectedTransport = CardTransfer.ap
      ..failAudioOnce = true;
    native.files.addAll({
      'REC.APM': [1, 2, 3],
      'REC.TXT': [4],
      'REC.MRK': [],
    });
    addTearDown(native.stream.close);
    final repository = RecordingRepository(
      directory: Directory('${root.path}/repository'),
    );
    final hotspot = fixtureHotspot(native);
    await hotspot.prepare('card:真实:device');
    final adapter = CardDownloadAdapter(
      native,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
    );
    final coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: SettingsRepository(directory: root),
      gateway: adapter,
    );
    addTearDown(coordinator.dispose);
    await expectLater(
      coordinator.sync('card:真实:device'),
      throwsA(isA<CardGatewayException>()),
    );
    final first = (await repository.load()).events.single;
    await repository.upsertEvent(
      first.copyWith(originalTranscript: '原文不能被重试覆盖'),
    );
    expect(native.files.keys, ['REC.APM']);
    await hotspot.prepare('card:真实:device');
    final result = await coordinator.sync('card:真实:device');
    expect(result.imports.single.duplicate, isTrue);
    expect(result.isMoveComplete, isTrue);
    expect(native.deletes, ['REC.MRK', 'REC.TXT', 'REC.APM']);
    final saved = (await repository.load()).index.single;
    expect(
      await repository.verifyRecording(saved.key),
      RecordingIntegrity.valid,
    );
    expect(saved.metadataPath, isNotNull);
    expect(saved.markPath, isNotNull);
    expect(
      (await repository.load()).events.single.originalTranscript,
      '原文不能被重试覆盖',
    );
  });
}
