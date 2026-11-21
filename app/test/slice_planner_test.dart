import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';

const _rate = 16000;

int _s(int seconds) => seconds * _rate;

void main() {
  group('SlicePlanner', () {
    const planner = SlicePlanner();

    test('没有语音 → 零片（不造静音片）', () {
      final slices = planner.plan(
        speech: const [],
        totalSamples: _s(600),
        sampleRate: _rate,
      );
      expect(slices, isEmpty);
    });

    test('按静音切：每片落在 SenseVoice 最佳窗口（<= 35 秒）、不重叠、顺序单调', () {
      // 每 14 秒说 12 秒、静音 2 秒
      final speech = <SpeechSpan>[];
      for (var i = 0; i < 8; i++) {
        final base = _s(i * 14);
        speech.add(SpeechSpan(base, base + _s(12)));
      }
      final slices = planner.plan(
        speech: speech,
        totalSamples: _s(120),
        sampleRate: _rate,
      );

      expect(slices, isNotEmpty);
      var previousEnd = 0;
      for (var i = 0; i < slices.length; i++) {
        final s = slices[i];
        final seconds = s.length / _rate;
        if (i < slices.length - 1) {
          expect(seconds, greaterThanOrEqualTo(25));
        }
        expect(seconds, lessThanOrEqualTo(35));
        expect(s.startSample, greaterThanOrEqualTo(previousEnd));
        expect(s.endSample, greaterThan(s.startSample));
        previousEnd = s.endSample;
      }
      // 覆盖到最后一段语音，且最后一片保留尾部真实静音
      expect(slices.last.endSample, greaterThanOrEqualTo(speech.last.endSample));
      expect(slices.last.silenceAfterSamples, _s(120) - speech.last.endSample);
    });

    test('连续说话超过 35 秒：硬切且片间不重叠', () {
      final slices = planner.plan(
        speech: [SpeechSpan(0, _s(300))],
        totalSamples: _s(300),
        sampleRate: _rate,
      );

      expect(slices.length, greaterThanOrEqualTo(9));
      var previousEnd = 0;
      for (final s in slices) {
        expect(s.length, lessThanOrEqualTo(35 * _rate));
        expect(s.startSample, greaterThanOrEqualTo(previousEnd));
        previousEnd = s.endSample;
      }
      expect(previousEnd, _s(300));
    });

    test('长静音会切开并记录在 silenceAfterSamples 里（用于分段）', () {
      final slices = planner.plan(
        speech: [
          SpeechSpan(_s(0), _s(30)),
          SpeechSpan(_s(50), _s(80)),
        ],
        totalSamples: _s(80),
        sampleRate: _rate,
      );
      expect(slices.length, 2);
      // 20 秒静音触发收片，正好是话题边界
      expect(slices.first.silenceAfterSamples / _rate, closeTo(20, 0.1));
      expect(slices.last.startSample, greaterThanOrEqualTo(_s(49)));
      expect(slices.last.endSample, greaterThanOrEqualTo(_s(80)));
    });

    test('单片录音只产出合法区间', () {
      final slices = planner.plan(
        speech: [SpeechSpan(_s(1), _s(11))],
        totalSamples: _s(12),
        sampleRate: _rate,
      );
      expect(slices.length, 1);
      expect(slices.first.startSample, greaterThanOrEqualTo(0));
      expect(slices.first.endSample, lessThanOrEqualTo(_s(12)));
    });
  });
}
