import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/service_backends.dart';
import 'package:recording_card/services/analysis/analysis_service.dart';
import 'package:recording_card/services/analysis/source_catalog.dart';
import 'package:recording_card/services/export/export_document.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/runtime/card_download_adapter.dart';
import 'package:recording_card/services/runtime/production_runtime.dart';
import 'package:recording_card/services/runtime/recording_pipeline.dart';
import 'package:recording_card/services/settings/settings_repository.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

import 'services/analysis_service_test.dart' as summary_fixture;
import 'fixtures/accessory_hotspot_fixture.dart';

// All spies are confined to this test. Real production defaults are unchanged.
class GatewaySpy extends CardGateway {
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final files = <String, List<int>>{};
  final downloads = <String>[];
  String? started;
  bool failStart = false, failStatus = false, recording = true;
  bool wifiOpen = false;
  int conversions = 0, stops = 0, disconnects = 0, recordingCommands = 0;
  final wifiCommands = <bool>[];
  CardTransfer expectedTransport = CardTransfer.ble;
  @override
  bool get available => true;
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<CardSnapshot> status() async {
    if (failStatus) throw StateError('status unavailable');
    return CardSnapshot(
      batteryLevel: 80,
      isCharging: false,
      wifiOpen: wifiOpen,
      recording: recording,
      fwVersion: '1',
      wifiVersion: '1',
      deviceId: 'card:真实:device',
    );
  }

  @override
  Future<CardSnapshot> connect(String id) => status();
  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<Map<String, dynamic>> setRecording(bool enabled) async {
    recordingCommands++;
    recording = enabled;
    return {};
  }

  @override
  Future<void> setWifiEnabled(bool enabled) async {
    wifiCommands.add(enabled);
    wifiOpen = enabled;
  }

  @override
  Future<CardAudioTask> startAudioCapture({
    required String taskId,
    required String directory,
    int chunkSeconds = 30,
    bool startRecordingIfIdle = false,
  }) async {
    started = taskId;
    if (failStart) throw StateError('real capture failed');
    return CardAudioTask(
      taskId: taskId,
      manifestPath: '$directory/$taskId.task.json',
      chunkSeconds: chunkSeconds,
      startedRecording: false,
    );
  }

  @override
  Future<Map<String, dynamic>> stopAudioCapture(
    String taskId, {
    bool stopOwnedRecording = false,
  }) async {
    expect(stopOwnedRecording, isFalse);
    stops++;
    return {};
  }

  @override
  Future<String> convertAudio(
    String path, {
    required String destination,
    String format = 'adpcm',
  }) async {
    conversions++;
    if (await File(destination).exists()) {
      throw StateError('destination exists');
    }
    await File(destination).writeAsBytes(wav30(), flush: true);
    return destination;
  }

  @override
  Future<List<CardFile>> listFiles({String? folder}) async => [
    for (final e in files.entries) CardFile(name: e.key, size: e.value.length),
  ];
  @override
  Future<CardDownload> downloadFilePreservingSource(
    String name, {
    required String directory,
    required String expectedDeviceId,
    required int expectedBytes,
    CardTransfer transport = CardTransfer.ble,
    void Function(CardProgress)? onProgress,
  }) async {
    expect(expectedDeviceId, 'card:真实:device');
    return downloadFile(
      name,
      directory: directory,
      expectedBytes: expectedBytes,
      transport: transport,
      allowDestructive: false,
      onProgress: onProgress,
    );
  }

  @override
  Future<CardDownload> downloadFile(
    String name, {
    required String directory,
    int? expectedBytes,
    CardTransfer transport = CardTransfer.ap,
    bool allowDestructive = false,
    void Function(CardProgress)? onProgress,
  }) async {
    expect(transport, expectedTransport);
    expect(allowDestructive, isFalse);
    downloads.add(name);
    final f = await File('$directory/$name').writeAsBytes(files[name]!);
    return CardDownload(
      path: f.path,
      bytes: files[name]!.length,
      originalName: name,
      sourceDeleted: false,
      recordedAt: name.toLowerCase().endsWith('.apm')
          ? DateTime(2026, 11, 7, 10)
          : null,
    );
  }
}

