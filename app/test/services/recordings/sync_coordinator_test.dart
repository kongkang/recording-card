import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

class MemorySecureStore implements SecureWifiStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class FakeNetwork implements RecordingNetworkProbe {
  RecordingNetwork value = RecordingNetwork.offline;
  int calls = 0;
  @override
  Future<RecordingNetwork> current() async {
    calls++;
    return value;
  }
}

class FakeDownloadGateway
    implements RecordingDownloadGateway, RecordingSourceCommitGateway {
  final File source;
  final List<String> log;
  bool failDownload = false, failOpen = false, failClose = false;
  bool failConfirm = false, confirmSupported = true;
  bool destructiveRequested = false, empty = false, internetRequired = false;
  bool truncate = false, identityReliable = true;
  int downloads = 0, confirmations = 0;
  Completer<void>? blocked;
  Future<void> Function(RecordingSourceReceipt)? onConfirm;
  FakeDownloadGateway(this.source, this.log);
  @override
  bool get usesNetwork => internetRequired;
  @override
  Future<void> openSession(String deviceId) async {
    log.add('open');
    if (failOpen) throw StateError('蓝牙未连接：test open failure');
  }

  @override
  Future<void> closeSession(String deviceId) async {
    log.add('close');
    if (failClose) throw StateError('session cleanup refused');
  }

  @override
  Future<List<RemoteRecording>> listRecordings(String deviceId) async {
    log.add('list');
    return empty
        ? []
        : [
            RemoteRecording(
              metadata: {'identityReliable': identityReliable},
              fileId: 'session-1:seq-1',
              name: 'real.apm',
              sizeBytes: await source.length(),
              recordedAt: DateTime.parse('2026-11-08T00:00:00Z'),
            ),
          ];
  }

  @override
  Future<DownloadedRecording> downloadRecording(
    String deviceId,
    RemoteRecording recording, {
    required String destinationPath,
    required bool allowDestructive,
    RecordingProgress? onProgress,
  }) async {
    downloads++;
    destructiveRequested = allowDestructive;
    log.add('download');
    await blocked?.future;
    if (failDownload) throw StateError('设备拒绝文件拉取：test device failure');
    final file = await source.copy(destinationPath);
    if (truncate) await file.writeAsBytes([1]);
    onProgress?.call(await file.length(), recording.sizeBytes);
    return DownloadedRecording(audioPath: file.path);
  }

  @override
  Future<bool> confirmImportedRecording(
    String deviceId,
    RemoteRecording recording,
    RecordingSourceReceipt receipt,
  ) async {
    log.add('confirm');
    confirmations++;
    await onConfirm?.call(receipt);
    if (failConfirm) throw StateError('设备删源确认超时；本机音频已保存');
    return confirmSupported;
  }

  @override
  Future<void> cancelActive() async {
    if (blocked != null && !blocked!.isCompleted) blocked!.complete();
  }
}

class FakeUploader implements RecordingUploader {
  int calls = 0;
  @override
  void validateConfiguration() {
    calls++;
    throw StateError('must not upload audio');
  }

  @override
  Future<RecordingUploadReceipt> upload(
    RecordingUploadRequest request, {
    RecordingProgress? onProgress,
  }) async {
    calls++;
    throw StateError('must not upload audio');
  }

  @override
  Future<void> cancelActive() async {
    calls++;
  }
}

