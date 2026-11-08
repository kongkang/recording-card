// AppStore 契约测试 —— 路由栈扁平化 / 勾选范围 / 会话导出恢复 / 生成链路。
//
// 这一轮 AppStore 的数据来源全部换成真实链路：
// - 默认 `events` 为空（真实录音由设备同步而来），需要固定数据集就注入 seedEvents；
// - `genSummary()` 真的调 `SummaryGenerator`（HTTP 用 MockClient 顶掉），
//   失败就落 `SummaryState.failed` 并给出原因，绝不产出「进度走完但是编的内容」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';

import 'support/model_stub.dart';

/// 与服务一致的三种范围语义（测试里独立再推导一遍，避免和实现共用一个 bug）。
bool _inRange(RecordEvent e, String r) {
  if (r == 'today') return e.dayOffset == 0;
  if (r == 'week') return e.dayOffset <= mondayOffset;
  final now = DateTime.now();
  final d = now.subtract(Duration(days: e.dayOffset));
  return d.month == now.month && d.year == now.year;
}

int _rangeCount(String r) => seedEvents.where((e) => _inRange(e, r)).length;

/// 建一个注入固定数据集的 store（不读磁盘、不去设备取）。
AppStore _store() =>
    AppStore(events: seedEvents, loadPersistedState: false);