Uint8List wav30() {
  final b = Uint8List(44 + 16000 * 30 * 2);
  final data = ByteData.sublistView(b);
  void tag(int offset, String text) =>
      b.setRange(offset, offset + text.length, text.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, b.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, b.length - 44, Endian.little);
  return b;
}

const speech = TranscriptionResult(
  text: '测试原文甲\n测试原文乙',
  audioDuration: Duration(seconds: 30),
  segments: [
    TranscriptSegment(
      index: 0,
      start: Duration.zero,
      end: Duration(seconds: 15),
      text: '测试原文甲',
    ),
    TranscriptSegment(
      index: 1,
      start: Duration(seconds: 15),
      end: Duration(seconds: 30),
      text: '测试原文乙',
    ),
  ],
);

class AsrSpy extends TranscriptionService {
  AsrSpy(Directory root) : super(models: AsrModelStore(directory: root));
  int calls = 0;
  bool fail = false;
  TranscriptionResult result = speech;
  Completer<void>? gate;
  @override
  Future<TranscriptionResult> transcribeFile(
    String path, {
    required AudioFileFormat format,
    int sampleRate = 16000,
    bool allowModelDownload = false,
    CancellationToken? cancellation,
    void Function(TranscriptionProgress)? onProgress,
  }) async {
    calls++;
    await gate?.future;
    if (fail) {
      throw const TranscriptionException('model_missing', 'test model missing');
    }
    cancellation?.throwIfCancelled();
    return result;
  }
}

class CloudSpy implements AnalysisGateway {
  bool fail = false;
  final prompts = <String>[];
  @override
  Future<String> complete(String prompt, {String? model}) async {
    prompts.add(prompt);
    if (fail) throw StateError('cloud unavailable');
    final data = jsonDecode(
      prompt.substring(prompt.lastIndexOf('资料：') + 3).trim(),
    ) as List;
    if (prompt.contains('录音润色助手')) {
      return jsonEncode({
        'chunks': [
          for (final c in data)
            {
              'id': c['id'],
              'text': '润色${c['rawText']}',
              'uncertainties': <String>[],
            },
        ],
      });
    }
    return jsonEncode({
      'overview': '真实来源测试阶段',
      'points': ['测试观点'],
      'todos': <String>[],
      'sourceChunkIds': [for (final c in data) c['id']],
      'uncertainties': <String>[],
    });
  }
}

class Harness {
  Harness(this.root) {
    repo = RecordingRepository(directory: root);
    asr = AsrSpy(root);
    pipeline = create();
  }
  final Directory root;
  final gateway = GatewaySpy();
  final cloud = CloudSpy();
  late final RecordingRepository repo;
  late final AsrSpy asr;
  late RecordingPipeline pipeline;
  RecordingPipeline create() => RecordingPipeline(
    gateway: gateway,
    repository: repo,
    asr: asr,
    analysis: AnalysisService(
      gateway: cloud,
      rebuildCleanEvent:
          (
            source, {
            required brief,
            required longText,
            required speakers,
            required dialog,
          }) => source.copyWith(
            brief: brief,
            longText: longText,
            speakers: speakers,
            dialog: dialog,
          ),
    ),
    analysisGateway: cloud,
  );
  Future<RecordEvent> import({String name = 'one.wav'}) async {
    final f = await File('${root.path}/$name').writeAsBytes(wav30());
    return (await repo.importRecording(
      RecordingImport(sourcePath: f.path, fileId: name, deviceId: 'fixture'),
    )).event;
  }

  Future<void> chunk(
    int index, {
    String task = 'session',
    bool discontinuous = false,
    bool interrupted = false,
    bool finalChunk = false,
  }) async {
    final dir = Directory('${root.path}/capture');
    await dir.create(recursive: true);
    final f = await File('${dir.path}/$task-$index.wav').writeAsBytes(wav30());
    final data = {
      'kind': 'audioChunk',
      'taskId': task,
      'path': f.path,
      'index': index,
      'samples': 16000 * 30,
      'receivedSampleOffset': (index - 1) * 16000 * 30,
      'discontinuous': discontinuous,
      'droppedChunks': discontinuous ? 1 : 0,
      'isFinal': finalChunk,
      'interrupted': interrupted,
    };
    await File('${dir.path}/$task-$index.json').writeAsString(jsonEncode(data));
    gateway.stream.add(data);
  }
}

