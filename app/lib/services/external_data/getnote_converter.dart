/// 将得到大脑（Get 笔记）OpenAPI 笔记详情转换为应用内 [RecordingFile] 模型。
library;

import '../../core/models/recording.dart';
import 'getnote_client.dart';

class GetNoteConverter {
  const GetNoteConverter._();

  static final RegExp _explicitSpeakerLine = RegExp(
    r'^(说话人\s*\d+|发言人\s*\d+|Speaker\s*\d+)\s*[：:]\s*(.+)$',
    caseSensitive: false,
  );

  /// 转换单条详情为可落盘的 [RecordingFile]；标题与正文/逐字稿全空时返回 `null`。
  static RecordingFile? toRecordingFile(
    GetNoteDetail detail, {
    GetNoteSummary? fallback,
  }) {
    final noteId = detail.noteId.trim().isNotEmpty
        ? detail.noteId.trim()
        : (fallback?.noteId.trim() ?? '');
    if (noteId.isEmpty) return null;

    final title = detail.title.trim().isNotEmpty
        ? detail.title.trim()
        : (fallback?.title.trim() ?? '');
    final content = detail.content.trim().isNotEmpty
        ? detail.content.trim()
        : (fallback?.content.trim() ?? '');
    final refContent = detail.refContent.trim().isNotEmpty
        ? detail.refContent.trim()
        : (fallback?.refContent.trim() ?? '');
    final rawTranscript = detail.rawTranscript.trim();
    final summaryText = detail.summary.trim();

    if (title.isEmpty &&
        content.isEmpty &&
        refContent.isEmpty &&
        rawTranscript.isEmpty &&
        summaryText.isEmpty) {
      return null;
    }

    final createdAt = detail.createdAt;
    final startAtMs = createdAt.millisecondsSinceEpoch;
    final durationMs = (detail.audioDurationSec * 1000).round().clamp(
      0,
      1 << 30,
    );

    final fullBody = _mergeBody(
      content: content,
      refContent: refContent,
      fallbackText: summaryText.isNotEmpty ? summaryText : rawTranscript,
    );

    final turns = _buildTurns(detail, fullBody);
    final utterances = _buildUtterances(rawTranscript, turns);

    final speakerLabels = <String>[];
    for (final t in turns) {
      final spk = t.speakerLabel.trim();
      if (spk.isEmpty || spk == '未区分' || speakerLabels.contains(spk)) continue;
      speakerLabels.add(spk);
    }

    final resolvedTitle = title.isNotEmpty
        ? title
        : _firstSentence(
            fullBody.isNotEmpty ? fullBody : rawTranscript,
            fallback: '得到大脑笔记',
          );
    final resolvedBrief = _previewText(
      summaryText.isNotEmpty ? summaryText : fullBody,
      fallback: resolvedTitle,
    );
    final resolvedLongText = fullBody.isNotEmpty
        ? fullBody
        : (rawTranscript.isNotEmpty ? rawTranscript : resolvedTitle);

    final tags = <String>[
      for (final t in detail.tags)
        if (t.trim().isNotEmpty) t.trim(),
      for (final t in fallback?.tags ?? const <String>[])
        if (t.trim().isNotEmpty) t.trim(),
      '得到大脑',
    ];
    final uniqueTags = <String>[];
    for (final tag in tags) {
      if (!uniqueTags.contains(tag)) uniqueTags.add(tag);
    }

    final segment = SegmentRecord(
      id: 'getnote-$noteId',
      sessionId: 'getnote',
      index: 0,
      startAtMs: startAtMs,
      endAtMs: startAtMs + durationMs,
      title: resolvedTitle,
      brief: resolvedBrief,
      longText: resolvedLongText,
      speakerLabels: speakerLabels,
      speakerCount: speakerLabels.length,
      tags: uniqueTags,
      status: SegmentStatus.closed,
      sliceIds: const [],
      turnIds: [for (final t in turns) t.id],
      summary: resolvedBrief,
    );

    return RecordingFile(
      deviceName: '${RecordingFile.getNoteDevicePrefix}$noteId',
      session: 'getnote',
      seq: 1,
      startAtMs: startAtMs,
      timeSynced: true,
      apmPath: '',
      wavPath: null,
      durationMs: durationMs,
      stage: RecordingStage.ready,
      slices: const [],
      utterances: utterances,
      turns: turns,
      segments: [segment],
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      sourceDeviceLabel: '得到大脑',
    );
  }

