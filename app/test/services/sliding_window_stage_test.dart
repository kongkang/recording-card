import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/analysis/analysis_gateway.dart';
import 'package:recording_card/services/analysis/sliding_window_service.dart';
import 'package:recording_card/services/analysis/stage_segmenter.dart';
import 'package:recording_card/services/analysis/stage_summary_service.dart';
import 'package:recording_card/services/transcription/transcription_types.dart';

RawTranscriptChunk chunk(
  String id,
  int ordinal, {
  String recordId = 'r-real',
  int? start,
  String? text,
}) => RawTranscriptChunk(
  id: id,
  recordId: recordId,
  ordinal: ordinal,
  start: Duration(seconds: start ?? ordinal * 15),
  end: Duration(seconds: (start ?? ordinal * 15) + 15),
  rawText: text ?? '原文$id',
);
List<dynamic> windowData(String prompt) =>
    jsonDecode(prompt.split('资料：').last.trim()) as List;
String polishedResponse(List<dynamic> rows, int revision) => jsonEncode({
  'chunks': [
    for (final row in rows)
      {
        'id': row['id'],
        'text': '润色${row['id']} v$revision',
        'uncertainties': [],
      },
  ],
});
Matcher code(String c) =>
    isA<AnalysisException>().having((e) => e.code, 'code', c);

