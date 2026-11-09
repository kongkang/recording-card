import 'dart:async';

enum AudioFileFormat { adpcm, pcm16, wav }

enum TranscriptionStage {
  queued,
  checkingModel,
  decodingAudio,
  recognizing,
  completed,
  waitingForModel,
}

class TranscriptionException implements Exception {
  final String code;
  final String message;
  const TranscriptionException(this.code, this.message);
  @override
  String toString() => 'TranscriptionException($code): $message';
}

class OperationCancelled extends TranscriptionException {
  const OperationCancelled() : super('cancelled', '任务已取消');
}

/// Cooperative cancellation. Native decode is not interruptible; the worker
/// frees native handles at the next chunk boundary, not by killing an isolate.
class CancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelled();
  }

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

class AudioFileInput {
  final String path;
  final AudioFileFormat format;

  /// ADPCM/PCM16 are raw 16-bit mono streams. WAV supplies its own header.
  final int sampleRate;
  const AudioFileInput(
    this.path, {
    required this.format,
    this.sampleRate = 16000,
  });
}

class AsrModelPaths {
  final String modelPath;
  final String tokensPath;
  final String? vadPath;
  final String? nativeLibraryPath;
  const AsrModelPaths({
    required this.modelPath,
    required this.tokensPath,
    this.vadPath,
    this.nativeLibraryPath,
  });
}

class TranscriptionOptions {
  final Duration maxDuration;
  final int maxFileBytes;
  final Duration maxChunkDuration;
  final Duration taskTimeout;
  final int numThreads;
  final String language;
  const TranscriptionOptions({
    this.maxDuration = const Duration(minutes: 30),
    this.maxFileBytes = 64 * 1024 * 1024,
    this.maxChunkDuration = const Duration(seconds: 15),
    this.taskTimeout = const Duration(minutes: 30),
    this.numThreads = 2,
    this.language = 'auto',
  });
  void validate() {
    if (maxDuration <= Duration.zero ||
        maxFileBytes <= 0 ||
        maxChunkDuration <= Duration.zero ||
        maxChunkDuration > const Duration(seconds: 30) ||
        taskTimeout <= Duration.zero ||
        numThreads < 1 ||
        numThreads > 4 ||
        !{'auto', 'zh', 'en', 'yue', 'ja', 'ko'}.contains(language)) {
      throw ArgumentError('ASR资源/语言参数无效');
    }
  }
}

class TranscriptionProgress {
  final TranscriptionStage stage;
  final int completedChunks;
  final int? totalChunks;
  final String? errorCode;
  final String? message;
  const TranscriptionProgress(
    this.stage, {
    this.completedChunks = 0,
    this.totalChunks,
    this.errorCode,
    this.message,
  });
}

class TranscriptSegment {
  final int index;

  /// Relative audio offsets; not word-level alignment or speaker diarization.
  final Duration start;
  final Duration end;
  final String text;
  final String? language;
  final bool timingApproximate;

  /// Only populated from actual native output. These are token CTC time
  /// points relative to this input chunk, NOT word [start,end] alignments.
  final List<String> tokens;
  final List<double> tokenTimestamps;
  final String? emotion;
  final String? audioEvent;
  const TranscriptSegment({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    this.language,
    this.timingApproximate = true,
    this.tokens = const [],
    this.tokenTimestamps = const [],
    this.emotion,
    this.audioEvent,
  });
  factory TranscriptSegment.fromJson(Map<String, dynamic> j) =>
      TranscriptSegment(
        index: j['index'] as int,
        start: Duration(
          microseconds: j['startUs'] as int? ?? (j['startMs'] as int) * 1000,
        ),
        end: Duration(
          microseconds: j['endUs'] as int? ?? (j['endMs'] as int) * 1000,
        ),
        text: j['text'] as String,
        language: j['language'] as String?,
        timingApproximate: j['timingApproximate'] != false,
        tokens: List<String>.unmodifiable(
          (j['tokens'] as List? ?? []).cast<String>(),
        ),
        tokenTimestamps: List<double>.unmodifiable(
          (j['tokenTimestamps'] as List? ?? []).cast<num>().map(
            (n) => n.toDouble(),
          ),
        ),
        emotion: j['emotion'] as String?,
        audioEvent: j['audioEvent'] as String?,
      );
  Map<String, dynamic> toJson() => {
    'index': index,
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
    'startUs': start.inMicroseconds,
    'endUs': end.inMicroseconds,
    'text': text,
    'language': language,
    'timingApproximate': timingApproximate,
    'tokens': tokens,
    'tokenTimestamps': tokenTimestamps,
    'emotion': emotion,
    'audioEvent': audioEvent,
    'speakerEmbedding': null,
  };
}

class TranscriptionResult {
  final String text;
  final Duration audioDuration;
  final List<TranscriptSegment> segments;
  final List<String> uncertainties;

  /// Set only by actual configured Silero inference, never ASR emptiness.
  final bool vadVerified;
  final List<List<int>> vadSpeechRangesMs;
  const TranscriptionResult({
    required this.text,
    required this.audioDuration,
    required this.segments,
    this.uncertainties = const [],
    this.vadVerified = false,
    this.vadSpeechRangesMs = const [],
  });
  factory TranscriptionResult.fromJson(Map<String, dynamic> j) =>
      TranscriptionResult(
        text: j['text'] as String,
        audioDuration: Duration(
          microseconds:
              j['durationUs'] as int? ?? (j['durationMs'] as int) * 1000,
        ),
        segments: List.unmodifiable([
          for (final s in j['segments'] as List)
            TranscriptSegment.fromJson((s as Map).cast<String, dynamic>()),
        ]),
        uncertainties: List<String>.unmodifiable(
          (j['uncertainties'] as List? ?? []).cast<String>(),
        ),
        vadVerified: j['vadVerified'] == true,
        vadSpeechRangesMs: [
          for (final span in j['vadSpeechRangesMs'] as List? ?? [])
            (span as List).cast<int>(),
        ],
      );
  Map<String, dynamic> toJson() => {
    'text': text,
    'durationMs': audioDuration.inMilliseconds,
    'durationUs': audioDuration.inMicroseconds,
    'segments': [for (final s in segments) s.toJson()],
    'uncertainties': uncertainties,
    'vadVerified': vadVerified,
    'vadSpeechRangesMs': vadSpeechRangesMs,
  };
}

abstract interface class TranscriptionBackend {
  Future<TranscriptionResult> transcribe(
    AudioFileInput input,
    AsrModelPaths model, {
    required TranscriptionOptions options,
    required CancellationToken cancellation,
    void Function(TranscriptionProgress)? onProgress,
  });
  Future<void> close();
}
