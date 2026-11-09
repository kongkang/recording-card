import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_decoder.dart';
import 'transcription_types.dart';

/// One job owns all native handles inside a worker isolate. No native pointers
/// cross isolates. Cancellation/timeout is cooperative at bounded chunk
/// boundaries, and the serial lane is retained until all native handles free.
class SherpaTranscriptionBackend implements TranscriptionBackend {
  bool _closed = false;
  final Set<CancellationToken> _active = {};
  final Set<Future<void>> _drains = {};

  @override
  Future<TranscriptionResult> transcribe(
    AudioFileInput input,
    AsrModelPaths model, {
    required TranscriptionOptions options,
    required CancellationToken cancellation,
    void Function(TranscriptionProgress)? onProgress,
  }) async {
    if (_closed) {
      throw const TranscriptionException('closed', 'ASR服务已关闭');
    }
    options.validate();
    cancellation.throwIfCancelled();
    final responses = ReceivePort();
    final completed = Completer<TranscriptionResult>();
    final drained = Completer<void>();
    _active.add(cancellation);
    _drains.add(drained.future);
    SendPort? commands;
    var timedOut = false;
    void cancel() => commands?.send('cancel');
    cancellation.addListener(cancel);
    final timer = Timer(options.taskTimeout, () {
      timedOut = true;
      cancel();
    });
    late StreamSubscription<dynamic> messages;
    messages = responses.listen((value) {
      // Results, uncaught errors and exit share one mailbox, so the terminal
      // result sent by worker cannot be overtaken by a separate exit port.
      if (value == null) {
        if (!completed.isCompleted) {
          completed.completeError(
            const TranscriptionException('asr_native', '本地识别worker未返回结果'),
          );
        }
        if (!drained.isCompleted) {
          drained.complete();
        }
        return;
      }
      if (value is List) {
        if (!completed.isCompleted) {
          completed.completeError(
            const TranscriptionException('asr_native', '本地识别worker异常退出'),
          );
        }
        return;
      }
      if (value is SendPort) {
        commands = value;
        if (cancellation.isCancelled || timedOut) {
          cancel();
        }
        return;
      }
      final m = (value as Map).cast<String, dynamic>();
      if (m['type'] == 'progress') {
        onProgress?.call(
          TranscriptionProgress(
            TranscriptionStage.values.byName(m['stage'] as String),
            completedChunks: m['completed'] as int? ?? 0,
            totalChunks: m['total'] as int?,
          ),
        );
      } else if (m['type'] == 'result' && !completed.isCompleted) {
        if (timedOut) {
          completed.completeError(
            const TranscriptionException('asr_timeout', '本地转写超时，原生资源已清理'),
          );
        } else if (cancellation.isCancelled) {
          completed.completeError(const OperationCancelled());
        } else {
          completed.complete(
            TranscriptionResult(
              text: m['text'] as String,
              audioDuration: Duration(microseconds: m['durationUs'] as int),
              segments: [
                for (final item in m['segments'] as List)
                  TranscriptSegment(
                    index: item['index'] as int,
                    start: Duration(microseconds: item['startUs'] as int),
                    end: Duration(microseconds: item['endUs'] as int),
                    text: item['text'] as String,
                    language: item['language'] as String?,
                    tokens: List<String>.unmodifiable(item['tokens'] as List),
                    tokenTimestamps: List<double>.unmodifiable(
                      (item['timestamps'] as List).cast<num>().map(
                        (n) => n.toDouble(),
                      ),
                    ),
                    emotion: item['emotion'] as String?,
                    audioEvent: item['event'] as String?,
                  ),
              ],
              uncertainties: (m['uncertainties'] as List).cast<String>(),
              vadVerified: m['vadVerified'] == true,
              vadSpeechRangesMs: [
                for (final span in m['vadSpeechRangesMs'] as List)
                  (span as List).cast<int>(),
              ],
            ),
          );
        }
      } else if (m['type'] == 'error' && !completed.isCompleted) {
        completed.completeError(
          timedOut
              ? const TranscriptionException(
                  'asr_timeout',
                  '本地转写超时，等待原生句柄释放后退出',
                )
              : cancellation.isCancelled
              ? const OperationCancelled()
              : TranscriptionException(
                  m['code'] as String,
                  m['message'] as String,
                ),
        );
      }
    });
    try {
      await Isolate.spawn(
        _worker,
        <String, Object?>{
          'port': responses.sendPort,
          'path': input.path,
          'format': input.format.name,
          'rate': input.sampleRate,
          'model': model.modelPath,
          'tokens': model.tokensPath,
          'vad': model.vadPath,
          'library': model.nativeLibraryPath,
          'maxDurationUs': options.maxDuration.inMicroseconds,
          'maxFileBytes': options.maxFileBytes,
          'chunkUs': options.maxChunkDuration.inMicroseconds,
          'threads': options.numThreads,
          'language': options.language,
        },
        onError: responses.sendPort,
        onExit: responses.sendPort,
        errorsAreFatal: true,
        debugName: 'recording-card-sensevoice',
      );
      // Await native cleanup even if worker has already sent a terminal error.
      TranscriptionResult? result;
      Object? error;
      StackTrace? stack;
      try {
        result = await completed.future;
      } catch (e, s) {
        error = e;
        stack = s;
      }
      await drained.future;
      if (error != null) {
        Error.throwWithStackTrace(error, stack!);
      }
      return result!;
    } finally {
      timer.cancel();
      cancellation.removeListener(cancel);
      _active.remove(cancellation);
      _drains.remove(drained.future);
      if (!drained.isCompleted) {
        drained.complete();
      }
      await messages.cancel();
      responses.close();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final token in List.of(_active)) {
      token.cancel();
    }
    await Future.wait(List.of(_drains));
  }
}

