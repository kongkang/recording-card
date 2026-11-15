// Timeline 下拉刷新即时切分与本地转写验收（M5）。
//
// 核心契约：
// 1. 硬件实时流或本机麦克风正在录音（已录 >= 0.5s）时下拉刷新：不停录、不发蓝牙 FILE_LIST，
//    立即把当前内存缓冲封口为一片正式 .WAV，等待本地 ASR 转写落库后刷新 Timeline；
//    后续切片起点毫秒精确衔接在下拉切分点之后，无重叠、无丢帧；
// 2. 连拉防抖（已累积 < 0.5s）：不产生极碎空片，返回「当前语音刚同步，继续说话后可随时下拉转写」；
// 3. 未连接录音卡且未在录音时下拉刷新：自动把本机排队未转写的本地音频送进本地 ASR，
//    全程不触碰蓝牙文件接口；本机已无待办时如实返回提示且不打成错误态。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

import '../support/fake_gateway.dart';
import '../support/model_stub.dart';

class _LiveStreamGateway extends FakeCardGateway {
  _LiveStreamGateway({super.initialSnapshot});

  final StreamController<RealtimeAudioEvent> controller =
      StreamController<RealtimeAudioEvent>.broadcast();
  int filesCalls = 0;

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    realtimeOpenCalls++;
    callLog.add('realtime.open');
    return controller.stream;
  }

  @override
  Future<List<CardFile>> files() async {
    filesCalls++;
    return super.files();
  }

  @override
  Future<void> dispose() async {
    await controller.close();
    await super.dispose();
  }
}

class _FakePhoneMicBackend implements PhoneMicBackend {
  void Function(Uint8List pcm)? onPcm;
  bool capturing = false;

  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcmCallback, {
    void Function(String error)? onError,
  }) async {
    onPcm = onPcmCallback;
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    capturing = false;
    onPcm = null;
  }
}

class _StubSpeechEngine implements SpeechEngine {
  String nextText = '刚才刚说的二十二秒语音立刻转写出来';
  int transcribeCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (samples.isEmpty) return const [];
    return [SpeechSpan(0, samples.length)];
  }

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    transcribeCalls++;
    return AsrResult(
      text: nextText,
      tokens: const [],
      timestampsMs: const [],
      audioMs: samples.length * 1000 ~/ sampleRate,
    );
  }

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1.0, 0.0, 0.0];

  @override
  Future<void> dispose() async {}
}

