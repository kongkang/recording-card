import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcription/audio_decoder.dart';
import 'package:recording_card/services/transcription/streaming_audio_slicer.dart';
import 'package:recording_card/services/transcription/transcription_types.dart';

void main() {
  test('PCM frames split mid-sample reconstruct bytes and exact offsets', () {
    final slicer = StreamingAudioSlicer(
      sampleRate: 8000,
      sliceDuration: const Duration(microseconds: 250),
    );
    expect(slicer.addPcm16(Uint8List.fromList([1, 2, 3])), isEmpty);
    final slices = slicer.addPcm16(Uint8List.fromList([4, 5, 6, 7, 8]));
    expect(slices, hasLength(2));
    expect(slices[0].pcm16, [1, 2, 3, 4]);
    expect(slices[1].pcm16, [5, 6, 7, 8]);
    expect(slices[0].start, Duration.zero);
    expect(slices[0].end, const Duration(microseconds: 250));
    expect(slices[1].start, const Duration(microseconds: 250));
    expect(slices[1].end, const Duration(microseconds: 500));
    expect(slicer.flush(), isNull);
  });
  test('ADPCM state carries across BLE frames and slices', () {
    final slicer = StreamingAudioSlicer(
      sampleRate: 8000,
      sliceDuration: const Duration(microseconds: 250),
    );
    final slices = [
      ...slicer.addAdpcm(Uint8List.fromList([0x21])),
      ...slicer.addAdpcm(Uint8List.fromList([0x43])),
    ];
    final samples = [
      for (final s in slices)
        ...AudioDecoder.decode(
          s.pcm16,
          AudioFileFormat.pcm16,
          sampleRate: 8000,
        ).samples,
    ];
    expect(samples.map((v) => (v * 32768).round()), [1, 4, 8, 15]);
    expect(slices.map((s) => s.sequence), [0, 1]);
  });
  test('source output is immutable after incoming buffer changes', () {
    final frame = Uint8List.fromList([1, 2, 3, 4]);
    final s = StreamingAudioSlicer(
      sampleRate: 8000,
      sliceDuration: const Duration(microseconds: 250),
    ).addPcm16(frame).single;
    frame[0] = 9;
    expect(s.pcm16[0], 1);
    expect(() => s.pcm16[0] = 6, throwsUnsupportedError);
  });
  test('short final chunk is emitted without pad or invented duration', () {
    final slicer = StreamingAudioSlicer();
    expect(slicer.addPcm16(Uint8List.fromList([1, 2])), isEmpty);
    final s = slicer.flush()!;
    expect(s.pcm16, [1, 2]);
    expect(s.end.inMicroseconds, 62);
    expect(slicer.flush(), isNull);
  });
  test(
    'truncated half sample refuses flush and can recover with final byte',
    () {
      final slicer = StreamingAudioSlicer();
      slicer.addPcm16(Uint8List.fromList([1]));
      expect(
        () => slicer.flush(),
        throwsA(
          isA<TranscriptionException>().having(
            (e) => e.code,
            'code',
            'audio_corrupt',
          ),
        ),
      );
      slicer.addPcm16(Uint8List.fromList([2]));
      expect(slicer.flush()!.pcm16, [1, 2]);
    },
  );
  test('frame size and stream encoding changes refuse operation', () {
    final slicer = StreamingAudioSlicer(maxFrameBytes: 4);
    slicer.addPcm16(Uint8List(2));
    expect(
      () => slicer.addPcm16(Uint8List(5)),
      throwsA(isA<TranscriptionException>()),
    );
    expect(
      () => slicer.addAdpcm(Uint8List(1)),
      throwsA(isA<TranscriptionException>()),
    );
    slicer.flush();
    expect(
      () => slicer.addPcm16(Uint8List(2)),
      throwsA(
        isA<TranscriptionException>().having((e) => e.code, 'code', 'closed'),
      ),
    );
  });
}
