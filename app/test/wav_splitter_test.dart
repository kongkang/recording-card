// WAV 切片验收（TDD）—— 16k/mono/16-bit 主路径 + 头合法性 + 容错。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/audio/wav_splitter.dart';

/// 生成 16kHz mono 16-bit PCM WAV；每帧样本值 i%1000，便于校验切片顺序。
Uint8List _wav(int samples) {
  const rate = 16000;
  const channels = 1;
  const bits = 16;
  const blockAlign = channels * bits ~/ 8;
  final dataLen = samples * blockAlign;
  final bytes = Uint8List(44 + dataLen);
  final bd = ByteData.sublistView(bytes);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[off + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, rate, Endian.little);
  bd.setUint32(28, rate * blockAlign, Endian.little);
  bd.setUint16(32, blockAlign, Endian.little);
  bd.setUint16(34, bits, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples; i++) {
    bd.setInt16(44 + i * 2, i % 1000, Endian.little);
  }
  return bytes;
}

void main() {
  test('1 秒音频按 400ms 切成 3 段，时间轴连续', () {
    final pieces =
        const WavSplitter().split(_wav(16000), segment: const Duration(milliseconds: 400));

    expect(pieces, hasLength(3));
    expect(pieces.map((p) => p.startMs), [0, 400, 800]);
    expect(pieces.map((p) => p.endMs), [400, 800, 1000]);
    expect(pieces.map((p) => p.bytes.length), [44 + 12800, 44 + 12800, 44 + 6400]);
  });

  test('每段都是合法 WAV：可直接再解析', () {
    final pieces =
        const WavSplitter().split(_wav(16000), segment: const Duration(milliseconds: 400));
    for (final p in pieces) {
      final again = const WavSplitter().split(p.bytes);
      expect(again, hasLength(1));
      expect(again.single.startMs, 0);
    }
  });

  test('短音频不切：单段保留原始 PCM', () {
    final wav = _wav(8000);
    final pieces =
        const WavSplitter().split(wav, segment: const Duration(seconds: 30));
    expect(pieces, hasLength(1));
    expect(pieces.single.startMs, 0);
    expect(pieces.single.endMs, 500);
    expect(pieces.single.bytes.length, wav.length);
  });

  test('空 data 返回空列表', () {
    final pieces = const WavSplitter().split(_wav(0));
    expect(pieces, isEmpty);
  });

  test('非 WAV / 非 PCM 抛 WavFormatException', () {
    expect(() => const WavSplitter().split(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<WavFormatException>()));
    final bad = _wav(100)
      ..[20] = 3; // audioFormat = float，非 PCM
    expect(() => const WavSplitter().split(bad),
        throwsA(isA<WavFormatException>()));
  });

  test('segment 必须为正', () {
    expect(
      () => const WavSplitter()
          .split(_wav(100), segment: Duration.zero),
      throwsArgumentError,
    );
  });
}
