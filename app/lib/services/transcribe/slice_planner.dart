/// VAD 切片规划（纯函数，便于单测）。
///
/// 目标：把一条 10 分钟的录音切成 45~90 秒的片，**只在静音处切**，
/// 片与片之间不重叠（避免同一句话在相邻片里被重复转写；上下文由云端
/// 窗口里的前 1~2 片文本提供，而不是音频重叠）。
///
/// 输入是 VAD 检测出的语音段（采样点区间），输出是切片区间 + 每片末尾的
/// 真实静音长度。真的没有语音时返回空列表——零片，不要造出一片静音。
library;

import 'dart:math' as math;

class SpeechSpan {
  const SpeechSpan(this.startSample, this.endSample);

  final int startSample;
  final int endSample;

  int get length => endSample - startSample;
}

class PlannedSlice {
  const PlannedSlice({
    required this.index,
    required this.startSample,
    required this.endSample,
    required this.silenceAfterSamples,
  });

  final int index;
  final int startSample;
  final int endSample;

  /// 本片最后一句到下一片第一句之间的真实静音（未加 padding）。
  final int silenceAfterSamples;

  int get length => endSample - startSample;

  int startMs(int sampleRate) => startSample * 1000 ~/ sampleRate;
  int endMs(int sampleRate) => endSample * 1000 ~/ sampleRate;
  int silenceAfterMs(int sampleRate) => silenceAfterSamples * 1000 ~/ sampleRate;
}

class SlicePlanner {
  const SlicePlanner({
    this.targetDuration = const Duration(seconds: 25),
    this.maxDuration = const Duration(seconds: 35),
    this.minSilence = const Duration(milliseconds: 450),
    this.edgePadding = const Duration(milliseconds: 300),
    this.longSilence = const Duration(seconds: 12),
  });

  /// 达到这个长度后，遇到静音就收片。
  final Duration targetDuration;

  /// 硬上限：连续说话超过这个长度也必须切。
  final Duration maxDuration;

  /// 小于这个长度的间隔不算"可以切"的静音。
  final Duration minSilence;

  /// 切片前后各留一点余量，避免削掉字头字尾。
  final Duration edgePadding;

  /// 超过这个长度的静音一定收片（即使还没到 target）：它通常意味着
  /// 一个话题/事件结束，硬凑在一起反而会把两段无关内容塞进同一片。
  final Duration longSilence;

  List<PlannedSlice> plan({
    required List<SpeechSpan> speech,
    required int totalSamples,
    required int sampleRate,
  }) {
    if (totalSamples <= 0 || sampleRate <= 0) return const [];

    final pad = _samples(edgePadding, sampleRate);
    final maxSamples = _samples(maxDuration, sampleRate);
    final targetSamples = _samples(targetDuration, sampleRate);
    final minSilenceSamples = _samples(minSilence, sampleRate);
    final longSilenceSamples = _samples(longSilence, sampleRate);
    if (maxSamples <= pad * 2) return const [];

    final spans = _normalize(speech, totalSamples, minSilenceSamples);
    if (spans.isEmpty) return const [];

    // 连续语音超过硬上限时先按上限切开，后面就不需要处理"跨片长句"。
    final chunked = <SpeechSpan>[];
    final chunkSamples = maxSamples - pad * 2;
    for (final span in spans) {
      var start = span.startSample;
      while (span.endSample - start > chunkSamples) {
        chunked.add(SpeechSpan(start, start + chunkSamples));
        start += chunkSamples;
      }
      chunked.add(SpeechSpan(start, span.endSample));
    }

    final slices = <PlannedSlice>[];
    var i = 0;
    var previousEnd = 0;
    while (i < chunked.length) {
      final first = chunked[i];
      var start = math.max(0, first.startSample - pad);
      // 片间不重叠：上一片已经覆盖到这里，就从这里开始
      if (start < previousEnd) start = previousEnd;
      var last = i;
      var end = math.min(totalSamples, first.endSample + pad);
      i++;

      while (i < chunked.length) {
        final next = chunked[i];
        final nextEnd = math.min(totalSamples, next.endSample + pad);
        if (nextEnd - start > maxSamples) break;

        final gap = next.startSample - chunked[last].endSample;
        final length = end - start;
        // 长静音一定收片：它通常就是话题边界
        if (gap >= longSilenceSamples) break;
        // 够长且遇到真正的静音：在下一句之前收片
        if (length >= targetSamples && gap >= minSilenceSamples) break;

        last = i;
        end = nextEnd;
        i++;
        if (end - start >= maxSamples) break;
      }

      if (end <= start) continue;
      final silenceAfter = i < chunked.length
          ? math.max(0, chunked[i].startSample - chunked[last].endSample)
          : math.max(0, totalSamples - chunked[last].endSample);
      slices.add(
        PlannedSlice(
          index: slices.length,
          startSample: start,
          endSample: end,
          silenceAfterSamples: silenceAfter,
        ),
      );
      previousEnd = end;
    }

    return slices;
  }

  static int _samples(Duration d, int sampleRate) =>
      (d.inMicroseconds * sampleRate / 1000000).round();

  /// 裁剪到录音范围、去掉空段、合并重叠/极短间隔。
  static List<SpeechSpan> _normalize(
    List<SpeechSpan> input,
    int totalSamples,
    int mergeGapSamples,
  ) {
    final cleaned = <SpeechSpan>[];
    for (final s in input) {
      final start = s.startSample.clamp(0, totalSamples);
      final end = s.endSample.clamp(0, totalSamples);
      if (end - start <= 0) continue;
      cleaned.add(SpeechSpan(start, end));
    }
    cleaned.sort((a, b) => a.startSample.compareTo(b.startSample));

    final merged = <SpeechSpan>[];
    for (final s in cleaned) {
      if (merged.isEmpty) {
        merged.add(s);
        continue;
      }
      final last = merged.last;
      if (s.startSample - last.endSample < mergeGapSamples) {
        merged[merged.length - 1] = SpeechSpan(
          last.startSample,
          math.max(last.endSample, s.endSample),
        );
      } else {
        merged.add(s);
      }
    }
    return merged;
  }
}