  static String _mergeBody({
    required String content,
    required String refContent,
    required String fallbackText,
  }) {
    if (content.isEmpty && refContent.isEmpty) return fallbackText;
    if (refContent.isEmpty || content.contains(refContent)) return content;
    if (content.isEmpty) return refContent;
    return '$content\n\n$refContent';
  }

  static List<PolishedTurn> _buildTurns(
    GetNoteDetail detail,
    String fullBody,
  ) {
    if (detail.turns.isNotEmpty) {
      return [
        for (var i = 0; i < detail.turns.length; i++)
          () {
            final t = detail.turns[i];
            final start = t.startMs.clamp(0, 1 << 30);
            final end = t.endMs >= start ? t.endMs.clamp(0, 1 << 30) : start;
            return PolishedTurn(
              id: 'gn-t-$i',
              startMs: start,
              endMs: end,
              speakerLabel: t.speaker.trim().isEmpty
                  ? '未区分'
                  : t.speaker.trim(),
              text: t.text.trim(),
              srcUtteranceIds: const [],
            );
          }(),
      ];
    }

    final lines = fullBody
        .split(RegExp(r'\n+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];

    return [
      for (var i = 0; i < lines.length; i++)
        () {
          final line = lines[i];
          final m = _explicitSpeakerLine.firstMatch(line);
          final spk = m != null ? m.group(1)!.trim() : '未区分';
          final text = m != null ? m.group(2)!.trim() : line;
          return PolishedTurn(
            id: 'gn-t-$i',
            startMs: 0,
            endMs: 0,
            speakerLabel: spk.isEmpty ? '未区分' : spk,
            text: text,
            srcUtteranceIds: const [],
          );
        }(),
    ];
  }

  static List<RawUtterance> _buildUtterances(
    String rawTranscript,
    List<PolishedTurn> turns,
  ) {
    if (rawTranscript.isNotEmpty) {
      final paras = rawTranscript
          .split(RegExp(r'\n+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return [
        for (var i = 0; i < paras.length; i++)
          () {
            final line = paras[i];
            final m = _explicitSpeakerLine.firstMatch(line);
            final spk = m != null ? m.group(1)!.trim() : '未区分';
            final text = m != null ? m.group(2)!.trim() : line;
            return RawUtterance(
              id: 'gn-u-$i',
              sliceId: '0001',
              startMs: 0,
              endMs: 0,
              text: text,
              speakerLabel: spk.isEmpty ? '未区分' : spk,
            );
          }(),
      ];
    }

    return [
      for (var i = 0; i < turns.length; i++)
        RawUtterance(
          id: 'gn-u-$i',
          sliceId: '0001',
          startMs: turns[i].startMs,
          endMs: turns[i].endMs,
          text: turns[i].text,
          speakerLabel: turns[i].speakerLabel,
        ),
    ];
  }

  static String _stripLightMarkdown(String input) {
    return input
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll('`', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _firstSentence(String raw, {required String fallback}) {
    final cleaned = _stripLightMarkdown(raw);
    if (cleaned.isEmpty) return fallback;
    final head = cleaned.split(RegExp(r'[。！？!?]')).first.trim();
    final pick = head.isNotEmpty ? head : cleaned;
    return pick.length <= 24 ? pick : '${pick.substring(0, 24)}…';
  }

  static String _previewText(String raw, {required String fallback}) {
    final cleaned = _stripLightMarkdown(raw);
    if (cleaned.isEmpty) return fallback;
    return cleaned.length <= 80 ? cleaned : '${cleaned.substring(0, 80)}…';
  }
}
