import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/services/analysis/analysis_service.dart';
import 'package:recording_card/services/analysis/sliding_window_service.dart';
import 'package:recording_card/services/analysis/stage_segmenter.dart';
import 'package:recording_card/services/analysis/stage_summary_service.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';
import 'analysis_service_test.dart' as a;
import 'transcription_service_test.dart' as t;

class ContractGateway {
  String? requestedModel;
  Future<String> complete(String prompt, {String? model}) async {
    requestedModel = model;
    return jsonEncode(a.summaryData());
  }
}

void main() {
  test(
    'A-compatible direct facade adapter works and passes authorized model',
    () async {
      final gateway = ContractGateway();
      final service = AnalysisService(
        gateway: gateway,
        model: 'authorized-test-model',
      );
      await service.generateSummary([a.event()], target: a.card());
      expect(gateway.requestedModel, 'authorized-test-model');
    },
  );
  test(
    'real native metadata is deep immutable in raw chunk and retains microseconds',
    () {
      final tokens = ['x'], stamps = [0.2];
      final segment = TranscriptSegment(
        index: 0,
        start: const Duration(microseconds: 1),
        end: const Duration(microseconds: 999),
        text: 'x',
        tokens: tokens,
        tokenTimestamps: stamps,
        emotion: '<|NEUTRAL|>',
      );
      final chunk = RawTranscriptChunk(
        id: 'x',
        recordId: 'r',
        ordinal: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        rawText: 'x',
        segments: [segment],
      );
      tokens[0] = 'tampered';
      stamps[0] = 4;
      expect(chunk.segments.single.tokens, ['x']);
      expect(chunk.segments.single.tokenTimestamps, [0.2]);
      expect(
        () => chunk.segments.single.tokens.add('y'),
        throwsUnsupportedError,
      );
      final restored = RawTranscriptChunk.fromJson(chunk.toJson());
      expect(restored.segments.single.start.inMicroseconds, 1);
      expect(restored.segments.single.end.inMicroseconds, 999);
    },
  );
  test(
    'sliding snapshot restore preserves revisions without making model request',
    () async {
      var calls = 0;
      final gateway = CallbackAnalysisGateway((p, {model}) async {
        calls++;
        return jsonEncode({
          'chunks': [
            {'id': 'x', 'text': 'clean', 'uncertainties': []},
          ],
        });
      });
      final source = SlidingWindowService(gateway: gateway);
      final chunk = RawTranscriptChunk(
        id: 'x',
        recordId: 'r',
        ordinal: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        rawText: 'raw',
      );
      await source.addChunk(chunk);
      final restored = SlidingWindowService(gateway: gateway)
        ..restoreSnapshot(source.toJson());
      expect(calls, 1);
      expect(restored.polishedById['x']!.revision, 1);
      await restored.addChunk(chunk);
      expect(restored.polishedById['x']!.revision, 2);
      expect(restored.rawChunks, hasLength(1));
      expect(
        () => restored.restoreSnapshot(source.toJson()),
        throwsA(isA<AnalysisException>()),
      );
    },
  );
  test(
    'private PCM inference copy is cleaned, caller source and models stay intact',
    () async {
      final root = await Directory.systemTemp.createTemp('private-asr-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = await t.fixture(root);
      final scratch = Directory('${root.path}/scratch');
      final source = File('${root.path}/source.pcm');
      await source.writeAsBytes([0, 0]);
      final service = TranscriptionService(
        models: store,
        backend: t.FakeBackend(),
      );
      await service.transcribePcmBytes(
        Uint8List.fromList([0, 0]),
        temporaryDirectory: scratch,
      );
      expect(await source.readAsBytes(), [0, 0]);
      expect(scratch.listSync(), isEmpty);
      expect(await File('${root.path}/model.onnx').exists(), isTrue);
      await service.close();
    },
  );
  test(
    'stage summary drops polished text whose context includes another stage',
    () async {
      final raw = RawTranscriptChunk(
        id: 'b',
        recordId: 'r',
        ordinal: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        rawText: '当前阶段',
      );
      final stages = StageSegmenter(recordId: 'r');
      stages.addChunk(raw);
      final stage = stages.flush()!;
      final service = StageSummaryService(
        gateway: CallbackAnalysisGateway((p, {model}) async {
          expect(p, isNot(contains('其他阶段私有内容')));
          return jsonEncode({
            'overview': '当前阶段',
            'points': ['当前信息'],
            'todos': [],
            'sourceChunkIds': ['b'],
            'uncertainties': [],
          });
        }),
      );
      await service.summarize(
        stage,
        polished: {
          'b': PolishedChunk(
            id: 'b',
            recordId: 'r',
            revision: 1,
            text: '其他阶段私有内容',
            contextChunkIds: ['a', 'b'],
            uncertainties: [],
          ),
        },
      );
    },
  );
  test('stage ID cannot be reused for different raw chunks', () async {
    final raw = RawTranscriptChunk(
      id: 'b',
      recordId: 'r',
      ordinal: 0,
      start: Duration.zero,
      end: const Duration(seconds: 1),
      rawText: 'one',
    );
    final segmenter = StageSegmenter(recordId: 'r');
    segmenter.addChunk(raw);
    final stage = segmenter.flush()!;
    final service = StageSummaryService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => jsonEncode({
          'overview': '阶段',
          'points': ['信息'],
          'todos': [],
          'sourceChunkIds': ['b'],
          'uncertainties': [],
        }),
      ),
    );
    await service.summarize(stage);
    final altered = TranscriptStage(
      id: stage.id,
      recordId: 'r',
      chunks: [
        RawTranscriptChunk(
          id: 'c',
          recordId: 'r',
          ordinal: 0,
          start: Duration.zero,
          end: const Duration(seconds: 1),
          rawText: 'two',
        ),
      ],
      start: Duration.zero,
      end: const Duration(seconds: 1),
      reason: stage.reason,
    );
    await expectLater(
      service.summarize(altered),
      throwsA(a.analysisCode('raw_immutable')),
    );
  });
  test(
    'whole-source existing summary is sent as context, new references remain canonical',
    () async {
      final prior = a.card('prior')
        ..state = SummaryState.done
        ..srcIds = ['new-record-42']
        ..overview = '已有真实阶段总结';
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway((p, {model}) async {
          expect(p, contains('已有真实阶段总结'));
          return jsonEncode(a.summaryData());
        }),
      );
      final c = await service.generateSummary(
        [a.event()],
        target: a.card(),
        existingSummaries: [prior],
      );
      expect(c.sources.single.range, '08:10:00—08:10:15');
    },
  );
}
