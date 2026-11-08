import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcribe/utterance_builder.dart';

void main() {
  group('splitSentences', () {
    test('按中文句末标点切分，保留文字', () {
      expect(
        splitSentences('今天讨论了三件事。第一是排期！第二是预算？'),
        ['今天讨论了三件事', '第一是排期', '第二是预算'],
      );
    });

    test('空文本返回空列表', () {
      expect(splitSentences('   '), isEmpty);
    });

    test('超长句按逗号再切，单句不超过 80 字', () {
      final long = '${'一' * 60}，${'二' * 60}，${'三' * 60}';
      final parts = splitSentences(long);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(81));
      }
    });
  });

  group('allocateTimes', () {
    test('严格递增、覆盖起止、每句至少 200ms', () {
      final times = allocateTimes(
        sentences: const ['短', '中等长度的一句话', '这是一句更长一些的话'],
        startMs: 1000,
        endMs: 10000,
      );
      expect(times.length, 3);
      expect(times.first.$1, 1000);
      expect(times.last.$2, 10000);
      for (var i = 0; i < times.length; i++) {
        expect(times[i].$2 - times[i].$1, greaterThanOrEqualTo(200));
        if (i > 0) expect(times[i].$1, times[i - 1].$2);
      }
    });
  });

  group('buildUtterancesFromAsr（token 对齐）', () {
    test('按 500ms 停顿切句，文本来自 token 拼接', () {
      final list = buildUtterancesFromAsr(
        sliceId: '0002',
        sliceStartMs: 60000,
        sliceEndMs: 120000,
        text: '今天讨论排期。明天确认预算。',
        tokens: const [
          '今', '天', '讨', '论', '排', '期', '。', //
          '明', '天', '确', '认', '预', '算', '。',
        ],
        tokenTimestampsMs: const [
          100, 400, 700, 1000, 1300, 1600, 1800, //
          3500, 3800, 4100, 4400, 4700, 5000, 5200,
        ],
      );
      expect(list.length, 2);
      expect(list.first.text, '今天讨论排期。');
      expect(list.last.text, '明天确认预算。');
      expect(list.first.startMs, 60100);
      expect(list.last.startMs, 63500);
      expect(list.first.endMs, lessThanOrEqualTo(list.last.startMs));
    });

    test('token 与 text 不一致时回退到标点切分（不丢内容）', () {
      final list = buildUtterancesFromAsr(
        sliceId: '0003',
        sliceStartMs: 0,
        sliceEndMs: 10000,
        text: '第一句话。第二句话。',
        tokens: const ['完全', '不同'],
        tokenTimestampsMs: const [0, 100],
      );
      expect(list.length, 2);
      expect(list.first.text, '第一句话');
    });

    test('特殊标记不进文本', () {
      final list = buildUtterancesFromAsr(
        sliceId: '0004',
        sliceStartMs: 0,
        sliceEndMs: 3000,
        text: '你好',
        tokens: const ['<|zh|>', '你', '好', '<|NEUTRAL|>'],
        tokenTimestampsMs: const [0, 100, 400, 800],
      );
      expect(list.single.text, '你好');
    });
  });

  group('buildUtterances（兜底）', () {
    test('生成稳定 id、相对时间、情绪与语种', () {
      final list = buildUtterances(
        sliceId: '0003',
        sliceStartMs: 120000,
        sliceEndMs: 180000,
        text: '第一句话。第二句话。',
        tokenTimestampsMs: const [500, 2500],
        lang: 'zh',
        emotion: 'NEUTRAL',
      );
      expect(list.length, 2);
      expect(list.first.id, '0003u0');
      expect(list.last.id, '0003u1');
      expect(list.first.startMs, 120500);
      expect(list.last.endMs, 122500);
      expect(list.first.emotion, 'NEUTRAL');
      expect(list.first.lang, 'zh');
    });

    test('空文本不产出 utterance', () {
      expect(
        buildUtterances(
          sliceId: '0001',
          sliceStartMs: 0,
          sliceEndMs: 1000,
          text: '   ',
        ),
        isEmpty,
      );
    });
  });
}
