import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/summary_result_page.dart';
import 'package:recording_card/services/ai/summary_checkpoint_store.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/model_stub.dart';
import 'support/test_transitions.dart';

const _fullJson = '''
{
  "title": "端侧流式总结测试",
  "overview": "讨论了语音输入法与端侧大模型方案。",
  "structure": [{"name": "方案设计", "leaves": ["时间窗口找气口", "上下文断点续跑"]}],
  "points": [{"title": "核心决定", "detail": "确认录音期间只录不转。", "sources": ["e1"]}],
  "todos": ["完成端到端测试并提交 PR"]
}
''';

void main() {
  testWidgets('前台实时流式输出 + 切后台缓存上下文 + 恢复后继续完成总结', (tester) async {
    final memStore = InMemoryStore();
    final jsonStore = JsonStore(store: memStore);
    final cpStore = SummaryCheckpointStore(jsonStore: jsonStore);

    final sseGate1 = Completer<void>();
    var requestSeq = 0;

    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      requestSeq++;
      if (requestSeq == 1) {
        // 第 1 次请求：先推一半 SSE delta，然后等待切后台暂停信号
        final ctrl = StreamController<List<int>>();
        final half = _fullJson.substring(0, 60);
        final sseLine = 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': half},
            },
          ],
        })}\n\n';
        ctrl.add(utf8.encode(sseLine));
        unawaited(
          sseGate1.future.then((_) {
            if (!ctrl.isClosed) ctrl.close();
          }),
        );
        return http.StreamedResponse(
          ctrl.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }

      // 第 2 次请求（恢复续跑）：验证消息中带有已缓存的前缀，并返回剩余/完整 JSON
      final ctrl = StreamController<List<int>>();
      final sseLine = 'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': _fullJson},
          },
        ],
      })}\n\ndata: [DONE]\n\n';
      ctrl.add(utf8.encode(sseLine));
      unawaited(ctrl.close());
      return http.StreamedResponse(
        ctrl.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final gateway = await buildModelGateway(client);
    final generator = SummaryGenerator(
      gateway: gateway,
      checkpointStore: cpStore,
    );
    final events = [
      const RecordEvent(
        id: 'e1',
        dayOffset: 0,
        time: '10:00',
        title: '技术评审',
        dur: '2m',
        speakers: '说话人 1',
        brief: '讨论端侧大模型方案',
        longText: '录音期间只录不转，切后台保存总结上下文。',
        mark: '',
        srcMap: '来源 10:00—10:02',
        raw: [TurnLine('说话人 1', '录音期间只录不转，切后台保存总结上下文。', '10:00')],
        dialog: [TurnLine('说话人 1', '录音期间只录不转，切后台保存总结上下文。', '10:00')],
      ),
    ];

    final appStore = AppStore(
      events: events,
      generator: generator,
      jsonStore: jsonStore,
      summaryCheckpoints: cpStore,
      loadPersistedState: true,
    );
    addTearDown(appStore.dispose);

    appStore.startSummary();
    appStore.toggleSel('e1');
    appStore.genSummary();

    final summaryId = appStore.summaries.first.id;
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: StoreScope(
          store: appStore,
          child: Scaffold(body: SummaryResultPage(summaryId: summaryId)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 1) 前台提示文案与流式预览必须实时可见
    expect(find.byKey(const Key('gen-stay-hint')), findsOneWidget);
    expect(find.byKey(const Key('gen-stream-preview')), findsOneWidget);
    expect(appStore.summaryById(summaryId)!.streamPreview, contains('端侧流式总结测试'));

    // 2) 模拟切后台/失活：暂停并落盘检查点，放行第 1 个挂起的流
    await appStore.pauseGeneratingSummaryForBackground();
    sseGate1.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final pausedCard = appStore.summaryById(summaryId)!;
    expect(pausedCard.state, SummaryState.generating);
    expect(pausedCard.pausedForBackground, isTrue);
    expect(find.byKey(const Key('gen-resume')), findsOneWidget);

    final savedCp = await cpStore.load(summaryId);
    expect(savedCp, isNotNull);
    expect(savedCp!.streamedText, contains('端侧流式总结测试'));

    // 3) 模拟进程被杀后冷重启：新 AppStore 从存储恢复检查点卡片，并点击继续生成完成总结
    final restoredStore = AppStore(
      events: events,
      generator: generator,
      jsonStore: jsonStore,
      summaryCheckpoints: cpStore,
      loadPersistedState: true,
    );
    addTearDown(restoredStore.dispose);
    await restoredStore.init();

    final restoredCard = restoredStore.summaryById(summaryId);
    expect(restoredCard, isNotNull);
    expect(restoredCard!.state, SummaryState.generating);
    expect(restoredCard.pausedForBackground, isTrue);
    expect(restoredCard.streamPreview, contains('端侧流式总结测试'));

    final resumed = await restoredStore.resumePausedSummary(summaryId);
    expect(resumed, isTrue);
    for (var i = 0; i < 20 && restoredCard.state != SummaryState.done; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(restoredCard.state, SummaryState.done);
    expect(restoredCard.title, '端侧流式总结测试');
    expect(await cpStore.load(summaryId), isNull, reason: '完成后应自动清理断点缓存');
  });

  test('Map-Reduce 长文总结断点续跑：中断后跳过已完成批次继续汇总', () async {
    final cpStore = SummaryCheckpointStore(jsonStore: JsonStore(store: InMemoryStore()));
    var callCount = 0;
    var pauseNow = false;

    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) {
        // 第 1 批 map 完成后立刻模拟切后台
        pauseNow = true;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '[e1] 第一批事实：预算 50 万。'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (callCount == 2) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '[e2] 第二批事实：周五上线。'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'content': _fullJson},
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final gateway = await buildModelGateway(client);
    final generator = SummaryGenerator(
      gateway: gateway,
      checkpointStore: cpStore,
      mapReduceTriggerChars: 2000,
      mapBatchTargetChars: 1500,
    );

    final big1 = '第一段内容。' * 200;
    final big2 = '第二段内容。' * 200;
    final events = [
      RecordEvent(
        id: 'e1',
        dayOffset: 0,
        time: '09:00',
        title: '早会一',
        dur: '10m',
        speakers: '说话人 1',
        brief: '预算讨论',
        longText: big1,
        mark: '',
        srcMap: '来源 09:00—09:10',
        raw: [TurnLine('说话人 1', big1, '09:00')],
        dialog: [TurnLine('说话人 1', big1, '09:00')],
      ),
      RecordEvent(
        id: 'e2',
        dayOffset: 0,
        time: '10:00',
        title: '早会二',
        dur: '10m',
        speakers: '说话人 1',
        brief: '上线安排',
        longText: big2,
        mark: '',
        srcMap: '来源 10:00—10:10',
        raw: [TurnLine('说话人 1', big2, '10:00')],
        dialog: [TurnLine('说话人 1', big2, '10:00')],
      ),
    ];

    late SummaryCheckpoint pausedCp;
    try {
      await generator.generate(
        events,
        summaryId: 'sum_mr_1',
        isPaused: () => pauseNow,
      );
      fail('预期应触发 SummaryPausedException');
    } on SummaryPausedException catch (e) {
      pausedCp = e.checkpoint;
    }

    expect(pausedCp.completedBatchDigests.length, 1);
    expect(pausedCp.totalBatches, 2);
    expect(callCount, 1);

    // 恢复续跑：应跳过第 1 批，只请求第 2 批 + reduce
    pauseNow = false;
    final draft = await generator.generate(
      events,
      summaryId: 'sum_mr_1',
      resumeFrom: pausedCp,
    );

    expect(callCount, 3, reason: '第 1 批已完成被跳过，仅跑第 2 批与全局汇总');
    expect(draft.title, '端侧流式总结测试');
  });
}
