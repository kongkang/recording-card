// 实时分析管线验收（TDD）—— 原始分段进入滑动窗口润色，润色结果再进入
// 阶段性总结；两段失败都上报且不丢段。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/analysis/incremental_refine.dart';
import 'package:recording_card/services/analysis/live_analysis_pipeline.dart';
import 'package:recording_card/services/analysis/staged_summary.dart';

RefineSegmentInput _raw(String id, int start, String text) =>
    RefineSegmentInput(
      id: id,
      startMs: start,
      endMs: start + 1000,
      rawText: text,
      speaker: 'A',
    );

class _Refiner implements SegmentRefiner {
  Object? error;

  @override
  Future<List<RefinedSegment>> refine(List<RefineSegmentInput> window) async {
    final failure = error;
    if (failure != null) throw failure;
    return [
      for (final s in window)
        RefinedSegment(
            id: s.id, cleanText: 'clean:${s.rawText}', speaker: s.speaker),
    ];
  }
}

class _Summarizer implements EventSummarizer {
  final List<List<String>> calls = [];

  @override
  Future<EventSummary> summarize(
    List<SummarySegmentInput> segments, {
    EventSummary? previousEvent,
  }) async {
    calls.add([for (final s in segments) s.id]);
    return EventSummary(
      id: 'e${calls.length}',
      startMs: segments.first.startMs,
      endMs: segments.last.endMs,
      title: '事件 ${calls.length}',
      overview: segments.map((s) => s.cleanText).join(' / '),
      segmentIds: [for (final s in segments) s.id],
    );
  }
}

void main() {
  test('原始段 → 润色 → 长静音切段 → 事件总结', () async {
    final summarizer = _Summarizer();
    final pipeline = LiveAnalysisPipeline(
      refine: IncrementalRefineCoordinator(refiner: _Refiner()),
      summary: StagedSummaryCoordinator(
        summarizer: summarizer,
        silenceGap: const Duration(seconds: 3),
      ),
    );

    final a = await pipeline.onRaw(_raw('a', 0, 'A'));
    expect(a.refined.single.cleanText, 'clean:A');
    expect(a.finalizedEvent, isNull);

    await pipeline.onRaw(_raw('b', 1200, 'B'));
    final c = await pipeline.onRaw(_raw('c', 9000, 'C'));

    expect(c.finalizedEvent?.segmentIds, ['a', 'b']);
    expect(c.events, hasLength(1));
    expect(c.finalizedEvent!.overview, contains('clean:A'));

    final flushed = await pipeline.flush();
    expect(flushed.finalizedEvent?.segmentIds, ['c']);
    expect(flushed.events, hasLength(2));
  });

  test('润色失败：新段以原文进入总结，error 上报', () async {
    final refiner = _Refiner();
    final pipeline = LiveAnalysisPipeline(
      refine: IncrementalRefineCoordinator(refiner: refiner),
      summary: StagedSummaryCoordinator(summarizer: _Summarizer()),
    );
    refiner.error = Exception('cloud down');
    final update = await pipeline.onRaw(_raw('a', 0, '原文 A'));

    expect(update.error, isNotNull);
    expect(update.refined.single.cleanText, '原文 A');
  });

  test('同一段多次 changed 不重复进入总结', () async {
    final summarizer = _Summarizer();
    final pipeline = LiveAnalysisPipeline(
      refine: IncrementalRefineCoordinator(refiner: _Refiner()),
      summary: StagedSummaryCoordinator(
        summarizer: summarizer,
        silenceGap: const Duration(seconds: 3),
      ),
    );
    await pipeline.onRaw(_raw('a', 0, 'A'));
    await pipeline.onRaw(_raw('b', 1200, 'B'));
    await pipeline.onRaw(_raw('c', 2400, 'C'));
    final flushed = await pipeline.flush();
    expect(flushed.finalizedEvent!.segmentIds, ['a', 'b', 'c']);
    expect(summarizer.calls, [
      ['a', 'b', 'c']
    ]);
  });
}
