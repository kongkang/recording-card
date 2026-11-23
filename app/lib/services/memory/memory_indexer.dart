/// 从已经在本机的总结和记录生成检索片段（支持滑动窗口重叠切块，消除 4,000 字截断盲区）。
library;

import 'dart:math' as math;

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'memory_chunk.dart';

typedef MemorySpeakerResolver = String Function(
  RecordEvent event,
  String rawSpeaker,
);

typedef MemoryTurnSpeakerResolver = String Function(
  RecordEvent event,
  int turnIndex,
  String rawSpeaker,
);

typedef MemoryDeviceLabelResolver = String? Function(RecordEvent event);

class MemoryCorpus {
  const MemoryCorpus({
    required this.events,
    required this.summaries,
    this.speakerResolver,
    this.turnSpeakerResolver,
    this.deviceLabelResolver,
  });

  final List<RecordEvent> events;
  final List<SummaryCard> summaries;
  final MemorySpeakerResolver? speakerResolver;
  final MemoryTurnSpeakerResolver? turnSpeakerResolver;
  final MemoryDeviceLabelResolver? deviceLabelResolver;
}

const int defaultPassageChars = 800;
const int defaultPassageOverlapChars = 120;

List<MemoryChunk> buildMemoryChunks(
  MemoryCorpus corpus, {
  int chunkChars = defaultPassageChars,
  int overlapChars = defaultPassageOverlapChars,
}) {
  final eventsById = {for (final event in corpus.events) event.id: event};
  final chunks = <MemoryChunk>[];

  for (final event in corpus.events) {
    if (event.live) continue;
    final passages = _eventPassages(
      event,
      corpus,
      chunkChars: chunkChars,
      overlapChars: overlapChars,
    );
    if (passages.isEmpty) continue;
    final title = event.title.trim().isEmpty ? '未命名记录' : event.title.trim();
    final timeLabel = event.time.trim();
    for (var i = 0; i < passages.length; i++) {
      final chunkId = passages.length == 1
          ? 'recording:${event.id}'
          : 'recording:${event.id}#$i';
      chunks.add(
        MemoryChunk(
          id: chunkId,
          kind: 'recording',
          sourceId: event.id,
          title: title,
          body: passages[i],
          dayOffset: event.dayOffset,
          timeLabel: timeLabel,
        ),
      );
    }
  }

  for (final summary in corpus.summaries) {
    if (summary.state != SummaryState.done) continue;
    final passages = _summaryPassages(
      summary,
      eventsById,
      corpus,
      chunkChars: chunkChars,
      overlapChars: overlapChars,
    );
    if (passages.isEmpty) continue;
    final title = (summary.title ?? '总结').trim().isEmpty
        ? '总结'
        : summary.title!.trim();
    final dayOffset = _summaryDay(summary, eventsById);
    final timeLabel = summary.time.trim();
    for (var i = 0; i < passages.length; i++) {
      final chunkId = passages.length == 1
          ? 'summary:${summary.id}'
          : 'summary:${summary.id}#$i';
      chunks.add(
        MemoryChunk(
          id: chunkId,
          kind: 'summary',
          sourceId: summary.id,
          title: title,
          body: passages[i],
          dayOffset: dayOffset,
          timeLabel: timeLabel,
        ),
      );
    }
  }
  return chunks;
}

int _summaryDay(SummaryCard summary, Map<String, RecordEvent> eventsById) {
  var best = 1 << 30;
  for (final id in summary.srcIds) {
    final event = eventsById[id];
    if (event != null && event.dayOffset < best) best = event.dayOffset;
  }
  return best == 1 << 30 ? 0 : best;
}

List<String> _eventPassages(
  RecordEvent event,
  MemoryCorpus corpus, {
  required int chunkChars,
  required int overlapChars,
}) {
  final metaLines = <String>[];
  final deviceLabel = corpus.deviceLabelResolver?.call(event)?.trim() ?? '';
  if (deviceLabel.isNotEmpty) {
    metaLines.add('来源设备：$deviceLabel');
  }
  final resolvedSpeakers = _resolveEventSpeakers(event, corpus);
  if (resolvedSpeakers.isNotEmpty) {
    metaLines.add('说话人：$resolvedSpeakers');
  }
  final markText = event.mark.trim();
  if (markText.isNotEmpty) {
    metaLines.add('重点标记：$markText');
  }

  final turns = event.dialog.isNotEmpty ? event.dialog : event.raw;
  final lines = <String>[
    if (event.brief.trim().isNotEmpty) event.brief.trim(),
    if (event.longText.trim().isNotEmpty &&
        event.longText.trim() != event.brief.trim())
      event.longText.trim(),
    for (var i = 0; i < turns.length; i++)
      if (turns[i].text.trim().isNotEmpty)
        '${_resolveTurnSpeaker(event, i, turns[i].spk, corpus)}：${turns[i].text.trim()}',
  ];

  final content = lines.join('\n').trim();
  final metaPrefix = metaLines.join('\n').trim();
  if (content.isEmpty && metaPrefix.isEmpty) return const [];
  if (content.isEmpty) return [metaPrefix];

  final budget = metaPrefix.isEmpty
      ? chunkChars
      : math.max(240, chunkChars - metaPrefix.length - 1);
  final windows = splitOverlappingPassages(
    content,
    maxChars: budget,
    overlapChars: math.min(overlapChars, budget ~/ 2),
  );
  if (metaPrefix.isEmpty) return windows;
  return [for (final w in windows) '$metaPrefix\n$w'];
}

