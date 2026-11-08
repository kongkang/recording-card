import '../../core/models/record.dart';
import '../transcription/transcription_types.dart';

class TranscriptMapping {
  final String sourceId;
  final int rawIndex;
  final int cleanedIndex;
  final String range;
  final String rawText;
  final String cleanedText;
  final String inferredSpeaker;
  final double speakerConfidence;
  const TranscriptMapping({
    required this.sourceId,
    required this.rawIndex,
    required this.cleanedIndex,
    required this.range,
    required this.rawText,
    required this.cleanedText,
    required this.inferredSpeaker,
    required this.speakerConfidence,
  });
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'rawIndex': rawIndex,
    'cleanedIndex': cleanedIndex,
    'range': range,
    'rawText': rawText,
    'cleanedText': cleanedText,
    'inferredSpeaker': inferredSpeaker,
    'speakerConfidence': speakerConfidence,
    'identityVerified': false,
  };
}

class TranscriptPhase {
  final String label;
  final List<int> rawIndices;
  final String rationale;
  const TranscriptPhase({
    required this.label,
    required this.rawIndices,
    required this.rationale,
  });
  Map<String, dynamic> toJson() => {
    'label': label,
    'rawIndices': rawIndices,
    'rationale': rationale,
    'inferred': true,
  };
}

class ProcessedTranscript {
  final RecordEvent event;
  final List<TranscriptMapping> mappings;
  final List<TranscriptPhase> phases;
  final List<String> uncertainties;
  const ProcessedTranscript({
    required this.event,
    required this.mappings,
    required this.phases,
    required this.uncertainties,
  });

  /// Persist beside the C-owned RecordEvent JSON, so original mapping and
  /// uncertainty survive restart. This is not a replacement recording index.
  Map<String, dynamic> toJson() => {
    'sourceId': event.id,
    'mappings': [for (final m in mappings) m.toJson()],
    'phases': [for (final p in phases) p.toJson()],
    'uncertainties': uncertainties,
  };
}

/// Constructs raw+initial dialogue with no fabricated identities or text.
/// Relative segment timings are converted to clock ranges using the supplied
/// recording start. Clock times include seconds and roll over midnight.
RecordEvent recordEventFromTranscription({
  required String id,
  required String title,
  required DateTime startedAt,
  required TranscriptionResult transcript,
  int dayOffset = 0,
  String mark = '',
}) {
  if (transcript.audioDuration <= Duration.zero ||
      transcript.segments.isEmpty ||
      transcript.segments.every((s) => s.text.trim().isEmpty)) {
    throw const TranscriptionException('no_speech', '录音未识别到可用语音，不能生成空白记录');
  }
  final raw = <TurnLine>[];
  Duration lastEnd = Duration.zero;
  for (final s in transcript.segments) {
    if (s.start.isNegative ||
        s.end <= s.start ||
        s.end > transcript.audioDuration ||
        s.start < lastEnd) {
      throw const TranscriptionException('source_invalid', 'ASR片段时间无效或重叠');
    }
    lastEnd = s.end;
    raw.add(
      TurnLine(
        '未知',
        s.text,
        '来源 ${_clock(startedAt.add(s.start))}—${_clock(startedAt.add(s.end))}',
      ),
    );
  }
  final text = raw.map((r) => r.text).join('\n');
  return RecordEvent(
    id: id,
    dayOffset: dayOffset,
    title: title,
    brief: text.length > 160 ? '${text.substring(0, 160)}…' : text,
    longText: text,
    time:
        '${startedAt.hour.toString().padLeft(2, '0')}:${startedAt.minute.toString().padLeft(2, '0')}',
    dur:
        '${transcript.audioDuration.inMinutes}分${transcript.audioDuration.inSeconds % 60}秒',
    speakers: '未知（未进行声纹识别）',
    mark: mark,
    srcMap:
        '来源 ${_clock(startedAt)}—${_clock(startedAt.add(transcript.audioDuration))}',
    dialog: List.unmodifiable(raw),
    raw: List.unmodifiable(raw),
  );
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
