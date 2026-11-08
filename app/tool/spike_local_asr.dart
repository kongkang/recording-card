// ignore_for_file: avoid_print
//
// Mac 端本地 ASR/声纹验证工具（不在 App 运行时使用）。
//
// 用途：不经过真机，快速验证 SenseVoice 的 tokens ↔ text 关系、token 时间戳、
// VAD 切片、pyannote+campplus 声纹聚类的行为与耗时。
//
// 跑法（dylib 目录按本机 pub-cache 调整）：
//   DYLD_LIBRARY_PATH=/Users/kongkang/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.3/macos \
//   dart run tool/spike_local_asr.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

const _senseVoiceDir =
    '/Users/kongkang/Library/Application Support/reai-vibe-board/models/sensevoice-int8';
const _vadPath =
    '/Users/kongkang/Developer/recording-card/app/assets/models/silero_vad.onnx';
const _wavPath = '$_senseVoiceDir/test_wavs/zh.wav';
const _pyannotePath =
    '/tmp/rc-model-serve/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx';
const _campplusPath =
    '/tmp/rc-model-serve/campplus-embedding/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx';

void main() {
  sherpa.initBindings(
    '/Users/kongkang/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.3/macos',
  );
  final wav = readWavFile(_wavPath);
  final single = wav.toFloat32();
  print('音频：${wav.durationMs}ms / ${wav.frames} 帧');

  // 1) tokens ↔ text
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: '$_senseVoiceDir/model.int8.onnx',
          language: 'zh',
          useInverseTextNormalization: true,
        ),
        tokens: '$_senseVoiceDir/tokens.txt',
        numThreads: 2,
        debug: false,
      ),
    ),
  );
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: single, sampleRate: 16000);
  recognizer.decode(stream);
  final result = recognizer.getResult(stream);
  stream.free();
  recognizer.free();

  print('text=${result.text}');
  print('lang=${result.lang} emotion=${result.emotion} event=${result.event}');
  print('tokens=${result.tokens.length} timestamps=${result.timestamps.length}');
  print('前 40 tokens：${result.tokens.take(40).toList()}');
  print('tokens.join() == text ? ${result.tokens.join() == result.text}');
  print(
    '去掉空格后相等 ? '
    '${result.tokens.join().replaceAll(' ', '') == result.text.replaceAll(' ', '')}',
  );
  print(
    'timestamps 前 10：${result.timestamps.take(10).map((e) => e.toStringAsFixed(3)).toList()}',
  );

  // 2) VAD + 切片（重复 12 次 ≈ 67s）
  final long = _repeat(single, 12);
  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: _vadPath,
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
  final spans = <SpeechSpan>[];
  const window = 512;
  for (var i = 0; i < long.length; i += window) {
    final end = i + window < long.length ? i + window : long.length;
    vad.acceptWaveform(Float32List.sublistView(long, i, end));
  }
  vad.flush();
  while (!vad.isEmpty()) {
    final s = vad.front();
    spans.add(SpeechSpan(s.start, s.start + s.samples.length));
    vad.pop();
  }
  vad.free();
  final slices = const SlicePlanner().plan(
    speech: spans,
    totalSamples: long.length,
    sampleRate: 16000,
  );
  print(
    'VAD ${spans.length} 段 → ${slices.length} 片：'
    '${slices.map((s) => '${(s.length / 16000).toStringAsFixed(1)}s').join(', ')}',
  );

  // 3) 声纹
  if (File(_pyannotePath).existsSync() && File(_campplusPath).existsSync()) {
    final watch = Stopwatch()..start();
    final diarizer = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: _pyannotePath,
          ),
          numThreads: 2,
          debug: false,
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: _campplusPath,
          numThreads: 2,
          debug: false,
        ),
        clustering: const sherpa.FastClusteringConfig(
          numClusters: -1,
          threshold: 0.5,
        ),
      ),
    );
    final segments = diarizer.process(samples: long);
    diarizer.free();
    print(
      '声纹 ${segments.length} 段 / ${segments.map((s) => s.speaker).toSet().length} 人，'
      '用时 ${watch.elapsed}',
    );
    for (final s in segments.take(10)) {
      print(
        '  ${s.start.toStringAsFixed(2)}~${s.end.toStringAsFixed(2)}s → '
        '说话人 ${s.speaker}',
      );
    }
  }
}

Float32List _repeat(Float32List source, int times) {
  final out = Float32List(source.length * times);
  for (var i = 0; i < times; i++) {
    out.setAll(i * source.length, source);
  }
  return out;
}
