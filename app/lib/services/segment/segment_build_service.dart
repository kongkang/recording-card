/// 阶段总结 / 话题分段 —— 把润色后的 turn 按静音/长度切成事件，交给云端总结，
/// 产出 Timeline 上的一张张分段卡。
///
/// 复用 `StagedSummaryCoordinator`：
/// - 相邻 turn 间隔 ≥ [silenceGap]（默认 30s）→ 切一个事件；
/// - [maxSegmentMs] 默认 null（不设单段时长上限；显式传值时才按上限强切）；
/// - 录音结束 → flush 最后一段；
/// - 云端失败 → 用原文兜底（`SegmentRecord.fallback=true`），不丢段。
///
/// 处理过程中同时维护一个 `live` 分段（status=live），供时间轴显示「整理中」；
/// 事件完成后再替换为 closed 卡。
library;

import '../../core/models/recording.dart';
import '../analysis/chat_completion.dart';
import '../analysis/staged_summary.dart';

class SegmentBuildResult {
  const SegmentBuildResult({
    required this.segments,
    required this.fallback,
    this.error,
  });

  final List<SegmentRecord> segments;
  final bool fallback;
  final Object? error;
}

class SegmentBuildService {
  SegmentBuildService({
    required ChatCompletion chat,
    String model = '',
    String Function()? modelResolver,
    this.silenceGap = const Duration(seconds: 30),
    this.maxSegmentMs,
    bool Function()? ready,
  }) : _chat = chat,
       _model = model,
       _modelResolver = modelResolver,
       _ready = ready;

  final ChatCompletion _chat;
  final String _model;
  final String Function()? _modelResolver;
  final bool Function()? _ready;
  final Duration silenceGap;
  final int? maxSegmentMs;

  String get effectiveModel {
    final resolved = _modelResolver?.call().trim() ?? '';
    return resolved.isNotEmpty ? resolved : _model.trim();
  }

  bool get configured =>
      effectiveModel.isNotEmpty && (_ready?.call() ?? true);

  Future<SegmentBuildResult> build(
    RecordingFile file, {
    required Future<void> Function() save,
  }) async {
    final turns = _turnsOf(file);
    if (turns.isEmpty) {
      file.segments = const [];
      await save();
      return const SegmentBuildResult(segments: [], fallback: false);
    }

    final resolvedModel = effectiveModel;
    final summarizer = configured
        ? CloudEventSummarizer(chat: _chat, model: resolvedModel)
        : _UnavailableSummarizer();
    final coordinator = StagedSummaryCoordinator(
      summarizer: summarizer,
      silenceGap: silenceGap,
    );
    final turnById = {for (final t in turns) t.id: t};
    final closed = <SegmentRecord>[];
    var pendingStartMs = turns.first.startMs;
    Object? error;

    for (final turn in turns) {
      // 可选单段时长上限（默认不限时长，仅按 30s 静音与主题分段切分）
      if (maxSegmentMs != null &&
          turn.startMs - pendingStartMs >= maxSegmentMs!) {
        final forced = await coordinator.flush();
        if (forced.finalized != null) {
          closed.add(_toSegment(forced.finalized!, file, turnById, closed.length));
        }
        error ??= forced.error;
        pendingStartMs = turn.startMs;
      }

      final update = await coordinator.add(
        SummarySegmentInput(
          id: turn.id,
          startMs: turn.startMs,
          endMs: turn.endMs,
          cleanText: turn.text,
          speaker: turn.speaker,
        ),
      );
      if (update.finalized != null) {
        closed.add(_toSegment(update.finalized!, file, turnById, closed.length));
        pendingStartMs = turn.startMs;
      }
      error ??= update.error;

      final live = _liveSegment(coordinator.pending, file, turnById, closed.length);
      file.segments = [...closed, ?live];
      await save();
    }

    final last = await coordinator.flush();
    if (last.finalized != null) {
      closed.add(_toSegment(last.finalized!, file, turnById, closed.length));
    }
    error ??= last.error;

    for (var i = 0; i < closed.length; i++) {
      closed[i] = _withIndex(closed[i], i);
    }
    file.segments = closed;
    await save();
    return SegmentBuildResult(
      segments: closed,
      fallback: closed.any((s) => s.fallback),
      error: error,
    );
  }

  // ── 输入投影 ─────────────────────────────────────────────

