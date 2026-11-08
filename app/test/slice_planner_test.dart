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

    test('按静音切：每片 45~90 秒、不重叠、顺序单调', () {
      // 每 25 秒说 20 秒、静音 5 秒
      final speech = <SpeechSpan>[];
      for (var i = 0; i < 8; i++) {
        final base = _s(i * 25);
        speech.add(SpeechSpan(base, base + _s(20)));
      }
      final slices = planner.plan(
        speech: speech,
        totalSamples: _s(200),
        sampleRate: _rate,
      );

      expect(slices, isNotEmpty);
      var previousEnd = 0;
      for (final s in slices) {
        final seconds = s.length / _rate;
        expect(seconds, greaterThanOrEqualTo(30));
        expect(seconds, lessThanOrEqualTo(90));
        expect(s.startSample, greaterThanOrEqualTo(previousEnd));
        expect(s.endSample, greaterThan(s.startSample));
        previousEnd = s.endSample;
      }
      // 覆盖到最后一段语音
      expect(slices.last.endSample, greaterThanOrEqualTo(speech.last.endSample));
    });

    test('连续说话超过 90 秒：硬切且片间不重叠', () {
      final slices = planner.plan(
        speech: [SpeechSpan(0, _s(300))],
        totalSamples: _s(300),
        sampleRate: _rate,
      );

      expect(slices.length, greaterThanOrEqualTo(4));
      var previousEnd = 0;
      for (final s in slices) {
        expect(s.length, lessThanOrEqualTo(90 * _rate));
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
