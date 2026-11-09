import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';
import 'package:recording_card/services/settings/settings_repository.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

import 'services/recordings/sync_coordinator_test.dart' as fixture;

class GroupGateway
    implements RecordingDownloadGateway, RecordingSourceCommitGateway {
  GroupGateway(this.files, this.log);
  final List<RemoteRecording> files;
  final List<String> log;
  String? failedFile;
  bool truncateSidecar = false;
  Future<void> Function()? confirming;
  Completer<void>? cleanupGate;
  @override
  bool get usesNetwork => false;
  @override
  Future<void> openSession(String deviceId) async => log.add('open');
  @override
  Future<List<RemoteRecording>> listRecordings(String deviceId) async => files;
  @override
  Future<DownloadedRecording> downloadRecording(
    String deviceId,
    RemoteRecording recording, {
    required String destinationPath,
    required bool allowDestructive,
    RecordingProgress? onProgress,
  }) async {
    expect(allowDestructive, isFalse);
    log.add('download:${recording.fileId}');
    if (recording.fileId == failedFile) {
      throw StateError('later download failed');
    }
    await File(destinationPath).writeAsBytes([1, 2, 3, 4], flush: true);
    final metadata = await File('$destinationPath.txt')
        .writeAsString('raw txt', flush: true);
    final marks = await File('$destinationPath.mrk')
        .writeAsString(truncateSidecar ? '123' : '1\n', flush: true);
    return DownloadedRecording(
      audioPath: destinationPath,
      metadataPath: metadata.path,
      markPath: marks.path,
    );
  }

  @override
  Future<bool> confirmImportedRecording(
    String deviceId,
    RemoteRecording recording,
    RecordingSourceReceipt receipt,
  ) async {
    expect(await File(receipt.audioPath).length(), 4);
    expect(await File(receipt.metadataPath!).readAsString(), 'raw txt');
    expect(await File(receipt.markPath!).readAsString(), '1\n');
    log.add('ack:${recording.fileId}');
    await confirming?.call();
    return false; // source-retained receipt, never delete a source
  }

  @override
  Future<void> closeSession(String deviceId) async {
    log.add('cleanup');
    await cleanupGate?.future;
    log.add('closed');
  }

  @override
  Future<void> cancelActive() async => log.add('cancel-ticket');
}

RemoteRecording remote(
  String id, {
  DateTime? recordedAt,
  Map<String, dynamic> metadata = const {},
}) => RemoteRecording(
  fileId: id,
  name: '$id.wav',
  sizeBytes: 4,
  recordedAt: recordedAt,
  metadata: metadata,
  metadataSizeBytes: 7,
  markSizeBytes: 2,
);

