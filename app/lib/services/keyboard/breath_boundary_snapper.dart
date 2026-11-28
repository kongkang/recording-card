/// 语音输入法时间戳气口对齐切片器（纯端侧能量扫描，零模型内存开销）。
///
/// 输入法仅与主应用共享「开始录音时间戳 tStartMs」与「结束录音时间戳 tEndMs」。
/// 实际说话时用户按下/松开按键常滞后或提前半拍，因此以 `[tStartMs, tEndMs]` 为中心，
/// 向前最多搜索 2 秒、向后最多搜索 2 秒（`maxSearchMs = 2000`），定位最近的气口（静音/换气谷底），
/// 自动补齐首尾半个词，再交由 ASR 与润色处理。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_ring_buffer.dart';

class SnappedBreathWindow {
  const SnappedBreathWindow({
    required this.requestedStartMs,
    required this.requestedEndMs,
    required this.snappedStartMs,
    required this.snappedEndMs,
    required this.slice,
  });

  final int requestedStartMs;
  final int requestedEndMs;
  final int snappedStartMs;
  final int snappedEndMs;
  final PcmWindowSlice slice;

  int get leadingExpansionMs => math.max(0, requestedStartMs - snappedStartMs);
  int get trailingExpansionMs => math.max(0, snappedEndMs - requestedEndMs);
}

class BreathBoundarySnapper {
  const BreathBoundarySnapper({
    this.frameMs = 20,
    this.minLeadingSilenceMs = 120,
    this.minTrailingSilenceMs = 140,
    this.guardPadMs = 60,
  });

  final int frameMs;
  final int minLeadingSilenceMs;
  final int minTrailingSilenceMs;
  final int guardPadMs;

