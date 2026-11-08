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
  StreamSubscription<CardAudioChunk>? _audio;
  StreamSubscription<Map<String, dynamic>>? _events;
  Future<void> _tail = Future.value();
  Future<void> _controls = Future.value();
  int _queued = 0;
  String? _captureId;
  String? _deviceId;
  bool _ownsRecording = false;
  bool _disposed = false;
  bool _suspended = false;
  bool _restored = false;
  final Map<String, SlidingWindowService> _windows = {};
  final Map<String, StageSegmenter> _segments = {};
  final Set<CancellationToken> _tokens = {};
  late final _stageSummaries = StageSummaryService(gateway: analysisGateway);
  String? get captureId => _captureId;
  Future<void> get drained => _tail;

  Future<void> publish() async {
    if (!_disposed) _changes.add((await repository.load()).events);
  }

  Future<void> _serial(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object e) async {
      await reportError('pipeline', e);
    });
    return result;
  }

  void _enqueue(Future<void> Function() operation) {
    _tail = _tail.then((_) => operation()).catchError((Object error) async {
      await reportError('pipeline', error);
    });
  }

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

  /// Desired policy commits only after native operations succeed. If a device
  /// command partially succeeded, restore only recording owned by this app.
  Future<void> apply(RecordingPolicy next) async {
    final before = policy;
    if (_deviceId == null) {
      await _applyMarks(next.markImportant);
      policy = next;
      return;
    }
    final ownedBefore = _ownsRecording;
    try {
      final snapshot = await gateway.status();
      if (next.continuousRecording && !snapshot.recording) {
        await stopCapture();
        await gateway.setRecording(true);
        _ownsRecording = true;
      } else if (!next.continuousRecording && _ownsRecording) {
        await stopCapture();
        await gateway.setRecording(false);
        _ownsRecording = false;
      }
      final current = await gateway.status();
      if (next.autoTranscribe && current.recording && _captureId == null) {
        await startCapture(current.deviceId);
      }
      if (!next.autoTranscribe) await stopCapture();
      await _applyMarks(next.markImportant);
      policy = next;
    } catch (error) {
      policy = before;
      try {
        if (_ownsRecording != ownedBefore) {
          await gateway.setRecording(ownedBefore);
          _ownsRecording = ownedBefore;
        }
        if (!before.autoTranscribe) await stopCapture();
      } catch (rollback) {
        await reportError('policy-rollback', rollback);
      }
      rethrow;
    }
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
    _listen();
    await apply(policy);
    if (policy.autoTranscribe) await processPending();
  }

  void _listen() {
    _audio ??= gateway.audioChunks.listen((chunk) {
      final infer = _queued < 4 && policy.autoTranscribe && !_suspended;
      _queued++;
      _enqueue(() async {
        try {
          await _receive(chunk, infer);
        } finally {
          _queued--;
        }
      });
    }, onError: (Object e) => unawaited(reportError('capture-stream', e)));
    _events ??= gateway.events.listen((event) {
      final kind = event['kind'];
      if ((kind == 'audioCaptureStopped' || kind == 'audioCaptureFailed') &&
          event['taskId'] == _captureId) {
        // Separate native control lane: never await stop from the audio lane.
        _controls = _controls.then((_) async {
          if (event['taskId'] != _captureId) return;
          try {
            await stopCapture();
          } catch (e) {
            await reportError('capture-terminal', e);
          }
          if (kind == 'audioCaptureFailed') {
            await reportError('capture-native', event['error'] ?? '采集失败');
          }
        });
      } else if (kind == 'recordStatus' && _deviceId != null && !_suspended) {
        _controls = _controls.then((_) async {
          try {
            final status = await gateway.status();
            if (!status.recording) {
              await stopCapture();
              _ownsRecording = false;
            } else if (policy.autoTranscribe && _captureId == null) {
              await startCapture(status.deviceId);
            }
          } catch (e) {
            await reportError('record-status', e);
          }
        });
      }
    });
  }

  Future<void> startCapture(String deviceId) async {
    if (_disposed || _suspended) throw StateError('采集服务已停止');
    if (_captureId != null) return;
    _listen();
    final hash = sha256
        .convert(utf8.encode(deviceId))
        .toString()
        .substring(0, 16);
    final id = 'live_${hash}_${DateTime.now().microsecondsSinceEpoch}';
    await _metadata('capture:$id', {'deviceId': deviceId});
    _captureId = id;
    try {
      await gateway.startAudioCapture(
        taskId: id,
        directory: '${repository.directory.path}/capture',
        chunkSeconds: 30,
        startRecordingIfIdle: false,
      );
    } catch (error) {
      _captureId = null;
      await reportError('capture-start', error);
      rethrow;
    }
  }

  Future<void> stopCapture() async {
    final id = _captureId;
    if (id == null) return;
    _captureId = null; // terminal callback cannot stop the same task twice
    try {
      await gateway.stopAudioCapture(id, stopOwnedRecording: false);
    } finally {
      await _tail;
      await _restore();
      for (final entry in _segments.entries.where(
        (e) => e.key == id || e.key.startsWith('$id-epoch-'),
      )) {
        final stage = entry.value.flush();
        await _metadata('segment:${entry.key}', entry.value.toJson());
        if (stage != null) await _persistStage(stage);
      }
    }
  }

  /// Disconnect/logout never stops SD recording that another owner started.
  Future<void> disconnected() async {
    try {
      await stopCapture();
    } finally {
      _deviceId = null;
      _ownsRecording = false;
    }
  }

  Future<void> suspend() async {
    _suspended = true;
    for (final token in List.of(_tokens)) {
      token.cancel();
    }
    await disconnected();
  }

  Future<void> _receive(CardAudioChunk chunk, bool infer) async {
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
      if (stage != null) await _persistStage(stage);
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

  Future<void> _recoverCaptureFiles() async {
    final directory = Directory('${repository.directory.path}/capture');
    if (!await directory.exists()) return;
    final chunks = <CardAudioChunk>[];
    final root = await directory.resolveSymbolicLinks();
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
        final audio = File(chunk.path);
        if (!await audio.exists() ||
            !chunk.path.endsWith('.wav') ||
            !(await audio.resolveSymbolicLinks()).startsWith('$root/')) {
          throw const FormatException('Invalid private capture path');
        }
        if (await audio.length() != 44 + chunk.samples * 2) {
          throw const FormatException('Incomplete capture WAV');
        }
        chunks.add(chunk);
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
      await _receive(chunk, false);
    }
  }

  Future<void> processPending() => _serial(_processPending);

  Future<void> _processPending() async {
    await _restore();
    await _recoverCaptureFiles();
    final state = await repository.load();
    final blocked = <String>{};
    for (final event in state.events) {
      if (event.recordingId != null && blocked.contains(event.recordingId)) {
        continue;
      }
      if (!policy.autoTranscribe || _suspended) break;
      if (event.audioPath == null) continue;
      final jobs = state.metadata['jobs:${event.id}'] as Map? ?? {};
      final needed =
          event.originalTranscript == null ||
          event.transcriptionStatus == 'failed' ||
          (policy.autoClean && jobs['clean'] != true) ||
          (policy.inferSpeakers && jobs['speakers'] != true);
      if (!needed) continue;
      try {
        await _transcribe(event);
      } catch (_) {
        final latest = (await repository.load()).events.firstWhere(
          (e) => e.id == event.id,
        );
        if (latest.originalTranscript == null && event.recordingId != null) {
          blocked.add(event.recordingId!);
        }
      }
    }
    if (policy.autoClean && !_suspended) await _retryStages();
  }

  Future<void> transcribe(
    RecordEvent event, {
    String? recordingId,
    int startMs = 0,
    int? endMs,
  }) => _serial(
    () => _transcribe(
      event,
      recordingId: recordingId,
      startMs: startMs,
      endMs: endMs,
    ),
  );

  Future<void> _transcribe(
    RecordEvent event, {
    String? recordingId,
    int startMs = 0,
    int? endMs,
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
    try {
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
          allowModelDownload: RuntimeConfig.allowModelDownload,
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
          );
        }
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
      await publish();
    } catch (error) {
      final current =
          (await repository.load()).events
              .where((e) => e.id == event.id)
              .firstOrNull ??
          event;
      await repository.upsertEvent(
        current.copyWith(
          transcriptionStatus: 'failed',
          error: error.toString(),
        ),
      );
      await publish();
      rethrow;
    } finally {
      _tokens.remove(token);
    }
  }

  Future<void> observeSilence(String recordingId, Duration through) async {
    final segment = _segments[recordingId];
    if (segment == null) return;
    final stage = segment.observeSilence(through);
    await _metadata('segment:$recordingId', segment.toJson());
    if (stage != null) await _persistStage(stage);
  }

  Future<void> _persistStage(TranscriptStage stage) async {
    await _metadata('pending-stage:${stage.id}', {
      ...stage.toJson(),
      'chunks': stage.chunks.map((c) => c.toJson()).toList(),
    });
    if (policy.autoClean && !_suspended && !_disposed) {
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
      await _audio?.cancel();
      await _events?.cancel();
      await _tail;
      await _controls;
      await asr.close();
      _disposed = true;
      await _changes.close();
    }
  }
}
