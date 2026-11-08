/// 转写数据模型与可替换的 ASR 服务接缝。
///
/// 真实 ASR（sherpa / 云端）适配器不在本模块范围；开发期与测试统一使用
/// [FakeTranscriptionService] 注入预置结果，不发起真实网络请求。
library;

import 'dart:typed_data';

/// 一句发言。speaker 为推测归类（A / B / 未知），不代表真实身份。
class TranscriptionTurn {
  const TranscriptionTurn({
    required this.speaker,
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String speaker;
  final String text;
  final int startMs;
  final int endMs;
}

/// 一次转写的完整结果：原始转写与清洗版都保留，turns 为分段说话人。
class TranscriptResult {
  const TranscriptResult({
    required this.rawText,
    required this.cleanText,
    this.turns = const <TranscriptionTurn>[],
    this.language,
  });

  /// 原始转写（含语气词 / 停顿），任何开关关闭都不丢。
  final String rawText;

  /// 清洗口语后的文本；清洗关闭时由管线回填为 [rawText]。
  final String cleanText;

  final List<TranscriptionTurn> turns;

  /// 识别语言（如 'zh'），可能为空。
  final String? language;
}

/// 转写服务接缝：真实实现调 ASR，测试/开发期用 Fake。
abstract class TranscriptionService {
  Future<TranscriptResult> transcribe(Uint8List audio, {String? language});
}

/// 转写不可用（未配置 / 服务失败），由上层决定是否提示重试。
class TranscriptionUnavailable implements Exception {
  const TranscriptionUnavailable([this.message = '转写服务不可用']);

  final String message;

  @override
  String toString() => 'TranscriptionUnavailable: $message';
}

/// 可注入结果或异常的假服务；记录调用次数与音频长度供断言。
///
/// 未注入 [result] 且未注入 [error] 时抛 [TranscriptionUnavailable]，
/// 模拟"尚未配置 ASR"的真实状态，而不是返回空结果。
class FakeTranscriptionService implements TranscriptionService {
  FakeTranscriptionService({
    this.result,
    this.error,
    this.delay = Duration.zero,
  });

  /// 返回结果；可在多次调用之间替换。
  TranscriptResult? result;

  /// 非空时直接抛出（用于验证管线不吞异常），优先于 [result]。
  Object? error;

  /// 模拟耗时；默认零延迟。
  final Duration delay;

  int callCount = 0;
  int lastAudioLength = 0;
  String? lastLanguage;

  @override
  Future<TranscriptResult> transcribe(
    Uint8List audio, {
    String? language,
  }) async {
    callCount++;
    lastAudioLength = audio.length;
    lastLanguage = language;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final failure = error;
    if (failure != null) throw failure;
    final value = result;
    if (value == null) {
      throw const TranscriptionUnavailable('未配置转写服务');
    }
    return value;
  }
}
