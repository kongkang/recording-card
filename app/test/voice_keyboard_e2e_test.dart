import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/ai/local_llm_models.dart';
import 'package:recording_card/services/ai/local_llm_service.dart';
import 'package:recording_card/services/ai/local_model_memory_guard.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/keyboard/voice_keyboard_ipc.dart';
import 'package:recording_card/services/keyboard/voice_keyboard_pipeline.dart';

import 'support/fake_gateway.dart';

class _StreamingVoiceGateway extends FakeCardGateway {
  final StreamController<RealtimeAudioEvent> audioController =
      StreamController<RealtimeAudioEvent>.broadcast();

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() => audioController.stream;

  @override
  Future<void> dispose() async {
    await audioController.close();
    await super.dispose();
  }
}

class _StubKeyboardLlmBackend implements LocalLlmBackend {
  _StubKeyboardLlmBackend(this.caps);
  final DeviceLlmCapabilities caps;
  int loadCalls = 0;

  @override
  Future<DeviceLlmCapabilities> probeCapabilities() async => caps;

  @override
  Future<void> loadModel({
    required String engine,
    required String? modelPath,
    required int nCtx,
    required bool useMetal,
    required bool quantizeKvQ8,
  }) async {
    loadCalls++;
  }

  @override
  Future<void> unloadModel() async {}

  @override
  Future<void> pauseAndDrain() async {}

  @override
  Stream<String> generateStream({
    required String requestId,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required double temperature,
  }) async* {
    yield '明天上午十点把端侧模型测试方案发到群里。';
  }

  @override
  Future<void> cancelGeneration(String requestId) async {}
}

Uint8List _speechPcm({required int durationMs, int sampleRate = 16000}) {
  final samples = (durationMs * sampleRate) ~/ 1000;
  final out = Uint8List(samples * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final v = (math.sin(2 * math.pi * 380 * i / sampleRate) * 10000).round();
    view.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

Uint8List _silencePcm({required int durationMs, int sampleRate = 16000}) {
  return Uint8List(((durationMs * sampleRate) ~/ 1000) * 2);
}

void main() {
  test('录音卡共享时间戳输入法全链路：推流实时波形 + 找气口切片 + ASR + 小模型润色回传键盘', () async {
    final root = await Directory.systemTemp.createTemp('rc_voice_kbd_e2e_');
    addTearDown(() => root.delete(recursive: true));

    // 安装占位 GGUF 小模型，验证 iPhone 13 mini (4GB) 走本地小模型润色路径
    final smallFile = File(
      '${root.path}/models/${qwen35SmallPolishSpec.id}/${qwen35SmallPolishSpec.fileName}',
    );
    await smallFile.create(recursive: true);
    await smallFile.writeAsBytes(const [1, 2, 3, 4]);

    var nowMs = 10000;
    final gateway = _StreamingVoiceGateway();
    final recorder = LiveAudioRecorder(
      gateway: gateway,
      baseDir: root,
      sliceDuration: const Duration(minutes: 1),
      clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
    );
    addTearDown(() async {
      await recorder.stop();
      recorder.dispose();
      await gateway.dispose();
    });

    final guard = LocalModelMemoryGuard();
    final backend = _StubKeyboardLlmBackend(
      const DeviceLlmCapabilities(
        platform: 'ios',
        physicalMemoryBytes: 4 * 1024 * 1024 * 1024,
        availableMemoryBytes: 1500 * 1024 * 1024,
        osMajorVersion: 18,
        machineModel: 'iPhone14,4',
        llamaRuntimeLinked: true,
      ),
    );
    final localLlm = LocalLlmService(
      backend: backend,
      memoryGuard: guard,
      locator: LocalLlmModelLocator(rootOverride: Directory('${root.path}/models')),
      clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
    );
    final ipc = InMemoryVoiceKeyboardIpc();
    addTearDown(() => ipc.dispose());

    var isRecordingActive = true;
    int? capturedSamplesLen;
    final kbdPipeline = VoiceKeyboardPipelineService(
      ringBuffer: recorder.ringBuffer,
      isRecordingActive: () => isRecordingActive,
      memoryGuard: guard,
      transcribeSamples: (samples, {sampleRate = 16000}) async {
        capturedSamplesLen = samples.length;
        return '嗯那个明天上午十点把端侧模型测试方案发到群里';
      },
      localLlm: localLlm,
      cloudPolishFallback: (raw) async => '云端兜底：$raw',
      cloudReady: () => true,
      ipc: ipc,
      trailingSettleWait: Duration.zero,
      waveformPushInterval: Duration.zero,
      clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
    );
    addTearDown(kbdPipeline.dispose);

    recorder.onAudioSamples = kbdPipeline.ingestLivePcmFrame;
    await recorder.start();
    gateway.audioController.add(const RealtimeAudioEvent(kind: RealtimeAudioKind.open));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // 先有一段前置静音 [10000..11200]
    nowMs = 11200;
    gateway.audioController.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _silencePcm(durationMs: 1200)),
    );
    // 开始说话 [11200..11700]，但用户到 11700ms 才在键盘点击开始！
    nowMs = 11700;
    gateway.audioController.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _speechPcm(durationMs: 500)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await kbdPipeline.handleCommandNow(
      const KeyboardTimestampCommand(
        type: VoiceKeyboardCommandType.start,
        timestampMs: 11700,
        sessionToken: 'kbd-1',
      ),
    );
    expect(kbdPipeline.isDictating, isTrue);

    // 说话继续 [11700..13900]，输入法期间实时收到波形帧
    for (var step = 0; step < 4; step++) {
      nowMs += 550;
      gateway.audioController.add(
        RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _speechPcm(durationMs: 550)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ipc.waveforms.where((w) => w.active).length, greaterThanOrEqualTo(4));
    expect(ipc.waveforms.last.bars32.length, 32);

    // 用户提前于 13900ms 松开按钮，但后半句持续到 14400ms 后才进入静音气口 [14400..15400]
    nowMs = 14400;
    gateway.audioController.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _speechPcm(durationMs: 500)),
    );
    nowMs = 15400;
    gateway.audioController.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _silencePcm(durationMs: 1000)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 15));

    await kbdPipeline.handleCommandNow(
      const KeyboardTimestampCommand(
        type: VoiceKeyboardCommandType.stop,
        timestampMs: 13900,
        sessionToken: 'kbd-1',
      ),
    );

    // 验证 ±2s 找气口确实把首尾半秒都补回来了（总时长 > 3.1s，即 > 49600 采样点）
    expect(capturedSamplesLen, isNotNull);
    expect(capturedSamplesLen!, greaterThan(49600));

    final doneResult = ipc.results.last;
    expect(doneResult.status, 'done');
    expect(doneResult.sessionToken, 'kbd-1');
    expect(doneResult.text, '明天上午十点把端侧模型测试方案发到群里。');
    expect(doneResult.routeLabel, LlmExecutionRoute.localSmall.label);
    expect(backend.loadCalls, 1);

    // 紧凑机型在输入法结束后自动清空槽位防杀后台
    expect(guard.activeSlot, LocalHeavyModelSlot.none);

    // 2) 未开启录音卡时触发输入法应明确报错，不静默卡死
    isRecordingActive = false;
    await kbdPipeline.handleCommandNow(
      const KeyboardTimestampCommand(
        type: VoiceKeyboardCommandType.start,
        timestampMs: 16000,
        sessionToken: 'kbd-2',
      ),
    );
    expect(ipc.results.last.status, 'error');
    expect(ipc.results.last.error, contains('请先在录音卡中开启录音'));
  });
}