  /// 在 `[tStartMs - maxSearchMs, tEndMs + maxSearchMs]` 范围内寻找首尾气口并切出 PCM。
  SnappedBreathWindow? snapAndSlice(
    PcmRingBuffer ringBuffer, {
    required int tStartMs,
    required int tEndMs,
    int maxSearchMs = 2000,
  }) {
    if (ringBuffer.isEmpty) return null;
    final reqStart = math.min(tStartMs, tEndMs);
    final reqEnd = math.max(tStartMs, tEndMs);
    final searchMs = maxSearchMs.clamp(0, 2000);

    final candidate = ringBuffer.slice(
      startMs: reqStart,
      endMs: reqEnd,
      preRollMs: searchMs,
      postRollMs: searchMs,
    );
    if (candidate == null || candidate.pcm16le.length < PcmRingBuffer.minSliceBytes) {
      return null;
    }

    final sr = candidate.sampleRate;
    final totalSamples = candidate.sampleCount;
    final frameSamples = math.max(1, (sr * frameMs) ~/ 1000);
    final frameCount = totalSamples ~/ frameSamples;
    if (frameCount <= 2) {
      return SnappedBreathWindow(
        requestedStartMs: reqStart,
        requestedEndMs: reqEnd,
        snappedStartMs: candidate.startMs,
        snappedEndMs: candidate.endMs,
        slice: candidate,
      );
    }

    final view = ByteData.sublistView(candidate.pcm16le);
    final rmsList = List<double>.filled(frameCount, 0);
    for (var f = 0; f < frameCount; f++) {
      var sumSq = 0.0;
      final base = f * frameSamples;
      for (var i = 0; i < frameSamples; i++) {
        final s = view.getInt16((base + i) * 2, Endian.little) / 32768.0;
        sumSq += s * s;
      }
      rmsList[f] = math.sqrt(sumSq / frameSamples);
    }

    final sortedRms = List<double>.of(rmsList)..sort();
    final noiseFloor = sortedRms[(frameCount * 0.20).floor().clamp(0, frameCount - 1)];
    final speechThreshold = math.max(0.012, noiseFloor * 2.5);

    int msToFrame(int absMs) {
      final relMs = absMs - candidate.startMs;
      return (relMs ~/ frameMs).clamp(0, frameCount - 1);
    }

    int frameStartMs(int f) => candidate.startMs + f * frameMs;
    int frameEndMs(int f) => candidate.startMs + (f + 1) * frameMs;

    final startFrame = msToFrame(reqStart);
    final endFrame = msToFrame(reqEnd);
    final minLeadSilenceFrames = math.max(1, (minLeadingSilenceMs / frameMs).round());
    final minTrailSilenceFrames = math.max(1, (minTrailingSilenceMs / frameMs).round());

    bool isActiveAround(int center) {
      final lo = math.max(0, center - 1);
      final hi = math.min(frameCount - 1, center + 1);
      for (var f = lo; f <= hi; f++) {
        if (rmsList[f] >= speechThreshold) return true;
      }
      return false;
    }

    // 1) 向前找起音前气口（仅在按下时已处于发声中才前扩，否则保留起音前极短缓冲）
    var snappedStartMs = reqStart;
    if (isActiveAround(startFrame)) {
      var silentRun = 0;
      var foundBoundaryMs = candidate.startMs;
      for (var f = startFrame; f >= 0; f--) {
        if (rmsList[f] < speechThreshold) {
          silentRun++;
          if (silentRun >= minLeadSilenceFrames) {
            // 气口结束位置在 f + silentRun 帧的起点前
            final voiceResumeFrame = f + silentRun;
            foundBoundaryMs = frameStartMs(voiceResumeFrame) - guardPadMs;
            break;
          }
        } else {
          silentRun = 0;
        }
      }
      snappedStartMs = foundBoundaryMs.clamp(
        math.max(candidate.startMs, reqStart - searchMs),
        reqStart,
      );
    } else {
      snappedStartMs = math.max(
        candidate.startMs,
        reqStart - math.min(guardPadMs, searchMs),
      );
    }

    // 2) 向后找收尾后气口（仅在松开时仍在发声才后扩）
    var snappedEndMs = reqEnd;
    if (isActiveAround(endFrame)) {
      var silentRun = 0;
      var foundBoundaryMs = math.min(candidate.endMs, reqEnd + searchMs);
      for (var f = endFrame; f < frameCount; f++) {
        if (rmsList[f] < speechThreshold) {
          silentRun++;
          if (silentRun >= minTrailSilenceFrames) {
            final silenceBeginFrame = f - silentRun + 1;
            foundBoundaryMs = frameEndMs(silenceBeginFrame) + guardPadMs;
            break;
          }
        } else {
          silentRun = 0;
        }
      }
      snappedEndMs = foundBoundaryMs.clamp(
        reqEnd,
        math.min(candidate.endMs, reqEnd + searchMs),
      );
    } else {
      snappedEndMs = math.min(
        candidate.endMs,
        reqEnd + math.min(guardPadMs, searchMs),
      );
    }

    if (snappedEndMs <= snappedStartMs) {
      snappedStartMs = math.max(candidate.startMs, reqStart);
      snappedEndMs = math.min(candidate.endMs, math.max(snappedStartMs + frameMs, reqEnd));
    }

    final startSample =
        (((snappedStartMs - candidate.startMs) * sr) ~/ 1000).clamp(0, totalSamples);
    final endSample =
        (((snappedEndMs - candidate.startMs) * sr) ~/ 1000).clamp(startSample, totalSamples);
    final byteStart = startSample * 2;
    final byteEnd = endSample * 2;
    if (byteEnd - byteStart < PcmRingBuffer.minSliceBytes) {
      return SnappedBreathWindow(
        requestedStartMs: reqStart,
        requestedEndMs: reqEnd,
        snappedStartMs: candidate.startMs,
        snappedEndMs: candidate.endMs,
        slice: candidate,
      );
    }

    final subPcm = Uint8List.fromList(
      Uint8List.sublistView(candidate.pcm16le, byteStart, byteEnd),
    );
    return SnappedBreathWindow(
      requestedStartMs: reqStart,
      requestedEndMs: reqEnd,
      snappedStartMs: snappedStartMs,
      snappedEndMs: snappedEndMs,
      slice: PcmWindowSlice(
        startMs: snappedStartMs,
        endMs: snappedEndMs,
        sampleRate: sr,
        pcm16le: subPcm,
      ),
    );
  }
}
