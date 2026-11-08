import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';

import 'support/fake_gateway.dart';

class _FakeEngine implements SpeechEngine {
  List<SpeechSpan>? spans;
  String text = '第一句话。第二句话。';
  bool failTranscribe = false;
  int embedCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (failTranscribe) throw const AsrException('注入转写失败');
    return AsrResult(
      text: text,
      tokens: const [],
      timestampsMs: const [],
      audioMs: samples.length * 1000 ~/ sampleRate,
    );
  }

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    final configured = spans;
    if (configured != null) return configured;
    final third = samples.length ~/ 3;
    return [SpeechSpan(0, third), SpeechSpan(third * 2, samples.length)];
  }

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    embedCalls++;
    return embedCalls.isOdd ? [1, 0, 0] : [0, 1, 0];
  }

  @override
  Future<void> dispose() async {}
}

class _FakeModels implements SpeechModelProvider {
  _FakeModels(this.paths);
  SpeechModelPaths? paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

class _FakeChat implements ChatCompletion {
  bool fail = false;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    if (fail) throw Exception('注入润色失败');
    final content = messages.last.content.trim();
    if (!content.startsWith('[')) {
      return jsonEncode({'title': '事件', 'overview': '事件概述'});
    }
    final payload = jsonDecode(content) as List;
    return jsonEncode([
      for (final s in payload)
        {
          'id': s['id'],
          'turns': [
            for (final t in (s['turns'] as List))
              {
                'src': [t['id']],
                'startMs': t['startMs'],
                'endMs': t['endMs'],
                'speaker': t['speaker'],
                'text': '润色：${t['text']}',
              },
          ],
          'boundary': 'none',
        },
    ]);
  }
}

const _paths = SpeechModelPaths(
  asrModelPath: '/models/asr.onnx',
  tokensPath: '/models/tokens.txt',
  vadPath: '/models/vad.onnx',
  speakerEmbeddingPath: '/models/spk.onnx',
);

