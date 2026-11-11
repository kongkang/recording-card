import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/speaker_profile_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

import 'support/fake_gateway.dart';

class _FakeEngine implements SpeechEngine {
  List<SpeechSpan>? spans;
  String text = '第一句话。第二句话。';
  bool failTranscribe = false;
  int transcribeCalls = 0;
  int embedCalls = 0;

  /// 按文件（loadSpeakerEmbedding 调用）分组指定每句的声纹向量；
  /// 用于跨文件说话人编号测试。null 时按调用奇偶交替返回两个说话人。
  List<List<List<double>>>? embeddingPlan;
  int labelPass = 0;
  int _embedInFile = 0;

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
    transcribeCalls++;
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
  Future<void> loadSpeakerEmbedding(String modelPath) async {
    labelPass++;
    _embedInFile = 0;
  }

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    embedCalls++;
    final plan = embeddingPlan;
    if (plan != null && plan.isNotEmpty) {
      final byFile = plan[(labelPass - 1).clamp(0, plan.length - 1)];
      final vector = byFile[_embedInFile.clamp(0, byFile.length - 1)];
      _embedInFile++;
      return vector;
    }
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

  RecordingPipeline withSettings(SettingsStore settings) => RecordingPipeline(
    gateway: gateway,
    store: store,
    engine: engine,
    models: models,
    settings: settings,
    polish: SlicePolishService(chat: chat, model: 'test-model'),
    segments: SegmentBuildService(chat: chat, model: 'test-model'),
  );