void main() {
  late Harness h;
  setUp(() async {
    h = Harness(await Directory.systemTemp.createTemp('runtime-repair-'));
  });
  tearDown(() async {
    await h.pipeline.dispose();
    await h.gateway.stream.close();
    await h.root.delete(recursive: true);
  });
  test(
    'production connect uses completed files and never starts realtime capture',
    () async {
      h.gateway.failStart = true;
      final errors = <Object>[];
      final sub = h.pipeline.changes.listen((_) {}, onError: errors.add);
      final delegate = ServiceDeviceBackend(
        gateway: h.gateway,
        settingsRepository: SettingsRepository(directory: h.root),
      );
      final backend = RuntimeDeviceBackend(delegate, h.pipeline, h.gateway);
      final reading = await backend.connect('test-device');
      expect(reading.snapshot.deviceId, 'card:真实:device');
      expect(h.gateway.started, isNull);
      expect(h.gateway.recordingCommands, 0);
      expect(h.pipeline.captureId, isNull);
      expect(errors, isEmpty);
      await sub.cancel();
    },
  );
  test(
    'settings are local policy only even when status is unavailable',
    () async {
      final old = h.pipeline.policy;
      await h.pipeline.connected(await h.gateway.status());
      h.gateway.failStatus = true;
      await h.pipeline.apply(old.toggled(2));
      expect(h.pipeline.policy.toJson(), old.toggled(2).toJson());
      expect(h.gateway.recording, isTrue);
      expect(h.gateway.recordingCommands, 0);
      expect(h.gateway.started, isNull);
      h.gateway.failStatus = false;
    },
  );
  test('APM conversion cache is source-hash bound and survives missing ASR model retry', () async {
    final event = await h.import(name: 'record.apm');
    h.pipeline.policy = const RecordingPolicy(
      autoClean: false,
      inferSpeakers: false,
    );
    h.asr.fail = true;
    await expectLater(
      h.pipeline.transcribe(event),
      throwsA(isA<TranscriptionException>()),
    );
    expect(h.gateway.conversions, 1);
    h.asr.fail = false;
    await h.pipeline.processPending();
    expect(h.gateway.conversions, 1);
    expect(h.asr.calls, 2);
    expect((await h.repo.load()).events.single.originalTranscript, speech.text);
  });
  test('raw survives cloud failure; restart resumes same window/offset without ASR rerun', () async {
    h.pipeline.policy = const RecordingPolicy(inferSpeakers: false);
    await h.chunk(1);
    await h.pipeline.recoverCaptureFiles();
    h.cloud.fail = true;
    await h.pipeline.processPending();
    final state = await h.repo.load();
    final event = state.events.single;
    expect(event.originalTranscript, speech.text);
    expect(event.transcriptionStatus, 'analysis_failed');
    expect(h.asr.calls, 1);
    await h.pipeline.dispose();
    h.pipeline = h.create()
      ..policy = const RecordingPolicy(inferSpeakers: false);
    h.cloud.fail = false;
    await h.pipeline.processPending();
    final recovered = (await h.repo.load()).events.single;
    expect(h.asr.calls, 1);
    expect(recovered.recordingId, 'session');
    expect(recovered.sourceStartMs, 0);
    expect(recovered.raw.map((r) => r.text), event.raw.map((r) => r.text));
    expect(recovered.cleanedTranscript, startsWith('润色'));
    final count = h.cloud.prompts.length;
    await h.pipeline.processPending();
    expect(h.cloud.prompts.length, count);
  });
  test(
    'native sidecar recovery is idempotent and epoch continues AFTER the gap',
    () async {
      h.pipeline.policy = const RecordingPolicy(autoTranscribe: false);
      await h.chunk(1, interrupted: true);
      await h.chunk(2, discontinuous: true);
      await h.chunk(3);
      await h.pipeline.recoverCaptureFiles();
      await h.pipeline.recoverCaptureFiles();
      final state = await h.repo.load();
      expect(state.events.length, 3);
      expect(state.chunks[0].recordingId, 'session');
      expect(state.chunks[1].recordingId, 'session-epoch-2');
      expect(state.chunks[2].recordingId, 'session-epoch-2');
      expect(state.chunks[2].startMs, 60000);
      expect(h.asr.calls, 0);
    },
  );
  test(
    'six completed sidecars recover all audio; no live PCM listener exists',
    () async {
      h.pipeline.policy = const RecordingPolicy(
        autoClean: false,
        inferSpeakers: false,
      );
      await h.pipeline.connected(await h.gateway.status());
      for (var i = 1; i <= 6; i++) {
        await h.chunk(i);
      }
      await h.pipeline.drained;
      expect(
        (await h.repo.load()).chunks,
        isEmpty,
        reason: 'events cannot activate live PCM',
      );
      await h.pipeline.recoverCaptureFiles();
      expect((await h.repo.load()).chunks.length, 6);
      expect(h.asr.calls, 0);
      await h.pipeline.processPending();
      final state = await h.repo.load();
      expect(state.chunks.length, 6);
      expect(h.asr.calls, 6);
      expect(state.events.where((e) => e.originalTranscript != null).length, 6);
      expect(state.chunks.last.startMs, 150000);
    },
  );
  test(
    'record-status events, suspend and legacy capture cannot control hardware',
    () async {
      await h.pipeline.connected(await h.gateway.status());
      h.gateway.stream.add({'kind': 'recordStatus'});
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        h.pipeline.startCapture('fixture'),
        throwsA(isA<CardGatewayException>()),
      );
      await h.pipeline.suspend();
      expect(h.gateway.started, isNull);
      expect(h.gateway.stops, 0);
      expect(h.gateway.recordingCommands, 0);
      expect(h.gateway.recording, isTrue);
    },
  );
  test('missing models queue both local fragments with exact reasons, not generic failure', () async {
    await h.import(name: 'first.wav');
    await h.import(name: 'second.wav');
    h.pipeline.policy = const RecordingPolicy(
      autoClean: false,
      inferSpeakers: false,
    );
    h.asr.fail = true;
    final errors = <Object>[];
    final sub = h.pipeline.changes.listen((_) {}, onError: errors.add);
    await h.pipeline.processPending();
    final state = await h.repo.load();
    expect(state.events.length, 2);
    expect(
      state.events.every((e) => e.transcriptionStatus == 'waiting_model'),
      isTrue,
    );
    expect(
      state.events.every((e) => e.error!.contains('model_missing')),
      isTrue,
    );
    expect(
      state.tasks.every((t) => t.state == RecordingTaskState.queued),
      isTrue,
    );
    expect(
      state.events.every((e) => e.originalTranscript == null && e.raw.isEmpty),
      isTrue,
    );
    for (final entry in state.index) {
      expect(await h.repo.verifyRecording(entry.key), RecordingIntegrity.valid);
    }
    expect(errors, isEmpty);
    expect(h.cloud.prompts, isEmpty);
    h.asr.fail = false;
    await h.pipeline.processPending();
    expect(
      (await h.repo.load()).events.every(
        (e) => e.transcriptionStatus == 'completed',
      ),
      isTrue,
    );
    await sub.cancel();
  });
  test('cancelled local ASR retains audio and resumes without changing file identity', () async {
    final event = await h.import();
    h.pipeline.policy = const RecordingPolicy(
      autoClean: false,
      inferSpeakers: false,
    );
    h.asr.gate = Completer<void>();
    final running = h.pipeline.transcribe(event);
    final assertion = expectLater(running, throwsA(isA<OperationCancelled>()));
    while (h.asr.calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await h.pipeline.suspend();
    h.asr.gate!.complete();
    await assertion;
    final cancelled = (await h.repo.load()).events.single;
    expect(cancelled.transcriptionStatus, 'cancelled');
    expect(await File(cancelled.audioPath!).exists(), isTrue);
    await h.pipeline.connected(await h.gateway.status());
    final retry = (await h.repo.load()).events.single;
    expect(retry.id, event.id);
    expect(retry.originalTranscript, speech.text);
  });
  test(
    'only actual VAD evidence seals long silence; empty ASR does not',
    () async {
      h.pipeline.policy = const RecordingPolicy(
        autoClean: false,
        inferSpeakers: false,
      );
      await h.chunk(1);
      await h.pipeline.processPending();
      await h.chunk(2);
      h.asr.result = const TranscriptionResult(
        text: '',
        audioDuration: Duration(seconds: 30),
        segments: [],
      );
      await h.pipeline.processPending();
      expect(
        (await h.repo.load()).metadata.keys.where(
          (k) => k.startsWith('pending-stage:'),
        ),
        isEmpty,
      );
      final rejected = (await h.repo.load()).events.firstWhere(
        (e) => e.transcriptionStatus == 'no_speech',
      );
      expect(rejected.status, 'failed');
      expect(rejected.error, contains('没有VAD静音证据'));
      await h.chunk(3);
      h.asr.result = const TranscriptionResult(
        text: '',
        audioDuration: Duration(seconds: 30),
        segments: [],
        vadVerified: true,
      );
      await h.pipeline.processPending();
      final state = await h.repo.load();
      final pending =
          state.metadata.entries
                  .where((e) => e.key.startsWith('pending-stage:'))
                  .single
                  .value
              as Map;
      expect(pending['reason'], 'long_silence');
      expect(pending['chunkIds'], [state.events.first.id]);
      final quiet = state.events.firstWhere((e) => e.status == 'silent');
      expect(quiet.brief, contains('本地转写完成'));
      expect(quiet.raw, isEmpty);
      expect(quiet.dialog, isEmpty);
      expect(quiet.dur, '30s');
      final calls = h.asr.calls;
      await h.pipeline.processPending();
      expect(h.asr.calls, calls);
    },
  );
  test('grouped polished includes all selected raw; excludes partial rows and unselected window context', () async {
    final e = recordEventFromTranscription(
      id: 'one',
      title: '片段',
      startedAt: DateTime(2026, 11, 8, 10),
      transcript: speech,
    );
    final polished = e.copyWith(
      dialog: [TurnLine('待确认', '整片润色', e.srcMap)],
      polishedContextChunkIds: ['one'],
    );
    final full = SourceCatalog([polished]).promptRecords.single;
    expect((full['cleaned'] as List).single['text'], '整片润色');
    expect(
      SourceCatalog(
        [polished],
        selectedRawIndices: {
          'one': [0],
        },
      ).promptRecords.single['cleaned'],
      isEmpty,
    );
    expect(
      SourceCatalog([
        polished.copyWith(polishedContextChunkIds: ['one', 'unselected']),
      ]).promptRecords.single['cleaned'],
      isEmpty,
    );
  });
  test('markImportant derives display without mutating source marks; AP retrieves paired sidecars', () async {
    h.gateway.recording = false;
    h.gateway.files.addAll({
      'REC.APM': [1, 2, 3],
      'rec.TXT': utf8.encode('metadata'),
      'Rec.MRK': utf8.encode('9\n2\n9\n'),
    });
    h.gateway.expectedTransport = CardTransfer.ap;
    final hotspot = fixtureHotspot(h.gateway);
    await hotspot.prepare('card:真实:device');
    final adapter = CardDownloadAdapter(
      h.gateway,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
    );
    await adapter.openSession('card:真实:device');
    final remote = (await adapter.listRecordings('card:真实:device')).single;
    final result = await adapter.downloadRecording(
      'card:真实:device',
      remote,
      destinationPath: '${h.root.path}/staging/apm',
      allowDestructive: false,
    );
    expect(result.marks.map((m) => m.offsetMs), [2000, 9000]);
    expect(result.metadataPath, isNotNull);
    expect(result.markPath, isNotNull);
    expect(
      result.recordedAt,
      DateTime(2026, 11, 7, 10),
      reason: 'native synced filename date is preserved',
    );
    expect(h.gateway.downloads, ['REC.APM', 'rec.TXT', 'Rec.MRK']);
    final imported = await h.repo.importRecording(
      RecordingImport(
        sourcePath: result.audioPath,
        fileId: remote.fileId,
        marks: result.marks,
        metadataPath: result.metadataPath,
        markPath: result.markPath,
      ),
    );
    await h.pipeline.apply(const RecordingPolicy(markImportant: true));
    expect((await h.repo.load()).events.single.mark, '重要标记');
    await h.pipeline.apply(const RecordingPolicy(markImportant: false));
    final latest = (await h.repo.load()).events.single;
    expect(latest.mark, isEmpty);
    expect(latest.marks.length, imported.event.marks.length);
    await adapter.closeSession('card:真实:device');
  });
  test('calendar offsets include yesterday, future, cross-month and DST calendar days', () async {
    final event = await h.import();
    expect(
      event
          .copyWith(recordedAt: DateTime(2026, 11, 7, 23))
          .dayOffsetAt(DateTime(2026, 11, 8, 1)),
      1,
    );
    expect(
      event
          .copyWith(recordedAt: DateTime(2026, 11, 9))
          .dayOffsetAt(DateTime(2026, 11, 8)),
      -1,
    );
    expect(
      event
          .copyWith(recordedAt: DateTime(2026, 10, 31))
          .dayOffsetAt(DateTime(2026, 11, 1)),
      1,
    );
    expect(
      event
          .copyWith(recordedAt: DateTime(2026, 3, 7, 23, 30))
          .dayOffsetAt(DateTime(2026, 3, 9, 0, 30)),
      2,
    );
  });
  test('complete export semantic document retains uncertainty, todo sources and all sources', () async {
    final event = await h.import();
    final summary = SummaryCard(id: 's', time: '10:00')..srcIds = [event.id];
    summary.uncertainties = ['尚未确认'];
    summary.todos = ['跟进'];
    summary.todoSources = [
      [SourceRef(event.id, '行动来源', '10:00—10:15')],
    ];
    summary.sources = [SourceRef(event.id, '完整来源', '10:00—10:30')];
    final text = ExportDocument(summary, [event]).markdown;
    expect(text, contains('尚未确认'));
    expect(text, contains('行动来源'));
    expect(text, contains('完整来源'));
  });

  test('runtime manual summary receives persisted stage context and full grouped polished rows', () async {
    final event =
        recordEventFromTranscription(
          id: 'source',
          title: '选中音频',
          startedAt: DateTime(2026, 11, 8, 10),
          transcript: speech,
        ).copyWith(
          dialog: [const TurnLine('未知', '选中整片润色', '来源 10:00:00—10:00:30')],
          polishedContextChunkIds: ['source'],
        );
    await h.repo.upsertEvent(event);
    await h.repo.update(
      (s) => s.copyWith(
        metadata: {
          ...s.metadata,
          'stage:test': {
            'id': 'test',
            'recordId': 'continuous-session',
            'revision': 1,
            'overview': '已保存阶段观点',
            'points': ['阶段事实'],
            'todos': <String>[],
            'sourceChunkIds': ['source'],
            'uncertainties': <String>[],
          },
          'pending-stage:test': {
            'chunkIds': ['source'],
          },
        },
      ),
    );
    final analysis = AnalysisService(
      gateway: CallbackAnalysisGateway((prompt, {model}) async {
        expect(prompt, contains('选中整片润色'));
        expect(prompt, contains('已保存阶段观点'));
        expect(prompt, contains('"sourceId":"source","rawIndex":1'));
        return jsonEncode(summary_fixture.summaryData(id: 'source'));
      }),
    );
    final backend = RuntimeAppBackend(
      recordingRepository: h.repo,
      settingsRepository: SettingsRepository(directory: h.root),
      analysisService: analysis,
      pipeline: h.pipeline,
    );
    final result = await backend.generateSummary(
      [event],
      target: SummaryCard(id: 'manual', time: '10:01'),
      policy: h.pipeline.policy,
      onProgress: (_) {},
    );
    expect(result.state, SummaryState.done);
    expect(result.sources.single.eventId, 'source');
    await backend.cancelAllAndDrain();
  });
}
