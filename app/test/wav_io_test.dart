import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

void main() {
  group('WAV 读写', () {
    test('16-bit 单声道往返：头部、帧数、时长、采样值', () {
      final samples = Float32List(16000);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = 0.5 * (i % 100) / 100;
      }
      final bytes = encodeWav(samples);
      final wav = parseWav(bytes);

      expect(wav.sampleRate, 16000);
      expect(wav.channels, 1);
      expect(wav.bitsPerSample, 16);
      expect(wav.frames, 16000);
      expect(wav.durationMs, 1000);

      final decoded = wav.toFloat32();
      expect(decoded.length, samples.length);
      for (var i = 0; i < samples.length; i += 97) {
        expect(decoded[i], closeTo(samples[i], 1e-3));
      }
    });

    test('切片是字节级无损：新片的 PCM 等于原片对应区间', () {
      final samples = Float32List.fromList(
        List<double>.generate(8000, (i) => (i % 200) / 400.0),
      );
      final wav = parseWav(encodeWav(samples));
      final slice = parseWav(wav.sliceWav(2000, 4000));

      expect(slice.frames, 2000);
      expect(slice.durationMs, 125);
      final a = wav.toFloat32().sublist(2000, 4000);
      final b = slice.toFloat32();
      expect(b.length, a.length);
      for (var i = 0; i < a.length; i += 13) {
        expect(b[i], a[i]);
      }
    });

    test('越界切片自动裁剪到合法范围', () {
      final wav = parseWav(
        encodeWav(Float32List.fromList(List<double>.filled(1600, 0.1))),
      );
      final slice = parseWav(wav.sliceWav(-10, 99999));
      expect(slice.frames, 1600);
    });

    test('非 WAV / 非 PCM / 立体声 / 44.1k 明确报错', () {
      expect(
        () => parseWav(Uint8List.fromList(List<int>.filled(100, 0))),
        throwsFormatException,
      );

      final stereo = encodeWav(Float32List(160), sampleRate: 16000);
      // 把声道数改成 2
      final view = ByteData.sublistView(stereo);
      view.setUint16(22, 2, Endian.little);
      expect(() => parseWav(stereo), throwsFormatException);

      final badRate = encodeWav(Float32List(160), sampleRate: 44100);
      expect(() => parseWav(badRate), throwsFormatException);
    });
  });
}