void main() {
  late Directory temp, directory;
  late File source;
  late RecordingRepository repository;
  late SettingsRepository settings;
  late FakeNetwork network;
  late FakeDownloadGateway gateway;
  late FakeUploader uploader;
  late List<String> log;
  late SyncCoordinator coordinator;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sync-coordinator-test-');
    directory = Directory('${temp.path}/data');
    source = await File('${temp.path}/real.apm')
        .writeAsBytes(List.generate(128, (i) => i));
    repository = RecordingRepository(directory: directory);
    settings = SettingsRepository(
      directory: directory,
      secureStore: MemorySecureStore(),
    );
    network = FakeNetwork();
    log = [];
    gateway = FakeDownloadGateway(source, log);
    uploader = FakeUploader();
    coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: settings,
      gateway: gateway,
      uploader: uploader,
      networkPolicy: RecordingNetworkPolicy(probe: network),
    );
  });
  tearDown(() async {
    await coordinator.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'offline ordinary sync commits locally without upload config or model',
    () async {
      final result = await coordinator.sync('card-1');
      expect(log, ['open', 'list', 'download', 'confirm', 'close']);
      expect(result.imports, hasLength(1));
      expect(result.uploaded, isEmpty);
      expect(gateway.destructiveRequested, isFalse);
      expect(network.calls, 0);
      expect(uploader.calls, 0);
      final state = await repository.load();
      expect(state.index.single.cloudFileId, isNull);
      expect(state.events.single.transcriptionStatus, 'queued');
      expect(state.events.single.originalTranscript, isNull);
      expect(state.metadata['lastSuccessfulSyncAt'], isA<String>());
    },
  );

  test(
    'source ack sees atomic durable repository and verified local SHA/size',
    () async {
      gateway.onConfirm = (receipt) async {
        final reopened = RecordingRepository(directory: directory);
        final state = await reopened.load();
        expect(state.index.single.key, receipt.repositoryKey);
        expect(state.index.single.contentHash, receipt.contentHash);
        expect(await File(receipt.audioPath).length(), receipt.sizeBytes);
        expect(
          await reopened.verifyRecording(receipt.repositoryKey),
          RecordingIntegrity.valid,
        );
      };
      await coordinator.sync('card-1');
      expect(
        (await repository.load()).metadata.values.whereType<Map>().any(
          (m) => m['state'] == 'confirmed',
        ),
        isTrue,
      );
    },
  );

  test('no source confirmation capability records retained source, never fake deletion', () async {
    gateway.confirmSupported = false;
    await coordinator.sync('card-1');
    expect(await source.exists(), isTrue);
    expect(
      (await repository.load()).metadata.values.whereType<Map>().any(
        (m) => m['state'] == 'source_retained',
      ),
      isTrue,
    );
  });

  test('dedup skips transfer and ack, preserves original audio/text/error on retry', () async {
    final first = (await coordinator.sync('card-1')).imports.single;
    await repository.upsertEvent(
      first.event.copyWith(
        originalTranscript: '真实原文',
        transcript: '真实原文',
        transcriptionStatus: 'analysis_failed',
        error: '未登录，不能润色',
      ),
    );
    final second = (await coordinator.sync('card-1')).imports.single;
    expect(second.duplicate, isTrue);
    expect(gateway.downloads, 1);
    expect(gateway.confirmations, 1);
    final event = (await repository.load()).events.single;
    expect(event.id, first.event.id);
    expect(event.audioPath, first.event.audioPath);
    expect(event.originalTranscript, '真实原文');
    expect(event.error, '未登录，不能润色');
    expect(uploader.calls, 0);
  });

  test(
    'failed ack retries without redownload or overwriting already saved text',
    () async {
      gateway.failConfirm = true;
      await expectLater(coordinator.sync('card-1'), throwsStateError);
      final original = (await repository.load()).events.single;
      await repository.upsertEvent(
        original.copyWith(originalTranscript: '已保存原文'),
      );
      gateway.failConfirm = false;
      await coordinator.sync('card-1');
      expect(gateway.downloads, 1);
      expect(gateway.confirmations, 2);
      expect(
        (await repository.load()).events.single.originalTranscript,
        '已保存原文',
      );
      expect(await source.exists(), isTrue);
    },
  );

  test(
    'truncated download never indexes or confirms source deletion',
    () async {
      gateway.truncate = true;
      await expectLater(
        coordinator.sync('card-1'),
        throwsA(isA<RecordingStorageException>()),
      );
      expect((await repository.load()).index, isEmpty);
      expect(gateway.confirmations, 0);
      expect(await source.exists(), isTrue);
      expect(log.last, 'close');
    },
  );

  test(
    'failed open and cleanup preserve exact primary reason in sync task',
    () async {
      gateway.failOpen = true;
      gateway.failClose = true;
      await expectLater(coordinator.sync('card-1'), throwsStateError);
      expect(log, ['open', 'close']);
      final state = await repository.load();
      expect(state.tasks.single.error, contains('蓝牙未连接'));
      expect(state.metadata['error:sync-cleanup'], contains('cleanup refused'));
      expect(state.index, isEmpty);
    },
  );

  test(
    'download refusal stores actual reason instead of generic task failure',
    () async {
      gateway.failDownload = true;
      await expectLater(coordinator.sync('card-1'), throwsStateError);
      expect(
        (await repository.load()).tasks.every(
          (t) =>
              t.state == RecordingTaskState.failed &&
              t.error!.contains('设备拒绝文件拉取'),
        ),
        isTrue,
      );
      expect(gateway.confirmations, 0);
    },
  );

  test(
    'cancelled transfer keeps original, staging and never confirms or uploads',
    () async {
      gateway.blocked = Completer<void>();
      final running = coordinator.sync('card-1');
      final assertion = expectLater(
        running,
        throwsA(isA<RecordingSyncCancelled>()),
      );
      while (gateway.downloads == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        coordinator.sync('card-1'),
        throwsA(isA<RecordingStorageException>()),
      );
      await coordinator.cancel();
      await assertion;
      expect(await source.exists(), isTrue);
      expect((await repository.load()).index, isEmpty);
      expect(
        await Directory('${directory.path}/staging').list().isEmpty,
        isFalse,
      );
      expect(gateway.confirmations, 0);
      expect(uploader.calls, 0);
      expect(
        (await repository.load()).tasks.every(
          (t) => t.state == RecordingTaskState.cancelled,
        ),
        isTrue,
      );
      final retry = await coordinator.sync('card-1');
      expect(retry.imports.single.event.id, startsWith('record-'));
    },
  );

  test(
    'cancellation racing with ack retains durable audio and receipt',
    () async {
      gateway.onConfirm = (_) async {
        await coordinator.cancel();
      };
      await expectLater(
        coordinator.sync('card-1'),
        throwsA(isA<RecordingSyncCancelled>()),
      );
      final state = await repository.load();
      expect(state.index, hasLength(1));
      expect(
        await repository.verifyRecording(state.index.single.key),
        RecordingIntegrity.valid,
      );
      expect(await source.exists(), isTrue);
    },
  );

  test('unreliable file identity re-downloads before dedup; same-size changed source never overwrites raw', () async {
    gateway.identityReliable = false;
    final first = (await coordinator.sync('card-1')).imports.single;
    await repository.upsertEvent(
      first.event.copyWith(originalTranscript: '保留的旧原文'),
    );
    await source.writeAsBytes(List.generate(128, (i) => 255 - i));
    await expectLater(
      coordinator.sync('card-1'),
      throwsA(isA<RecordingStorageException>()),
    );
    expect(gateway.downloads, 2);
    expect(gateway.confirmations, 1);
    expect(
      (await repository.load()).events.single.originalTranscript,
      '保留的旧原文',
    );
    expect(
      await repository.verifyRecording(first.entry.key),
      RecordingIntegrity.valid,
    );
  });

  test(
    'legacy audio upload retry is explicitly refused with local source intact',
    () async {
      await coordinator.sync('card-1');
      await expectLater(
        coordinator.resumePendingUploads(),
        throwsA(isA<RecordingStorageException>()),
      );
      expect(await source.exists(), isTrue);
      expect(uploader.calls, 0);
    },
  );

  test(
    'empty card without prior imports does not claim recording sync success',
    () async {
      gateway.empty = true;
      await expectLater(
        coordinator.sync('card-1'),
        throwsA(isA<RecordingStorageException>()),
      );
      expect(
        (await repository.load()).metadata['lastSuccessfulSyncAt'],
        isNull,
      );
      expect(uploader.calls, 0);
    },
  );

  test('adapters explicitly requiring Internet still respect policy, not used for BLE', () async {
    gateway.internetRequired = true;
    await expectLater(
      coordinator.sync('card-1'),
      throwsA(isA<RecordingNetworkPolicyException>()),
    );
    expect(log, isEmpty);
    expect(network.calls, 1);
    expect(gateway.confirmations, 0);
  });
}
