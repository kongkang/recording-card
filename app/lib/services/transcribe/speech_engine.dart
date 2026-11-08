/// 转写/声纹引擎接缝 —— 生产实现是 [LocalAsrService]（sherpa worker isolate），
/// 测试注入 Fake，管线不依赖 sherpa 类型。
library;

import 'dart:typed_data';

import 'local_asr_service.dart';
import 'slice_planner.dart';

abstract interface class SpeechEngine {
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language,
    int numThreads,
  });

  Future<AsrResult> transcribe(Float32List samples, {int sampleRate});

  Future<void> loadVad(String vadPath);

  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate,
  });

  Future<void> loadSpeakerEmbedding(String modelPath);

  Future<List<double>> embedSpeaker(Float32List samples, {int sampleRate});

  Future<void> dispose();
}
