import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/recordings/speaker_profile_store.dart';
import 'package:recording_card/services/schedule/organize_pass_service.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/services/segment/rolling_clean_segment_service.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speaker_clusterer.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/system_speech_client.dart';
import 'package:recording_card/services/transcribe/utterance_builder.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

import 'support/fake_gateway.dart';

const int _rate = 16000;

/// 生成指定时长（毫秒）的 16kHz 16-bit 单声道 PCM：
/// [amplitude] 为峰值（0..32767）；传 0 生成静音。
Uint8List _pcmMs(int durationMs, {int amplitude = 5000}) {
  final samples = durationMs * _rate ~/ 1000;
  final bytes = Uint8List(samples * 2);
  if (amplitude <= 0) return bytes;
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    final v = (amplitude * math.sin(2 * math.pi * 220 * i / _rate)).round();
    view.setInt16(i * 2, v.clamp(-32768, 32767), Endian.little);
  }
  return bytes;
}

class _TrackingSpeechEngine implements SpeechEngine {
  List<SpeechSpan> spans = const [];
  String nextText = '测试语音识别内容。';
  String? lastLoadedLanguage;
  int loadCalls = 0;
  int vadLoadCalls = 0;
  int detectCalls = 0;
  int transcribeCalls = 0;
  int embedCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {
    loadCalls++;
    lastLoadedLanguage = language;
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
  Future<void> loadVad(String vadPath) async {
    vadLoadCalls++;
  }

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    detectCalls++;
    return spans;
  }

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    embedCalls++;
    return const [1.0, 0.0, 0.0];
  }

  @override
  Future<void> dispose() async {}
}

class _FixedModels implements SpeechModelProvider {
  const _FixedModels(this.paths);
  final SpeechModelPaths? paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

class _MockChat implements ChatCompletion {
  _MockChat(this.handler);
  final FutureOr<String> Function(List<ChatMessage> messages, String model)
  handler;
  int calls = 0;
  final List<String> userPayloads = [];

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    calls++;
    userPayloads.add(messages.last.content);
    return await handler(messages, model);
  }
}

class _SpeechWavFakeGateway extends FakeCardGateway {
  _SpeechWavFakeGateway({required this.wavSamples});
  final Float32List wavSamples;

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async {
    transcodeCalls++;
    await Directory(File(wavPath).parent.path).create(recursive: true);
    await File(wavPath).writeAsBytes(encodeWav(wavSamples), flush: true);
    return CardAudio(
      path: wavPath,
      samples: wavSamples.length,
      durationSecs: wavSamples.length / _rate,
    );
  }
}

const _defaultPaths = SpeechModelPaths(
  asrModelPath: '/models/sensevoice.onnx',
  tokensPath: '/models/tokens.txt',
  vadPath: '/models/silero_vad.onnx',
  speakerEmbeddingPath: '/models/campplus.onnx',
);

