// 增量滑动窗口润色验收（TDD）—— A / A+B / A+B+C / B+C+D 窗口推进、
// 结果合并、缺失 ID 回退原文、异常不丢已润色结果、并发串行。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/analysis/incremental_refine.dart';

class FakeChat implements ChatCompletion {
  FakeChat(this.response);

  String response;
  int calls = 0;
  List<ChatMessage> lastMessages = const [];

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    String? model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    calls++;
    lastMessages = messages;
    return response;
  }
}

RefineSegmentInput _in(String id, String raw, {int start = 0}) =>
    RefineSegmentInput(
      id: id,
      startMs: start,
      endMs: start + 1000,
      rawText: raw,
      speaker: 'A',
      emotion: 'neutral',
    );

class FakeRefiner implements SegmentRefiner {
  final List<List<String>> calls = [];
  final Set<String> omitIds = {};
  final Set<String> extraIds = {};
  Object? error;

  @override
  Future<List<RefinedSegment>> refine(List<RefineSegmentInput> window) async {
    calls.add([for (final s in window) s.id]);
    final failure = error;
    if (failure != null) throw failure;
    return [
      for (final s in window)
        if (!omitIds.contains(s.id))
          RefinedSegment(
            id: s.id,
            cleanText: 'clean:${s.rawText}',
            speaker: s.speaker,
            emotion: s.emotion,
          ),
      for (final id in extraIds)
        RefinedSegment(id: id, cleanText: 'ghost'),
    ];
  }
}

void main() {
  test('窗口按 A / A+B / A+B+C / B+C+D 推进', () async {
    final refiner = FakeRefiner();
    final c = IncrementalRefineCoordinator(refiner: refiner);
    for (final id in ['a', 'b', 'c', 'd']) {
      await c.add(_in(id, id));
    }
    expect(refiner.calls, [
      ['a'],
      ['a', 'b'],
      ['a', 'b', 'c'],
      ['b', 'c', 'd'],
    ]);
    expect(c.segments.map((s) => s.id), ['a', 'b', 'c', 'd']);
  });

  test('changed 只包含新增或文本变化的段', () async {
    final refiner = FakeRefiner();
    final c = IncrementalRefineCoordinator(refiner: refiner);
    final first = await c.add(_in('a', 'a'));
    expect(first.changed.map((s) => s.id), ['a']);

    final second = await c.add(_in('b', 'b'));
    expect(second.changed.map((s) => s.id), ['b']);
  });

  test('润色器漏掉 ID：该段回退原文，不伪造', () async {
    final refiner = FakeRefiner()..omitIds.add('b');
    final c = IncrementalRefineCoordinator(refiner: refiner);
    await c.add(_in('a', 'raw-a'));
    final update = await c.add(_in('b', 'raw-b'));

    expect(c.segments.firstWhere((s) => s.id == 'b').cleanText, 'raw-b');
    expect(update.changed.map((s) => s.id), ['b']);
  });

  test('润色器返回未知 ID：忽略，不写入', () async {
    final refiner = FakeRefiner()..extraIds.add('ghost');
    final c = IncrementalRefineCoordinator(refiner: refiner);
    await c.add(_in('a', 'a'));
    expect(c.segments.map((s) => s.id), ['a']);
  });

  test('润色失败：新段回退原文，已润色结果保留，error 上报', () async {
    final refiner = FakeRefiner();
    final c = IncrementalRefineCoordinator(refiner: refiner);
    await c.add(_in('a', 'a'));
    refiner.error = Exception('cloud down');
    final update = await c.add(_in('b', 'raw-b'));

    expect(update.error, isNotNull);
    expect(c.segments.firstWhere((s) => s.id == 'a').cleanText, 'clean:a');
    expect(c.segments.firstWhere((s) => s.id == 'b').cleanText, 'raw-b');
  });

  test('并发 add 串行执行，窗口顺序不被打乱', () async {
    final refiner = FakeRefiner();
    final c = IncrementalRefineCoordinator(refiner: refiner);
    await Future.wait([
      c.add(_in('a', 'a')),
      c.add(_in('b', 'b')),
      c.add(_in('c', 'c')),
    ]);
    expect(refiner.calls, [
      ['a'],
      ['a', 'b'],
      ['a', 'b', 'c'],
    ]);
  });

  test('CloudSegmentRefiner 解析合法 JSON 数组', () async {
    final chat = FakeChat(jsonEncode([
      {'id': 'a', 'cleanText': '清洗 A', 'speaker': 'A'},
      {'id': 'b', 'cleanText': '清洗 B', 'speaker': 'B'},
    ]));
    final refiner = CloudSegmentRefiner(chat: chat, model: 'text-1');
    final out = await refiner.refine([_in('a', 'raw-a'), _in('b', 'raw-b')]);
    expect(out.map((s) => s.cleanText), ['清洗 A', '清洗 B']);
    expect(chat.calls, 1);
    expect(chat.lastMessages.first.role, 'system');
  });

  test('CloudSegmentRefiner 非 JSON 输出抛异常', () async {
    final refiner =
        CloudSegmentRefiner(chat: FakeChat('抱歉，我无法完成'), model: 'text-1');
    await expectLater(
      refiner.refine([_in('a', 'raw-a')]),
      throwsA(isA<AnalysisException>()),
    );
  });
}