Future<void> _worker(Map<String, Object?> message) async {
  final port = message['port'] as SendPort;
  final commands = ReceivePort();
  var cancelled = false;
  commands.listen((m) {
    if (m == 'cancel') cancelled = true;
  });
  port.send(commands.sendPort);
  void check() {
    if (cancelled) throw const OperationCancelled();
  }

  void progress(TranscriptionStage stage, {int completed = 0, int? total}) =>
      port.send({
        'type': 'progress',
        'stage': stage.name,
        'completed': completed,
        'total': total,
      });
  sherpa.OfflineRecognizer? recognizer;
  try {
    // Yield to receive cancellation before heavyweight IO/model load.
    await Future<void>.delayed(Duration.zero);
    check();
    progress(TranscriptionStage.decodingAudio);
    final options = TranscriptionOptions(
      maxDuration: Duration(microseconds: message['maxDurationUs'] as int),
      maxFileBytes: message['maxFileBytes'] as int,
      maxChunkDuration: Duration(microseconds: message['chunkUs'] as int),
      numThreads: message['threads'] as int,
      language: message['language'] as String,
    );
    final audio = AudioDecoder.forLocalModels(
      AudioDecoder.readFile(
        AudioFileInput(
          message['path'] as String,
          format: AudioFileFormat.values.byName(message['format'] as String),
          sampleRate: message['rate'] as int,
        ),
        options,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    check();
    sherpa.initBindings(message['library'] as String?);
    final spans = await _spans(
      audio,
      message['vad'] as String?,
      options,
      check,
    );
    // Only actual Silero inference may establish silence. An empty speech
    // plan needs no ASR model allocation and must not run ASR on silence.
    if (spans.isNotEmpty) {
      recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: message['model'] as String,
              language: options.language == 'auto' ? '' : options.language,
              useInverseTextNormalization: false,
            ),
            tokens: message['tokens'] as String,
            numThreads: options.numThreads,
            provider: 'cpu',
            debug: false,
          ),
        ),
      );
    }
    final segments = <Map<String, Object?>>[];
    for (var i = 0; i < spans.length; i++) {
      await Future<void>.delayed(Duration.zero);
      check();
      final span = spans[i];
      final stream = recognizer!.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.sublistView(audio.samples, span.$1, span.$2),
          sampleRate: audio.sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        segments.add({
          'index': i,
          'startUs': span.$1 * 1000000 ~/ audio.sampleRate,
          'endUs': span.$2 * 1000000 ~/ audio.sampleRate,
          'text': result.text,
          'language': result.lang.isEmpty ? null : result.lang,
          'tokens': result.tokens,
          'timestamps': result.timestamps,
          'emotion': result.emotion.isEmpty ? null : result.emotion,
          'event': result.event.isEmpty ? null : result.event,
        });
      } finally {
        stream.free();
      }
      progress(
        TranscriptionStage.recognizing,
        completed: i + 1,
        total: spans.length,
      );
    }
    await Future<void>.delayed(Duration.zero);
    check();
    // Keep raw chunk output, including possible hard-boundary duplication. Do
    // not guess alignment or silently remove content from uncertain ASR text.
    final text = segments
        .map((s) => (s['text'] as String).trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
    recognizer?.free();
    recognizer = null;
    port.send({
      'type': 'result',
      'text': text,
      'durationUs': audio.duration.inMicroseconds,
      'segments': segments,
      'vadVerified': message['vad'] != null,
      'vadSpeechRangesMs': [
        for (final span in spans)
          [
            span.$1 * 1000 ~/ audio.sampleRate,
            span.$2 * 1000 ~/ audio.sampleRate,
          ],
      ],
      'uncertainties': [
        '时间为音频切片范围，并非逐字对齐；SenseVoice不提供说话人身份。',
        if (message['vad'] == null) '未配置VAD：按固定时长切片，边界语句可能不完整。',
      ],
    });
  } catch (e) {
    port.send({
      'type': 'error',
      'code': e is TranscriptionException ? e.code : 'asr_native',
      'message': e is TranscriptionException
          ? e.message
          : '本地模型加载/识别失败，请检查模型与原生库配置',
    });
  } finally {
    recognizer?.free();
    commands.close();
  }
}

