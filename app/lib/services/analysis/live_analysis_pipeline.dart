/// 实时分析管线 —— 原始 ASR 分段 → 增量滑动窗口润色 → 阶段性事件总结。
///
/// 这是「一份数据三个展示位置」的上游编排：原始段保留在调用方，
/// [refined] 是详情页/时间轴的清洗数据，[events] 是时间轴事件分段。
library;

import 'incremental_refine.dart';
import 'staged_summary.dart';

class LiveAnalysisUpdate {
  const LiveAnalysisUpdate({
    required this.refined,
    required this.changed,
    required this.events,
    this.finalizedEvent,
    this.error,
  });

  final List<RefinedSegment> refined;
  final List<RefinedSegment> changed;
  final List<EventSummary> events;
  final EventSummary? finalizedEvent;
  final Object? error;
}

class LiveAnalysisPipeline {
  LiveAnalysisPipeline({
    required this.refine,
    required this.summary,
  });

  final IncrementalRefineCoordinator refine;
  final StagedSummaryCoordinator summary;

  final Set<String> _enteredSummary = {};

  Future<LiveAnalysisUpdate> onRaw(RefineSegmentInput input) async {
    _times[input.id] = (startMs: input.startMs, endMs: input.endMs);
    final update = await refine.add(input);
    Object? error = update.error;
    EventSummary? finalized;

    for (final segment in update.changed) {
      if (!_enteredSummary.add(segment.id)) continue;
      final times = _times[segment.id] ??
          (startMs: input.startMs, endMs: input.endMs);
      final result = await summary.add(SummarySegmentInput(
        id: segment.id,
        startMs: times.startMs,
        endMs: times.endMs,
        cleanText: segment.cleanText,
        speaker: segment.speaker,
      ));
      finalized ??= result.finalized;
      error ??= result.error;
    }

    return LiveAnalysisUpdate(
      refined: update.all,
      changed: update.changed,
      events: summary.events,
      finalizedEvent: finalized,
      error: error,
    );
  }

  Future<LiveAnalysisUpdate> flush() async {
    final result = await summary.flush();
    return LiveAnalysisUpdate(
      refined: refine.segments,
      changed: const [],
      events: summary.events,
      finalizedEvent: result.finalized,
      error: result.error,
    );
  }

  // 当前窗口结果只带 id/文本；时间在首见时记录，后续复用。
  final Map<String, ({int startMs, int endMs})> _times = {};
}