class _StubModels implements SpeechModelProvider {
  _StubModels(this.paths);
  SpeechModelPaths? paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

Uint8List _tonePcm({required int seconds}) {
  final samples = seconds * 16000;
  final bytes = Uint8List(samples * 2);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    final v = (6000 * ((i % 160) - 80) / 80).round();
    bd.setInt16(i * 2, v, Endian.little);
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SpeechModelPaths readyModels;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rc-pull-flush-');
    readyModels = SpeechModelPaths(
      asrModelPath: '${root.path}/model.onnx',
      tokensPath: '${root.path}/tokens.txt',
      vadPath: '${root.path}/vad.onnx',
      speakerEmbeddingPath: '${root.path}/spk.onnx',
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('硬件实时流录音中下拉刷新：不停录即时切分 22s 语音转写落库，后续切片精确衔接 +22000ms 且防 <0.5s 连拉', () async {
    final gateway = _LiveStreamGateway(initialSnapshot: defaultSnapshot);
    final recStore = RecordingStore(root: Directory('${root.path}/store'));
    final engine = _StubSpeechEngine();
    final models = _StubModels(readyModels);
    final pipeline = RecordingPipeline(
      gateway: gateway,
      store: recStore,
      engine: engine,
      models: models,
      liveAudioBaseDir: root,
    );
    final status = RecordingStatusController();
    final generator = await SummaryModel().generator();
    final appStore = AppStore(status: status, loadPersistedState: false)
      ..attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: generator,
        status: status,
      );

    final emitted = <LiveAudioSlice>[];
    final recorder = LiveAudioRecorder(
      gateway: gateway,
      baseDir: root,
      sliceDuration: const Duration(minutes: 1),
    );
    final sub = recorder.slices.listen((s) {
      emitted.add(s);
      unawaited(appStore.ingestLiveSlice(s));
    });
    addTearDown(() async {
      await sub.cancel();
      await recorder.stop();
      recorder.dispose();
      await gateway.dispose();
    });

    appStore.deviceConnected = () => true;
    appStore.deviceRecording = () => recorder.isRunning;
    appStore.flushActiveRecordingSlice = recorder.flushActiveSlice;

    recorder.updateDeviceSessionId('AA11BB22');
    status.startRecording();
    appStore.onLiveRecordingStarted();
    await recorder.start();

    gateway.controller.add(const RealtimeAudioEvent(kind: RealtimeAudioKind.open));
    gateway.controller.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tonePcm(seconds: 22)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(emitted, isEmpty, reason: '未满 1 分钟前尚未自动切分');

    // 第 22 秒用户下拉刷新：立即封口第 1 片并完成本地转写，录音绝不中断！
    final msg1 = await appStore.syncRecordings();
    expect(msg1, isNull);
    expect(recorder.isRunning, isTrue, reason: '下拉刷新不得关闭实时流');
    expect(gateway.realtimeCloseCalls, 0);
    expect(gateway.filesCalls, 0, reason: '录音期间下拉刷新不得请求蓝牙 FILE_LIST');
    expect(emitted.length, 1);
    expect(emitted[0].durationMs, 22000);
    expect(emitted[0].isFinal, isFalse);
    expect(appStore.events.length, 1);
    expect(appStore.events.single.title, contains('刚才刚说的二十二秒语音'));

    // 紧接着 0.2 秒内再次下拉（缓冲 < 0.5 秒）：防抖不产生碎切片，给出友好提示
    final shortPcm = Uint8List(3200 * 2); // 0.2 秒
    gateway.controller.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: shortPcm),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final msg2 = await appStore.syncRecordings();
    expect(msg2, '当前语音刚同步，继续说话后可随时下拉转写');
    expect(emitted.length, 1, reason: '不足 0.5s 不得切出碎空片');

    // 继续说话满 60 秒窗口（补齐 59.8s -> 触发下一片自动封口），验证第 2 片 startAtMs 精确接在 +22000ms
    engine.nextText = '紧接在下拉刷新之后的第二段内容';
    final restBytes = (60 * 16000 - 3200) * 2;
    gateway.controller.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: Uint8List(restBytes)),
    );
    for (var i = 0; i < 80 && emitted.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await appStore.finishLiveRecording();

    expect(emitted.length, 2);
    expect(
      emitted[1].startAtMs,
      emitted[0].startAtMs + 22000,
      reason: '下一片起点必须精确等于上一片下拉封口终点，无重叠无丢帧',
    );
    expect(emitted[1].durationMs, 60000);
    expect(appStore.events.length, 2);

    await recorder.stop();
  });

  test('本机麦克风录音中下拉刷新：不停麦克风与灵动岛，立即切分当前语音本地转写', () async {
    final gateway = _LiveStreamGateway();
    final micBackend = _FakePhoneMicBackend();
    final phoneRecorder = PhoneMicRecorder(
      sliceDuration: const Duration(minutes: 1),
      sliceRootDir: () async => Directory('${root.path}/phone_slices'),
    );
    final device = DeviceStore(
      gateway: gateway,
      phoneMicBackend: micBackend,
      phoneMicRecorder: phoneRecorder,
    );
    final recStore = RecordingStore(root: Directory('${root.path}/store_phone'));
    final engine = _StubSpeechEngine()..nextText = '本机麦克风刚录十秒下拉即出';
    final pipeline = RecordingPipeline(
      gateway: gateway,
      store: recStore,
      engine: engine,
      models: _StubModels(readyModels),
      liveAudioBaseDir: root,
    );
    final status = RecordingStatusController();
    final generator = await SummaryModel().generator();
    final appStore = AppStore(status: status, loadPersistedState: false)
      ..attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: generator,
        status: status,
      );

    final emitted = <LiveAudioSlice>[];
    final sub = device.phoneAudioSlices.listen((s) {
      emitted.add(s);
      unawaited(appStore.ingestLiveSlice(s));
    });
    addTearDown(() async {
      await sub.cancel();
      await device.stopPhoneRecording();
      device.dispose();
      phoneRecorder.dispose();
      await gateway.dispose();
    });

    appStore.deviceConnected = () => false;
    appStore.deviceRecording = () => device.isPhoneRecording;
    appStore.flushActiveRecordingSlice = device.flushPhoneRecordingSlice;

    final started = await device.startPhoneRecording(islandEnabled: false);
    expect(started, isTrue);
    status.startRecording();

    // 推入 10 秒本机麦克风 PCM，然后下拉刷新
    micBackend.onPcm!(_tonePcm(seconds: 10));
    final msg = await appStore.syncRecordings();
    expect(msg, isNull);
    expect(device.isPhoneRecording, isTrue, reason: '本机录音保持进行中');
    expect(micBackend.capturing, isTrue);
    expect(emitted.length, 1);
    expect(emitted.first.durationMs, 10000);
    expect(appStore.events.single.title, contains('本机麦克风刚录十秒下拉即出'));

    // 再推入 6 秒并停录，验证第二片起点无漂移衔接在 +10000ms
    engine.nextText = '本机麦克风后续六秒尾片';
    micBackend.onPcm!(_tonePcm(seconds: 6));
    await device.stopPhoneRecording();
    status.stopRecording();
    await appStore.finishLiveRecording();

    expect(emitted.length, 2);
    expect(emitted[1].startAtMs, emitted[0].startAtMs + 10000);
    expect(appStore.events.length, 2);
  });

  test('未连接录音卡且未在录音时下拉刷新：本地排队音频直接离线转写，无待办时诚实提示不报错', () async {
    final gateway = _LiveStreamGateway(initialSnapshot: null);
    final recStore = RecordingStore(root: Directory('${root.path}/store_off'));
    final engine = _StubSpeechEngine()..nextText = '模型下载完成后下拉补转写的本地切片';
    final models = _StubModels(null); // 初始无本地模型
    final pipeline = RecordingPipeline(
      gateway: gateway,
      store: recStore,
      engine: engine,
      models: models,
      liveAudioBaseDir: root,
    );
    final appStore = AppStore(loadPersistedState: false)
      ..attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: await SummaryModel().generator(),
      );
    appStore.deviceConnected = () => false;
    appStore.deviceRecording = () => false;
    addTearDown(gateway.dispose);

    // 先写入一段模型未就绪时入库排队的本地 LIVE 切片
    final wavPath = '${root.path}/pending_live.wav';
    final samples = Float32List(16000)..fillRange(0, 16000, 0.08);
    await File(wavPath).writeAsBytes(encodeWav(samples), flush: true);
    final queued = await pipeline.ingestLiveSlice(
      LiveAudioSlice(
        sessionId: 'S_OFF',
        deviceSessionId: 'S_OFF',
        sliceIndex: 0,
        startAtMs: DateTime.now().millisecondsSinceEpoch - 30000,
        durationMs: 1000,
        wavPath: wavPath,
      ),
    );
    expect(queued.stage, isNot(RecordingStage.ready), reason: '模型缺失时排队保留音频');
    expect(appStore.events, isEmpty);

    // 模型就绪后，用户在未连接录音卡状态下直接下拉刷新 Timeline
    models.paths = readyModels;
    final res1 = await appStore.syncRecordings();
    expect(res1, isNull, reason: '成功把本地待转写切片转出时静默落 Timeline');
    expect(gateway.filesCalls, 0, reason: '未连接录音卡不得访问蓝牙文件列表');
    expect(appStore.syncError, isNull);
    expect(appStore.events.length, 1);
    expect(appStore.events.single.title, contains('模型下载完成后下拉补转写'));

    // 再次下拉刷新：本机已无待转写切片，如实提示且 syncError 保持 null
    final res2 = await appStore.syncRecordings();
    expect(res2, contains('未连接录音卡'));
    expect(res2, contains('本地语音已是最新'));
    expect(appStore.syncError, isNull);
  });
}