  test('自动转录关闭：不跑 ASR，切片保留；开关恢复后 processPending 续跑', () async {
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    await settings.setValue(RecordingPipeline.autoTranscribeKey, false);
    final p = withSettings(settings);
    gateway.deviceFiles = [apm()];

    await p.sync();

    expect(engine.transcribeCalls, 0);
    var file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.transcribing);
    expect(file.error, contains('自动转录已关闭'));
    expect(file.slices, isNotEmpty);
    expect(file.utterances, isEmpty);

    await settings.setValue(RecordingPipeline.autoTranscribeKey, true);
    final resumed = await p.processPending();
    expect(resumed.ready, 1);
    file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.ready);
    expect(file.utterances, isNotEmpty);
  });

  test('说话人开关关闭：不做声纹嵌入，统一「未区分」', () async {
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    await settings.setValue(RecordingPipeline.speakerLabelKey, false);
    final p = withSettings(settings);
    gateway.deviceFiles = [apm()];

    await p.sync();

    final file = (await store.loadAll(refresh: true)).single;
    expect(file.utterances, isNotEmpty);
    expect(file.utterances.map((u) => u.speakerLabel).toSet(), {'未区分'});
    expect(engine.embedCalls, 0);
  });

  test('清洗开关关闭：跳过云端润色，原始 turn 保留', () async {
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    await settings.setValue(RecordingPipeline.cleanSpeechKey, false);
    final p = withSettings(settings);
    gateway.deviceFiles = [apm()];

    await p.sync();

    final file = (await store.loadAll(refresh: true)).single;
    expect(file.stage, RecordingStage.ready);
    expect(file.utterances, isNotEmpty);
    expect(file.turns, isEmpty);
    expect(file.polishedThroughSlice, -1);
  });

  test('跨文件声纹：同一 session 的第二个文件沿用会话编号', () async {
    // 两句话长度差异明显 → 每个文件里第 1 句都是主导说话人。
    engine.text = '第一句话很长很长很长。第二句。';
    // 同步按起点倒序处理：later 先处理，earlier 后处理且两句话的声纹顺序相反。
    engine.embeddingPlan = [
      [
        [1, 0, 0],
        [0, 1, 0],
      ],
      [
        [0, 1, 0],
        [1, 0, 0],
      ],
    ];
    gateway.deviceFiles = [
      apm(name: 'later.APM', startAtSec: 1730000600),
      apm(name: 'earlier.APM', startAtSec: 1730000000),
    ];

    final report = await pipeline.sync();
    expect(report.ready, 2);

    final later = (await store.load('later.APM'))!;
    final earlier = (await store.load('earlier.APM'))!;
    expect(later.utterances.length, 2);
    expect(earlier.utterances.length, 2);

    // later：e1=说话人 1，e2=说话人 2
    expect(later.utterances[0].speakerLabel, '说话人 1');
    expect(later.utterances[1].speakerLabel, '说话人 2');
    // earlier：本文件里 e2 才是主导，但会话编号必须沿用 → e2 仍是说话人 2
    expect(earlier.utterances[0].speakerLabel, '说话人 2');
    expect(earlier.utterances[1].speakerLabel, '说话人 1');
    expect(earlier.utterances[0].speakerCluster, 1);
    expect(earlier.utterances[1].speakerCluster, 0);

    final profiles = await SpeakerProfileStore(root: root).load('S1');
    expect(profiles.profiles.length, 2);
    expect(profiles.contributors, {'later.APM', 'earlier.APM'});
  });

  test('实时流切片：录音期间直接本地 VAD+ASR 落库，不调云端润色；后续蓝牙同步自动跳过已覆盖卡文件', () async {
    final liveBase = Directory('${root.path}/app_support');
    await liveBase.create(recursive: true);

    // 准备一段 2 秒的实时流音频（按 1 秒切片）
    final pcm2s = Uint8List(32000 * 2);
    final view = ByteData.sublistView(pcm2s);
    for (var i = 0; i < 32000; i++) {
      view.setInt16(i * 2, ((i % 100) - 50) * 120, Endian.little);
    }
    gateway.realtimeEvents.addAll([
      const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: pcm2s),
    ]);

    var chatCalls = 0;
    final countingChat = _CountingChat(() => chatCalls++);
    final livePipeline = RecordingPipeline(
      gateway: gateway,
      store: store,
      engine: engine,
      models: models,
      liveAudioBaseDir: liveBase,
      polish: SlicePolishService(chat: countingChat, model: 'test-model'),
      segments: SegmentBuildService(chat: countingChat, model: 'test-model'),
    );

    final slices = <LiveAudioSlice>[];
    final recorder = LiveAudioRecorder(
      gateway: gateway,
      baseDir: liveBase,
      sliceDuration: const Duration(seconds: 1),
      onSliceReady: slices.add,
    );
    recorder.updateDeviceSessionId('1ABE9622');
    await recorder.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(recorder.isRunning, isTrue, reason: '仍在录音状态中');
    expect(slices.length, 2);

    // 在开启录音状态下直接把切片送入本地 ASR
    engine.text = '流式切片第一分钟本地转写';
    final f0 = await livePipeline.ingestLiveSlice(slices[0]);
    final f1 = await livePipeline.ingestLiveSlice(slices[1]);
    await recorder.stop();

    expect(f0.stage, RecordingStage.ready);
    expect(f1.stage, RecordingStage.ready);
    expect(f0.utterances, isNotEmpty);
    expect(f0.turns, isEmpty, reason: '本阶段不跑云端文本润色，保留本地原始转写');
    expect(f0.segments.single.title, contains('流式切片第一分钟本地转写'));
    expect(chatCalls, 0, reason: '实时流切片不得请求云端大模型');
    expect(gateway.downloadCalls, 0, reason: '录音期间不拉取蓝牙文件');

    // 随后用户手动执行一次蓝牙文件同步：
    // 卡上有两条文件：1) 刚才实时流已无断档覆盖的 3600E239.APM；2) 蓝牙未连时离线录的 OFFLINE.APM
    final sessionStartSec = slices[0].startAtMs ~/ 1000;
    gateway.deviceFiles = [
      CardFile(
        name: '3600E239.APM',
        size: 64000,
        session: '1ABE9622',
        seq: 1,
        startAtSec: sessionStartSec,
        createdAtSec: sessionStartSec + 2,
      ),
      CardFile(
        name: 'OFFLINE.APM',
        size: 64000,
        session: 'OFF99999',
        seq: 1,
        startAtSec: sessionStartSec - 3600,
        createdAtSec: sessionStartSec - 3540,
      ),
    ];

    final syncReport = await livePipeline.sync();
    expect(syncReport.skipped, 1, reason: '实时流已无断档落库的切片跳过重复蓝牙下载');
    expect(syncReport.downloaded, 1, reason: '只补传蓝牙未同步过的离线录音');
    expect(gateway.downloadCalls, 1);
    expect(await store.load('3600E239.APM'), isNull, reason: '已覆盖卡文件不重复入库');
    expect((await store.load('OFFLINE.APM'))?.stage, RecordingStage.ready);
  });

  test('直流偏置去除 + 远场弱语音兜底 + 历史误判空切片一次性重检', () async {
    // 复现真机 ADPCM 实时流：+10000 直流偏置 + 幅值约 800 (-32 dBFS) 的人声交流分量
    final n = 16000; // 1 秒
    final dcSpeech = Float32List(n);
    for (var i = 0; i < n; i++) {
      final ac = (((i % 80) - 40) / 40.0) * (800 / 32768.0);
      dcSpeech[i] = (10000 / 32768.0) + ac;
    }
    expect(hasAcousticSpeechCandidate(dcSpeech), isTrue);
    final conditioned = conditionSpeechSamples(dcSpeech);
    var mean = 0.0;
    var peak = 0.0;
    for (final v in conditioned) {
      mean += v;
      if (v.abs() > peak) peak = v.abs();
    }
    mean /= conditioned.length;
    expect(mean.abs(), lessThan(0.01), reason: '去直流后均值回到 0 附近');
    expect(peak, greaterThan(0.15), reason: '弱人声归一化到模型可识别幅值');

    // 纯硬件底噪（振幅 ~11/32768）加同样直流偏置：去直流后不应被误放大成假语音
    final dcSilence = Float32List(n);
    for (var i = 0; i < n; i++) {
      dcSilence[i] = (10000 / 32768.0) + ((i.isEven ? 11 : -11) / 32768.0);
    }
    expect(hasAcousticSpeechCandidate(dcSilence), isFalse);

    // 即使 VAD 返回空 spans，只要存在明显声学能量，也走 SenseVoice 兜底并成功识别；
    // 同时验证旧版误判为「未识别到人声」的 LIVE_* 记录能被 reprocessSilentLiveSlices 恢复一次。
    final wavPath = '${root.path}/dc_slice.wav';
    await File(wavPath).writeAsBytes(encodeWav(dcSpeech), flush: true);

    final oldSilent = RecordingFile(
      deviceName: 'LIVE_2DD798CE_0007.WAV',
      session: '2DD798CE',
      seq: 7,
      startAtMs: 1794390972609,
      timeSynced: true,
      apmPath: wavPath,
      wavPath: wavPath,
      durationMs: 1000,
      createdAtMs: 1794390973609,
      stage: RecordingStage.ready,
    );
    await store.save(oldSilent);

    engine.spans = const []; // 模拟 VAD 未检出区间
    engine.text = '第七分钟一直在说话的内容';
    final recovered = await pipeline.reprocessSilentLiveSlices();
    expect(recovered, 1, reason: '应自动重检并恢复被直流偏置淹没的实时切片');

    final updated = (await store.load('LIVE_2DD798CE_0007.WAV'))!;
    expect(updated.utterances, isNotEmpty);
    expect(updated.utterances.first.text, contains('第七分钟一直在说话'));

    // 再次调用不会重复重检（由 .dc_rechecked_v1 标记幂等保护）
    expect(await pipeline.reprocessSilentLiveSlices(), 0);
  });
}

class _CountingChat implements ChatCompletion {
  _CountingChat(this.onCall);
  final void Function() onCall;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    onCall();
    return jsonEncode({'title': '事件', 'overview': '概述'});
  }
}
