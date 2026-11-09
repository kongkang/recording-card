import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/recordings/recording_download_gateway.dart';
import 'package:recording_card/services/runtime/card_download_adapter.dart';

import 'runtime_repair_test.dart' as fixture;

class ReceiptGateway extends fixture.GatewaySpy {
  int confirms = 0;
  String errorCode = 'source_retained';
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
      originalName: name,
      sourceDeleted: false,
      downloadId: 'test-receipt-$name',
      deviceId: expectedDeviceId,
      transportId: 'test-transport',
      sha256: sha256.convert(files[name]!).toString(),
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
    expect(await File(verifiedPath!).length(), receipt.bytes);
    confirms++;
    throw CardGatewayException(errorCode, 'test Native confirmation guard');
  }
}

void main() {
  for (final code in ['source_retained', 'identity', 'integrity']) {
    test(
      'Native $code maps through actual adapter without fabricated deletion',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'rc-retained-adapter-',
        );
        final gateway = ReceiptGateway()
          ..recording = false
          ..errorCode = code;
        gateway.files['one.wav'] = fixture.wav30();
        final adapter = CardDownloadAdapter(gateway);
        const device = 'card:真实:device';
        await adapter.openSession(device);
        final recording = (await adapter.listRecordings(device)).single;
        final download = await adapter.downloadRecording(
          device,
          recording,
          destinationPath: '${root.path}/import.wav',
          allowDestructive: false,
        );
        final receipt = RecordingSourceReceipt(
          repositoryKey: 'test-durable-repository-key',
          audioPath: download.audioPath,
          sizeBytes: recording.sizeBytes,
          contentHash: sha256
              .convert(await File(download.audioPath).readAsBytes())
              .toString(),
        );
        if (code == 'source_retained') {
          expect(
            await adapter.confirmImportedRecording(device, recording, receipt),
            isFalse,
          );
          expect(
            await adapter.confirmImportedRecording(device, recording, receipt),
            isFalse,
          );
          expect(gateway.confirms, 2);
          expect(adapter.hasPendingSourceReceipt(device, recording), isTrue);
        } else {
          await expectLater(
            adapter.confirmImportedRecording(device, recording, receipt),
            throwsA(
              isA<CardGatewayException>().having((e) => e.code, 'code', code),
            ),
          );
        }
        expect(await File(download.audioPath).exists(), isTrue);
        expect(gateway.files.containsKey('one.wav'), isTrue);
        await adapter.closeSession(device);
        await gateway.stream.close();
        await root.delete(recursive: true);
      },
    );
  }
}
