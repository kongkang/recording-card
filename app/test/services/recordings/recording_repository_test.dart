import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';

RecordEvent record(String id, {String title = '录音'}) => RecordEvent(
  id: id,
  dayOffset: -2,
  title: title,
  brief: '',
  longText: '',
  time: '12:00',
  dur: '1分',
  speakers: '',
  mark: '',
  srcMap: '',
  dialog: const [],
  raw: const [],
);

void main() {
  late Directory temp;
  late Directory data;
  late File source;
  late RecordingRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('recording-repo-test-');
    data = Directory('${temp.path}/data');
    source = await File('${temp.path}/sample.apm')
        .writeAsBytes(List.generate(128, (i) => i % 256));
    repository = RecordingRepository(directory: data);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<RecordingImportResult> import({
    String id = 'session-1:sequence-1',
  }) async => repository.importRecording(
    RecordingImport(
      sourcePath: source.path,
      fileId: id,
      deviceId: 'card-1',
      expectedSize: await source.length(),
      recordedAt: DateTime.parse('2026-11-08T04:00:00Z'),
      durationMs: 1000,
      marks: const [RecordMark(offsetMs: 500, label: '重要')],
    ),
  );

  test(
    'old constructor remains compatible and full record JSON round trips',
    () {
      final event = record('a').copyWith(
        audioPath: '/tmp/audio.apm',
        fileId: 'f',
        deviceId: 'card',
        recordedAt: DateTime.parse('2026-11-06T04:00:00Z'),
        endedAt: DateTime.parse('2026-11-06T04:01:00Z'),
        importedAt: DateTime.parse('2026-11-08T04:01:00Z'),
        durationMs: 60000,
        transcript: '清洗后',
        originalTranscript: '呃原文',
        cleanedTranscript: '清洗后',
        dialog: const [TurnLine('A?', '内容', '0—1000', startMs: 0, endMs: 1000)],
        raw: const [TurnLine('unknown', '呃原文', '0—1000')],
        marks: const [RecordMark(offsetMs: 250)],
        status: 'ready',
        transcriptionStatus: 'succeeded',
        taskId: 't',
        error: 'old error',
        recordingId: 'r',
        sourceChunkIds: ['c'],
        sourceStartMs: 0,
        sourceEndMs: 1000,
        revision: 2,
      );
      final restored = RecordEvent.fromJson(
        jsonDecode(jsonEncode(event.toJson())) as Map<String, dynamic>,
      );
      expect(restored.toJson(), event.toJson());
      expect(restored.dayOffsetAt(DateTime(2026, 11, 8)), 2);
      expect(record('legacy').dayOffsetAt(DateTime(2026, 11, 8)), -2);
      expect(restored.copyWith(error: null, transcript: null).error, isNull);
      expect(
        RecordEvent.fromJson(record('legacy').toJson()).status,
        'imported',
      );
      expect(() => RecordEvent.fromJson({'id': ''}), throwsFormatException);
    },
  );

  test('imports real bytes, records true timestamps, preserves source, deduplicates concurrent imports', () async {
    final results = await Future.wait([import(), import()]);
    expect(results.where((result) => result.duplicate).length, 1);
    final loaded = await repository.load();
    expect(loaded.events, hasLength(1));
    expect(loaded.index, hasLength(1));
    expect(
      await File(loaded.index.single.audioPath).readAsBytes(),
      await source.readAsBytes(),
    );
    expect(await source.exists(), isTrue);
    expect(
      loaded.events.single.recordedAt,
      DateTime.parse('2026-11-08T04:00:00Z'),
    );
    expect(
      loaded.events.single.endedAt,
      DateTime.parse('2026-11-08T04:00:01Z'),
    );
    expect(loaded.events.single.marks.single.offsetMs, 500);
    expect(loaded.events.single.originalTranscript, isNull);
    final restarted = await RecordingRepository(directory: data).load();
    expect(restarted.events.single.toJson(), loaded.events.single.toJson());
    expect(restarted.index.single.contentHash, loaded.index.single.contentHash);
    final persisted = jsonDecode(
      await File('${data.path}/recordings.json').readAsString(),
    );
    expect(persisted['payload'], isNot(contains(data.path)));
  });

  test('same audio from distinct devices has distinct identity; unknown recording time remains unknown', () async {
    final a = await import();
    final b = await repository.importRecording(
      RecordingImport(
        sourcePath: source.path,
        fileId: a.entry.fileId,
        deviceId: 'card-2',
      ),
    );
    expect(b.entry.key, isNot(a.entry.key));
    expect(b.event.recordedAt, isNull);
    expect(b.event.time, isEmpty);
    expect(b.entry.contentHash, a.entry.contentHash);
  });

  test('half files, empty sources, checksum mismatch and changed stable identities fail without index', () async {
    await expectLater(
      repository.importRecording(
        RecordingImport(
          sourcePath: source.path,
          fileId: 'f',
          expectedSize: 1024,
        ),
      ),
      throwsA(isA<RecordingStorageException>()),
    );
    await expectLater(
      repository.importRecording(
        RecordingImport(
          sourcePath: source.path,
          fileId: 'f',
          expectedSha256: 'bad',
        ),
      ),
      throwsA(isA<RecordingStorageException>()),
    );
    final partial = await File('${temp.path}/sample.apm.part')
        .writeAsBytes([1]);
    await expectLater(
      repository.importRecording(
        RecordingImport(sourcePath: partial.path, fileId: 'f'),
      ),
      throwsA(isA<RecordingStorageException>()),
    );
    final empty = await File('${temp.path}/empty.apm').writeAsBytes([]);
    await expectLater(
      repository.importRecording(
        RecordingImport(sourcePath: empty.path, fileId: 'f'),
      ),
      throwsA(isA<RecordingStorageException>()),
    );
    expect((await repository.load()).index, isEmpty);
    await import();
    await source.writeAsBytes(List.filled(128, 42));
    await expectLater(import(), throwsA(isA<RecordingStorageException>()));
    expect((await repository.load()).index, hasLength(1));
    expect(await source.exists(), isTrue);
  });

  test('events summaries routes todo states and settings metadata survive restart; running tasks become queued', () async {
    final imported = await import();
    final summary =
        SummaryCard(id: 'done', time: '12:01', state: SummaryState.done)
          ..srcIds = [imported.event.id]
          ..title = '总结'
          ..overview = '概览'
          ..todos = ['行动']
          ..points = [
            InfoPoint('点', '细节', [SourceRef(imported.event.id, '录音', '0—1')]),
          ];
    final pending = SummaryCard(id: 'pending', time: '12:02');
    final generating = SummaryCard(
      id: 'generating',
      time: '12:03',
      state: SummaryState.generating,
    )..progress = 25;
    final now = DateTime.now();
    await repository.update(
      (s) => s.copyWith(
        summaries: [summary, pending, generating],
        routes: [
          {'kind': 'summary', 'id': 'done'},
        ],
        todoStates: {'done:0': true},
        settingsMetadata: {'wifiOnlySync': true},
        metadata: {'expanded': imported.event.id},
        tasks: [
          RecordingTask(
            id: 'work',
            kind: 'analysis',
            createdAt: now,
            updatedAt: now,
            state: RecordingTaskState.running,
            progress: .25,
            metadata: {'nextChunk': 2},
          ),
        ],
      ),
    );
    final restarted = await RecordingRepository(directory: data).load();
    expect(restarted.summaries.first.toJson(), summary.toJson());
    expect(restarted.summaries[1].state, SummaryState.pending);
    expect(restarted.summaries[2].state, SummaryState.pending);
    expect(restarted.summaries[2].progress, 0);
    expect(restarted.tasks.single.state, RecordingTaskState.queued);
    expect(restarted.tasks.single.stage, 'interrupted');
    expect(restarted.tasks.single.progress, isNull);
    expect(restarted.tasks.single.metadata['nextChunk'], 2);
    expect(restarted.routes.single['id'], 'done');
    expect(restarted.todoStates['done:0'], true);
    expect(restarted.settingsMetadata['wifiOnlySync'], true);
  });

  test('corrupted main recovers valid backup; corrupted main and backup fail closed', () async {
    await repository.save(
      RecordingSnapshot(events: [record('a', title: 'first')]),
    );
    await repository.save(
      RecordingSnapshot(events: [record('a', title: 'second')]),
    );
    await File('${data.path}/recordings.json').writeAsString('{bad');
    final recovered = RecordingRepository(directory: data);
    expect((await recovered.load()).events.single.title, 'first');
    expect(recovered.diagnostics, isNotEmpty);
    await File('${data.path}/recordings.json').writeAsString('{bad');
    await File('${data.path}/recordings.json.bak').writeAsString('{bad');
    await expectLater(
      RecordingRepository(directory: data).load(),
      throwsA(isA<RepositoryCorruptionException>()),
    );
    expect(await File('${data.path}/recordings.json').readAsString(), '{bad');
  });

  test('uncommitted state and partial staging files are never accepted as recordings', () async {
    await Directory('${data.path}/staging').create(recursive: true);
    await File('${data.path}/staging/unfinished.apm.part').writeAsBytes([1, 2]);
    await File('${data.path}/recordings.json.tmp').writeAsString('{bad');
    expect((await repository.load()).events, isEmpty);
    expect(repository.diagnostics, isNotEmpty);
  });

  test('restart detects same-length audio corruption and explicit reimport repairs without deleting source', () async {
    final imported = await import();
    await File(imported.entry.audioPath)
        .writeAsBytes(List.filled(imported.entry.sizeBytes, 99));
    repository = RecordingRepository(directory: data);
    final state = await repository.load();
    expect(state.index.single.integrity, RecordingIntegrity.corrupt);
    expect(state.events.single.status, 'failed');
    final repaired = await import();
    expect(repaired.duplicate, false);
    expect(
      await repository.verifyRecording(repaired.entry.key),
      RecordingIntegrity.valid,
    );
    expect(await source.exists(), true);
  });

  test('slice raw is write-once; overlapping-window revision updates stable event rather than append', () async {
    final imported = await import();
    var chunk = RecordingChunk(
      id: 'slice-A',
      recordingId: 'continuous-1',
      audioPath: imported.entry.audioPath,
      sizeBytes: imported.entry.sizeBytes,
      contentHash: imported.entry.contentHash,
      startMs: 0,
      endMs: 1000,
      recordedAt: imported.event.recordedAt,
    );
    await repository.putChunk(chunk);
    chunk = chunk.copyWith(rawTranscript: '原始呃转写');
    await repository.putChunk(chunk);
    await repository.putChunk(chunk); // exact duplicate is idempotent
    await expectLater(
      repository.putChunk(chunk.copyWith(rawTranscript: '被云覆盖')),
      throwsA(isA<RecordingStorageException>()),
    );
    final event = imported.event.copyWith(
      originalTranscript: '原始呃转写',
      raw: const [TurnLine('unknown', '原始呃转写', '0—1')],
      recordingId: 'continuous-1',
      sourceChunkIds: ['slice-A'],
      sourceStartMs: 0,
      sourceEndMs: 1000,
    );
    await repository.upsertEvent(event);
    final revision = await repository.updateEventRevision(
      event.id,
      expectedRevision: 0,
      transform: (current) => current.copyWith(
        cleanedTranscript: '润色版',
        dialog: const [TurnLine('A?', '润色版', '0—1')],
      ),
    );
    expect(revision.revision, 1);
    expect(revision.id, event.id);
    await expectLater(
      repository.updateEventRevision(
        event.id,
        expectedRevision: 0,
        transform: (event) => event,
      ),
      throwsA(isA<RecordingRevisionConflict>()),
    );
    await expectLater(
      repository.upsertEvent(revision.copyWith(originalTranscript: '覆盖')),
      throwsA(isA<RecordingStorageException>()),
    );
    await expectLater(
      repository.update((state) => state.copyWith(chunks: [])),
      throwsA(isA<RecordingStorageException>()),
    );
    final restarted = await RecordingRepository(directory: data).load();
    expect(restarted.events, hasLength(1));
    expect(restarted.chunks, hasLength(1));
    expect(restarted.chunks.single.rawTranscript, '原始呃转写');
    expect(restarted.events.single.cleanedTranscript, '润色版');
    expect(restarted.events.single.originalTranscript, '原始呃转写');
    expect(restarted.events.single.revision, 1);
  });

  test(
    'invalid chunk source ranges and secret settings metadata fail explicitly',
    () async {
      final imported = await import();
      await expectLater(
        repository.upsertEvent(
          imported.event.copyWith(
            sourceChunkIds: ['unknown'],
            sourceStartMs: 0,
            sourceEndMs: 1000,
          ),
        ),
        throwsA(isA<RecordingStorageException>()),
      );
      await expectLater(
        repository.update(
          (s) => s.copyWith(settingsMetadata: {'wifiPassword': 'not-allowed'}),
        ),
        throwsA(isA<RecordingStorageException>()),
      );
    },
  );
}
