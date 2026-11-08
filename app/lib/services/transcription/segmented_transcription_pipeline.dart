/// 分段转写管线 —— WAV 按窗口切片 → 逐片 ASR → 滑动窗口润色 →
/// 长静音阶段总结。原始文本按片保留，清洗/说话人由分析层回填。
library;

import 'dart:typed_data';

import '../analysis/incremental_refine.dart';
import '../analysis/live_analysis_pipeline.dart';
import '../analysis/staged_summary.dart';
import '../audio/wav_splitter.dart';
import 'transcription_pipeline.dart';

class SegmentTranscript {
  const SegmentTranscript({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.rawText,
    required this.cleanText,
    this.speaker,
    this.emotion,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String rawText;
  final String cleanText;
  final String? speaker;
  final String? emotion;
}

class SegmentedRecordingResult {
  const SegmentedRecordingResult({
    required this.segments,
    required this.events,
    this.errors = const [],
    this.error,
    this.skipped = false,
  });

  final List<SegmentTranscript> segments;
  final List<EventSummary> events;
  final List<String> errors;
  final Object? error;

  /// 自动转录关闭导致整段未调用 ASR（区别于「调用失败/无内容」）。
  final bool skipped;

  bool get hasContent => segments.isNotEmpty;
}

abstract class SegmentedTranscriber {
  Future<SegmentedRecordingResult> process(
    Uint8List wav, {
    required String recordingId,
    String? language,
  });
}

class SegmentedTranscriptionPipeline implements SegmentedTranscriber {
  SegmentedTranscriptionPipeline({
    required this.splitter,
    required this.transcription,
    required this.analysis,
    this.segment = const Duration(seconds: 30),
  });

  final WavSplitter splitter;
  final TranscriptionPipeline transcription;
  final LiveAnalysisPipeline analysis;
  final Duration segment;

  @override
  Future<SegmentedRecordingResult> process(
    Uint8List wav, {
    required String recordingId,
    String? language,
  }) async {
    final pieces = splitter.split(wav, segment: segment);
    if (pieces.isEmpty) {
      return const SegmentedRecordingResult(segments: [], events: []);
    }

    final rawById = <String, String>{};
    final times = <String, ({int startMs, int endMs})>{};
    final errors = <String>[];
    Object? firstError;
    var refined = <RefinedSegment>[];
    var events = <EventSummary>[];
    var attempted = false;

    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      final id = '$recordingId-$i';
      times[id] = (startMs: piece.startMs, endMs: piece.endMs);
      try {
        final result = await transcription.process(
          piece.bytes,
          language: language,
        );
        if (result == null) continue; // 自动转录关闭
        attempted = true;
        rawById[id] = result.rawText;
        final update = await analysis.onRaw(RefineSegmentInput(
          id: id,
          startMs: piece.startMs,
          endMs: piece.endMs,
          rawText: result.rawText,
        ));
        refined = update.refined;
        events = update.events;
        firstError ??= update.error;
      } catch (e) {
        attempted = true;
        errors.add('$id: $e');
      }
    }

    final flushed = await analysis.flush();
    refined = flushed.refined;
    events = flushed.events;
    firstError ??= flushed.error;

    final segments = <SegmentTranscript>[];
    for (final s in refined) {
      final t = times[s.id];
      if (t == null) continue;
      segments.add(SegmentTranscript(
        id: s.id,
        startMs: t.startMs,
        endMs: t.endMs,
        rawText: rawById[s.id] ?? s.cleanText,
        cleanText: s.cleanText,
        speaker: s.speaker,
        emotion: s.emotion,
      ));
    }

    return SegmentedRecordingResult(
      segments: segments,
      events: events,
      errors: errors,
      error: firstError,
      skipped: !attempted,
    );
  }
}
