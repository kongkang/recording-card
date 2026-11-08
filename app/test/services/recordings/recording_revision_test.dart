import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';

void main() {
  late Directory temp;
  late Directory data;
  late File source;
  late RecordingRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('recording-revision-test-');
    data = Directory('${temp.path}/data');
    source = await File(
      '${temp.path}/slice.apm',
    ).writeAsBytes(List.generate(128, (i) => i));
    repository = RecordingRepository(directory: data);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<RecordingImportResult> import(String id) => repository.importRecording(
    RecordingImport(sourcePath: source.path, fileId: id),
  );

  test(
    'ABC to BCD window CAS rewrites existing polished/stage projection, preserves canonical raw slices',
    () async {
      final originals = <String>[];
      for (var i = 0; i < 4; i++) {
        final result = await import('slice-$i');
        final text = '原文-$i';
        originals.add(text);
        await repository.putChunk(
          RecordingChunk(
            id: 'chunk-$i',
            recordingId: 'recording-1',
            audioPath: result.entry.audioPath,
            sizeBytes: result.entry.sizeBytes,
            contentHash: result.entry.contentHash,
            startMs: i * 1000,
            endMs: (i + 1) * 1000,
            rawTranscript: text,
          ),
        );
      }
      final stage = RecordEvent(
        id: 'stable-stage-1',
        dayOffset: 0,
        title: '阶段',
        brief: '',
        longText: '',
        time: '',
        dur: '',
        speakers: '',
        mark: '',
        srcMap: '',
        dialog: const [],
        raw: const [],
        recordingId: 'recording-1',
        sourceChunkIds: ['chunk-0', 'chunk-1', 'chunk-2'],
        sourceStartMs: 0,
        sourceEndMs: 3000,
        cleanedTranscript: 'ABC润色',
      );
      await repository.upsertEvent(stage);
      final updated = await repository.updateEventRevision(
        stage.id,
        expectedRevision: 0,
        transform: (event) => event.copyWith(
          sourceChunkIds: ['chunk-1', 'chunk-2', 'chunk-3'],
          sourceStartMs: 1000,
          sourceEndMs: 4000,
          cleanedTranscript: 'BCD润色',
          title: '阶段修订',
        ),
      );
      expect(updated.id, stage.id);
      expect(updated.revision, 1);
      final restarted = await RecordingRepository(directory: data).load();
      expect(
        restarted.events.where((event) => event.id == stage.id),
        hasLength(1),
      );
      expect(restarted.chunks.map((chunk) => chunk.rawTranscript), originals);
      expect(
        restarted.events
            .firstWhere((event) => event.id == stage.id)
            .sourceChunkIds,
        ['chunk-1', 'chunk-2', 'chunk-3'],
      );
      final revisionJobs = await Future.wait([
        repository
            .updateEventRevision(
              stage.id,
              expectedRevision: 1,
              transform: (event) => event.copyWith(title: 'worker-1'),
            )
            .then<Object>((event) => event, onError: (Object error) => error),
        repository
            .updateEventRevision(
              stage.id,
              expectedRevision: 1,
              transform: (event) => event.copyWith(title: 'worker-2'),
            )
            .then<Object>((event) => event, onError: (Object error) => error),
      ]);
      expect(revisionJobs.whereType<RecordEvent>(), hasLength(1));
      expect(revisionJobs.whereType<RecordingRevisionConflict>(), hasLength(1));
    },
  );

  test(
    'mutating a transform input list cannot bypass immutable raw transcript checks',
    () async {
      final result = await import('slice');
      await repository.upsertEvent(
        result.event.copyWith(
          originalTranscript: 'raw',
          raw: [const TurnLine('unknown', 'raw', '0—1')],
        ),
      );
      await expectLater(
        repository.updateEventRevision(
          result.event.id,
          expectedRevision: 0,
          transform: (event) {
            event.raw.clear();
            return event;
          },
        ),
        throwsA(isA<RecordingStorageException>()),
      );
      final current = (await repository.load()).events.single;
      expect(current.raw.single.text, 'raw');
      expect(current.revision, 0);
      current.raw.clear();
      expect((await repository.load()).events.single.raw.single.text, 'raw');
    },
  );

  test(
    'sidecar length and presence failures cannot create complete recording index',
    () async {
      final sidecar = await File(
        '${temp.path}/metadata.txt',
      ).writeAsString('real metadata');
      await expectLater(
        repository.importRecording(
          RecordingImport(
            sourcePath: source.path,
            fileId: 'partial',
            metadataPath: sidecar.path,
            expectedMetadataSize: 1000,
          ),
        ),
        throwsA(isA<RecordingStorageException>()),
      );
      await expectLater(
        repository.importRecording(
          RecordingImport(
            sourcePath: source.path,
            fileId: 'missing',
            expectedMetadataSize: 10,
          ),
        ),
        throwsA(isA<RecordingStorageException>()),
      );
      expect((await repository.load()).index, isEmpty);
      final result = await repository.importRecording(
        RecordingImport(
          sourcePath: source.path,
          fileId: 'valid',
          metadataPath: sidecar.path,
          expectedMetadataSize: await sidecar.length(),
        ),
      );
      expect(await source.exists(), true);
      expect(await sidecar.exists(), true);
      await File(
        result.entry.metadataPath!,
      ).writeAsString('corrupted metadata');
      final restarted = await RecordingRepository(directory: data).load();
      expect(restarted.index.single.integrity, RecordingIntegrity.corrupt);
    },
  );

  test('managed paths rebase after app container relocation', () async {
    final imported = await import('slice');
    await repository.putChunk(
      RecordingChunk(
        id: 'chunk',
        recordingId: 'recording',
        audioPath: imported.entry.audioPath,
        sizeBytes: imported.entry.sizeBytes,
        contentHash: imported.entry.contentHash,
        startMs: 0,
        endMs: 1000,
      ),
    );
    final relocated = Directory('${temp.path}/relocated');
    await for (final entity in data.list(recursive: true)) {
      final path =
          '${relocated.path}/${entity.path.substring(data.path.length + 1)}';
      if (entity is Directory) {
        await Directory(path).create(recursive: true);
      }
      if (entity is File) {
        await File(path).parent.create(recursive: true);
        await entity.copy(path);
      }
    }
    final restored = await RecordingRepository(directory: relocated).load();
    expect(restored.index.single.audioPath, startsWith(relocated.path));
    expect(restored.events.single.audioPath, startsWith(relocated.path));
    expect(restored.chunks.single.audioPath, startsWith(relocated.path));
    expect(restored.index.single.integrity, RecordingIntegrity.valid);
  });
}
