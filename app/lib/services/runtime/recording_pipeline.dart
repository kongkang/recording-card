import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/device/card_gateway.dart';
import '../../core/models/record.dart';
import '../../core/store/app_backend.dart';
import '../analysis/analysis_service.dart';
import '../analysis/sliding_window_service.dart';
import '../analysis/stage_segmenter.dart';
import '../analysis/stage_summary_service.dart';
import '../recordings/recording_repository.dart';
import '../transcription/transcription_service.dart';
import 'runtime_config.dart';
import 'private_capture_path.dart';

/// Private, single-writer pipeline. Audio/raw are durable before cloud work.
/// Retry is explicit; a completed subtask is not submitted/billed again.
class RecordingPipeline {
  RecordingPipeline({
    required this.gateway,
    required this.repository,
    required this.asr,
    required this.analysis,
    required this.analysisGateway,
  });
  final CardGateway gateway;
  final RecordingRepository repository;
  final TranscriptionService asr;
  final AnalysisService analysis;
  final Object analysisGateway;
  final _changes = StreamController<List<RecordEvent>>.broadcast();
  Stream<List<RecordEvent>> get changes => _changes.stream;
  RecordingPolicy policy = const RecordingPolicy();
  Future<void> _tail = Future.value();
  String? _deviceId;
  bool _disposed = false;
  bool _suspended = false;
  bool _restored = false;
  final Map<String, SlidingWindowService> _windows = {};
  final Map<String, StageSegmenter> _segments = {};
  final Set<CancellationToken> _tokens = {};
  late final _stageSummaries = StageSummaryService(gateway: analysisGateway);

  /// V1 never opens a realtime audio stream. Kept for old runtime callers.
  String? get captureId => null;
  Future<void> get drained => _tail;

  Future<void> publish() async {
    if (!_disposed) _changes.add((await repository.load()).events);
  }

