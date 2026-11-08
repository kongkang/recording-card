import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'asr_model_store.dart';
import 'sherpa_backend.dart';
import 'transcription_types.dart';
export 'asr_model_store.dart';
export 'streaming_audio_slicer.dart';
export 'transcription_types.dart';

class TranscriptionService {
  final AsrModelStore models;
  final TranscriptionBackend _backend;
  final TranscriptionOptions options;
  final int maxQueuedJobs;
  Future<void> _tail = Future.value();
  int _queued = 0;
  bool _closed = false;
  final Set<CancellationToken> _tokens = {};

  TranscriptionService({
    required this.models,
    TranscriptionBackend? backend,
    this.options = const TranscriptionOptions(),
    this.maxQueuedJobs = 4,
  }) : _backend = backend ?? SherpaTranscriptionBackend() {
    options.validate();
    if (maxQueuedJobs < 1) {
      throw ArgumentError('转写队列容量必须为正');
    }
  }

  Future<TranscriptionResult> transcribeFile(
    String path, {
    required AudioFileFormat format,
    int sampleRate = 16000,
    bool allowModelDownload = false,
    CancellationToken? cancellation,
    void Function(TranscriptionProgress)? onProgress,
  }) {
    if (_closed) {
      return Future.error(const TranscriptionException('closed', 'ASR服务已关闭'));
    }
    if (_queued >= maxQueuedJobs) {
      return Future.error(
        const TranscriptionException('queue_full', '本地转写队列已满'),
      );
    }
    final token = cancellation ?? CancellationToken();
    _queued++;
    _tokens.add(token);
    onProgress?.call(const TranscriptionProgress(TranscriptionStage.queued));
    final result = _tail
        .then((_) async {
          token.throwIfCancelled();
          onProgress?.call(
            const TranscriptionProgress(TranscriptionStage.checkingModel),
          );
          final paths = await models.ensureReady(
            allowDownload: allowModelDownload,
            cancellation: token,
          );
          token.throwIfCancelled();
          final result = await _backend.transcribe(
            AudioFileInput(path, format: format, sampleRate: sampleRate),
            paths,
            options: options,
            cancellation: token,
            onProgress: onProgress,
          );
          token.throwIfCancelled();
          onProgress?.call(
            TranscriptionProgress(
              TranscriptionStage.completed,
              completedChunks: result.segments.length,
              totalChunks: result.segments.length,
            ),
          );
          return result;
        })
        .whenComplete(() {
          _queued--;
          _tokens.remove(token);
        });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// A caller persists the immutable source slice through C first. This
  /// method creates only a private inference copy and never deletes source.
  Future<TranscriptionResult> transcribePcmBytes(
    Uint8List pcm16, {
    required Directory temporaryDirectory,
    int sampleRate = 16000,
    CancellationToken? cancellation,
    void Function(TranscriptionProgress)? onProgress,
  }) async {
    if (_closed) {
      throw const TranscriptionException('closed', 'ASR服务已关闭');
    }
    final token = cancellation ?? CancellationToken();
    token.throwIfCancelled();
    if (pcm16.isEmpty || pcm16.length.isOdd) {
      throw const TranscriptionException('audio_corrupt', 'PCM16片段为空或未对齐');
    }
    if (pcm16.length > options.maxFileBytes ||
        !{8000, 16000}.contains(sampleRate)) {
      throw const TranscriptionException('audio_limit', 'PCM片段超过限额或采样率无效');
    }
    await temporaryDirectory.create(recursive: true);
    final jobDir = await temporaryDirectory.createTemp('asr-private-');
    try {
      final file = File('${jobDir.path}/inference.pcm');
      await file.writeAsBytes(pcm16, flush: true);
      token.throwIfCancelled();
      return await transcribeFile(
        file.path,
        format: AudioFileFormat.pcm16,
        sampleRate: sampleRate,
        cancellation: token,
        onProgress: onProgress,
      );
    } finally {
      // This directory was created by this invocation, never caller source.
      if (await jobDir.exists()) {
        await jobDir.delete(recursive: true);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final token in List.of(_tokens)) {
      token.cancel();
    }
    await _tail;
    await _backend.close();
  }
}
