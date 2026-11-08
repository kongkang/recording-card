// 阶段性总结验收（TDD）—— 长静音切段、片段上下文送总结、失败回退不丢段。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/analysis/staged_summary.dart';
import 'package:recording_card/services/model_gateway/model_gateway_client.dart';

SummarySegmentInput _seg(String id, int start, int end, String text) =>
    SummarySegmentInput(
      id: id,
      startMs: start,
      endMs: end,
      cleanText: text,
      speaker: 'A',
    );

class FakeSummarizer implements EventSummarizer {
  final List<List<String>> calls = [];
  final List<EventSummary?> previous = [];
  Object? error;

  @override
  Future<EventSummary> summarize(
    List<SummarySegmentInput> segments, {
    EventSummary? previousEvent,
  }) async {
    calls.add([for (final s in segments) s.id]);
    previous.add(previousEvent);
    final failure = error;
    if (failure != null) throw failure;
    return EventSummary(
      id: 'event-${calls.length}',
      startMs: segments.first.startMs,
      endMs: segments.last.endMs,
      title: '事件 ${calls.length}',
      overview: segments.map((s) => s.cleanText).join(' / '),
      segmentIds: [for (final s in segments) s.id],
    );
  }
}

void main() {
  test('长静音触发切段：a+b 在 c 到达时先总结，flush 再总结 c', () async {
    final summarizer = FakeSummarizer();
    final c = StagedSummaryCoordinator(
      summarizer: summarizer,
      silenceGap: const Duration(seconds: 3),
    );
    await c.add(_seg('a', 0, 1000, 'A'));
    await c.add(_seg('b', 1500, 2500, 'B'));
    final beforeFlush = await c.add(_seg('c', 9000, 10000, 'C'));

    expect(beforeFlush.finalized?.segmentIds, ['a', 'b']);
    expect(summarizer.calls, [
      ['a', 'b']
    ]);
    expect(beforeFlush.events.single.title, '事件 1');

    final flushed = await c.flush();
    expect(flushed.finalized?.segmentIds, ['c']);
    expect(summarizer.calls, [
      ['a', 'b'],
      ['c']
    ]);
    expect(flushed.events, hasLength(2));
  });

  test('无静音时不提前总结，flush 只总结一次', () async {
    final summarizer = FakeSummarizer();
    final c = StagedSummaryCoordinator(
      summarizer: summarizer,
      silenceGap: const Duration(seconds: 3),
    );
    await c.add(_seg('a', 0, 1000, 'A'));
    final update = await c.add(_seg('b', 1200, 2200, 'B'));
    expect(update.finalized, isNull);
    expect(summarizer.calls, isEmpty);

    final flushed = await c.flush();
    expect(flushed.finalized?.segmentIds, ['a', 'b']);
    expect(summarizer.calls, [
      ['a', 'b']
    ]);
  });

  test('空 flush 不调用总结', () async {
    final summarizer = FakeSummarizer();
    final c = StagedSummaryCoordinator(summarizer: summarizer);
    final update = await c.flush();
    expect(update.finalized, isNull);
    expect(update.events, isEmpty);
    expect(summarizer.calls, isEmpty);
  });

  test('后续事件收到上一事件作为上下文', () async {
    final summarizer = FakeSummarizer();
    final c = StagedSummaryCoordinator(
      summarizer: summarizer,
      silenceGap: const Duration(seconds: 3),
    );
    await c.add(_seg('a', 0, 1000, 'A'));
    await c.add(_seg('b', 9000, 10000, 'B'));
    await c.flush();

    expect(summarizer.previous.first, isNull);
    expect(summarizer.previous.last?.segmentIds, ['a']);
  });

  test('总结失败：回退为原文事件并上报 error，不丢段', () async {
    final summarizer = FakeSummarizer()..error = Exception('cloud down');
    final c = StagedSummaryCoordinator(summarizer: summarizer);
    await c.add(_seg('a', 0, 1000, 'A'));
    final update = await c.flush();

    expect(update.error, isNotNull);
    final event = update.finalized!;
    expect(event.fallback, isTrue);
    expect(event.segmentIds, ['a']);
    expect(event.overview, contains('A'));
  });

  test('CloudEventSummarizer 解析 title/overview', () async {
    final gateway = ModelGatewayClient(
      modelsUri: Uri.parse('https://api.example.com/models'),
      chatCompletionsUri: Uri.parse('https://api.example.com/chat'),
      headers: () async => {'authorization': 'Bearer t'},
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode(
                        {'title': '项目排期讨论', 'overview': '讨论了排期。'})
                  }
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );
    final summarizer =
        CloudEventSummarizer(gateway: gateway, model: 'text-1');
    final event = await summarizer.summarize([_seg('a', 0, 1000, 'A')]);

    expect(event.title, '项目排期讨论');
    expect(event.overview, '讨论了排期。');
    expect(event.segmentIds, ['a']);
    expect(event.fallback, isFalse);
  });

  test('CloudEventSummarizer 非 JSON 输出抛异常', () async {
    final gateway = ModelGatewayClient(
      modelsUri: Uri.parse('https://api.example.com/models'),
      chatCompletionsUri: Uri.parse('https://api.example.com/chat'),
      headers: () async => {'authorization': 'Bearer t'},
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '无法总结'}
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );
    final summarizer =
        CloudEventSummarizer(gateway: gateway, model: 'text-1');
    await expectLater(
      summarizer.summarize([_seg('a', 0, 1000, 'A')]),
      throwsA(isA<AnalysisException>()),
    );
  });
}