Future<List<(int, int)>> _spans(
  DecodedAudio audio,
  String? vadPath,
  TranscriptionOptions options,
  void Function() check,
) async {
  final limit = math.max(
    1,
    options.maxChunkDuration.inMicroseconds * audio.sampleRate ~/ 1000000,
  );
  final regions = <(int, int)>[];
  if (vadPath == null) {
    regions.add((0, audio.samples.length));
  } else {
    if (audio.sampleRate != 16000) {
      throw const TranscriptionException('audio_rate', '固定Silero模型需要16kHz推理输入');
    }
    const windowSize = 512;
    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          windowSize: windowSize,
          threshold: 0.5,
          minSilenceDuration: 0.4,
          minSpeechDuration: 0.25,
          maxSpeechDuration: options.maxChunkDuration.inMilliseconds / 1000,
        ),
        sampleRate: audio.sampleRate,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    void drain() {
      while (!vad.isEmpty()) {
        final segment = vad.front();
        final padding = audio.sampleRate ~/ 5;
        final start = math.max(0, segment.start - padding);
        final end = math.min(
          audio.samples.length,
          segment.start + segment.samples.length + padding,
        );
        if (end > start) {
          if (regions.isNotEmpty && start <= regions.last.$2) {
            final previous = regions.removeLast();
            regions.add((previous.$1, math.max(previous.$2, end)));
          } else {
            regions.add((start, end));
          }
        }
        vad.pop();
      }
    }

    try {
      for (
        var offset = 0;
        offset < audio.samples.length;
        offset += windowSize
      ) {
        if (offset % (windowSize * 64) == 0) {
          await Future<void>.delayed(Duration.zero);
          check();
        }
        final end = math.min(offset + windowSize, audio.samples.length);
        final window = end - offset == windowSize
            ? Float32List.sublistView(audio.samples, offset, end)
            : (Float32List(windowSize)
                ..setRange(0, end - offset, audio.samples, offset));
        vad.acceptWaveform(window);
        drain();
      }
      vad.flush();
      drain();
    } finally {
      vad.free();
    }
  }
  return [
    for (final region in regions)
      for (var start = region.$1; start < region.$2; start += limit)
        (start, math.min(region.$2, start + limit)),
  ];
}
