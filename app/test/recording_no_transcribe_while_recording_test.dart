import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';

class _CountingSpeechEngine implements SpeechEngine {
  int transcribeCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
    String? nativeLibraryPath,
  }) async {}

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => [SpeechSpan(0, samples.length)];

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    transcribeCalls++;
    return const AsrResult(
      text: '停录后才触发的转写内容',
      tokens: ['停录'],
      timestampsMs: [0],
      audioMs: 1000,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _ReadyModels implements SpeechModelProvider {
  _ReadyModels(this.root);
  final Directory root;

  @override
  Future<SpeechModelPaths?> resolve() async {
    final dir = Directory('${root.path}/models');
    if (!await dir.exists()) await dir.create(recursive: true);
    final m = File('${dir.path}/model.onnx')..writeAsBytesSync(const [1]);
    final t = File('${dir.path}/tokens.txt')..writeAsStringSync('a 0\n');
    final v = File('${dir.path}/vad.onnx')..writeAsBytesSync(const [1]);
    return SpeechModelPaths(
      asrModelPath: m.path,
      tokensPath: t.path,
      vadPath: v.path,
    );
  }
}

Future<String> _writeDummyWav(Directory root, String name, int durationMs) async {
  final sampleCount = (16000 * durationMs) ~/ 1000;
  final dataBytes = sampleCount * 2;
  final out = Uint8List(44 + dataBytes);
  final h = ByteData.sublistView(out, 0, 44);
  out.setRange(0, 4, 'RIFF'.codeUnits);
  h.setUint32(4, 36 + dataBytes, Endian.little);
  out.setRange(8, 12, 'WAVE'.codeUnits);
  out.setRange(12, 16, 'fmt '.codeUnits);
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, 16000, Endian.little);
  h.setUint32(28, 32000, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  out.setRange(36, 40, 'data'.codeUnits);
  h.setUint32(40, dataBytes, Endian.little);
  final file = File('${root.path}/$name');
  await file.writeAsBytes(out, flush: true);
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('录音过程中只录音不转写（含超过批量周期阈值），停录后才统一转写', () async {
    final root = await Directory.systemTemp.createTemp('rc_rec_no_asr_');
    addTearDown(() => root.delete(recursive: true));

    final gateway = FakeCardGateway();
    final recStore = RecordingStore(root: Directory('${root.path}/store'));
    final engine = _CountingSpeechEngine();
    final pipeline = RecordingPipeline(
      gateway: gateway,
      store: recStore,
      engine: engine,
      models: _ReadyModels(root),
      liveAudioBaseDir: root,
    );
    final status = RecordingStatusController();
    final generator = await SummaryModel().generator();
    final appStore = AppStore(status: status, loadPersistedState: false)
      ..deferredBatchTranscription = true
      ..pauseTranscriptionWhileRecording = true
      ..transcribeCycleMinutes = 1 // 极小周期验证录音期也不触发
      ..attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: generator,
        status: status,
      )
      ..deviceRecording = () => status.sessionActive;
    addTearDown(status.dispose);
    addTearDown(appStore.dispose);

    // 1) 开始录音，录满 2 分钟切片（已超过 1 分钟周期）
    status.startRecording();
    final wav1 = await _writeDummyWav(root, 's1.wav', 60 * 1000);
    final wav2 = await _writeDummyWav(root, 's2.wav', 60 * 1000);

    await appStore.ingestLiveSlice(
      LiveAudioSlice(
        sessionId: 'SES_REC_1',
        sliceIndex: 0,
        startAtMs: DateTime(2026, 11, 28, 10, 0).millisecondsSinceEpoch,
        durationMs: 60 * 1000,
        wavPath: wav1,
      ),
    );
    await appStore.ingestLiveSlice(
      LiveAudioSlice(
        sessionId: 'SES_REC_1',
        sliceIndex: 1,
        startAtMs: DateTime(2026, 11, 28, 10, 1).millisecondsSinceEpoch,
        durationMs: 60 * 1000,
        wavPath: wav2,
      ),
    );

    // 切回页面或触发 view-resume 也不得在录音期间偷跑 ASR
    await appStore.transcribeAndOrganizePending(reason: 'view-resume');
    expect(engine.transcribeCalls, 0);
    expect(appStore.pendingLocalAudioCount, 2);

    // 2) 停录后调用 finishLiveRecording，立刻触发待转写队列完成转写
    status.stopRecording();
    await appStore.finishLiveRecording();

    expect(engine.transcribeCalls, greaterThanOrEqualTo(2));
    expect(appStore.pendingLocalAudioCount, 0);
    expect(appStore.events, isNotEmpty);
  });
}
