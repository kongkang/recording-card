import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/recordings_manifest.dart';

RecordingFile _sample({
  String name = '059F19DF.APM',
  int startAtMs = 1730000000000,
  int durationMs = 600000,
  RecordingStage stage = RecordingStage.ready,
}) {
  final segment = SegmentRecord(
    id: 'seg-0',
    sessionId: 'S1',
    index: 0,
    startAtMs: 1730000000000,
    endAtMs: 1730000300000,
    title: '项目讨论',
    brief: '讨论了排期',
    speakerLabels: ['说话人 1'],
    speakerCount: 1,
    status: SegmentStatus.closed,
  );
  return RecordingFile(
    deviceName: name,
    session: 'S1',
    seq: 1,
    startAtMs: startAtMs,
    apmPath: '/tmp/audio.apm',
    wavPath: '/tmp/audio.wav',
    durationMs: durationMs,
    stage: stage,
    createdAtMs: startAtMs + 1000,
    slices: const [
      AudioSlice(
        id: '0001',
        index: 0,
        startMs: 0,
        endMs: 60000,
        wavPath: '/tmp/slice1.wav',
        stage: SliceStage.transcribed,
        silenceAfterMs: 800,
      ),
    ],
    utterances: const [
      RawUtterance(
        id: '0001u0',
        sliceId: '0001',
        startMs: 500,
        endMs: 3000,
        text: '今天讨论排期',
        lang: 'zh',
        emotion: 'NEUTRAL',
        speakerCluster: 0,
        speakerLabel: '说话人 1',
        spkConfidence: 0.91,
      ),
    ],
    turns: const [
      PolishedTurn(
        id: 't0',
        startMs: 500,
        endMs: 3000,
        speakerLabel: '说话人 1',
        text: '今天讨论排期。',
        srcUtteranceIds: ['0001u0'],
      ),
    ],
    segments: [segment],
    polishedThroughSlice: 0,
  );
}

void main() {
  late Directory root;
  late JsonStore json;
  late RecordingStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rc-store-');
    json = JsonStore(store: InMemoryStore());
    store = RecordingStore(root: root, jsonStore: json);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('RecordingStore', () {
    test('保存 → 读取：切片/原始句/润色/分段全部往返', () async {
      final file = _sample();
      await store.save(file);
      final loaded = await store.loadAll(refresh: true);
      expect(loaded.length, 1);
      final r = loaded.single;
      expect(r.deviceName, file.deviceName);
      expect(r.slices.single.id, '0001');
      expect(r.utterances.single.text, '今天讨论排期');
      expect(r.utterances.single.emotion, 'NEUTRAL');
      expect(r.turns.single.speakerLabel, '说话人 1');
      expect(r.segments.single.title, '项目讨论');
      expect(r.polishedThroughSlice, 0);
    });

    test('原子写：不留下 .tmp', () async {
      await store.save(_sample());
      final dir = await store.dirFor('059F19DF.APM');
      final names = await dir.list().map((e) => e.path.split('/').last).toList();
      expect(names.any((n) => n.endsWith('.tmp')), isFalse);
      expect(names, contains('meta.json'));
    });

    test('单条损坏 JSON 被跳过，不影响其它录音', () async {
      await store.save(_sample(name: 'A.APM'));
      final badDir = Directory('${root.path}/BROKEN');
      await badDir.create();
      await File('${badDir.path}/meta.json').writeAsString('{not json');
      final loaded = await store.loadAll(refresh: true);
      expect(loaded.length, 1);
      expect(loaded.single.deviceName, 'A.APM');
    });

    test('v1 迁移：旧 transcript → legacy 分段，幂等', () async {
      final manifest = RecordingsManifest(store: json);
      await manifest.add(
        RecordingItem(
          deviceName: 'OLD.APM',
          apmPath: '/tmp/old.apm',
          wavPath: '/tmp/old.wav',
          transcript: '这是旧版本的转写。第二句。',
          durationSecs: 120,
          recordedAt: DateTime.fromMillisecondsSinceEpoch(1720000000000),
        ),
      );

      final migrated = await store.migrateFromV1(manifest);
      expect(migrated, 1);
      final loaded = await store.loadAll(refresh: true);
      expect(loaded.single.segments.single.legacy, isTrue);
      expect(loaded.single.segments.single.longText, contains('旧版本'));
      expect(loaded.single.turns.single.text, contains('旧版本'));

      final again = await store.migrateFromV1(manifest);
      expect(again, 0);
      expect((await store.loadAll(refresh: true)).length, 1);
    });

    test('清理过期音频：只删 ready 的旧文件，文本保留', () async {
      final old = _sample();
      await store.save(old);
      final dir = await store.dirFor(old.deviceName);
      await Directory('${dir.path}/slices').create(recursive: true);
      final apm = File('${dir.path}/audio.apm');
      final wav = File('${dir.path}/audio.wav');
      final slice = File('${dir.path}/slices/0001.wav');
      for (final f in [apm, wav, slice]) {
        await f.writeAsBytes(List<int>.filled(128, 0));
      }
      // 把 meta 里的路径改到实际文件（apmPath 是 final，重建一份）
      final withPaths = RecordingFile(
        deviceName: old.deviceName,
        session: old.session,
        seq: old.seq,
        startAtMs: old.startAtMs,
        apmPath: apm.path,
        wavPath: wav.path,
        durationMs: old.durationMs,
        stage: old.stage,
        createdAtMs: old.createdAtMs,
        slices: [
          AudioSlice(
            id: '0001',
            index: 0,
            startMs: 0,
            endMs: 60000,
            wavPath: slice.path,
          ),
        ],
        utterances: old.utterances,
        turns: old.turns,
        segments: old.segments,
      );
      await store.save(withPaths);

      final freed = await store.pruneAudio(keep: const Duration(days: 1));
      expect(freed, greaterThan(0));
      expect(await apm.exists(), isFalse);
      expect(await wav.exists(), isFalse);
      expect(await slice.exists(), isFalse);
      expect(await File(await store.metaPath(old.deviceName)).exists(), isTrue);
      expect((await store.loadAll(refresh: true)).single.segments.single.title, '项目讨论');
    });

    test('未完成的录音不清理音频', () async {
      final file = _sample(stage: RecordingStage.transcribing);
      await store.save(file);
      final dir = await store.dirFor(file.deviceName);
      final apm = File('${dir.path}/audio.apm');
      await apm.writeAsBytes([1, 2, 3]);
      final withPath = RecordingFile(
        deviceName: file.deviceName,
        session: file.session,
        seq: file.seq,
        startAtMs: file.startAtMs,
        apmPath: apm.path,
        durationMs: file.durationMs,
        stage: file.stage,
        createdAtMs: file.createdAtMs,
      );
      await store.save(withPath);
      await store.pruneAudio(keep: const Duration(days: 1));
      expect(await apm.exists(), isTrue);
    });
  });
}
