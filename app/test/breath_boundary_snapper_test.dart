import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/audio/pcm_ring_buffer.dart';
import 'package:recording_card/services/keyboard/breath_boundary_snapper.dart';

Uint8List _toneSegmentPcm({required int durationMs, int sampleRate = 16000}) {
  final samples = (durationMs * sampleRate) ~/ 1000;
  final out = Uint8List(samples * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / sampleRate) * 9000).round();
    view.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

Uint8List _silencePcm({required int durationMs, int sampleRate = 16000}) {
  final samples = (durationMs * sampleRate) ~/ 1000;
  return Uint8List(samples * 2);
}

void main() {
  group('BreathBoundarySnapper', () {
    test('起止时间戳落在发声中间时，在 2 秒范围内向前后寻找气口并补齐完整语音', () {
      final ring = PcmRingBuffer(maxDuration: const Duration(seconds: 30));
      // 构造 6 秒音频（基准时刻 t0 = 10000ms）：
      // [10000..11200] 静音 (1200ms)
      // [11200..14400] 持续说话 (3200ms)
      // [14400..16000] 静音 (1600ms)
      ring.append(_silencePcm(durationMs: 1200), endTimestampMs: 11200);
      ring.append(_toneSegmentPcm(durationMs: 3200), endTimestampMs: 14400);
      ring.append(_silencePcm(durationMs: 1600), endTimestampMs: 16000);

      // 模拟用户按下晚了 500ms（11700ms）、松开早了 500ms（13900ms）
      const snapper = BreathBoundarySnapper();
      final snapped = snapper.snapAndSlice(
        ring,
        tStartMs: 11700,
        tEndMs: 13900,
        maxSearchMs: 2000,
      );

      expect(snapped, isNotNull);
      // 向前找到 11200ms 附近的气口边界
      expect(snapped!.snappedStartMs, lessThanOrEqualTo(11220));
      expect(snapped.snappedStartMs, greaterThanOrEqualTo(11700 - 2000));
      expect(snapped.leadingExpansionMs, greaterThan(400));

      // 向后找到 14400ms 附近的气口边界
      expect(snapped.snappedEndMs, greaterThanOrEqualTo(14380));
      expect(snapped.snappedEndMs, lessThanOrEqualTo(13900 + 2000));
      expect(snapped.trailingExpansionMs, greaterThan(400));
      expect(snapped.slice.durationMs, greaterThan(3100));
    });

    test('连续不间断语音无气口时，严格钳制在前后 2000ms 以内', () {
      final ring = PcmRingBuffer(maxDuration: const Duration(seconds: 30));
      ring.append(_toneSegmentPcm(durationMs: 10000), endTimestampMs: 20000);

      const snapper = BreathBoundarySnapper();
      final snapped = snapper.snapAndSlice(
        ring,
        tStartMs: 14000,
        tEndMs: 16000,
        maxSearchMs: 2000,
      );

      expect(snapped, isNotNull);
      expect(snapped!.snappedStartMs, greaterThanOrEqualTo(14000 - 2000));
      expect(snapped.snappedEndMs, lessThanOrEqualTo(16000 + 2000));
      expect(snapped.leadingExpansionMs, lessThanOrEqualTo(2000));
      expect(snapped.trailingExpansionMs, lessThanOrEqualTo(2000));
    });

    test('空缓冲区返回 null', () {
      final ring = PcmRingBuffer();
      const snapper = BreathBoundarySnapper();
      final snapped = snapper.snapAndSlice(
        ring,
        tStartMs: 1000,
        tEndMs: 2000,
      );
      expect(snapped, isNull);
    });
  });
}
