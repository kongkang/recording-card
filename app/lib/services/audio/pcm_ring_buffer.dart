/// 带时间戳的滚动内存 PCM 环形缓冲区 —— 支持在持续录音期间按 `[startMs, endMs]`
/// 零干扰截取任意窗口音频（跨越 1 分钟主分片边界也不丢失），供按键 Agent 任务直接转写。
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../transcribe/wav_io.dart';

class _TimedPcmChunk {
  const _TimedPcmChunk({
    required this.startMs,
    required this.endMs,
    required this.pcm16le,
  });

  final int startMs;
  final int endMs;
  final Uint8List pcm16le;
}

/// 按时间窗从环形缓冲区切出的一段音频切片（16kHz / 16-bit / 单声道）。
class PcmWindowSlice {
  const PcmWindowSlice({
    required this.startMs,
    required this.endMs,
    required this.sampleRate,
    required this.pcm16le,
  });

  final int startMs;
  final int endMs;
  final int sampleRate;
  final Uint8List pcm16le;

  int get sampleCount => pcm16le.length ~/ 2;

  int get durationMs => sampleCount * 1000 ~/ sampleRate;

  /// 转成归一化 [-1.0, 1.0] 浮点采样（经过去直流与噪声门控增益调整，兼容蓝牙实时流）。
  Float32List get floatSamples {
    final count = sampleCount;
    final out = Float32List(count);
    final view = ByteData.sublistView(pcm16le);
    for (var i = 0; i < count; i++) {
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return conditionSpeechSamples(out, sampleRate: sampleRate);
  }

  /// 封装成完整 44 字节 WAV 字节流（零额外重采样开销）。
  Uint8List get wavBytes => encodePcm16MonoWav(pcm16le, sampleRate: sampleRate);
}

/// 将原始 16-bit LE 单声道 PCM 封装为标准 RIFF WAV 字节流。
Uint8List encodePcm16MonoWav(
  Uint8List pcm16le, {
  int sampleRate = 16000,
}) {
  final alignedLen = pcm16le.length & ~1;
  final byteRate = sampleRate * 2;
  final out = Uint8List(44 + alignedLen);
  final h = ByteData.sublistView(out, 0, 44);
  out.setRange(0, 4, 'RIFF'.codeUnits);
  h.setUint32(4, 36 + alignedLen, Endian.little);
  out.setRange(8, 12, 'WAVE'.codeUnits);
  out.setRange(12, 16, 'fmt '.codeUnits);
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, byteRate, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  out.setRange(36, 40, 'data'.codeUnits);
  h.setUint32(40, alignedLen, Endian.little);
  if (alignedLen > 0) {
    out.setRange(44, 44 + alignedLen, pcm16le, 0);
  }
  return out;
}

/// 滚动内存 PCM 环形缓冲（默认保留最近 120 秒，16kHz 16-bit 单声道 ≈ 3.84MB）。
class PcmRingBuffer {
  PcmRingBuffer({
    this.maxDuration = const Duration(seconds: 120),
    this.sampleRate = 16000,
  });

  final Duration maxDuration;
  final int sampleRate;
  final Queue<_TimedPcmChunk> _chunks = Queue<_TimedPcmChunk>();

  /// 至少需要 50ms 音频（1600 字节）才认为是有效可识别片段。
  static const int minSliceBytes = 1600;

  bool get isEmpty => _chunks.isEmpty;

  int get latestTimestampMs => _chunks.isEmpty ? 0 : _chunks.last.endMs;

  int get totalBytes {
    var sum = 0;
    for (final c in _chunks) {
      sum += c.pcm16le.length;
    }
    return sum;
  }

  /// 追加一块按帧到达的 16-bit LE PCM 数据；自动按采样时长反推起止时刻并做微抖动连续性平滑。
  void append(Uint8List pcm16le, {required int endTimestampMs}) {
    final evenLen = pcm16le.length & ~1;
    if (evenLen <= 0) return;
    final aligned = evenLen == pcm16le.length
        ? Uint8List.fromList(pcm16le)
        : Uint8List.fromList(Uint8List.sublistView(pcm16le, 0, evenLen));

    final samples = aligned.length ~/ 2;
    final chunkDurMs = math.max(1, (samples * 1000 / sampleRate).round());
    var startMs = endTimestampMs - chunkDurMs;
    var endMs = endTimestampMs;

    if (_chunks.isNotEmpty) {
      final prevEnd = _chunks.last.endMs;
      // 仅对 <= 250ms 的传输到达微抖动做首尾相接，大于该阈值则按真实时钟保留断档位置
      if (startMs < prevEnd && prevEnd - startMs <= 250) {
        startMs = prevEnd;
        endMs = startMs + chunkDurMs;
      } else if (startMs > prevEnd && startMs - prevEnd <= 120) {
        startMs = prevEnd;
        endMs = math.max(endMs, startMs + chunkDurMs);
      }
    }

    _chunks.add(_TimedPcmChunk(startMs: startMs, endMs: endMs, pcm16le: aligned));
    final cutoffMs = endMs - maxDuration.inMilliseconds;
    while (_chunks.length > 1 && _chunks.first.endMs < cutoffMs) {
      _chunks.removeFirst();
    }
  }

  /// 按 `[startMs, endMs]` 切出这段音频，并支持：
  /// - [preRollMs] 前置预卷（补偿长按阈值/反应延迟，避免吞掉第一个字）；
  /// - [postRollMs] 尾部余量（等待蓝牙分包传输到达）；
  /// - [notBeforeMs] 早于该时刻的样本一律裁掉（避免误切入上一段系统 TTS 外放音）。
  PcmWindowSlice? slice({
    required int startMs,
    required int endMs,
    int preRollMs = 300,
    int postRollMs = 250,
    int? notBeforeMs,
  }) {
    if (_chunks.isEmpty) return null;
    final winStart = math.max(startMs - preRollMs, notBeforeMs ?? 0);
    final winEnd = math.max(winStart, endMs + postRollMs);

    final out = BytesBuilder(copy: false);
    int? actualStart;
    int? actualEnd;

    for (final c in _chunks) {
      if (c.endMs <= winStart || c.startMs >= winEnd) continue;
      final ovStart = math.max(winStart, c.startMs);
      final ovEnd = math.min(winEnd, c.endMs);
      if (ovEnd <= ovStart) continue;

      final totalSamples = c.pcm16le.length ~/ 2;
      final durMs = math.max(1, c.endMs - c.startMs);
      final s0 = (((ovStart - c.startMs) * totalSamples) / durMs)
          .floor()
          .clamp(0, totalSamples);
      final s1 = (((ovEnd - c.startMs) * totalSamples) / durMs)
          .ceil()
          .clamp(s0, totalSamples);
      if (s1 <= s0) continue;

      out.add(Uint8List.sublistView(c.pcm16le, s0 * 2, s1 * 2));
      actualStart ??= ovStart;
      actualEnd = ovEnd;
    }

    final bytes = out.takeBytes();
    if (bytes.length < minSliceBytes) return null;
    return PcmWindowSlice(
      startMs: actualStart ?? winStart,
      endMs: actualEnd ?? winEnd,
      sampleRate: sampleRate,
      pcm16le: bytes,
    );
  }

  void clear() => _chunks.clear();
}