/// 等生成流程真正跑完（真实异步：HTTP → 解析 → 落卡）。
Future<void> _waitDone(SummaryCard card) async {
  for (var i = 0; i < 200; i++) {
    if (card.state != SummaryState.generating) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('生成没有在预期时间内结束（state=${card.state}）');
}

void main() {
  group('路由栈', () {
    test('跳向栈内已有页面即扁平化截断，不会无限嵌套', () {
      final store = _store();
      addTearDown(store.dispose);

      store.openDetail('e1');
      store.openDetail('e2');
      expect(store.subStack.length, 2);
      store.openDetail('e1'); // 回到栈内已有的层
      expect(store.subStack.length, 1, reason: '扁平化：截断到已存在的那一层');
      expect(store.stackTop, const RouteEntry('detail', 'e1'));
    });

    test('goBack 逐层弹栈，最后一层回到根页并清空栈', () {
      final store = _store();
      addTearDown(store.dispose);

      store.openDetail('e1');
      store.openDetail('e2');
      expect(store.crumbDest, '记录', reason: '上层是 detail → 返回文案「记录」');

      store.goBack();
      expect(store.subStack.length, 1);
      expect(store.crumbDest, 'Timeline', reason: '栈底时返回目标是根页');

      store.goBack();
      expect(store.subStack, isEmpty);
      expect(store.rootTab, RootTab.timeline);
    });

    test('根级新选择（fresh）把栈重置成单层，不叠返回', () {
      final store = _store();
      addTearDown(store.dispose);

      store.openDetail('e1');
      store.openDetail('e2');
      store.openDetail('e4', fresh: true);
      expect(store.subStack.length, 1);
      expect(store.stackPrev, isNull);
      expect(store.showPaneBackDetail, isFalse);
    });

    test('handleSystemBack：栈内有页就退一页并接管，栈空交还系统', () {
      final store = _store();
      addTearDown(store.dispose);

      expect(store.handleSystemBack(), isFalse, reason: '栈空 → 系统退出 App');
      store.openDetail('e1');
      expect(store.handleSystemBack(), isTrue);
      expect(store.subStack, isEmpty);
    });

    test('onSubPopped（手势返回）：只同步栈状态，不反向触发导航', () {
      final store = _store();
      addTearDown(store.dispose);
      store.openDetail('e1');
      store.openDetail('e2');
      store.onSubPopped();
      expect(store.subStack.single, const RouteEntry('detail', 'e1'));
    });

    test('openSum 只接受已完成的总结卡（未完成点不进去）', () async {
      final model = SummaryModel();
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      final pendingId = store.summaries.first.id;
      store.openSum(pendingId);
      expect(store.subStack, isEmpty, reason: 'pending 卡没有可看的结果');

      store.selRange('week');
      store.genSummary();
      await _waitDone(store.summaries.first);
      store.openSum(pendingId);
      expect(store.stackTop, RouteEntry('sum', pendingId));
    });
  });

  group('勾选范围与 Tab 锁定', () {
    test('今日 / 本周 / 本月 三档范围按记录日期推导', () {
      final store = _store();
      addTearDown(store.dispose);

      store.startSummary();
      expect(store.tabsLocked, isTrue);
      expect(store.filter, FeedFilter.event);
      expect(store.selIds, isEmpty);

      store.selRange('today');
      expect(store.selCount, _rangeCount('today'));

      store.selRange('week');
      expect(store.selCount, _rangeCount('week'));
      expect(
        store.selCount,
        greaterThanOrEqualTo(_rangeCount('today')),
        reason: '本周至少包含今日',
      );

      store.selRange('month');
      expect(store.selCount, _rangeCount('month'));
      expect(
        store.selCount,
        greaterThanOrEqualTo(_rangeCount('week')),
        reason: '本月至少包含本周',
      );

      store.selNone();
      expect(store.selIds, isEmpty);

      store.toggleSel('e1');
      expect(store.selIds, {'e1'});
      store.toggleSel('e1');
      expect(store.selIds, isEmpty);
    });

    test('取消勾选模式：锁解开、筛选回「全部」、挂起卡移除', () {
      final store = _store();
      addTearDown(store.dispose);

      store.startSummary();
      expect(store.summaries.single.state, SummaryState.pending);

      store.cancelSummary();
      expect(store.selMode, isFalse);
      expect(store.tabsLocked, isFalse);
      expect(store.filter, FeedFilter.all);
      expect(store.summaries, isEmpty);
      expect(store.pend, isNull);
    });
  });

  group('生成总结（真实生成器）', () {
    test('成功：卡片字段来自模型返回，统计行由本地推导', () async {
      final model = SummaryModel();
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('week');
      final card = store.summaries.first;
      expect(card.srcIds, isEmpty);

      store.genSummary();
      expect(card.state, SummaryState.generating);
      expect(card.srcIds.length, _rangeCount('week'), reason: '生成时的来源已固定');
      expect(store.stackTop?.type, 'sum', reason: '立即跳到总结页看进度');

      await _waitDone(card);
      expect(card.state, SummaryState.done);
      expect(card.progress, 100);
      expect(card.title, '项目排期与客户反馈');
      expect(card.overview, isNotEmpty);
      expect(card.structure.length, 3);
      expect(card.points.length, 4);
      expect(card.todos.length, 3);
      expect(card.markdown, contains('## 概览'));
      // 统计行是本地推导：「今天/跨 X 至 Y · N 条记录」
      expect(card.subDesc, contains('${card.srcIds.length} 条记录'));
      expect(card.subDesc, isNot(contains('来源')));
      expect(card.srcDesc, contains('午后项目方向讨论'));
      expect(model.requests, hasLength(1), reason: '真的发了一次模型请求');
    });

    test('失败：落 failed 且带原因，不产出任何内容字段', () async {
      final model = SummaryModel(content: kMalformedJson);
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('week');
      final card = store.summaries.first;
      store.genSummary();
      await _waitDone(card);

      expect(card.state, SummaryState.failed);
      expect(card.error, '总结结果解析失败，请重试');
      expect(card.title, isNull);
      expect(card.overview, isNull);
      expect(card.points, isEmpty);
      expect(card.markdown, isNull);
      expect(store.stackTop?.type, 'sum', reason: '失败也留在总结页给出重试入口');
    });

    test('没注入生成器（服务未装配）→ failed 文案「总结服务未就绪」', () async {
      final store = AppStore(events: seedEvents, loadPersistedState: false);
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('week');
      final card = store.summaries.first;
      store.genSummary();
      await _waitDone(card);
      expect(card.state, SummaryState.failed);
      expect(card.error, '总结服务未就绪');
    });

    test('重试：复用同一张卡，成功后填内容', () async {
      final model = SummaryModel(content: kNotJson);
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('today');
      final card = store.summaries.first;
      final id = card.id;
      store.genSummary();
      await _waitDone(card);
      expect(card.state, SummaryState.failed);

      model.content = kSummaryJson; // 这次模型正常返回
      store.retryGeneration(id);
      expect(card.state, SummaryState.generating);
      await _waitDone(card);
      expect(card.state, SummaryState.done);
      expect(card.title, '项目排期与客户反馈');
      expect(store.summaries.length, 1, reason: '重试复用同一张卡，不新开');
    });

    test('放弃失败卡：卡片从列表与会话快照里消失', () async {
      final model = SummaryModel(content: kNotJson);
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('today');
      final card = store.summaries.first;
      store.genSummary();
      await _waitDone(card);

      store.dismissFailed(card.id);
      expect(store.summaries, isEmpty);
      expect(store.subStack, isEmpty, reason: '栈顶就是这张卡 → 一并退出');

      // 失败卡不写进会话快照（只有 done 才落盘）
      expect(store.exportState()['sums'], isEmpty);
    });
  });

  group('会话导出 / 恢复', () {
    test('只保存已完成的总结与栈，恢复后能重建同一页面与卡片', () async {
      final model = SummaryModel();
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('today');
      final card = store.summaries.first;
      store.genSummary();
      await _waitDone(card);
      store.openDetail('e1'); // 栈：sum → detail

      final exported = store.exportState();

      // 新 store 恢复（等价于同标签页刷新）
      final restored = AppStore(events: seedEvents, loadPersistedState: false);
      addTearDown(restored.dispose);
      restored.restoreState(exported);

      expect(restored.summaries.length, 1);
      final back = restored.summaries.first;
      expect(back.state, SummaryState.done);
      expect(back.id, card.id);
      expect(back.title, '项目排期与客户反馈');
      expect(back.points.length, 4);
      expect(back.points.first.sources.single.eventId, 'e1');
      expect(back.subDesc, contains('条记录'));
      expect(restored.subStack, [
        RouteEntry('sum', card.id),
        const RouteEntry('detail', 'e1'),
      ]);
    });

    test('栈里失效的 sum id 被丢弃，detail id 保留（详情页自己有失效空态）', () {
      final store = _store();
      addTearDown(store.dispose);

      store.restoreState({
        'sums': [
          {
            'id': 'act1',
            'time': '09:00',
            'srcIds': ['e1'],
            'title': '标题',
            'subDesc': '今天 09:00–09:30 · 1 条记录',
            'overview': '概览',
            'structure': [
              {'name': '分支', 'leaves': ['叶子']},
            ],
            'points': [
              {
                't': '信息点',
                'd': '细节',
                'src': [
                  ['e1', '午后项目方向讨论', '14:20 · 18分40秒'],
                ],
              },
            ],
            'todos': <String>[],
            'srcDesc': '今天 14:20 午后项目方向讨论',
            'md': '# 标题',
          },
        ],
        'stack': [
          {'t': 'sum', 'id': 'act1'},
          {'t': 'detail', 'id': 'e2'},
          {'t': 'sum', 'id': 'ghost'},
        ],
      });

      expect(store.summaries.single.id, 'act1');
      expect(store.subStack, [
        const RouteEntry('sum', 'act1'),
        const RouteEntry('detail', 'e2'),
      ], reason: '不存在的总结 id 不能恢复出一张空结果页');
    });

    test('restoreState(null) 是安全的空操作', () {
      final store = _store();
      addTearDown(store.dispose);
      store.restoreState(null);
      expect(store.summaries, isEmpty);
      expect(store.subStack, isEmpty);
    });
  });

  group('记录查找与引用', () {
    test('eventByIdOrNull 对未知 id 返回 null（不抛、不乱回退）', () {
      final store = _store();
      addTearDown(store.dispose);
      expect(store.eventByIdOrNull('e1')?.title, '午后项目方向讨论');
      expect(store.eventByIdOrNull('e404'), isNull);
      // 明确需要「至少有内容可展示」的地方才用带 fallback 的版本
      expect(store.eventByIdOrNullOrFallback('e404')?.id, 'e1');
    });

    test('空数据集的 fallback 返回 null（没有记录就不编一条出来）', () {
      final store = AppStore(loadPersistedState: false);
      addTearDown(store.dispose);
      expect(store.eventByIdOrNull('e1'), isNull);
      expect(store.eventByIdOrNullOrFallback('e1'), isNull);
      expect(store.feedGroups, isEmpty);
    });

    test('doneSummariesReferencing 只统计已完成且覆盖该记录的卡', () async {
      final model = SummaryModel();
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(store.dispose);

      store.startSummary();
      store.selRange('today');
      final card = store.summaries.first;
      store.genSummary();
      await _waitDone(card);

      expect(store.doneSummariesReferencing('e1').length, 1);
      expect(store.doneSummariesReferencing('e6'), isEmpty);
    });
  });

  group('录音同步入口', () {
    test('未装配同步服务时明确报「录音同步未就绪」，不动数据', () async {
      final store = _store();
      addTearDown(store.dispose);
      final before = [...store.events];
      final error = await store.syncRecordings();
      expect(error, '录音同步未就绪，请稍后重试');
      expect(store.syncError, error, reason: '失败要能被界面读到');
      expect(store.events.length, before.length);
      expect(store.syncStage, isNull);
    });
  });
}
