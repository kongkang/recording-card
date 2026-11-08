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
  RecordingNetwork value = RecordingNetwork.wifi;
  @override
  Future<RecordingNetwork> current() async => value;
}

class FakeDownloadGateway implements RecordingDownloadGateway {
  final File source;
  final List<String> log;
  bool failDownload = false;
  bool failOpen = false;
  Completer<void>? blocked;
  bool destructiveRequested = false;
  int downloads = 0;
  bool empty = false;
  FakeDownloadGateway(this.source, this.log);
  @override
  bool get usesNetwork => true;
  @override
  Future<void> openSession(String deviceId) async {
    log.add('open');
    if (failOpen) throw StateError('test open failure');
  }

  @override
  Future<void> closeSession(String deviceId) async {
    log.add('close');
  }

  @override
  Future<List<RemoteRecording>> listRecordings(String deviceId) async {
    log.add('list');
    return empty
        ? []
        : [
            RemoteRecording(
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
    if (failDownload) throw StateError('test device failure');
    final file = await source.copy(destinationPath);
    onProgress?.call(await file.length(), recording.sizeBytes);
    return DownloadedRecording(audioPath: file.path);
  }

  @override
  Future<void> cancelActive() async {
    if (blocked != null && !blocked!.isCompleted) blocked!.complete();
  }
}

class FakeUploader implements RecordingUploader {
  final List<String> log;
  bool configured = true;
  bool fail = false;
  int uploads = 0;
  final keys = <String>[];
  void Function()? duringUpload;
  FakeUploader(this.log);
  @override
  void validateConfiguration() {
    if (!configured) {
      throw const RecordingUploadConfigurationException('test missing config');
    }
  }

  @override
  Future<RecordingUploadReceipt> upload(
    RecordingUploadRequest request, {
    RecordingProgress? onProgress,
  }) async {
    log.add('upload');
    uploads++;
    keys.add(request.idempotencyKey);
    await request.requireNetwork?.call();
    duringUpload?.call();
    await request.requireNetwork?.call();
    if (fail) throw const RecordingUploadException('test service refused');
    onProgress?.call(request.entry.sizeBytes, request.entry.sizeBytes);
    return const RecordingUploadReceipt(cloudFileId: 'accepted-server-file');
  }

  @override
  Future<void> cancelActive() async {}
}

void main() {
  late Directory temp;
  late Directory directory;
  late File source;
  late RecordingRepository repository;
  late SettingsRepository settings;
  late MemorySecureStore secrets;
  late FakeNetwork network;
  late FakeDownloadGateway gateway;
  late FakeUploader uploader;
  late List<String> log;
  late SyncCoordinator coordinator;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sync-coordinator-test-');
    directory = Directory('${temp.path}/data');
    source = await File(
      '${temp.path}/real.apm',
    ).writeAsBytes(List.generate(128, (i) => i));
    repository = RecordingRepository(directory: directory);
    secrets = MemorySecureStore();
    settings = SettingsRepository(directory: directory, secureStore: secrets);
    network = FakeNetwork();
    log = [];
    gateway = FakeDownloadGateway(source, log);
    uploader = FakeUploader(log);
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
    'unconfigured sync refuses before opening device, does not silently become local download',
    () async {
      uploader.configured = false;
      await expectLater(
        coordinator.syncAndUpload('card-1'),
        throwsA(isA<RecordingUploadConfigurationException>()),
      );
      expect(log, isEmpty);
      expect((await repository.load()).index, isEmpty);
      final imports = await coordinator.importFromDevice('card-1');
      expect(imports, hasLength(1));
      expect(uploader.uploads, 0);
      expect((await repository.load()).index.single.cloudFileId, isNull);
      expect(
        (await repository.load()).metadata['lastSuccessfulSyncAt'],
        isNull,
      );
    },
  );

  test(
    'two-phase sync closes download session before upload and only succeeds with accepted receipt',
    () async {
      final updates = <RecordingTask>[];
      final subscription = coordinator.changes.listen(updates.add);
      final result = await coordinator.syncAndUpload('card-1');
      await subscription.cancel();
      expect(log, ['open', 'list', 'download', 'close', 'upload']);
      expect(gateway.destructiveRequested, false);
      expect(result.imports, hasLength(1));
      expect(result.uploaded.single.cloudFileId, 'accepted-server-file');
      expect(await source.exists(), true);
      expect(
        (await repository.load()).metadata['lastSuccessfulSyncAt'],
        isA<String>(),
      );
      expect(
        updates.any((task) => task.state == RecordingTaskState.running),
        true,
      );
      expect(
        (await repository.load()).tasks.every(
          (task) => task.state == RecordingTaskState.succeeded,
        ),
        true,
      );
      await coordinator.syncAndUpload('card-1');
      expect(gateway.downloads, 1);
      expect(uploader.uploads, 1);
    },
  );

  test(
    'every network enum respects wifiOnly; offline and unknown fail closed',
    () async {
      await settings.setSwitch('wifiOnlySync', true);
      for (final kind in RecordingNetwork.values.where(
        (value) => value != RecordingNetwork.wifi,
      )) {
        network.value = kind;
        await expectLater(
          coordinator.syncAndUpload('card-1'),
          throwsA(isA<RecordingNetworkPolicyException>()),
        );
      }
      expect(log, isEmpty);
      await settings.setSwitch('wifiOnlySync', false);
      network.value = RecordingNetwork.mobile;
      expect(
        (await coordinator.syncAndUpload('card-1')).uploaded,
        hasLength(1),
      );
    },
  );

  test(
    'network changing away from Wi-Fi aborts upload rather than recording success',
    () async {
      await settings.setSwitch('wifiOnlySync', true);
      uploader.duringUpload = () {
        network.value = RecordingNetwork.mobile;
      };
      await expectLater(
        coordinator.syncAndUpload('card-1'),
        throwsA(isA<RecordingNetworkPolicyException>()),
      );
      final state = await repository.load();
      expect(state.index.single.cloudFileId, isNull);
      expect(state.metadata['lastSuccessfulSyncAt'], isNull);
      expect(
        state.tasks.where((task) => task.kind == 'upload').single.state,
        RecordingTaskState.failed,
      );
      expect(await source.exists(), true);
    },
  );

  test(
    'upload rejection remains pending and explicit restart retry uses same idempotency key without device',
    () async {
      uploader.fail = true;
      await expectLater(
        coordinator.syncAndUpload('card-1'),
        throwsA(isA<RecordingUploadException>()),
      );
      expect((await repository.load()).index.single.cloudFileId, isNull);
      final originalKey = uploader.keys.single;
      final restarted = RecordingRepository(directory: directory);
      final retry = SyncCoordinator(
        repository: restarted,
        settingsRepository: settings,
        uploader: uploader,
        networkPolicy: RecordingNetworkPolicy(probe: network),
      );
      uploader.fail = false;
      final result = await retry.resumePendingUploads(deviceId: 'card-1');
      expect(result.single.cloudFileId, 'accepted-server-file');
      expect(uploader.keys.last, originalKey);
      expect(gateway.downloads, 1);
      expect(
        (await restarted.load()).tasks
            .where((task) => task.kind == 'upload')
            .single
            .attempts,
        2,
      );
      await retry.dispose();
    },
  );

  test(
    'failed open and failed download always close session; no successful index/upload',
    () async {
      gateway.failOpen = true;
      await expectLater(coordinator.syncAndUpload('card-1'), throwsStateError);
      expect(log, ['open', 'close']);
      gateway.failOpen = false;
      gateway.failDownload = true;
      await expectLater(coordinator.syncAndUpload('card-1'), throwsStateError);
      expect(log.last, 'close');
      expect((await repository.load()).index, isEmpty);
      expect(uploader.uploads, 0);
    },
  );

  test(
    'cancellation stops upload and marks tasks cancelled without deleting source',
    () async {
      gateway.blocked = Completer<void>();
      final running = coordinator.syncAndUpload('card-1');
      final assertion = expectLater(
        running,
        throwsA(isA<RecordingSyncCancelled>()),
      );
      while (gateway.downloads == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await expectLater(
        coordinator.syncAndUpload('card-1'),
        throwsA(isA<RecordingStorageException>()),
      );
      await coordinator.cancel();
      await assertion;
      expect(uploader.uploads, 0);
      expect(
        (await repository.load()).tasks.any(
          (task) => task.state == RecordingTaskState.cancelled,
        ),
        true,
      );
      expect(await source.exists(), true);
      expect(log.last, 'close');
    },
  );

  test(
    'empty remote and no pending local upload does not report sync success',
    () async {
      gateway.empty = true;
      await expectLater(
        coordinator.syncAndUpload('card-1'),
        throwsA(isA<RecordingStorageException>()),
      );
      expect(uploader.uploads, 0);
      expect(
        (await repository.load()).metadata['lastSuccessfulSyncAt'],
        isNull,
      );
    },
  );
}