  List<_TurnView> _turnsOf(RecordingFile file) {
    if (file.turns.isNotEmpty) {
      final sliceByUtterance = {
        for (final u in file.utterances) u.id: u.sliceId,
      };
      return [
        for (final t in file.turns)
          _TurnView(
            id: t.id,
            startMs: t.startMs,
            endMs: t.endMs,
            text: t.text,
            speaker: t.speakerLabel,
            sliceId: t.srcUtteranceIds.isEmpty
                ? null
                : sliceByUtterance[t.srcUtteranceIds.first],
          ),
      ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    }
    return [
      for (final u in file.utterances)
        _TurnView(
          id: u.id,
          startMs: u.startMs,
          endMs: u.endMs,
          text: u.text,
          speaker: u.speakerLabel ?? '未区分',
          sliceId: u.sliceId,
        ),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
  }

  SegmentRecord _toSegment(
    EventSummary event,
    RecordingFile file,
    Map<String, _TurnView> turnById,
    int index,
  ) {
    final eventTurns = [
      for (final id in event.segmentIds)
        if (turnById[id] != null) turnById[id]!,
    ];
    final speakers = <String>{
      for (final t in eventTurns)
        if (t.speaker.trim().isNotEmpty && t.speaker != '未区分') t.speaker,
    };
    final sliceIds = <String>{
      for (final t in eventTurns)
        if (t.sliceId != null) t.sliceId!,
    };
    final overview = event.overview.trim();
    return SegmentRecord(
      id: 'seg-${file.id}-$index',
      sessionId: file.session,
      index: index,
      startAtMs: file.startAtMs + event.startMs,
      endAtMs: file.startAtMs + event.endMs,
      title: event.title.trim().isEmpty ? '录音片段' : event.title.trim(),
      brief: overview.length <= 60 ? overview : '${overview.substring(0, 60)}…',
      longText: overview,
      speakerLabels: speakers.toList()..sort(),
      speakerCount: speakers.length,
      status: SegmentStatus.closed,
      sliceIds: sliceIds.toList()..sort(),
      turnIds: event.segmentIds,
      fallback: event.fallback,
      polishStale: file.polishStale,
    );
  }

  SegmentRecord? _liveSegment(
    List<SummarySegmentInput> pending,
    RecordingFile file,
    Map<String, _TurnView> turnById,
    int index,
  ) {
    if (pending.isEmpty) return null;
    final first = pending.first;
    final last = pending.last;
    final texts = [for (final p in pending) p.cleanText.trim()].where((t) => t.isNotEmpty);
    final flat = texts.join(' ');
    final speakers = <String>{
      for (final p in pending)
        if ((p.speaker ?? '').trim().isNotEmpty && p.speaker != '未区分')
          p.speaker!,
    };
    final sliceIds = <String>{
      for (final p in pending)
        if (turnById[p.id]?.sliceId != null) turnById[p.id]!.sliceId!,
    };
    return SegmentRecord(
      id: 'live-${file.id}',
      sessionId: file.session,
      index: index,
      startAtMs: file.startAtMs + first.startMs,
      endAtMs: file.startAtMs + last.endMs,
      title: '整理中…',
      brief: flat.length <= 60 ? flat : '${flat.substring(0, 60)}…',
      longText: flat,
      speakerLabels: speakers.toList()..sort(),
      speakerCount: speakers.length,
      status: SegmentStatus.live,
      sliceIds: sliceIds.toList()..sort(),
      turnIds: [for (final p in pending) p.id],
    );
  }

  static SegmentRecord _withIndex(SegmentRecord s, int index) => SegmentRecord(
    id: s.id,
    sessionId: s.sessionId,
    index: index,
    startAtMs: s.startAtMs,
    endAtMs: s.endAtMs,
    title: s.title,
    brief: s.brief,
    longText: s.longText,
    speakerLabels: s.speakerLabels,
    speakerCount: s.speakerCount,
    tags: s.tags,
    status: s.status,
    sliceIds: s.sliceIds,
    turnIds: s.turnIds,
    mark: s.mark,
    legacy: s.legacy,
    polishStale: s.polishStale,
    fallback: s.fallback,
  );
}

class _TurnView {
  const _TurnView({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.speaker,
    this.sliceId,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final String speaker;
  final String? sliceId;
}

/// 未配置云端总结时使用：协调器会捕获异常并用原文生成 fallback 事件。
class _UnavailableSummarizer implements EventSummarizer {
  @override
  Future<EventSummary> summarize(
    List<SummarySegmentInput> segments, {
    EventSummary? previousEvent,
  }) async {
    throw const AnalysisException('未配置阶段总结服务');
  }
}
