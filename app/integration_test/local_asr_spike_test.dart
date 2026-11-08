// 本地转写链路 Spike（真机）：模型下载 → SenseVoice 加载 → VAD 切片 → 转写 → 声纹聚类。
//
// 跑法（先在 Mac 上起模型服务，见 docs/handoff 的 P0 Spike 命令）：
//   flutter test integration_test/local_asr_spike_test.dart \
//     -d 00008110-000C71C22212801E \
//     --dart-define=RC_MODEL_BASE=http://<mac-lan-ip>:8765
//
// 这个测试也是 P1 的验收探针：它打印的模型加载耗时、RTF、token 时间戳是否可用、
// 声纹聚类结果，直接决定后续实现细节。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/sherpa_runtime.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speaker_clusterer.dart';
import 'package:recording_card/services/transcribe/utterance_builder.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

void _log(String message) {
  // ignore: avoid_print
  print('[spike] $message');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('本地转写链路：模型 → VAD → 切片 → 转写 → 声纹', (tester) async {
    const base = String.fromEnvironment('RC_MODEL_BASE');
    expect(
      base,
      isNotEmpty,
      reason: '需要 --dart-define=RC_MODEL_BASE=http://<mac-ip>:8765',
    );
    final baseUri = Uri.parse(base);
    final installer = ModelInstaller();
    const runDiarization = bool.fromEnvironment('RC_SPIKE_DIARIZATION');
    const waitForModels = bool.fromEnvironment('RC_SPIKE_WAIT_FOR_MODELS');

    // 真机上模型目录由外部（devicectl）拷入；把真实路径打出来，排障时
    // 一眼能看出"拷错容器"还是"没拷进去"。
    final support = await getApplicationSupportDirectory();
    _log('应用支持目录：${support.path}');
    _log('模型根：${(await installer.root()).path}');

    // 0) 可选：等模型通过 USB（devicectl）拷进应用容器。
    //    flutter test 会先卸载再安装，数据容器会被清空，所以真机上没法
    //    "先拷模型再跑"；这里让测试等外部把文件送进来，避免依赖局域网。
    if (waitForModels) {
      _log('等待模型拷贝到应用容器（最多 10 分钟）…');
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      var lastLog = DateTime.fromMillisecondsSinceEpoch(0);
      while (DateTime.now().isBefore(deadline)) {
        final asrStatus = await installer.status(senseVoiceSpec);
        final embStatus = await installer.status(campplusEmbeddingSpec);
        final ready = asrStatus.installed &&
            (!runDiarization || embStatus.installed);
        if (ready) {
          _log('模型已就位：ASR ${asrStatus.presentBytes}B');
          break;
        }
        if (DateTime.now().difference(lastLog).inSeconds >= 10) {
          lastLog = DateTime.now();
          final asrDir = Directory(
            '${(await installer.root()).path}/sensevoice-small-int8/2024-07-17',
          );
          final exists = await asrDir.exists();
          final names = exists
              ? (await asrDir.list().map((e) => e.path.split('/').last).toList())
              : const <String>[];
          _log(
            '等待中：ASR 缺 ${asrStatus.missing}, 声纹嵌入 ${embStatus.installed}；'
            '目录存在=$exists 内容=$names',
          );
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final finalStatus = await installer.status(senseVoiceSpec);
      expect(finalStatus.installed, isTrue, reason: '等待超时：模型没有拷进来');
    }

    // 1) 模型安装（已装则跳过下载）
    final installWatch = Stopwatch()..start();
    var lastProgress = -1;
    await installer.installFrom(
      senseVoiceSpec,
      baseUri: baseUri,
      onProgress: (progress, text) {
        final pct = (progress * 100).floor();
        if (pct >= lastProgress + 10 || pct >= 100) {
          lastProgress = pct;
          _log('$text $pct%');
        }
      },
    );
    final vadPath = await installer.ensureBundled(sileroVadSpec);
    final modelPath = await installer.resolve(
      senseVoiceSpec,
      'model.int8.onnx',
    );
    final tokensPath = await installer.resolve(senseVoiceSpec, 'tokens.txt');
    expect(modelPath, isNotNull);
    expect(tokensPath, isNotNull);
    _log('模型就绪，用时 ${installWatch.elapsed}');

    // 2) 读测试音频，并拼成 60 秒以上的长音频（用于切片/RTF）
    final asset = await rootBundle.load('assets/spike/zh.wav');
    final wav = parseWav(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
    );
    _log('测试音频：${wav.durationMs}ms / ${wav.frames} 帧');
    final single = wav.toFloat32();
    final longSamples = _repeat(single, 12);
    _log('长音频：${longSamples.length * 1000 ~/ 16000}ms');

    // 3) VAD 切片（主 isolate，Spike 只为验证模型/参数）
    initSherpaBindings();
    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          threshold: 0.25,
          minSilenceDuration: 0.5,
          minSpeechDuration: 0.25,
          windowSize: 512,
          maxSpeechDuration: 10,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    final vadWatch = Stopwatch()..start();
    final spans = <SpeechSpan>[];
    try {
      // Silero VAD 必须按窗口喂（16k 下 512 采样）；一次性喂 67 秒会超出
      // 内部 30 秒环形缓冲，导致只保留最后一小段。
      const window = 512;
      for (var i = 0; i < longSamples.length; i += window) {
        final end = i + window < longSamples.length
            ? i + window
            : longSamples.length;
        vad.acceptWaveform(Float32List.sublistView(longSamples, i, end));
      }
      vad.flush();
      while (!vad.isEmpty()) {
        final segment = vad.front();
        spans.add(SpeechSpan(segment.start, segment.start + segment.samples.length));
        vad.pop();
      }
    } finally {
      vad.free();
    }
    _log('VAD ${spans.length} 段，用时 ${vadWatch.elapsed}');

    final slices = const SlicePlanner().plan(
      speech: spans,
      totalSamples: longSamples.length,
      sampleRate: 16000,
    );
    _log(
      '切片 ${slices.length} 片：'
      '${slices.map((s) => '${(s.length / 16000).toStringAsFixed(1)}s').join(', ')}',
    );
    expect(slices, isNotEmpty);

    // 4) worker isolate 加载 + 转写（生产路径）
    final asr = LocalAsrService();
    addTearDown(asr.dispose);
    final loadWatch = Stopwatch()..start();
    await asr.load(
      modelPath: modelPath!,
      tokensPath: tokensPath!,
      language: 'zh',
    );
    _log('ASR 加载完成，用时 ${loadWatch.elapsed}');

    final first = slices.first;
    final sliceSamples = longSamples.sublist(
      first.startSample,
      first.endSample,
    );
    final decodeWatch = Stopwatch()..start();
    final result = await asr.transcribe(sliceSamples);
    final elapsed = decodeWatch.elapsedMilliseconds;
    final audioMs = sliceSamples.length * 1000 ~/ 16000;
    _log('转写完成：${elapsed}ms / 音频 ${audioMs}ms，RTF=${(elapsed / audioMs).toStringAsFixed(3)}');
    _log('文本：${result.text}');
    _log(
      'lang=${result.lang} emotion=${result.emotion} event=${result.event} '
      'tokens=${result.tokens.length} timestamps=${result.timestampsMs.length}',
    );
    if (result.timestampsMs.isNotEmpty) {
      _log(
        '时间戳范围：${result.timestampsMs.first}~${result.timestampsMs.last}ms',
      );
    } else {
      _log('模型未返回 token 时间戳：句级时间将按 VAD + 字符比例分配');
    }

    final utterances = buildUtterancesFromAsr(
      sliceId: '0001',
      sliceStartMs: first.startMs(16000),
      sliceEndMs: first.endMs(16000),
      text: result.text,
      tokens: result.tokens,
      tokenTimestampsMs: result.timestampsMs,
      lang: result.lang,
      emotion: result.emotion,
    );
    _log('句子 ${utterances.length} 条，首句 ${utterances.first.startMs}~${utterances.first.endMs}ms：${utterances.first.text}');
    expect(result.text.trim(), isNotEmpty);
    expect(utterances, isNotEmpty);

    // 5) 声纹：句级 Campplus 嵌入 + 本地聚类（pyannote 分割在 iOS 会卡死，
    //    已实测；这里用唤醒词同款嵌入模型，避免整条链路被它拖住）。
    if (runDiarization) {
      await installer.installFrom(campplusEmbeddingSpec, baseUri: baseUri);
      final embPath = await installer.resolve(
        campplusEmbeddingSpec,
        campplusEmbeddingSpec.files.first.relPath,
      );
      expect(embPath, isNotNull);
      await asr.loadSpeakerEmbedding(embPath!);
      final embedWatch = Stopwatch()..start();
      final samples = <SpeakerSample>[];
      for (var i = 0; i < spans.length; i++) {
        final span = spans[i];
        final seg = longSamples.sublist(span.startSample, span.endSample);
        final vector = await asr.embedSpeaker(seg);
        if (vector.isNotEmpty) {
          samples.add(
            SpeakerSample(
              id: 'spk$i',
              embedding: vector,
              durationMs: span.length * 1000 ~/ 16000,
            ),
          );
        }
      }
      _log(
        '声纹嵌入 ${samples.length}/${spans.length} 段，用时 ${embedWatch.elapsed}',
      );
      const clusterer = SpeakerClusterer();
      final clustered = clusterer.cluster(samples);
      _log(
        '聚类：${clustered.speakerCount} 人，'
        '已知 ${clustered.knownCount}/${samples.length} 段',
      );
      for (final a in clustered.assignments.take(8)) {
        _log('  ${a.id} → 簇 ${a.cluster}（置信度 ${a.confidence.toStringAsFixed(2)}）');
      }
      expect(samples, isNotEmpty);
      expect(clustered.speakerCount, greaterThanOrEqualTo(1));
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Float32List _repeat(Float32List source, int times) {
  final out = Float32List(source.length * times);
  for (var i = 0; i < times; i++) {
    out.setAll(i * source.length, source);
  }
  return out;
}