  Future<void> _serial(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object e) async {
      if (!_isWaiting(e) && e is! OperationCancelled) {
        await reportError('pipeline', e);
      }
    });
    return result;
  }

  static bool _isWaiting(Object error) =>
      error is TranscriptionException &&
      (error.code.startsWith('model_') || error.code == 'queue_full');

  Future<void> reportError(String id, Object error) async {
    await _metadata('error:$id', error.toString());
    if (!_disposed) _changes.addError(StateError(error.toString()));
  }

  Future<void> _metadata(String key, Object? value) => repository
      .update((s) => s.copyWith(metadata: {...s.metadata, key: value}))
      .then((_) {});

  Future<void> _restore() async {
    if (_restored) return;
    final state = await repository.load();
    for (final entry in state.metadata.entries) {
      if (entry.key.startsWith('window:') && entry.value is Map) {
        final id = entry.key.substring(7);
        _windows[id] = SlidingWindowService(gateway: analysisGateway)
          ..restoreSnapshot((entry.value as Map).cast<String, dynamic>());
      }
      if (entry.key.startsWith('segment:') && entry.value is Map) {
        final id = entry.key.substring(8);
        _segments[id] = StageSegmenter(recordId: id, sealSourceGaps: false)
          ..restoreSnapshot((entry.value as Map).cast<String, dynamic>());
      }
    }
    _restored = true;
  }

  /// Settings control local processing only. Recording control belongs to the
  /// explicit device switch; connect/settings must never start or stop hardware.
  Future<void> apply(RecordingPolicy next) async {
    await _applyMarks(next.markImportant);
    policy = next;
  }

  Future<void> _applyMarks(bool enabled) async {
    await repository.update(
      (s) => s.copyWith(
        events: [
          for (final e in s.events)
            e.copyWith(mark: enabled && e.marks.isNotEmpty ? '重要标记' : ''),
        ],
      ),
    );
    await publish();
  }

  Future<void> connected(CardSnapshot snapshot) async {
    _suspended = false;
    _deviceId = snapshot.deviceId;
    await apply(policy);
    if (policy.autoTranscribe) await processPending();
  }

  /// Compatibility guard for old composition roots. V1 is completed-file pull,
  /// not live PCM; no native capture or recording command is sent.
  Future<void> startCapture(String deviceId) async {
    throw const CardGatewayException('file_pull_only', 'V1使用已完成录音文件拉取，不支持实时采集');
  }

  /// V1 has no capture to stop and never stops recording owned by the user.
  Future<void> stopCapture() async {}

  Future<void> disconnected() async {
    _deviceId = null;
  }

  Future<void> suspend() async {
    _suspended = true;
    for (final token in List.of(_tokens)) {
      token.cancel();
    }
    await disconnected();
  }

  Future<void> _receive(
    CardAudioChunk chunk,
    bool infer, {
    bool localOnly = false,
  }) async {
    await _restore();
    final state = await repository.load();
    final existing = state.metadata.values
        .whereType<Map>()
        .where((m) => m['taskId'] == chunk.taskId && m['index'] == chunk.index)
        .firstOrNull;
    if (existing != null) return; // sidecar/event replay is idempotent
    final prior =
        state.metadata.entries
            .where(
              (e) =>
                  e.key.startsWith('audio:') &&
                  e.value is Map &&
                  (e.value as Map)['taskId'] == chunk.taskId,
            )
            .map((e) => (e.value as Map).cast<String, dynamic>())
            .toList()
          ..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
    final previous = prior.lastOrNull;
    // interrupted marks the LAST pre-gap chunk, discontinuous the FIRST after.
    final newEpoch =
        previous != null &&
        (chunk.discontinuous || previous['interrupted'] == true);
    final recordingId = newEpoch
        ? '${chunk.taskId}-epoch-${chunk.index}'
        : previous?['recordingId'] as String? ?? chunk.taskId;
    final capture = state.metadata['capture:${chunk.taskId}'] as Map?;
    final result = await repository.importRecording(
      RecordingImport(
        sourcePath: chunk.path,
        fileId: '${chunk.taskId}:${chunk.index}.wav',
        deviceId: capture?['deviceId'] as String? ?? _deviceId ?? 'unknown',
        title: '录音片段 ${chunk.index}',
        expectedSize: await File(chunk.path).length(),
      ),
    );
    final startMs = chunk.receivedSampleOffset * 1000 ~/ 16000;
    final endMs = (chunk.receivedSampleOffset + chunk.samples) * 1000 ~/ 16000;
    await repository.putChunk(
      RecordingChunk(
        id: result.event.id,
        recordingId: recordingId,
        audioPath: result.entry.audioPath,
        sizeBytes: result.entry.sizeBytes,
        contentHash: result.entry.contentHash,
        startMs: startMs,
        endMs: endMs,
      ),
    );
    await repository.upsertEvent(
      result.event.copyWith(
        recordingId: recordingId,
        sourceStartMs: startMs,
        sourceEndMs: endMs,
      ),
    );
    await _metadata('audio:${result.event.id}', {
      'taskId': chunk.taskId,
      'index': chunk.index,
      'recordingId': recordingId,
      'startMs': startMs,
      'endMs': endMs,
      'discontinuous': chunk.discontinuous,
      'interrupted': chunk.interrupted,
      'isFinal': chunk.isFinal,
      'droppedChunks': chunk.droppedChunks,
      'clock': 'received-relative-not-device-absolute',
    });
    if (newEpoch) {
      final old = previous['recordingId'] as String;
      final stage = _segments[old]?.flush();
      if (_segments[old] != null) {
        await _metadata('segment:$old', _segments[old]!.toJson());
      }
      if (stage != null) await _persistStage(stage, localOnly: localOnly);
    }
    await publish();
    if (infer && !_suspended) {
      final earlierPending = (await repository.load()).events.any(
        (e) =>
            e.recordingId == recordingId &&
            e.sourceStartMs != null &&
            e.sourceStartMs! < startMs &&
            e.originalTranscript == null,
      );
      if (!earlierPending) await _transcribe(result.event);
    }
  }

  /// Import ONLY completed private native sidecars; .part is never audio.
  /// No hardware operation or model call is made by recovery itself.
  Future<void> recoverCaptureFiles() => _serial(_recoverCaptureFiles);

  Future<void> _recoverCaptureFiles({bool localOnly = false}) async {
    final directory = Directory('${repository.directory.path}/capture');
    if (!await directory.exists()) return;
    final chunks = <CardAudioChunk>[];
    await for (final file in directory.list()) {
      if (file is! File ||
          !file.path.endsWith('.json') ||
          file.path.endsWith('.task.json')) {
        continue;
      }
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (json['kind'] != 'audioChunk') continue;
        final chunk = CardAudioChunk.fromJson(json);
        if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(chunk.taskId)) {
          throw const FormatException('Invalid task ID');
        }
        final audio = await resolvePrivateCaptureAudio(
          directory,
          file,
          chunk.path,
        );
        if (await audio.length() != 44 + chunk.samples * 2) {
          throw const FormatException('Incomplete capture WAV');
        }
        chunks.add(CardAudioChunk.fromJson({...json, 'path': audio.path}));
      } catch (e) {
        await reportError('capture-recovery', e);
      }
    }
    chunks.sort(
      (a, b) => a.taskId == b.taskId
          ? a.index.compareTo(b.index)
          : a.taskId.compareTo(b.taskId),
    );
    for (final chunk in chunks) {
      await _receive(chunk, false, localOnly: localOnly);
    }
  }

  Future<void> processPending({bool localOnly = false}) =>
      _serial(() => _processPending(localOnly: localOnly));

  Future<void> _processPending({bool localOnly = false}) async {
    await _restore();
    await _recoverCaptureFiles(localOnly: localOnly);
    final state = await repository.load();
    final blocked = <String>{};
    // A failed update moves an event to the end of the snapshot. Restore source
    // order before retry so overlapping windows remain ABC -> BCD, never ACD.
    final pending = state.events.toList()
      ..sort((a, b) {
        if (a.recordingId != null && a.recordingId == b.recordingId) {
          return (a.sourceStartMs ?? 0).compareTo(b.sourceStartMs ?? 0);
        }
        return (a.importedAt ?? DateTime.utc(1970)).compareTo(
          b.importedAt ?? DateTime.utc(1970),
        );
      });
    for (final event in pending) {
      if (event.recordingId != null && blocked.contains(event.recordingId)) {
        continue;
      }
      if (!policy.autoTranscribe || _suspended) break;
      if (event.audioPath == null) continue;
      final jobs = state.metadata['jobs:${event.id}'] as Map? ?? {};
      final needed =
          event.originalTranscript == null ||
          (event.status == 'imported' &&
              event.transcriptionStatus == 'completed' &&
              event.originalTranscript?.isEmpty == true &&
              state.metadata['asr:${event.id}'] is Map) ||
          event.transcriptionStatus == 'failed' ||
          event.transcriptionStatus == 'analysis_failed' ||
          event.transcriptionStatus == 'cancelled' ||
          (policy.autoClean && jobs['clean'] != true) ||
          (policy.inferSpeakers && jobs['speakers'] != true);
      if (!needed) continue;
      try {
        await _transcribe(event, localOnly: localOnly);
      } catch (_) {
        final latest = (await repository.load()).events.firstWhere(
          (e) => e.id == event.id,
        );
        if (latest.originalTranscript == null && event.recordingId != null) {
          blocked.add(event.recordingId!);
        }
      }
    }
    if (!localOnly && policy.autoClean && !_suspended) await _retryStages();
  }

  Future<void> transcribe(
    RecordEvent event, {
    String? recordingId,
    int startMs = 0,
    int? endMs,
    bool localOnly = false,
  }) => _serial(
    () => _transcribe(
      event,
      recordingId: recordingId,
      startMs: startMs,
      endMs: endMs,
      localOnly: localOnly,
    ),
  );

  Future<void> _transcribe(
    RecordEvent event, {
    String? recordingId,
    int startMs = 0,
    int? endMs,
    bool localOnly = false,
  }) async {
    await _restore();
    final state = await repository.load();
    event = state.events.where((e) => e.id == event.id).firstOrNull ?? event;
    final audio = state.metadata['audio:${event.id}'] as Map?;
    recordingId ??= audio?['recordingId'] as String? ?? event.recordingId;
    startMs =
        (audio?['startMs'] as num?)?.toInt() ?? event.sourceStartMs ?? startMs;
    endMs ??= (audio?['endMs'] as num?)?.toInt() ?? event.sourceEndMs;
    final jobs = Map<String, dynamic>.from(
      state.metadata['jobs:${event.id}'] as Map? ?? {},
    );
    final token = CancellationToken();
    _tokens.add(token);
    final taskId = 'transcription:${event.id}';
    final oldTask = state.tasks.where((t) => t.id == taskId).firstOrNull;
    final now = DateTime.now();
    var task = RecordingTask(
      id: taskId,
      kind: 'transcription',
      deviceId: event.deviceId,
      fileId: event.fileId,
      createdAt: oldTask?.createdAt ?? now,
      updatedAt: now,
      attempts: (oldTask?.attempts ?? 0) + 1,
      state: RecordingTaskState.running,
      stage: event.originalTranscript == null ? 'local_asr' : 'text_analysis',
    );
    try {
      await repository.upsertTask(task);
      token.throwIfCancelled();
      TranscriptionResult transcript;
      final saved = state.metadata['asr:${event.id}'];
      if (saved is Map) {
        transcript = TranscriptionResult.fromJson(
          saved.cast<String, dynamic>(),
        );
      } else {
        if (event.originalTranscript != null) {
          throw StateError('原文已保存但ASR快照缺失，拒绝重推理覆盖原文');
        }
        await repository.upsertEvent(
          event.copyWith(transcriptionStatus: 'running', error: null),
        );
        await publish();
        var path = event.audioPath!;
        final fileId = event.fileId?.toLowerCase() ?? path.toLowerCase();
        var format = fileId.endsWith('.wav') || path.endsWith('.wav')
            ? AudioFileFormat.wav
            : fileId.endsWith('.pcm')
            ? AudioFileFormat.pcm16
            : AudioFileFormat.adpcm;
        if (fileId.endsWith('.apm') || path.endsWith('.apm')) {
          // A private unique directory for each attempt. Never overwrite an
          // existing destination; after success persist exact source+WAV hashes.
          final derived = state.metadata['derived:${event.id}'] as Map?;
          final sourceHash = sha256
              .convert(await File(path).readAsBytes())
              .toString();
          if (derived != null &&
              derived['sourceHash'] == sourceHash &&
              await File(derived['path'] as String).exists() &&
              sha256
                      .convert(
                        await File(derived['path'] as String).readAsBytes(),
                      )
                      .toString() ==
                  derived['wavHash']) {
            path = derived['path'] as String;
          } else {
            final dir = Directory('${repository.directory.path}/derived');
            await dir.create(recursive: true);
            final attempt = await dir.createTemp('convert-');
            path = await gateway.convertAudio(
              path,
              destination: '${attempt.path}/audio.wav',
              format: 'apm',
            );
            await _metadata('derived:${event.id}', {
              'sourceHash': sourceHash,
              'path': path,
              'wavHash': sha256
                  .convert(await File(path).readAsBytes())
                  .toString(),
            });
          }
          format = AudioFileFormat.wav;
        }
        transcript = await asr.transcribeFile(
          path,
          format: format,
          allowModelDownload: !localOnly && RuntimeConfig.allowModelDownload,
          cancellation: token,
        );
        await _metadata('asr:${event.id}', transcript.toJson());
      }
      if (transcript.text.trim().isEmpty) {
        final verifiedSilence =
            transcript.vadVerified && transcript.vadSpeechRangesMs.isEmpty;
        await repository.upsertEvent(
          event.copyWith(
            originalTranscript: transcript.text,
            transcript: transcript.text,
            durationMs: transcript.audioDuration.inMilliseconds,
            transcriptionStatus: verifiedSilence ? 'completed' : 'no_speech',
            status: verifiedSilence ? 'silent' : 'failed',
            brief: verifiedSilence ? '本地转写完成，未检测到有效语音' : '本地转写未识别到可用文本，原始音频已保留',
            dur: '${transcript.audioDuration.inSeconds}s',
            error: verifiedSilence ? null : 'ASR未识别到可用文本；没有VAD静音证据',
          ),
        );
        jobs['clean'] = true;
        jobs['speakers'] = true;
        await _metadata('jobs:${event.id}', jobs);
        if (verifiedSilence && recordingId != null) {
          await observeSilence(
            recordingId,
            Duration(
              milliseconds:
                  endMs ?? startMs + transcript.audioDuration.inMilliseconds,
            ),
            localOnly: localOnly,
          );
        }
        await repository.upsertTask(
          task.copyWith(
            state: verifiedSilence
                ? RecordingTaskState.succeeded
                : RecordingTaskState.failed,
            stage: verifiedSilence ? 'complete' : 'local_asr_no_text',
            progress: 1,
            clearError: verifiedSilence,
            error: verifiedSilence ? null : 'ASR未识别到可用文本；没有VAD静音证据',
          ),
        );
        await publish();
        return;
      }
      if (event.originalTranscript == null) {
        final display = recordEventFromTranscription(
          id: event.id,
          title: event.title,
          startedAt:
              event.recordedAt ??
              DateTime.utc(1970).add(Duration(milliseconds: startMs)),
          transcript: transcript,
        );
        event = event.copyWith(
          brief: display.brief,
          longText: display.longText,
          time: event.recordedAt == null ? '' : display.time,
          dur: display.dur,
          speakers: display.speakers,
          srcMap: display.srcMap,
          dialog: display.dialog,
          raw: display.raw,
          originalTranscript: transcript.text,
          transcript: transcript.text,
          durationMs: transcript.audioDuration.inMilliseconds,
          error: null,
          recordingId: recordingId,
          sourceStartMs: startMs,
          sourceEndMs: endMs,
        );
        await repository.upsertEvent(event);
        final chunk = (await repository.load()).chunks
            .where((c) => c.id == event.id)
            .firstOrNull;
        if (chunk != null) {
          await repository.putChunk(
            chunk.copyWith(rawTranscript: transcript.text),
          );
        }
        await publish();
      }
      event = event.copyWith(
        mark: policy.markImportant && event.marks.isNotEmpty ? '重要标记' : '',
      );
      token.throwIfCancelled();
      if (localOnly) {
        final pendingAnalysis =
            (policy.autoClean && jobs['clean'] != true) ||
            (policy.inferSpeakers && jobs['speakers'] != true);
        await repository.upsertEvent(
          event.copyWith(
            transcriptionStatus: pendingAnalysis
                ? 'analysis_pending'
                : 'completed',
            error: null,
          ),
        );
        await repository.upsertTask(
          task.copyWith(
            state: pendingAnalysis
                ? RecordingTaskState.queued
                : RecordingTaskState.succeeded,
            stage: pendingAnalysis ? 'analysis_pending' : 'complete',
            progress: pendingAnalysis ? null : 1,
            clearProgress: pendingAnalysis,
            clearError: true,
          ),
        );
        await publish();
        return;
      }
      if (transcript.text.trim().isNotEmpty) {
        if (recordingId != null) {
          final rid = recordingId;
          var window = _windows.putIfAbsent(
            rid,
            () => SlidingWindowService(gateway: analysisGateway),
          );
          final old = window.rawChunks
              .where((c) => c.id == event.id)
              .firstOrNull;
          final raw = RawTranscriptChunk(
            id: event.id,
            recordId: recordingId,
            ordinal: old?.ordinal ?? window.rawChunks.length,
            start: Duration(milliseconds: startMs),
            end: Duration(
              milliseconds:
                  endMs ?? startMs + transcript.audioDuration.inMilliseconds,
            ),
            rawText: transcript.text,
            segments: transcript.segments,
          );
          // Persist raw/stage BEFORE any cloud request; retry order must not
          // depend on which model request failed or completed first.
          if (old == null) {
            window = SlidingWindowService(gateway: analysisGateway)
              ..restoreSnapshot({
                'raw': [
                  ...window.rawChunks.map((c) => c.toJson()),
                  raw.toJson(),
                ],
                'polished': window.polishedById.values
                    .map((c) => c.toJson())
                    .toList(),
              });
            _windows[rid] = window;
            await _metadata('window:$rid', window.toJson());
          }
          final segment = _segments.putIfAbsent(
            rid,
            () => StageSegmenter(recordId: rid, sealSourceGaps: false),
          );
          final stage = segment.addChunk(raw);
          await _metadata('segment:$rid', segment.toJson());
          if (stage != null) await _persistStage(stage);
          if (audio?['interrupted'] == true || audio?['isFinal'] == true) {
            final closed = segment.flush();
            await _metadata('segment:$rid', segment.toJson());
            if (closed != null) await _persistStage(closed);
          }
          if (policy.inferSpeakers && jobs['speakers'] != true) {
            final processed = await analysis.cleanTranscript(
              event,
              inferSpeakers: true,
              cleanOral: false,
              sliceStages: false,
              cancellation: token,
            );
            event = processed.event;
            jobs['speakers'] = true;
            await repository.upsertEvent(event);
            await _metadata('processed:${event.id}', processed.toJson());
            await _metadata('jobs:${event.id}', jobs);
          }
          if (policy.autoClean && jobs['clean'] != true) {
            try {
              final updates = await window.addChunk(raw, cancellation: token);
              for (final update in updates) {
                final source = (await repository.load()).events.firstWhere(
                  (e) => e.id == update.id,
                );
                await repository.upsertEvent(
                  source.copyWith(
                    cleanedTranscript: update.text,
                    longText: update.text,
                    dialog: [
                      TurnLine(source.speakers, update.text, source.srcMap),
                    ],
                    revision: update.revision,
                    polishedContextChunkIds: update.contextChunkIds,
                  ),
                );
                await _metadata('polished:${update.id}', update.toJson());
              }
              jobs['clean'] = true;
              await _metadata('jobs:${event.id}', jobs);
            } finally {
              await _metadata('window:$recordingId', window.toJson());
            }
          }
        } else {
          if (policy.inferSpeakers && jobs['speakers'] != true) {
            final processed = await analysis.cleanTranscript(
              event,
              inferSpeakers: true,
              cleanOral: false,
              sliceStages: false,
              cancellation: token,
            );
            event = processed.event;
            jobs['speakers'] = true;
            await repository.upsertEvent(event);
            await _metadata('processed:${event.id}', processed.toJson());
            await _metadata('jobs:${event.id}', jobs);
          }
          if (policy.autoClean && jobs['clean'] != true) {
            final processed = await analysis.cleanTranscript(
              event,
              inferSpeakers: false,
              sliceStages: true,
              cancellation: token,
            );
            await repository.upsertEvent(
              processed.event.copyWith(
                cleanedTranscript: processed.event.longText,
              ),
            );
            await _metadata('processed:${event.id}', processed.toJson());
            jobs['clean'] = true;
          }
        }
      } else if (recordingId != null &&
          transcript.vadVerified &&
          transcript.vadSpeechRangesMs.isEmpty) {
        // Actual Silero classification over this completed WAV, not ASR emptiness.
        await observeSilence(
          recordingId,
          Duration(
            milliseconds:
                endMs ?? startMs + transcript.audioDuration.inMilliseconds,
          ),
        );
        jobs['clean'] = true;
        jobs['speakers'] = true;
      }
      await _metadata('jobs:${event.id}', jobs);
      final latest = (await repository.load()).events.firstWhere(
        (e) => e.id == event.id,
      );
      await repository.upsertEvent(
        latest.copyWith(
          mark: event.mark,
          transcriptionStatus: 'completed',
          error: null,
        ),
      );
      await repository.upsertTask(
        task.copyWith(
          state: RecordingTaskState.succeeded,
          stage: 'complete',
          progress: 1,
          clearError: true,
        ),
      );
      await publish();
    } catch (error) {
      final current =
          (await repository.load()).events
              .where((e) => e.id == event.id)
              .firstOrNull ??
          event;
      final waiting = _isWaiting(error);
      final cancelled = error is OperationCancelled;
      final reason = error is TranscriptionException
          ? '[${error.code}] ${error.message}'
          : error.toString();
      final status = cancelled
          ? 'cancelled'
          : waiting
          ? (error is TranscriptionException && error.code == 'queue_full'
                ? 'queued'
                : 'waiting_model')
          : current.originalTranscript != null
          ? 'analysis_failed'
          : 'failed';
      await repository.upsertEvent(
        current.copyWith(
          transcriptionStatus: status,
          error: cancelled ? '处理已取消；原音频与已保存原文保留，可重试' : reason,
        ),
      );
      await repository.upsertTask(
        task.copyWith(
          state: cancelled
              ? RecordingTaskState.cancelled
              : waiting
              ? RecordingTaskState.queued
              : RecordingTaskState.failed,
          stage: status,
          error: reason,
          clearProgress: true,
        ),
      );
      await publish();
      rethrow;
    } finally {
      _tokens.remove(token);
    }
  }

  Future<void> observeSilence(
    String recordingId,
    Duration through, {
    bool localOnly = false,
  }) async {
    final segment = _segments[recordingId];
    if (segment == null) return;
    final stage = segment.observeSilence(through);
    await _metadata('segment:$recordingId', segment.toJson());
    if (stage != null) await _persistStage(stage, localOnly: localOnly);
  }

  Future<void> _persistStage(
    TranscriptStage stage, {
    bool localOnly = false,
  }) async {
    await _metadata('pending-stage:${stage.id}', {
      ...stage.toJson(),
      'chunks': stage.chunks.map((c) => c.toJson()).toList(),
    });
    if (!localOnly && policy.autoClean && !_suspended && !_disposed) {
      if (!(await repository.load()).metadata.containsKey(
        'stage:${stage.id}',
      )) {
        try {
          await _summarizeStage(stage);
        } catch (e) {
          await reportError('stage:${stage.id}', e);
        }
      }
    }
  }

  Future<void> _retryStages() async {
    final state = await repository.load();
    for (final entry in state.metadata.entries.where(
      (e) => e.key.startsWith('pending-stage:'),
    )) {
      final j = (entry.value as Map).cast<String, dynamic>();
      if (state.metadata.containsKey('stage:${j['id']}')) continue;
      final stage = TranscriptStage(
        id: j['id'] as String,
        recordId: j['recordId'] as String,
        start: Duration(microseconds: j['startUs'] as int),
        end: Duration(microseconds: j['endUs'] as int),
        reason: j['reason'] as String,
        chunks: [
          for (final c in j['chunks'] as List)
            RawTranscriptChunk.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );
      try {
        await _summarizeStage(stage);
      } catch (e) {
        await reportError('stage:${stage.id}', e);
      }
    }
  }

  Future<void> _summarizeStage(TranscriptStage stage) async {
    final token = CancellationToken();
    _tokens.add(token);
    try {
      final result = await _stageSummaries.summarize(
        stage,
        polished: _windows[stage.recordId]?.polishedById ?? {},
        cancellation: token,
      );
      final state = await repository.load();
      final sources = [
        for (final c in stage.chunks)
          state.events.firstWhere((e) => e.id == c.id),
      ];
      final first = sources.first;
      final raw = [for (final e in sources) ...e.raw];
      final dlg = [for (final e in sources) ...e.dialog];
      await repository.upsertEvent(
        first.copyWith(
          id: result.id,
          title: '阶段总结',
          brief: result.overview,
          longText: result.overview,
          originalTranscript: raw.map((r) => r.text).join('\n'),
          raw: raw,
          dialog: dlg,
          audioPath: null,
          fileId: null,
          recordingId: stage.recordId,
          sourceChunkIds: stage.chunks.map((c) => c.id).toList(),
          sourceStartMs: stage.start.inMilliseconds,
          sourceEndMs: stage.end.inMilliseconds,
          srcMap:
              '${first.srcMap.split('—').first}—${sources.last.srcMap.split('—').last}',
          cleanedTranscript: dlg.map((r) => r.text).join('\n'),
        ),
      );
      await _metadata('stage:${result.id}', result.toJson());
      await publish();
    } finally {
      _tokens.remove(token);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _suspended = true;
    for (final token in List.of(_tokens)) {
      token.cancel();
    }
    try {
      await stopCapture();
    } finally {
      await _tail;
      await asr.close();
      _disposed = true;
      await _changes.close();
    }
  }
}
