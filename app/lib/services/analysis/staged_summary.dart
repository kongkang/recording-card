/// 阶段性总结协调器 —— 连续转录按「长静音」切分为事件；
/// 每个事件单独送云端总结，并把上一个事件作为上下文；
/// 云端失败时回退为原文事件并上报 error，绝不丢段。
library;

import 'dart:convert';

import 'chat_completion.dart';
import 'incremental_refine.dart' show AnalysisException;

// 测试与调用方只 import 本文件即可捕获云端异常；复用 incremental_refine 的定义。
export 'incremental_refine.dart' show AnalysisException;

/// 参与阶段总结的清洗后分段。
class SummarySegmentInput {
  const SummarySegmentInput({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.cleanText,
    this.speaker,
  });

  final String id;
  final int startMs;
  final int endMs;

  /// 已清洗的转录文本（优先于原始数据展示）。
  final String cleanText;

  /// 推测说话人；不做真实身份断言。
  final String? speaker;
}

/// 一个事件（一段连续对话）的总结结果。
class EventSummary {
  const EventSummary({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.title,
    required this.overview,
    required this.segmentIds,
    this.fallback = false,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String title;
  final String overview;

  /// 归属本事件的分段 id，按输入顺序，保证可溯源。
  final List<String> segmentIds;

  /// 云端失败时为 true：title / overview 由原文回退生成。
  final bool fallback;
}

abstract class EventSummarizer {
  Future<EventSummary> summarize(
    List<SummarySegmentInput> segments, {
    EventSummary? previousEvent,
  });
}

class StagedSummaryUpdate {
  const StagedSummaryUpdate({
    required this.finalized,
    required this.events,
    this.error,
  });

  /// 本次调用新完成的事件；没有切段或没有待总结分段时为 null。
  final EventSummary? finalized;

  /// 目前已完成的全部事件（按时间顺序，不含尚未切分的待总结段）。
  final List<EventSummary> events;

  /// 本次总结失败时的异常；此时 [finalized] 为回退的原文事件。
  final Object? error;
}

class StagedSummaryCoordinator {
  StagedSummaryCoordinator({
    required this.summarizer,
    this.silenceGap = const Duration(seconds: 3),
    this.maxEventDuration = const Duration(minutes: 5),
  });

  final EventSummarizer summarizer;

  /// 相邻分段间隔达到该静音时长即切分事件。
  final Duration silenceGap;

  /// 没有可用静音检测时的兜底：单事件最长时长，超过就切段，
  /// 避免整段长录音只生成一个事件。
  final Duration maxEventDuration;

  final List<SummarySegmentInput> _pending = [];
  final List<EventSummary> _events = [];
  Future<void> _tail = Future.value();

  List<EventSummary> get events => List.unmodifiable(_events);

  List<SummarySegmentInput> get pending => List.unmodifiable(_pending);

  /// 串行执行：并发 add 也按调用顺序推进切段与总结。
  Future<StagedSummaryUpdate> add(SummarySegmentInput input) {
    final result = _tail.then((_) => _add(input));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 把剩余的待总结分段立即总结（例如录音结束）。
  Future<StagedSummaryUpdate> flush() {
    final result = _tail.then((_) => _flush());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<StagedSummaryUpdate> _add(SummarySegmentInput input) async {
    EventSummary? finalized;
    Object? error;
    if (_pending.isNotEmpty) {
      final gapMs = input.startMs - _pending.last.endMs;
      final pendingMs = _pending.last.endMs - _pending.first.startMs;
      if (gapMs >= silenceGap.inMilliseconds ||
          pendingMs >= maxEventDuration.inMilliseconds) {
        final outcome = await _finalize();
        finalized = outcome.event;
        error = outcome.error;
      }
    }
    _pending.add(input);
    return StagedSummaryUpdate(
      finalized: finalized,
      events: List.unmodifiable(_events),
      error: error,
    );
  }

  Future<StagedSummaryUpdate> _flush() async {
    if (_pending.isEmpty) {
      return StagedSummaryUpdate(
        finalized: null,
        events: List.unmodifiable(_events),
      );
    }
    final outcome = await _finalize();
    return StagedSummaryUpdate(
      finalized: outcome.event,
      events: List.unmodifiable(_events),
      error: outcome.error,
    );
  }

  Future<_FinalizeOutcome> _finalize() async {
    final batch = List<SummarySegmentInput>.unmodifiable(_pending);
    final previousEvent = _events.isEmpty ? null : _events.last;
    EventSummary summary;
    Object? error;
    try {
      summary = _normalize(
        await summarizer.summarize(batch, previousEvent: previousEvent),
        batch,
      );
    } catch (e) {
      error = e;
      summary = _fallbackEvent(batch);
    }
    _pending.clear();
    _events.add(summary);
    return _FinalizeOutcome(event: summary, error: error);
  }

  /// 总结器返回字段缺失时不丢段：用本批分段补齐。
  EventSummary _normalize(
    EventSummary summary,
    List<SummarySegmentInput> batch,
  ) {
    final needsRepair = summary.segmentIds.isEmpty ||
        summary.title.trim().isEmpty ||
        summary.overview.trim().isEmpty;
    if (!needsRepair) return summary;
    final texts = _texts(batch);
    return EventSummary(
      id: summary.id.trim().isEmpty
          ? 'event-${batch.first.id}-${batch.last.id}'
          : summary.id,
      startMs: summary.startMs,
      endMs: summary.endMs,
      title: summary.title.trim().isEmpty
          ? _fallbackTitle(texts)
          : summary.title,
      overview:
          summary.overview.trim().isEmpty ? texts.join(' / ') : summary.overview,
      segmentIds: summary.segmentIds.isEmpty
          ? List.unmodifiable([for (final s in batch) s.id])
          : summary.segmentIds,
      fallback: summary.fallback,
    );
  }

  EventSummary _fallbackEvent(List<SummarySegmentInput> batch) {
    final texts = _texts(batch);
    return EventSummary(
      id: 'event-fallback-${batch.first.id}-${batch.last.id}',
      startMs: batch.first.startMs,
      endMs: batch.last.endMs,
      title: _fallbackTitle(texts),
      overview: texts.join(' / '),
      segmentIds: List.unmodifiable([for (final s in batch) s.id]),
      fallback: true,
    );
  }

  List<String> _texts(List<SummarySegmentInput> batch) => [
        for (final segment in batch)
          if (segment.cleanText.trim().isNotEmpty) segment.cleanText.trim()
      ];

  String _fallbackTitle(List<String> texts) {
    if (texts.isEmpty) return '录音片段';
    final flat = texts.first.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 20) return flat;
    return '${flat.substring(0, 20)}…';
  }
}

class _FinalizeOutcome {
  const _FinalizeOutcome({required this.event, this.error});

  final EventSummary event;
  final Object? error;
}

/// 云端阶段总结：OpenAI-compatible chat，输入 JSON（本批分段 + 上一事件），
/// 输出 {"title": "...", "overview": "..."}；非 JSON 抛 [AnalysisException]。
class CloudEventSummarizer implements EventSummarizer {
  CloudEventSummarizer({
    required this.chat,
    this.model = '',
    this.temperature = 0.1,
  });

  final ChatCompletion chat;
  final String model;
  final double temperature;

  static const _systemPrompt = '''
你是录音整理助手。输入是 JSON：segments 是同一事件的连续转录分段（含 id、时间、说话人、文本），previousEvent 是上一个事件的总结，可用于保持上下文连贯。
请把 segments 归纳为一个事件：title 是简短事件标题（不超过 20 字，不含日期），overview 是 2~4 句中文概述；只依据输入内容，不编造身份或事实。
输出必须是 JSON 对象，形如 {"title": "...", "overview": "..."}；不要输出 Markdown、代码块或解释。''';

  @override
  Future<EventSummary> summarize(
    List<SummarySegmentInput> segments, {
    EventSummary? previousEvent,
  }) async {
    if (segments.isEmpty) {
      throw const AnalysisException('没有可总结的分段');
    }
    final previous = previousEvent;
    final content = await chat.complete(
      [
        const ChatMessage(role: 'system', content: _systemPrompt),
        ChatMessage(
          role: 'user',
          content: jsonEncode({
            if (previous != null)
              'previousEvent': {
                'title': previous.title,
                'overview': previous.overview,
              },
            'segments': [
              for (final segment in segments)
                {
                  'id': segment.id,
                  'startMs': segment.startMs,
                  'endMs': segment.endMs,
                  'speaker': segment.speaker,
                  'text': segment.cleanText,
                }
            ],
          }),
        ),
      ],
      model: model,
      temperature: temperature,
    );
    final parsed = _parse(content);
    return EventSummary(
      id: 'event-${segments.first.id}-${segments.last.id}',
      startMs: segments.first.startMs,
      endMs: segments.last.endMs,
      title: parsed.title,
      overview: parsed.overview,
      segmentIds: List.unmodifiable([for (final s in segments) s.id]),
    );
  }

  ({String title, String overview}) _parse(String content) {
    final start = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const AnalysisException('模型未返回 JSON 对象');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(content.substring(start, end + 1));
    } on FormatException {
      throw const AnalysisException('模型返回的 JSON 无法解析');
    }
    if (decoded is! Map) {
      throw const AnalysisException('模型返回不是 JSON 对象');
    }
    final title = decoded['title'];
    final overview = decoded['overview'];
    if (title is! String || title.trim().isEmpty) {
      throw const AnalysisException('模型返回缺少 title');
    }
    if (overview is! String || overview.trim().isEmpty) {
      throw const AnalysisException('模型返回缺少 overview');
    }
    return (title: title.trim(), overview: overview.trim());
  }
}