List<String> _summaryPassages(
  SummaryCard summary,
  Map<String, RecordEvent> eventsById,
  MemoryCorpus corpus, {
  required int chunkChars,
  required int overlapChars,
}) {
  final speakerSet = <String>{};
  for (final id in summary.srcIds) {
    final ev = eventsById[id];
    if (ev == null) continue;
    final spk = _resolveEventSpeakers(ev, corpus);
    if (spk.isNotEmpty) {
      for (final part in spk.split('/')) {
        final t = part.trim();
        if (t.isNotEmpty) speakerSet.add(t);
      }
    }
  }

  final metaPrefix = speakerSet.isEmpty ? '' : '说话人：${speakerSet.join(' / ')}';
  final lines = <String>[
    if ((summary.overview ?? '').trim().isNotEmpty) summary.overview!.trim(),
    for (final point in summary.points) ...[
      if (point.title.trim().isNotEmpty) point.title.trim(),
      if (point.detail.trim().isNotEmpty) point.detail.trim(),
    ],
    for (final todo in summary.todos)
      if (todo.trim().isNotEmpty) todo.trim(),
    if (summary.fullText.trim().isNotEmpty) summary.fullText.trim(),
  ];

  final content = lines.join('\n').trim();
  if (content.isEmpty) return const [];
  final budget = metaPrefix.isEmpty
      ? chunkChars
      : math.max(240, chunkChars - metaPrefix.length - 1);
  final windows = splitOverlappingPassages(
    content,
    maxChars: budget,
    overlapChars: math.min(overlapChars, budget ~/ 2),
  );
  if (metaPrefix.isEmpty) return windows;
  return [for (final w in windows) '$metaPrefix\n$w'];
}

String _resolveTurnSpeaker(
  RecordEvent event,
  int turnIndex,
  String rawSpeaker,
  MemoryCorpus corpus,
) {
  final resolved =
      (corpus.turnSpeakerResolver?.call(event, turnIndex, rawSpeaker) ??
              corpus.speakerResolver?.call(event, rawSpeaker) ??
              rawSpeaker)
          .trim();
  return resolved.isEmpty ? '未区分' : resolved;
}

String _resolveEventSpeakers(RecordEvent event, MemoryCorpus corpus) {
  final raw = event.speakers.trim();
  if (raw.isEmpty || raw == '未区分' || raw == '无语音') return '';
  final parts = raw
      .split('/')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty && p != '未区分' && p != '无语音')
      .toList();
  if (parts.isEmpty) return '';
  final resolved = <String>{
    for (final p in parts)
      (corpus.speakerResolver?.call(event, p) ?? p).trim(),
  }..removeWhere((s) => s.isEmpty || s == '未区分' || s == '无语音');
  return resolved.join(' / ');
}

/// 按目标长度与重叠窗口将长文本切分为多段（对齐换行/句末标点，且保护 UTF-16 代理对不断裂）。
List<String> splitOverlappingPassages(
  String text, {
  int maxChars = defaultPassageChars,
  int overlapChars = defaultPassageOverlapChars,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  final safeMax = math.max(120, maxChars);
  final safeOverlap = overlapChars.clamp(0, safeMax ~/ 2);
  if (trimmed.length <= safeMax) return [trimmed];

  final out = <String>[];
  var start = 0;
  while (start < trimmed.length) {
    start = _alignSurrogateStart(trimmed, start);
    if (start >= trimmed.length) break;

    var end = math.min(trimmed.length, start + safeMax);
    if (end < trimmed.length) {
      end = _alignSurrogateEnd(trimmed, end);
      final minBreak = start + (safeMax * 0.65).round();
      final snapped = _findNaturalBreak(trimmed, minBreak, end);
      if (snapped > start) end = snapped;
    }

    final piece = trimmed.substring(start, end).trim();
    if (piece.isNotEmpty) {
      out.add(piece);
    }
    if (end >= trimmed.length) break;

    var nextStart = math.max(start + 1, end - safeOverlap);
    nextStart = _alignSurrogateStart(trimmed, nextStart);
    // 若附近 36 字内有换行，贴齐下一行开头避免把说话人前缀截成半截
    final nl = trimmed.indexOf('\n', nextStart);
    if (nl >= 0 && nl + 1 < end && (nl - nextStart) <= 36) {
      nextStart = nl + 1;
    }
    if (nextStart <= start) {
      nextStart = _alignSurrogateStart(trimmed, start + 1);
    }
    start = nextStart;
  }
  return out;
}

int _findNaturalBreak(String s, int minPos, int maxPos) {
  for (var i = maxPos - 1; i >= minPos; i--) {
    if (s.codeUnitAt(i) == 0x0A) return i + 1;
  }
  const sentenceEnds = '。！？!?；;';
  for (var i = maxPos - 1; i >= minPos; i--) {
    if (sentenceEnds.contains(s[i])) return i + 1;
  }
  return maxPos;
}

int _alignSurrogateStart(String s, int index) {
  if (index <= 0 || index >= s.length) return index;
  final unit = s.codeUnitAt(index);
  if (unit >= 0xDC00 && unit <= 0xDFFF) {
    return index + 1;
  }
  return index;
}

int _alignSurrogateEnd(String s, int index) {
  if (index <= 0 || index >= s.length) return index;
  final prev = s.codeUnitAt(index - 1);
  if (prev >= 0xD800 && prev <= 0xDBFF) {
    return index - 1;
  }
  return index;
}