void main() {
  group('1. Energy-Valley Soft-Boundary Live Slicing & marksMs', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rc-soft-slice-');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test(
      'LiveAudioRecorder 在达到 75% (45s) 后遇到 >=300ms 低能量谷底立即软切，不丢采样不漂移时间戳',
      () async {
        final gw = FakeCardGateway();
        // 0..48.0s 持续说话 + 48.0..48.45s 静音停顿 (450ms) + 48.45..65.0s 持续说话
        final events = <RealtimeAudioEvent>[
          const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
        ];
        // 分块推送模拟真实 BLE 流（每包 500ms，停顿段按 50ms 细粒度包）
        for (var t = 0; t < 48000; t += 500) {
          events.add(
            RealtimeAudioEvent(
              kind: RealtimeAudioKind.audio,
              pcm: _pcmMs(500, amplitude: 5500),
            ),
          );
        }
        for (var t = 0; t < 450; t += 50) {
          events.add(
            RealtimeAudioEvent(
              kind: RealtimeAudioKind.audio,
              pcm: _pcmMs(50, amplitude: 20),
            ),
          );
        }
        for (var t = 0; t < 16550; t += 500) {
          final chunkMs = math.min(500, 16550 - t);
          events.add(
            RealtimeAudioEvent(
              kind: RealtimeAudioKind.audio,
              pcm: _pcmMs(chunkMs, amplitude: 5500),
            ),
          );
        }
        gw.realtimeEvents.addAll(events);

        final slices = <LiveAudioSlice>[];
        final startClock = DateTime.fromMillisecondsSinceEpoch(1795000000000);
        final recorder = LiveAudioRecorder(
          gateway: gw,
          baseDir: tmp,
          sliceDuration: const Duration(seconds: 60),
          onSliceReady: slices.add,
          clock: () => startClock,
        );

        await recorder.start();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await recorder.pendingSliceWrites;

        // 录音尚未停止，首片应在 48.3s 静音谷底提前封口，绝不等到 60.0s 硬切半个词
        expect(slices.length, 1);
        expect(slices.first.isFinal, isFalse);
        expect(slices.first.durationMs, greaterThanOrEqualTo(48250));
        expect(slices.first.durationMs, lessThanOrEqualTo(48450));

        final session = await recorder.stop();
        expect(session, isNotNull);
        expect(slices.length, 2);
        expect(slices[1].isFinal, isTrue);

        // 时间戳严格连续，零漂移；总采样数精确守恒（65.000s = 1,040,000 samples）
        expect(slices[0].startAtMs, startClock.millisecondsSinceEpoch);
        expect(
          slices[1].startAtMs,
          slices[0].startAtMs + slices[0].durationMs,
        );
        final wav0 = readWavFile(slices[0].wavPath);
        final wav1 = readWavFile(slices[1].wavPath);
        expect(wav0.frames + wav1.frames, 65 * _rate);
      },
    );

    test(
      'LiveAudioRecorder 若连续说话无 >=300ms 停顿则在 60s 硬上限兜底切分',
      () async {
        final gw = FakeCardGateway();
        final events = <RealtimeAudioEvent>[
          const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
          for (var i = 0; i < 65; i++)
            RealtimeAudioEvent(
              kind: RealtimeAudioKind.audio,
              pcm: _pcmMs(1000, amplitude: 6000),
            ),
        ];
        gw.realtimeEvents.addAll(events);

        final slices = <LiveAudioSlice>[];
        final recorder = LiveAudioRecorder(
          gateway: gw,
          baseDir: tmp,
          sliceDuration: const Duration(seconds: 60),
          onSliceReady: slices.add,
        );
        await recorder.start();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await recorder.pendingSliceWrites;

        expect(slices.length, 1);
        expect(slices.first.durationMs, 60000);
        await recorder.stop();
        expect(slices.length, 2);
        expect(slices[1].durationMs, 5000);
      },
    );

    test(
      'PhoneMicRecorder 在 75% 软边界后遇到 >=300ms 静音谷底软切且采样精确守恒',
      () async {
        final slices = <LiveAudioSlice>[];
        final startClock = DateTime.fromMillisecondsSinceEpoch(1795000100000);
        final mic = PhoneMicRecorder(
          sliceDuration: const Duration(seconds: 60),
          sliceRootDir: () async => Directory('${tmp.path}/phone_slices'),
          clock: () => startClock,
        );
        addTearDown(mic.dispose);
        final sub = mic.slices.listen(slices.add);
        addTearDown(sub.cancel);

        await mic.start(startedAt: startClock);
        // 0..47.0s 持续人声 -> 47.0..47.35s 350ms 停顿 -> 47.35..62.0s 持续人声
        mic.ingestPcm(_pcmMs(47000, amplitude: 5000));
        mic.ingestPcm(_pcmMs(350, amplitude: 15));
        mic.ingestPcm(_pcmMs(14650, amplitude: 5000));
        await mic.stop();

        expect(slices.length, 2);
        expect(slices[0].isFinal, isFalse);
        expect(slices[0].durationMs, greaterThanOrEqualTo(47250));
        expect(slices[0].durationMs, lessThanOrEqualTo(47350));
        expect(slices[1].isFinal, isTrue);
        expect(
          slices[1].startAtMs,
          slices[0].startAtMs + slices[0].durationMs,
        );

        final f0 = readWavFile(slices[0].wavPath);
        final f1 = readWavFile(slices[1].wavPath);
        expect(f0.frames + f1.frames, 62 * _rate);
      },
    );

    test(
      'PhoneMicRecorder 奇数散字节跨 flushActiveSlice 不错位不丢采样',
      () async {
        final sliceDir = Directory('${tmp.path}/odd_phone_slices')
          ..createSync(recursive: true);

        final emitted = <LiveAudioSlice>[];
        final startClock = DateTime.fromMillisecondsSinceEpoch(1795000200000);
        final mic = PhoneMicRecorder(
          sliceDuration: const Duration(seconds: 60),
          sliceRootDir: () async => sliceDir,
          clock: () => startClock,
        );
        addTearDown(mic.dispose);
        final sub = mic.slices.listen(emitted.add);
        addTearDown(sub.cancel);

        // 构造确定性 16-bit LE 样本序列（共 16000 个样本 = 1.000s = 32000 字节），
        // 故意在第 8000 个样本中间（第 16001 字节：低字节已到、高字节未到）劈成两半，
        // 并在中间调用 flushActiveSlice()！
        const totalSamples = 16000;
        final fullPcm = Uint8List(totalSamples * 2);
        final fullBd = ByteData.sublistView(fullPcm);
        for (var i = 0; i < totalSamples; i++) {
          final sampleVal = ((i * 37) % 20000) - 10000;
          fullBd.setInt16(i * 2, sampleVal, Endian.little);
        }

        final oddPart1 = Uint8List.sublistView(fullPcm, 0, 16001); // 8000 samples + 1 low byte
        final oddPart2 = Uint8List.sublistView(fullPcm, 16001); // 1 high byte + 7999 samples

        await mic.start(startedAt: startClock);
        mic.ingestPcm(oddPart1);
        final flushed = await mic.flushActiveSlice();
        expect(flushed, isTrue);
        mic.ingestPcm(oddPart2);
        await mic.stop();

        expect(emitted.length, 2);
        final wav0 = readWavFile(emitted[0].wavPath);
        final wav1 = readWavFile(emitted[1].wavPath);
        expect(wav0.frames, 8000);
        expect(wav1.frames, 8000);
        expect(wav0.frames + wav1.frames, totalSamples);

        // 逐样本核对：跨 flushActiveSlice 边界的第 8000 号样本及后续所有样本绝无字节错位！
        final recon = BytesBuilder(copy: false)
          ..add(
            Uint8List.sublistView(
              wav0.bytes,
              wav0.dataOffset,
              wav0.dataOffset + wav0.dataLength,
            ),
          )
          ..add(
            Uint8List.sublistView(
              wav1.bytes,
              wav1.dataOffset,
              wav1.dataOffset + wav1.dataLength,
            ),
          );
        final reconBytes = recon.takeBytes();
        expect(reconBytes.length, fullPcm.length);
        final reconBd = ByteData.sublistView(reconBytes);
        for (var i = 0; i < totalSamples; i++) {
          expect(
            reconBd.getInt16(i * 2, Endian.little),
            fullBd.getInt16(i * 2, Endian.little),
            reason: 'Sample #$i byte-shifted after odd-byte flushActiveSlice!',
          );
        }
      },
    );

    testWidgets(
      'PhoneMicRecorder 在 FakeAsync 组件测试内 start/stop 零挂起零残留 Timer',
      (tester) async {
        final startClock = DateTime.fromMillisecondsSinceEpoch(1795000300000);
        final mic = PhoneMicRecorder(clock: () => startClock);
        addTearDown(mic.dispose);
        await mic.start(startedAt: startClock);
        expect(await mic.flushActiveSlice(), isFalse);
        await mic.stop();
        await tester.pump();
      },
    );

    test(
      'LiveAudioSlice.marksMs 透传至 RecordingPipeline.ingestLiveSlice -> SegmentRecord.mark',
      () async {
        final wavPath = '${tmp.path}/marked_live.wav';
        final samples = Float32List(_rate * 4);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = 0.2 * math.sin(2 * math.pi * 200 * i / _rate);
        }
        await File(wavPath).writeAsBytes(encodeWav(samples), flush: true);

        final store = RecordingStore(
          root: Directory('${tmp.path}/store'),
          jsonStore: JsonStore(store: InMemoryStore()),
        );
        final engine = _TrackingSpeechEngine()
          ..spans = const [SpeechSpan(0, _rate * 4)]
          ..nextText = '这里有一段按物理键打点的重点内容。';
        final pipeline = RecordingPipeline(
          gateway: FakeCardGateway(),
          store: store,
          engine: engine,
          models: const _FixedModels(_defaultPaths),
        );

        final baseEpoch = DateTime(2026, 11, 19, 14, 5).millisecondsSinceEpoch;
        final slice = LiveAudioSlice(
          sessionId: 'live-mark-1',
          deviceSessionId: 'MARK0001',
          sliceIndex: 0,
          startAtMs: baseEpoch,
          durationMs: 4000,
          wavPath: wavPath,
          gapCount: 1,
          marksMs: const [2000],
        );

        final recorded = await pipeline.ingestLiveSlice(slice);
        expect(recorded.segments, hasLength(1));
        final mark = recorded.segments.single.mark;
        expect(mark, isNotNull);
        expect(mark, contains('14:05'));
        expect(mark, contains('流中断 1 次'));

        // 无语音但有 marksMs 的切片也不得在投影层被静默折叠吞掉
        final silentEngine = _TrackingSpeechEngine()..spans = const [];
        final silentPipeline = RecordingPipeline(
          gateway: FakeCardGateway(),
          store: store,
          engine: silentEngine,
          models: const _FixedModels(_defaultPaths),
        );
        final silentWav = '${tmp.path}/silent_marked.wav';
        await File(silentWav).writeAsBytes(
          encodeWav(Float32List(_rate * 2)),
          flush: true,
        );
        final fA = await silentPipeline.ingestLiveSlice(
          LiveAudioSlice(
            sessionId: 'live-mark-2',
            sliceIndex: 0,
            startAtMs: baseEpoch + 60000,
            durationMs: 2000,
            wavPath: silentWav,
          ),
        );
        final fMarked = await silentPipeline.ingestLiveSlice(
          LiveAudioSlice(
            sessionId: 'live-mark-2',
            sliceIndex: 1,
            startAtMs: baseEpoch + 120000,
            durationMs: 2000,
            wavPath: silentWav,
            marksMs: const [1000],
          ),
        );
        final proj = SegmentProjection.build([fA, fMarked]);
        expect(proj.events.length, 2, reason: '带 marksMs 的静音切片不得被吞并');
      },
    );
  });

  group('2. Optimal SenseVoice SlicePlanner & Silero VAD Alignment', () {
    test('SlicePlanner 默认窗口对齐 SenseVoice 最佳 25s/35s/450ms/12s', () {
      const planner = SlicePlanner();
      expect(planner.targetDuration, const Duration(seconds: 25));
      expect(planner.maxDuration, const Duration(seconds: 35));
      expect(planner.minSilence, const Duration(milliseconds: 450));
      expect(planner.longSilence, const Duration(seconds: 12));

      // 连续 120s 语音：单片绝不超过 35s
      final slices = planner.plan(
        speech: const [SpeechSpan(0, 120 * _rate)],
        totalSamples: 120 * _rate,
        sampleRate: _rate,
      );
      expect(slices.length, greaterThanOrEqualTo(4));
      for (final s in slices) {
        expect(s.length, lessThanOrEqualTo(35 * _rate));
      }
    });

    test('SlicePlanner 最后一片保留 WAV 尾部真实静音时长（不再写死 0）', () {
      const planner = SlicePlanner();
      final slices = planner.plan(
        speech: const [
          SpeechSpan(1 * _rate, 15 * _rate),
          SpeechSpan(30 * _rate, 40 * _rate),
        ],
        totalSamples: 105 * _rate,
        sampleRate: _rate,
      );
      expect(slices.length, 2);
      // 第一片与第二片之间 15s 静音
      expect(slices.first.silenceAfterSamples, 15 * _rate);
      // 最后一片语音结束于 40s，WAV 总长 105s → 尾部真实静音 65s（>= 1 分钟空白触发话题切分关键依据）
      expect(slices.last.silenceAfterSamples, 65 * _rate);
      expect(slices.last.silenceAfterMs(_rate), 65000);
    });

    test('SileroVadModelConfig 对齐 minSilenceDuration=0.45 与 maxSpeechDuration=28', () {
      final cfg = LocalAsrService.buildSileroVadConfig('/models/silero_vad.onnx');
      expect(cfg.minSilenceDuration, closeTo(0.45, 1e-6));
      expect(cfg.maxSpeechDuration, closeTo(28.0, 1e-6));
    });
  });

  group('3. Single-Pass Conditioning, Zero Model Thrashing & Diarization Calibration', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rc-cond-asr-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('conditionSpeechSamples 对极微弱衣服摩擦底噪限制最大增益（禁 24x 幻觉放大）且二次调用幂等', () {
      // 模拟极微弱环境摩擦声：峰值 ~0.0022 (约 72/32768, p95Rms ≈ 0.0015)
      final rustle = Float32List(_rate * 2);
      for (var i = 0; i < rustle.length; i++) {
        rustle[i] = 0.0022 * math.sin(2 * math.pi * 180 * i / _rate);
      }
      final once = conditionSpeechSamples(rustle);
      var peakOnce = 0.0;
      for (final s in once) {
        if (s.abs() > peakOnce) peakOnce = s.abs();
      }
      // 旧逻辑 24x 放大后峰值高达 ~0.053；限幅后应远低于 0.015（增益 < 5x）
      expect(peakOnce, lessThan(0.015));

      // 二次重复调用不得再次叠加增益或滤波失真
      final twice = conditionSpeechSamples(once);
      var peakTwice = 0.0;
      for (final s in twice) {
        if (s.abs() > peakTwice) peakTwice = s.abs();
      }
      expect(peakTwice, closeTo(peakOnce, 1e-6));
    });

    test('RecordingPipeline 默认 language=auto 零模型颠簸，且 _processFile 具备 30s 声学能量兜底', () async {
      // 45s 含清晰人声包络的录音，模拟 VAD 漏检返回空 spans
      final samples = Float32List(_rate * 45);
      for (var i = 0; i < samples.length; i++) {
        final env = (i ~/ (_rate ~/ 2)).isEven ? 0.08 : 0.002;
        samples[i] = env * math.sin(2 * math.pi * 240 * i / _rate);
      }
      final gw = _SpeechWavFakeGateway(wavSamples: samples)
        ..writeDownload = true
        ..deviceFiles = const [
          CardFile(
            name: 'FALLBACK45.APM',
            size: 32000,
            startAtSec: 1795000000,
            session: 'SES_FB',
            seq: 1,
            synced: true,
          ),
        ];
      final store = RecordingStore(
        root: Directory('${tmp.path}/store'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final engine = _TrackingSpeechEngine()
        ..spans = const [] // VAD 漏检
        ..nextText = '离线同步文件的声学兜底成功识别。';

      final pipeline = RecordingPipeline(
        gateway: gw,
        store: store,
        engine: engine,
        models: const _FixedModels(_defaultPaths),
      );

      expect(pipeline.language, 'auto');
      final res = await pipeline.sync();
      expect(res.ready, 1);
      expect(engine.lastLoadedLanguage, 'auto');
      // 45s 按 30s 兜底窗口拆为 2 片（30s + 15s）
      expect(engine.transcribeCalls, 2);

      final saved = (await store.load('FALLBACK45.APM'))!;
      expect(saved.utterances, isNotEmpty);
      expect(saved.utterances.first.text, contains('声学兜底成功识别'));
    });

    test('SystemSpeechClient 有现成 wavPath 时直接转写原文件，不重复编码临时 WAV', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const ch = MethodChannel('com.reai.recordingcard/system_speech');
      final capturedPaths = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
            if (call.method == 'requestAuthorization') return 'authorized';
            if (call.method == 'transcribeWav') {
              final args = call.arguments as Map<Object?, Object?>;
              capturedPaths.add(args['wavPath'] as String);
              return <Object?, Object?>{
                'text': '直接使用切片路径完成系统转写',
                'tokens': const ['直', '接', '转', '写'],
                'timestampsMs': const [100, 250, 400, 600],
                'lang': 'zh-CN',
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ch, null);
      });

      final existingWav = File('${tmp.path}/direct_slice.wav');
      final cleanSamples = Float32List(_rate * 2);
      for (var i = 0; i < cleanSamples.length; i++) {
        cleanSamples[i] = 0.15 * math.sin(2 * math.pi * 220 * i / _rate);
      }
      await existingWav.writeAsBytes(encodeWav(cleanSamples), flush: true);

      final client = SystemSpeechClient(
        channel: ch,
        debugForceNativePlatform: true,
      );
      final out = await client.transcribeSamples(
        cleanSamples,
        wavPath: existingWav.path,
      );

      expect(out.text, '直接使用切片路径完成系统转写');
      expect(capturedPaths, [existingWav.path]);
      expect(
        capturedPaths.single.contains('rc_sys_asr_'),
        isFalse,
        reason: '已有合法 wavPath 时不得再编码临时 WAV',
      );
      expect(await existingWav.exists(), isTrue, reason: '原切片 WAV 不得被误删');
    });

    test('utterance_builder 容忍 SenseVoice ITN 数字/标点/空格差异并保留真实 token 时间戳', () {
      // SenseVoice ITN 把 tokens 中的「三」「十」转成阿拉伯数字并补了标点，
      // 旧版因 _normalize(joined) != _normalize(text) 直接丢弃全部 token 时间戳！
      final utterances = buildUtterancesFromAsr(
        sliceId: '0001',
        sliceStartMs: 10000,
        sliceEndMs: 40000,
        text: '下午3点半开会，记得带转换器。明天上午10点复盘。',
        tokens: const [
          '下', '午', '三', '点', '半', '开', '会',
          '记', '得', '带', '转', '换', '器',
          '明', '天', '上', '午', '十', '点', '复', '盘',
        ],
        tokenTimestampsMs: const [
          200, 350, 500, 650, 800, 950, 1100, // 200..1100ms
          2200, 2350, 2500, 2650, 2800, 2950, // 停顿 1100ms -> 2200..2950ms
          5500, 5650, 5800, 5950, 6100, 6250, 6400, 6550, // 停顿 2550ms -> 5500..6550ms
        ],
      );

      // 若退化为比例切分，第 2 句起点会被拉到 ~25000ms；保留 token 对齐则精确落在 12200ms / 15500ms！
      expect(utterances.length, greaterThanOrEqualTo(2));
      expect(utterances.first.startMs, 10200);
      expect(utterances.last.startMs, 15500);
      expect(
        utterances.map((u) => u.text).join(),
        contains('3点半'),
      );
    });

    test('SpeakerClusterer 短切片自适应 1200ms 保留 1.5s 简短回应，且 SessionSpeakerMatcher 默认阈值降至 0.70', () {
      const clusterer = SpeakerClusterer();
      // 短切片（总语音 13.5s <= 90s）：说话人 B 简短回应 1500ms（"好的，没问题"）
      final shortRes = clusterer.cluster(const [
        SpeakerSample(id: 'u1', embedding: [1.0, 0.0, 0.0], durationMs: 6000),
        SpeakerSample(id: 'u2', embedding: [0.0, 1.0, 0.0], durationMs: 1500),
        SpeakerSample(id: 'u3', embedding: [0.99, 0.05, 0.0], durationMs: 6000),
      ]);
      final shortById = {for (final a in shortRes.assignments) a.id: a};
      expect(shortRes.speakerCount, 2);
      expect(shortById['u2']!.known, isTrue, reason: '短切片内 1.5s 回应不得抹成未区分');

      // 长录音（总语音 > 90s）：孤立 1500ms 杂音仍按 2500ms 门槛判未区分
      final longRes = clusterer.cluster(const [
        SpeakerSample(id: 'l1', embedding: [1.0, 0.0, 0.0], durationMs: 55000),
        SpeakerSample(id: 'l2', embedding: [0.0, 1.0, 0.0], durationMs: 45000),
        SpeakerSample(id: 'noise', embedding: [0.0, 0.0, 1.0], durationMs: 1500),
      ]);
      final longById = {for (final a in longRes.assignments) a.id: a};
      expect(longRes.speakerCount, 2);
      expect(longById['noise']!.cluster, -1);

      // SessionSpeakerMatcher 默认阈值 0.70：跨文件相似度 0.72 应沿用已有说话人编号
      const matcher = SessionSpeakerMatcher();
      expect(matcher.matchThreshold, closeTo(0.70, 1e-6));
      final first = matcher.assign(
        existing: SpeakerProfileSet.empty('SES_1'),
        fileCentroids: const {0: [1.0, 0.0, 0.0]},
        clusterSpeechMs: const {0: 8000},
        deviceName: 'F1.APM',
      );
      final second = matcher.assign(
        existing: first.profiles,
        fileCentroids: {
          0: [0.72, math.sqrt(1 - 0.72 * 0.72), 0.0],
        },
        clusterSpeechMs: const {0: 5000},
        deviceName: 'F2.APM',
      );
      expect(second.clusterToSpeaker[0], 0);
      expect(second.profiles.profiles.length, 1);
    });
  });

  group('4. Zero Triple-Redundant Cloud Calls, Concurrency Lock & Timestamp Preservation', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rc-clean-pipe-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('RecordingPipeline 挂载 rollingCleaner 时 _processFile 自动跳过旧云端 polish+segments，零重复调云并生成本地分段', () async {
      final samples = Float32List(_rate * 10);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = 0.12 * math.sin(2 * math.pi * 200 * i / _rate);
      }
      final gw = _SpeechWavFakeGateway(wavSamples: samples)
        ..writeDownload = true
        ..deviceFiles = const [
          CardFile(
            name: 'SYNC01.APM',
            size: 16000,
            startAtSec: 1795000500,
            session: 'SES_SYNC',
            seq: 1,
            synced: true,
          ),
        ];
      final store = RecordingStore(
        root: Directory('${tmp.path}/store'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final engine = _TrackingSpeechEngine()
        ..spans = const [SpeechSpan(0, _rate * 10)]
        ..nextText = '周三下午对齐一下硬件量产排期。';
      final chat = _MockChat((_, _) => '{"title":"t","overview":"o"}');

      final pipeline = RecordingPipeline(
        gateway: gw,
        store: store,
        engine: engine,
        models: const _FixedModels(_defaultPaths),
        polish: SlicePolishService(chat: chat, model: 'qwen-plus'),
        segments: SegmentBuildService(chat: chat, model: 'qwen-plus'),
        rollingCleaner: RollingCleanSegmentService(
          chat: chat,
          model: 'qwen-plus',
          resolveRoot: store.root,
        ),
      );

      final report = await pipeline.sync();
      expect(report.ready, 1);
      expect(chat.calls, 0, reason: '挂载 rollingCleaner 时同步阶段绝不重复调旧 polish/segments 云接口');

      final file = (await store.load('SYNC01.APM'))!;
      expect(file.stage, RecordingStage.ready);
      expect(file.segments, isNotEmpty, reason: '必须生成干净的本地确定性 SegmentRecord 供时间轴与滚动清洗消费');
      expect(file.segments.first.title, contains('周三下午对齐一下硬件量产排期'));
    });

    test('RollingCleanSegmentService 按真实语音起点判 hasLaterGroup，且历史 30s..59s 间隔组严格遵守纯声学不调云', () async {
      final store = RecordingStore(
        root: Directory('${tmp.path}/roll_store'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final topicStore = TopicSegmentationStore(resolveRoot: store.root);
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      await cfg.setCleanCycleMinutes(10);

      final todayBase = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;

      RecordingFile makeSpeechFile({
        required String name,
        required int containerStartMs,
        required int durationMs,
        required int uttRelStartMs,
        required int uttRelEndMs,
        required String text,
      }) => RecordingFile(
        deviceName: name,
        session: 'SES_GAP',
        seq: 1,
        startAtMs: containerStartMs,
        apmPath: '${tmp.path}/$name',
        createdAtMs: containerStartMs,
        durationMs: durationMs,
        timeSynced: true,
        stage: RecordingStage.ready,
        slices: [
          AudioSlice(
            id: 's0',
            index: 0,
            startMs: 0,
            endMs: durationMs,
            wavPath: '',
          ),
        ],
        utterances: [
          RawUtterance(
            id: 'u0',
            sliceId: 's0',
            startMs: uttRelStartMs,
            endMs: uttRelEndMs,
            text: text,
            speakerLabel: '说话人 1',
            spkConfidence: 0.9,
          ),
        ],
        segments: [
          SegmentRecord(
            id: 'seg-$name',
            sessionId: 'SES_GAP',
            index: 0,
            startAtMs: containerStartMs,
            endAtMs: containerStartMs + durationMs,
            title: text,
            brief: text,
            status: SegmentStatus.closed,
            sliceIds: const ['s0'],
          ),
        ],
      );

      // 场景 A：Group 0 语音结束于 +50s；Group 1 容器始于 +60s（容器差仅 10s），
      // 但真实首句始于 +115s（真实静音 65s >= 60s），当前时刻 +105s（甚至距 G0 结束仅 55s < 60s，
      // 唯有靠 nextUnits.first.absStartMs - units.last.absEndMs >= 60s 才能命中触发！）。
      final g0 = makeSpeechFile(
        name: 'G0.WAV',
        containerStartMs: todayBase,
        durationMs: 60000,
        uttRelStartMs: 10000,
        uttRelEndMs: 50000,
        text: '第一组在五十秒说完的话题。',
      );
      final g1 = makeSpeechFile(
        name: 'G1.WAV',
        containerStartMs: todayBase + 60000,
        durationMs: 70000,
        uttRelStartMs: 55000, // absStart = +115s -> 距 g0 结束 +50s 真实静音达 65s!
        uttRelEndMs: 65000,
        text: '第二组在一百一十五秒才开口。',
      );

      final chatA = _MockChat((_, _) => jsonEncode({
            'sections': [
              {
                'continuesPrevious': false,
                'title': '第一组整理标题',
                'summary': '摘要',
                'paragraphs': [
                  {'uStart': 0, 'uEnd': 0, 'speaker': '说话人 1', 'text': '第一组在五十秒说完的话题。'},
                ],
              },
            ],
          }));
      final cleanerA = RollingCleanSegmentService(
        chat: chatA,
        model: 'qwen-plus',
        resolveRoot: store.root,
        agentConfig: cfg,
      );
      expect(
        cleanerA.hasReadyTrigger(
          [g0, g1],
          const TopicSegmentationState.empty(),
          wallClockNowMs: todayBase + 105000,
        ),
        isTrue,
        reason: '真实语音间隔 65s >= 60s，不能被容器起点 +60s 误判为仅差 10s',
      );
      final resA = await cleanerA.run(
        [g0, g1],
        topicStore: topicStore,
        wallClockNowMs: todayBase + 105000,
      );
      expect(chatA.calls, 1);
      expect(resA.state.rollingByAnchor.containsKey('seg-G0.WAV'), isTrue);
      expect(resA.state.rollingByAnchor.containsKey('seg-G1.WAV'), isFalse);
      await topicStore.clear();

      // 场景 B：历史闭合组 H0 (0..20s) 与 H1 (65s..85s) 之间仅停顿 45s（落入 30s..59s 纯声学拆段区间！），
      // H1 之后在 +200s..210s 有 H2（H1 与 H2 间隔 115s >= 60s），当前时刻 +220s。
      // 旧版因 nowMs - H0.endMs = 200s >= 60s 错误触发了 H0 上云！修复后 H0 必须跳过，仅 H1 触发上云。
      final h0 = makeSpeechFile(
        name: 'H0.WAV',
        containerStartMs: todayBase,
        durationMs: 30000,
        uttRelStartMs: 0,
        uttRelEndMs: 20000,
        text: '仅隔四十五秒的历史短片段不该调云端。',
      );
      final h1 = makeSpeechFile(
        name: 'H1.WAV',
        containerStartMs: todayBase + 60000,
        durationMs: 30000,
        uttRelStartMs: 5000, // absStart = +65s (距 H0 结束 45s)
        uttRelEndMs: 25000, // absEnd = +85s
        text: '随后静音超过一分钟的第二段才应该调云端。',
      );
      final h2 = makeSpeechFile(
        name: 'H2.WAV',
        containerStartMs: todayBase + 195000,
        durationMs: 20000,
        uttRelStartMs: 5000, // absStart = +200s (距 H1 结束 115s >= 60s)
        uttRelEndMs: 15000, // absEnd = +210s (距 now +220s 仅 10s < 60s)
        text: '正在进行中的第三段尚未满一分钟停顿。',
      );

      final chatB = _MockChat((_, _) => jsonEncode({
            'sections': [
              {
                'continuesPrevious': false,
                'title': '合规触发段标题',
                'summary': '摘要',
                'paragraphs': [
                  {'uStart': 0, 'uEnd': 0, 'speaker': '说话人 1', 'text': '随后静音超过一分钟的第二段才应该调云端。'},
                ],
              },
            ],
          }));
      final cleanerB = RollingCleanSegmentService(
        chat: chatB,
        model: 'qwen-plus',
        resolveRoot: store.root,
        agentConfig: cfg,
      );
      final resB = await cleanerB.run(
        [h0, h1, h2],
        topicStore: topicStore,
        wallClockNowMs: todayBase + 220000,
      );

      expect(chatB.calls, 1, reason: '只有 H1 满足 >=60s 后继静音；H0 (45s 间隔) 与 H2 (仅过 10s) 均不得调云');
      expect(resB.state.rollingByAnchor.containsKey('seg-H0.WAV'), isFalse);
      expect(resB.state.rollingByAnchor.containsKey('seg-H1.WAV'), isTrue);
      expect(resB.state.rollingByAnchor.containsKey('seg-H2.WAV'), isFalse);
    });

    test('TopicSegmentationStore 异步互斥锁 + readModifyWrite 杜绝 clean.short 与 clean.medium 并发互相覆盖', () async {
      final rootDir = Directory('${tmp.path}/concurrent_topic');
      final store = TopicSegmentationStore(resolveRoot: () async => rootDir);

      // 并发模拟：任务 1 (clean.short) 先读后慢写；任务 2 (clean.medium writeStageOverlay) 中途快写
      final shortStarted = Completer<void>();
      final allowShortFinish = Completer<void>();

      final fShort = store.readModifyWrite((current) async {
        shortStarted.complete();
        await allowShortFinish.future;
        return current.withRollingRun(
          const TopicRunSegmentation(
            runKey: 'anchor-short',
            startAtMs: 1000,
            endAtMs: 5000,
            evaluatedAtMs: 10,
            sections: [
              TopicSectionOverride(
                title: '短轮结果',
                brief: '短轮',
                startTurnIndex: 0,
                endTurnIndex: 0,
              ),
            ],
          ),
        );
      });

      await shortStarted.future;
      final fMedium = writeStageOverlay(
        store: store,
        taskId: 'clean.medium',
        evaluatedAtMs: 20,
        sections: const [
          OrganizedSection(
            anchorId: 'anchor-med',
            title: '中轮结果',
            brief: '中轮',
            overview: '中轮概述',
            startAtMs: 1000,
            endAtMs: 5000,
          ),
        ],
      );

      allowShortFinish.complete();
      await Future.wait([fShort, fMedium]);

      final persisted = await store.load(refresh: true);
      expect(persisted.rollingByAnchor.containsKey('anchor-short'), isTrue);
      expect(
        persisted.stageByTask['clean.medium']?.containsKey('anchor-med'),
        isTrue,
        reason: '并发读写修改下 clean.short 与 clean.medium 均不得丢失',
      );
    });

    test('OrganizePassService 保留每段精确 startAtMs / endAtMs 与各自 srcUtteranceIds', () async {
      final chat = _MockChat((_, _) => jsonEncode({
            'sections': [
              {
                'title': '客户端与后端发版联调',
                'brief': '对齐灰度包与预发部署时间',
                'overview': '双方确认周三前打灰度包、今晚部署预发接口，并于周四早会核对监控。',
                'sourceIndexes': [0, 1],
                'paragraphs': [
                  {
                    'speaker': '说话人 1',
                    'text': '今天先对齐客户端发版计划，周三前把灰度包打出来。',
                  },
                  {
                    'speaker': '说话人 2',
                    'text': '没问题，后端接口今晚就能部署到预发环境。',
                  },
                  {
                    'speaker': '说话人 1',
                    'text': '好，那周四早会看监控数据。',
                  },
                ],
              },
            ],
          }));

      final service = OrganizePassService(
        chat: chat,
        modelResolver: () => 'qwen-plus',
        ready: () => true,
      );

      final res = await service.merge(
        prompt: '',
        sections: const [
          OrganizedSection(
            anchorId: 'seg-org-1',
            title: '前半段',
            brief: '发版计划',
            overview: '发版计划',
            startAtMs: 1000,
            endAtMs: 12000,
            paragraphs: [
              OrganizedParagraph(
                speaker: '说话人 1',
                text: '今天我们先对齐一下客户端发版计划。',
                startAtMs: 1000,
                endAtMs: 5000,
                srcUtteranceIds: ['f1::u0', 'f1::u1'],
              ),
              OrganizedParagraph(
                speaker: '说话人 1',
                text: '周三前把灰度包打出来。',
                startAtMs: 6000,
                endAtMs: 12000,
                srcUtteranceIds: ['f1::u2'],
              ),
            ],
          ),
          OrganizedSection(
            anchorId: 'seg-org-1',
            title: '后半段',
            brief: '预发部署',
            overview: '预发部署',
            startAtMs: 15000,
            endAtMs: 30000,
            paragraphs: [
              OrganizedParagraph(
                speaker: '说话人 2',
                text: '没问题，后端接口今晚就能部署到预发环境。',
                startAtMs: 15000,
                endAtMs: 22000,
                srcUtteranceIds: ['f2::u0', 'f2::u1'],
              ),
              OrganizedParagraph(
                speaker: '说话人 1',
                text: '好，那周四早会看监控数据。',
                startAtMs: 25000,
                endAtMs: 30000,
                srcUtteranceIds: ['f2::u2'],
              ),
            ],
          ),
        ],
      );

      expect(res.ok, isTrue);
      final paras = res.sections.single.paragraphs;
      expect(paras, hasLength(3));

      expect(paras[0].startAtMs, 1000);
      expect(paras[0].endAtMs, 12000);
      expect(paras[0].srcUtteranceIds, ['f1::u0', 'f1::u1', 'f1::u2']);

      expect(paras[1].startAtMs, 15000);
      expect(paras[1].endAtMs, 22000);
      expect(paras[1].srcUtteranceIds, ['f2::u0', 'f2::u1']);

      expect(paras[2].startAtMs, 25000);
      expect(paras[2].endAtMs, 30000);
      expect(paras[2].srcUtteranceIds, ['f2::u2']);
    });

    test('LiveSession.isHealthy / coversCardFile 对 >=60s 长会话容忍轻微瞬态丢包（gapCount <= 3）', () {
      final start = DateTime.fromMillisecondsSinceEpoch(1795000000000);
      const card = CardFile(
        name: 'LONG10M.APM',
        size: 480000,
        session: 'SES10MIN',
        startAtSec: 1795000000,
        createdAtSec: 1795000600,
      );

      // 10 分钟实时流（600s >= 60s）仅出现 2 次瞬态丢包（总缺口 80ms）→ 视为健康已覆盖
      final minorLoss10m = LiveSession(
        id: 'live-10m',
        startedAt: start,
        deviceSessionId: 'SES10MIN',
        gapCount: 2,
        spans: const [
          ReceivedSpan(startMs: 0, endMs: 180000),
          ReceivedSpan(startMs: 180040, endMs: 420000),
          ReceivedSpan(startMs: 420040, endMs: 600000),
        ],
      );
      expect(minorLoss10m.isHealthy, isTrue);
      expect(minorLoss10m.coversCardFile(card), isTrue);

      // 超过 3 次断档（gapCount == 4）→ 不健康，保留给蓝牙补传
      final heavyLoss10m = minorLoss10m.copyWith(gapCount: 4);
      expect(heavyLoss10m.isHealthy, isFalse);
      expect(heavyLoss10m.coversCardFile(card), isFalse);

      // 短于 60s 的短会话（20s）出现断档 → 不健康，保留给蓝牙补传
      final shortGapped = LiveSession(
        id: 'live-20s',
        startedAt: start,
        deviceSessionId: 'SES10MIN',
        gapCount: 1,
        spans: const [
          ReceivedSpan(startMs: 0, endMs: 10000),
          ReceivedSpan(startMs: 10040, endMs: 20000),
        ],
      );
      expect(shortGapped.isHealthy, isFalse);
      expect(
        shortGapped.coversCardFile(
          const CardFile(
            name: 'SHORT20S.APM',
            size: 16000,
            session: 'SES10MIN',
            startAtSec: 1795000000,
            createdAtSec: 1795000020,
          ),
        ),
        isFalse,
      );
    });

    testWidgets(
      'TopicSegmentationStore 在 FakeAsync 内构造后跨 tester.runAsync 读写不发生跨 Zone 死锁',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('rc_topic_zone_');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final topicStore = TopicSegmentationStore(resolveRoot: () async => dir);
        await tester.runAsync(() async {
          final initial = await topicStore.load();
          expect(initial.watermarkEndAtMs, 0);
          await topicStore.readModifyWrite(
            (cur) => TopicSegmentationState(
              watermarkEndAtMs: 42000,
              lockedRunKeys: cur.lockedRunKeys,
              runsByKey: cur.runsByKey,
              rollingByAnchor: cur.rollingByAnchor,
              stageByTask: cur.stageByTask,
            ),
          );
          final reloaded = await topicStore.load(refresh: true);
          expect(reloaded.watermarkEndAtMs, 42000);
        });
      },
    );
  });
}
