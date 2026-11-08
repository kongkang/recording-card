import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/services/analysis/analysis_service.dart';
import 'package:recording_card/services/analysis/stage_summary_service.dart';

import 'analysis_service_test.dart' as f;

StageEvent stage() => StageEvent(
  id: 'stage-original',
  recordId: 'new-record-42',
  revision: 1,
  overview: '已有选中阶段总结',
  points: ['原文实验观察'],
  todos: [],
  sourceChunkIds: ['chunk-a'],
  uncertainties: [],
);
void main() {
  test('selected polished + mapped stage summary enter prompt, sources stay original', () async {
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway((prompt, {model}) async {
        expect(prompt, contains('已有选中阶段总结'));
        expect(prompt, isNot(contains('下周复测')));
        return jsonEncode(f.summaryData());
      }),
    );
    final result = await service.generateSummary(
      [f.event()],
      target: f.card(),
      selectedRawIndices: {
        'new-record-42': [0],
      },
      existingStageSummaries: [
        StageSummaryContext(summary: stage(), chunkRawIndices: {'chunk-a': 0}),
      ],
    );
    expect(result.sources.single.eventId, 'new-record-42');
    expect(result.sources.single.range, '08:10:00—08:10:15');
  });
  test('existing stage mapped outside chosen original rows fails before cloud call', () async {
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => throw StateError('must not call'),
      ),
    );
    await expectLater(
      service.generateSummary(
        [f.event()],
        target: f.card(),
        selectedRawIndices: {
          'new-record-42': [0],
        },
        existingStageSummaries: [
          StageSummaryContext(
            summary: stage(),
            chunkRawIndices: {'chunk-a': 1},
          ),
        ],
      ),
      throwsA(f.analysisCode('source_invalid')),
    );
  });
  test(
    'C event rebuilder is injected and cannot modify original text or mapping',
    () async {
      var invoked = false;
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway(
          (p, {model}) async => jsonEncode({
            'turns': [
              {
                'rawIndex': 0,
                'text': '清洗一',
                'speaker': 'unknown',
                'confidence': 0,
              },
              {
                'rawIndex': 1,
                'text': '清洗二',
                'speaker': 'unknown',
                'confidence': 0,
              },
            ],
            'phases': [],
            'uncertainties': [],
          }),
        ),
        rebuildCleanEvent:
            (
              source, {
              required brief,
              required longText,
              required speakers,
              required dialog,
            }) {
              invoked = true;
              return RecordEvent(
                id: source.id,
                dayOffset: source.dayOffset,
                title: source.title,
                brief: brief,
                longText: longText,
                time: source.time,
                dur: source.dur,
                speakers: speakers,
                mark: source.mark,
                srcMap: source.srcMap,
                dialog: dialog,
                raw: [
                  const TurnLine('unknown', '非法改写原文', '来源 08:10:00—08:10:15'),
                  source.raw[1],
                ],
              );
            },
      );
      await expectLater(
        service.cleanTranscript(f.event(), sliceStages: false),
        throwsA(f.analysisCode('raw_immutable')),
      );
      expect(invoked, isTrue);
    },
  );
}
