/// 从已经在本机的总结和记录生成检索片段。
library;

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'memory_chunk.dart';

class MemoryCorpus {
  const MemoryCorpus({required this.events, required this.summaries});

  final List<RecordEvent> events;
  final List<SummaryCard> summaries;
}

const int _maxBodyChars = 4000;

List<MemoryChunk> buildMemoryChunks(MemoryCorpus corpus) {
  final eventsById = {for (final event in corpus.events) event.id: event};
  final chunks = <MemoryChunk>[];
  for (final event in corpus.events) {
    if (event.live) continue;
    final body = _eventBody(event);
    if (body.isEmpty) continue;
    chunks.add(
      MemoryChunk(
        id: 'recording:${event.id}',
        kind: 'recording',
        sourceId: event.id,
        title: event.title.trim().isEmpty ? '未命名记录' : event.title.trim(),
        body: body,
        dayOffset: event.dayOffset,
        timeLabel: event.time.trim(),
      ),
    );
  }
  for (final summary in corpus.summaries) {
    if (summary.state != SummaryState.done) continue;
    final body = _summaryBody(summary);
    if (body.isEmpty) continue;
    chunks.add(
      MemoryChunk(
        id: 'summary:${summary.id}',
        kind: 'summary',
        sourceId: summary.id,
        title: (summary.title ?? '总结').trim().isEmpty
            ? '总结'
            : summary.title!.trim(),
        body: body,
        dayOffset: _summaryDay(summary, eventsById),
        timeLabel: summary.time.trim(),
      ),
    );
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

String _eventBody(RecordEvent event) {
  final turns = event.dialog.isNotEmpty ? event.dialog : event.raw;
  final lines = <String>[
    if (event.brief.trim().isNotEmpty) event.brief.trim(),
    if (event.longText.trim().isNotEmpty &&
        event.longText.trim() != event.brief.trim())
      event.longText.trim(),
    for (final turn in turns)
      if (turn.text.trim().isNotEmpty) '${turn.spk}：${turn.text.trim()}',
  ];
  return _clip(lines.join('\n'));
}

String _summaryBody(SummaryCard summary) {
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
  return _clip(lines.join('\n'));
}

String _clip(String text) {
  final trimmed = text.trim();
  if (trimmed.length <= _maxBodyChars) return trimmed;
  return trimmed.substring(0, _maxBodyChars);
}