void main() {
  late Directory root;
  late RecordingRepository repository;
  late SettingsRepository settings;
  late List<String> log;
  late fixture.FakeUploader uploader;
  SyncCoordinator? coordinator;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('progressive-sync-');
    repository = RecordingRepository(directory: root);
    settings = SettingsRepository(
      directory: root,
      secureStore: fixture.MemorySecureStore(),
    );
    log = [];
    uploader = fixture.FakeUploader();
  });
  tearDown(() async {
    await coordinator?.dispose();
    await root.delete(recursive: true);
  });

  test('whole group is verified and acknowledged before callback; processing failure cannot abort next download', () async {
    final gateway = GroupGateway([remote('one'), remote('two')], log);
    coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: settings,
      gateway: gateway,
      uploader: uploader,
      onImported: (result) async {
        expect(
          await repository.verifyRecording(result.entry.key),
          RecordingIntegrity.valid,
        );
        final state = await repository.load();
        expect(
          (state.metadata['source-commit:${result.entry.key}'] as Map)['state'],
          'source_retained',
        );
        expect(log.last, 'ack:${result.entry.fileId}');
        log.add('process:${result.entry.fileId}');
        if (result.entry.fileId == 'one') {
          throw const TranscriptionException(
            'model_missing',
            'local ASR missing',
          );
        }
      },
    );
    final result = await coordinator!.sync('card');
    expect(log, [
      'open',
      'download:one',
      'ack:one',
      'process:one',
      'download:two',
      'ack:two',
      'process:two',
      'cleanup',
      'closed',
    ]);
    expect(result.imports, hasLength(2));
    expect(result.isMoveComplete, isFalse);
    expect(result.retainedSourceFileIds, ['one', 'two']);
    expect(
      (await repository.load())
          .metadata['error:import-processing:${result.imports.first.entry.key}'],
      contains('model_missing'),
    );
    expect(uploader.calls, 0);
  });

  test('later failure retains previously published full group', () async {
    final gateway = GroupGateway([remote('one'), remote('two')], log)
      ..failedFile = 'two';
    coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: settings,
      gateway: gateway,
      onImported: (result) => log.add('published:${result.entry.fileId}'),
    );
    await expectLater(coordinator!.sync('card'), throwsStateError);
    final state = await repository.load();
    expect(state.index.single.fileId, 'one');
    expect(
      await repository.verifyRecording(state.index.single.key),
      RecordingIntegrity.valid,
    );
    expect(log.indexOf('published:one'), lessThan(log.indexOf('download:two')));
    expect(log.last, 'closed');
  });

  test('incomplete sidecar never triggers source ack or callback', () async {
    final gateway = GroupGateway([remote('one')], log)..truncateSidecar = true;
    coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: settings,
      gateway: gateway,
      onImported: (_) => log.add('published'),
    );
    await expectLater(
      coordinator!.sync('card'),
      throwsA(isA<RecordingStorageException>()),
    );
    expect((await repository.load()).index, isEmpty);
    expect(log.any((entry) => entry.startsWith('ack:')), isFalse);
    expect(log, isNot(contains('published')));
  });

  test('device start/created timestamps sort newest first; ties and unknowns remain stable', () async {
    final gateway = GroupGateway([
      remote('unknown-a'),
      remote(
        'old-start',
        metadata: {'deviceStartAt': 100, 'deviceCreatedAt': 9999},
      ),
      remote('new-created', metadata: {'deviceCreatedAt': 300}),
      remote('unknown-b'),
      remote(
        'new-recorded',
        recordedAt: DateTime.fromMillisecondsSinceEpoch(400000, isUtc: true),
      ),
      remote('tie-created', metadata: {'deviceCreatedAt': 300}),
    ], log);
    coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: settings,
      gateway: gateway,
    );
    final result = await coordinator!.sync('card');
    expect(result.imports.map((r) => r.entry.fileId), [
      'new-recorded',
      'new-created',
      'tie-created',
      'old-start',
      'unknown-a',
      'unknown-b',
    ]);
    expect(
      result.imports
          .where((r) => r.entry.fileId != 'new-recorded')
          .every((r) => r.entry.recordedAt == null),
      isTrue,
    );
  });

  test('cancel racing with ack still publishes durable file, then drains cleanup without next file', () async {
    final gateway = GroupGateway([remote('one'), remote('two')], log)
      ..cleanupGate = Completer<void>();
    coordinator = SyncCoordinator(
      repository: repository,
      settingsRepository: settings,
      gateway: gateway,
      onImported: (result) => log.add('published:${result.entry.fileId}'),
    );
    gateway.confirming = () => coordinator!.cancel();
    final running = coordinator!.sync('card');
    final assertion = expectLater(
      running,
      throwsA(isA<RecordingSyncCancelled>()),
    );
    while (!log.contains('cleanup')) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(coordinator!.isBusy, isTrue);
    expect(log, contains('published:one'));
    expect(log, isNot(contains('download:two')));
    var drained = false;
    final drain = coordinator!.drained.then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    gateway.cleanupGate!.complete();
    await assertion;
    await drain;
    expect(coordinator!.isBusy, isFalse);
    expect((await repository.load()).index, hasLength(1));
  });
}