void main() {
  late Directory root;
  late FakeCardGateway gateway;
  late RecordingStore store;
  late _FakeEngine engine;
  late _FakeModels models;
  late _FakeChat chat;
  late RecordingPipeline pipeline;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rc-pipe-');
    gateway = FakeCardGateway()
      ..writeDownload = true
      ..transcodeSeconds = 30;
    store = RecordingStore(
      root: root,
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    engine = _FakeEngine();
    models = _FakeModels(_paths);
    chat = _FakeChat();
    pipeline = RecordingPipeline(
      gateway: gateway,
      store: store,
      engine: engine,
      models: models,
      polish: SlicePolishService(chat: chat, model: 'test-model'),
      segments: SegmentBuildService(chat: chat, model: 'test-model'),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  CardFile apm({
    String name = 'A.APM',
    int? startAtSec = 1730000000,
    int? createdAtSec,
    bool? synced = true,
  }) => CardFile(
    name: name,
    size: 1000,
    startAtSec: startAtSec,
    createdAtSec: createdAtSec,
    session: 'S1',
    seq: 1,
    synced: synced,
  );

  test('完整同步：下载→转码→切片→转写→声纹→ready，二次同步跳过', () async {
    gateway.deviceFiles = [apm()];
    final report = await pipeline.sync();

    expect(report.downloaded, 1);
    expect(report.ready, 1);
    expect(report.failed, 0);

    final file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.ready);
    expect(file.startAtMs, 1730000000000);
    expect(file.timeSynced, isTrue);
    expect(file.slices.length, 1);
    expect(file.utterances.length, 2);
    expect(
      file.utterances.map((u) => u.speakerLabel).toSet(),
      containsAll(<String>['说话人 1', '说话人 2']),
    );
    expect(file.turns.length, 2);
    expect(file.turns.first.text, startsWith('润色：'));
    expect(file.polishedThroughSlice, 0);
    expect(file.polishStale, isFalse);
    expect(file.segments, isNotEmpty);
    expect(file.segments.first.title, '事件');
    expect(file.segments.first.turnIds, isNotEmpty);
    expect(File(file.apmPath).existsSync(), isTrue);
    expect(File(file.wavPath!).existsSync(), isTrue);
    expect(File(file.slices.first.wavPath).existsSync(), isTrue);

    final again = await pipeline.sync();
    expect(again.skipped, 1);
    expect(gateway.downloadCalls, 1);
    expect(gateway.transcodeCalls, 1);
  });

  test('模型未就绪：音频入库但不切片；模型就绪后 processPending 续跑', () async {
    gateway.deviceFiles = [apm()];
    models.paths = null;

    final report = await pipeline.sync();
    expect(report.ready, 0);
    var file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.transcoding);
    expect(file.error, contains('模型未就绪'));
    expect(file.slices, isEmpty);
    expect(File(file.wavPath!).existsSync(), isTrue);

    models.paths = _paths;
    final resumed = await pipeline.processPending();
    expect(resumed.ready, 1);
    file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.ready);
    expect(file.utterances, isNotEmpty);
  });

  test('失败隔离：一个文件下载失败不影响另一个', () async {
    gateway.deviceFiles = [apm(name: 'A.APM'), apm(name: 'B.APM')];
    gateway.failDownloadNames = {'A.APM'};

    final report = await pipeline.sync();
    expect(report.failed, 1);
    expect(report.ready, 1);
    expect(report.failures.single, contains('A.APM'));

    final a = await store.load('A.APM');
    final b = await store.load('B.APM');
    expect(a!.stage, RecordingStage.failed);
    expect(a.error, contains('注入失败'));
    expect(b!.stage, RecordingStage.ready);
  });

  test('断点续跑：切片已存在但未转写，重跑只补转写', () async {
    gateway.deviceFiles = [apm()];
    await pipeline.sync();
    final file = (await store.loadAll(refresh: true)).single;

    file
      ..stage = RecordingStage.transcribing
      ..utterances = []
      ..slices = [file.slices.first.copyWith(stage: SliceStage.queued)];
    await store.save(file);
    final downloadsBefore = gateway.downloadCalls;
    final transcodesBefore = gateway.transcodeCalls;

    final report = await pipeline.processPending();
    expect(report.ready, 1);
    final resumed = (await store.loadAll(refresh: true)).single;
    expect(resumed.stage, RecordingStage.ready);
    expect(resumed.utterances, isNotEmpty);
    expect(gateway.downloadCalls, downloadsBefore);
    expect(gateway.transcodeCalls, transcodesBefore);
  });

  test('全静音：不产出切片，直接 ready', () async {
    gateway.deviceFiles = [apm()];
    engine.spans = const [];

    await pipeline.sync();
    final file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.ready);
    expect(file.slices, isEmpty);
    expect(file.utterances, isEmpty);
  });

  test('start_at 缺失：用 created_at - 时长反推起点并标时间未校准', () async {
    gateway.deviceFiles = [
      apm(name: 'C.APM', startAtSec: null, createdAtSec: 1730000000, synced: false),
    ];
    await pipeline.sync();
    final file = (await store.loadAll(refresh: true)).single;
    expect(file.timeSynced, isFalse);
    expect(file.startAtMs, (1730000000 - 30) * 1000);
  });

  test('转写失败：文件标 failed 并保留音频，下一次可重试', () async {
    gateway.deviceFiles = [apm()];
    engine.failTranscribe = true;

    final report = await pipeline.sync();
    expect(report.failed, 1);
    final file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.failed);
    expect(file.error, contains('转写失败'));
    expect(File(file.wavPath!).existsSync(), isTrue);

    engine.failTranscribe = false;
    await pipeline.processPending();
    expect((await store.loadAll(refresh: true)).single.stage, RecordingStage.ready);
  });

  test('润色失败：本地原文与切片保留，文件仍 ready，标 stale', () async {
    gateway.deviceFiles = [apm()];
    chat.fail = true;

    await pipeline.sync();
    final file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.ready);
    expect(file.polishStale, isTrue);
    expect(file.turns.length, 2);
    expect(file.turns.first.text, '第一句话');
    expect(file.slices, isNotEmpty);
    expect(file.segments, isNotEmpty);
  });
}