void main() {
  test(
    'A -> AB -> ABC -> BCD; ID revisions update without duplicate raw/event',
    () async {
      final windows = <List<String>>[];
      var calls = 0;
      final service = SlidingWindowService(
        gateway: CallbackAnalysisGateway((prompt, {model}) async {
          final rows = windowData(prompt);
          windows.add([for (final row in rows) row['id'] as String]);
          return polishedResponse(rows, ++calls);
        }),
      );
      for (var i = 0; i < 4; i++) {
        await service.addChunk(chunk('ABCD'[i], i));
      }
      expect(windows, [
        ['A'],
        ['A', 'B'],
        ['A', 'B', 'C'],
        ['B', 'C', 'D'],
      ]);
      expect(service.rawChunks.map((c) => c.rawText), [
        '原文A',
        '原文B',
        '原文C',
        '原文D',
      ]);
      expect(service.polishedById, hasLength(4));
      expect(service.polishedById['A']!.revision, 3);
      expect(service.polishedById['B']!.revision, 3);
      expect(service.polishedById['C']!.revision, 2);
      expect(service.polishedById['D']!.revision, 1);
      expect(() => service.rawChunks.clear(), throwsUnsupportedError);
    },
  );
  test('window does not cross recordings', () async {
    final windows = <List<String>>[];
    final service = SlidingWindowService(
      gateway: CallbackAnalysisGateway((p, {model}) async {
        final rows = windowData(p);
        windows.add([for (final row in rows) row['id'] as String]);
        return polishedResponse(rows, 1);
      }),
    );
    await service.addChunk(chunk('A', 0));
    await service.addChunk(chunk('X', 0, recordId: 'r-other'));
    expect(windows, [
      ['A'],
      ['X'],
    ]);
  });
  test('raw ID cannot be repurposed or reordered', () async {
    final service = SlidingWindowService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => polishedResponse(windowData(p), 1),
      ),
    );
    await service.addChunk(chunk('A', 0));
    await expectLater(
      service.addChunk(chunk('A', 0, text: '偷偷改原文')),
      throwsA(code('raw_immutable')),
    );
    await expectLater(
      service.addChunk(chunk('C', 2)),
      throwsA(code('chunk_order')),
    );
    expect(service.rawChunks, hasLength(1));
  });
  test('response cannot append phantom id or change metadata', () async {
    final service = SlidingWindowService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => jsonEncode({
          'chunks': [
            {'id': 'other', 'text': '假内容', 'uncertainties': []},
          ],
        }),
      ),
    );
    await expectLater(
      service.addChunk(chunk('A', 0)),
      throwsA(code('mapping_invalid')),
    );
    expect(service.rawChunks, hasLength(1));
    expect(service.polishedById, isEmpty);
  });
  test(
    'failed/cancelled cloud retains raw and does not apply late revisions',
    () async {
      final gate = Completer<String>();
      final token = CancellationToken();
      final service = SlidingWindowService(
        gateway: CallbackAnalysisGateway((p, {model}) => gate.future),
      );
      final pending = service.addChunk(chunk('A', 0), cancellation: token);
      final assertion = expectLater(
        pending,
        throwsA(isA<OperationCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      gate.complete(
        polishedResponse([
          {'id': 'A'},
        ], 1),
      );
      await assertion;
      expect(service.rawChunks.single.rawText, '原文A');
      expect(service.polishedById, isEmpty);
    },
  );
  test('model responses apply in serialized input order', () async {
    var active = 0, maxActive = 0;
    final service = SlidingWindowService(
      gateway: CallbackAnalysisGateway((p, {model}) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        return polishedResponse(windowData(p), 1);
      }),
    );
    await Future.wait([
      service.addChunk(chunk('A', 0)),
      service.addChunk(chunk('B', 1)),
      service.addChunk(chunk('C', 2)),
    ]);
    expect(maxActive, 1);
    expect(service.polishedById['A']!.revision, 3);
  });
  test(
    'long silence threshold seals once and stage includes only pending speech',
    () {
      final stages = StageSegmenter(
        recordId: 'r-real',
        silenceThreshold: const Duration(seconds: 30),
      );
      stages.addChunk(chunk('A', 0));
      expect(stages.observeSilence(const Duration(seconds: 44)), isNull);
      final first = stages.observeSilence(const Duration(seconds: 45))!;
      expect(first.id, 'r-real:stage:0');
      expect(first.chunks.map((c) => c.id), ['A']);
      expect(stages.observeSilence(const Duration(seconds: 60)), isNull);
      stages.addChunk(chunk('B', 1, start: 61));
      final second = stages.flush()!;
      expect(second.id, 'r-real:stage:1');
      expect(second.chunks.single.id, 'B');
      expect(stages.flush(), isNull);
    },
  );
  test('gap-triggered stages are not duplicated by later silence ticks', () {
    final stages = StageSegmenter(recordId: 'r-real');
    stages.addChunk(chunk('A', 0));
    final first = stages.addChunk(chunk('B', 1, start: 60))!;
    expect(first.reason, 'long_silence');
    expect(first.end, const Duration(seconds: 15));
    expect(stages.addChunk(chunk('B', 1, start: 60)), isNull);
    expect(
      stages.observeSilence(const Duration(seconds: 105))!.chunks.single.id,
      'B',
    );
    expect(stages.stages, hasLength(2));
  });
  test('stage rejects backwards time and mixed recordings', () {
    final stages = StageSegmenter(recordId: 'r-real');
    stages.addChunk(chunk('A', 0));
    expect(
      () => stages.addChunk(chunk('B', 1, start: 5)),
      throwsA(code('chunk_order')),
    );
    expect(
      () => stages.addChunk(chunk('X', 0, recordId: 'other')),
      throwsA(code('stage_record')),
    );
    expect(
      () => stages.observeSilence(const Duration(seconds: 5)),
      throwsA(code('silence_order')),
    );
  });
  test(
    'stage summary produces stable event, deduplicates and can revise',
    () async {
      var calls = 0;
      final service = StageSummaryService(
        gateway: CallbackAnalysisGateway((p, {model}) async {
          calls++;
          expect(p, contains('原文A'));
          return jsonEncode({
            'overview': '观察结论$calls',
            'points': ['温度变化'],
            'todos': [],
            'sourceChunkIds': ['A'],
            'uncertainties': [],
          });
        }),
      );
      final segmenter = StageSegmenter(recordId: 'r-real');
      segmenter.addChunk(chunk('A', 0));
      final stage = segmenter.flush()!;
      final first = await service.summarize(stage);
      final same = await service.summarize(stage);
      expect(identical(first, same), isTrue);
      expect(calls, 1);
      final revised = await service.summarize(stage, revise: true);
      expect(revised.id, first.id);
      expect(revised.revision, 2);
      expect(service.eventsById, hasLength(1));
    },
  );
  test('stage summary rejects sources outside its original chunks', () async {
    final service = StageSummaryService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => jsonEncode({
          'overview': 'x',
          'points': ['y'],
          'todos': [],
          'sourceChunkIds': ['foreign'],
          'uncertainties': [],
        }),
      ),
    );
    final segmenter = StageSegmenter(recordId: 'r-real');
    segmenter.addChunk(chunk('A', 0));
    await expectLater(
      service.summarize(segmenter.flush()!),
      throwsA(code('source_invalid')),
    );
    expect(service.eventsById, isEmpty);
  });
  test('raw/dlg/event projections expose same stable recording without append on revise', () async {
    final window = SlidingWindowService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => polishedResponse(windowData(p), 1),
      ),
    );
    await window.addChunk(chunk('A', 0));
    final stages = StageSummaryService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => jsonEncode({
          'overview': '阶段',
          'points': ['温控'],
          'todos': [],
          'sourceChunkIds': ['A'],
          'uncertainties': [],
        }),
      ),
    );
    final segmenter = StageSegmenter(recordId: 'r-real');
    segmenter.addChunk(chunk('A', 0));
    final stage = segmenter.flush()!;
    await stages.summarize(stage);
    await stages.summarize(stage, revise: true);
    final projections = TranscriptProjections.forRecord(
      'r-real',
      window,
      stages,
    );
    expect(projections.raw, hasLength(1));
    expect(projections.dlg, hasLength(1));
    expect(projections.events, hasLength(1));
    expect(projections.events.single.revision, 2);
  });
}
