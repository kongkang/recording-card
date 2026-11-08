// 窄屏主线验收 —— 对齐 prototype/verify.cjs（390×844）检查项。
// 命名沿用 verify.cjs 末尾 checks 数组；段落注释标注对应脚本行号。
//
// 这一轮的数据来源换成真实链路：记录集固定注入（模拟设备同步结果），
// 总结由真实的 SummaryGenerator 产出（HTTP 由 MockClient 顶掉），
// 因此断言的是「模型返回了什么 + 本地推导了什么」，不再是 6 秒假进度。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';

import 'support/harness.dart';
import 'support/model_stub.dart';

/// 与服务一致的三种勾选范围语义（测试独立推导，避免和实现共用同一个 bug）。
bool _inRange(RecordEvent e, String r) {
  if (r == 'today') return e.dayOffset == 0;
  if (r == 'week') return e.dayOffset <= mondayOffset;
  final now = DateTime.now();
  final d = now.subtract(Duration(days: e.dayOffset));
  return d.month == now.month && d.year == now.year;
}

int _rangeCount(String r) => seedEvents.where((e) => _inRange(e, r)).length;

/// 模型返回的第一条信息点的溯源链接 key（range = 记录的时间 · 时长）。
const _srcChipE1 = Key('srcchip-e1-14:20 · 18分40秒');

void main() {
  // verify.cjs 33-44：固定高度顶栏、底栏、tab 文案、根页 crumb 隐藏、无模拟标注、电池胶囊仅图标
  testWidgets('fixed-chrome / crumb-root-hidden / battery-capsule / no-sim-labels', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
    expect(find.byKey(const Key('nav-setting')), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.text('Setting'), findsOneWidget);
    expect(find.byKey(const Key('tab-all')), findsOneWidget);
    expect(find.byKey(const Key('tab-event')), findsOneWidget);
    expect(find.byKey(const Key('tab-summary')), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('总结'), findsWidgets); // Tab + 发起按钮
    expect(find.byKey(const Key('app-title')), findsOneWidget);
    expect(find.byKey(const Key('crumb-back')), findsNothing);
    final hh = tester.getSize(find.byKey(const Key('app-header'))).height;
    expect(hh >= 50 && hh <= 56, isTrue, reason: 'header 高度应固定 ≈52，实际 $hh');
    expect(find.textContaining('模拟'), findsNothing);
    expect(find.textContaining('演示'), findsNothing);
    // 下拉刷新是真实入口（从录音卡取回新录音），不是装饰
    expect(find.byKey(const Key('timeline-refresh')), findsOneWidget);
    // 胶囊内不得出现数字（电量不显百分比）
    for (final t in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('hw-capsule')),
        matching: find.byType(Text),
      ),
    )) {
      expect(RegExp(r'\d').hasMatch(t.data ?? ''), isFalse);
    }
  });

  // verify.cjs 47-64：卡片展开/收起 → 详情 → 原始数据 → 顶栏返回
  testWidgets(
    'two-line-card / expand-collapse / detail-entry / subpage-hides-nav / detail-tabs-raw',
    (tester) async {
      await pumpShell(tester);
      expect(find.byKey(const Key('when-e1')), findsOneWidget); // 两行：标题 + 时间·时长
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      expect(find.byKey(const Key('detail-e1')), findsOneWidget); // 展开出现详情按钮
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      expect(find.byKey(const Key('detail-e1')), findsNothing); // 再次点击收起
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detail-e1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.text('午后项目方向讨论'), findsOneWidget);
      expect(find.byKey(const Key('nav-timeline')), findsNothing); // 子页隐藏底栏
      expect(find.byKey(const Key('crumb-back')), findsOneWidget);
      expect(find.byKey(const Key('crumb-dest')), findsOneWidget);
      expect(find.text('Timeline'), findsOneWidget);
      expect(find.byKey(const Key('det-tab-refs')), findsNothing); // 无引用时隐藏第三 tab
      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pump();
      expect(find.textContaining('啊不对'), findsOneWidget); // 原始数据保留语气词
      await tester.tap(find.byKey(const Key('det-tab-dlg')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('nav-timeline')), findsOneWidget); // 返回后底栏恢复
    },
  );

  // verify.cjs 67-87：勾选模式锁定 Tab + 范围全选 + 底部操作栏两行
  testWidgets('select-mode / tabs-lock-on-summary / range-* / tap-toggle / sumbar-rows', (
    tester,
  ) async {
    final h = await pumpShell(tester);
    final store = h.store;
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    expect(disabledOf(tester, const Key('tab-all')), isTrue);
    expect(disabledOf(tester, const Key('tab-summary')), isTrue);
    expect(disabledOf(tester, const Key('tab-event')), isFalse);
    expect(store.filter, FeedFilter.event);
    expect(store.events.length, 6); // 6 条记录进入勾选模式
    expect(store.selIds, isEmpty);
    expect(find.byKey(const Key('rangebar')), findsOneWidget);
    expect(find.byKey(const Key('sumbar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-today')));
    await tester.pump();
    final todayCount = _rangeCount('today');
    expect(store.selCount, todayCount);
    expect(find.text('已选 $todayCount 项'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-week')));
    await tester.pump();
    expect(store.selCount, _rangeCount('week'), reason: '本周 = 今日 + 昨天 + 本周一');
    expect(store.selCount, greaterThanOrEqualTo(_rangeCount('today')));

    await tester.tap(find.byKey(const Key('chip-month')));
    await tester.pump();
    expect(store.selCount, _rangeCount('month'));
    expect(store.selCount, greaterThanOrEqualTo(_rangeCount('week')));

    await tester.tap(find.byKey(const Key('chip-none')));
    await tester.pump();
    expect(store.selCount, 0);

    await tester.tap(find.byKey(const Key('chip-week')));
    await tester.pump();
    final weekCount = _rangeCount('week');
    expect(find.text('已选 $weekCount 项'), findsOneWidget);
    expect(find.text('生成总结'), findsOneWidget);
    expect(disabledOf(tester, const Key('generate-summary')), isFalse);

    // 手动点选切换（卡片可见区）
    await tester.tap(find.byKey(const Key('card-e1')));
    await tester.pump();
    expect(store.selCount, weekCount - 1);
    await tester.tap(find.byKey(const Key('card-e1')));
    await tester.pump();
    expect(store.selCount, weekCount);
  });

  // verify.cjs 90-107：生成 → 进度/秒数/步骤（真实计时）→ 完成就地填充结果
  testWidgets('gen-status-view / generate-progress / sum-tabs / default-all-view', (
    tester,
  ) async {
    // autoReply: false：请求挂住 → 能稳定断言「生成中」这一帧
    final model = SummaryModel(autoReply: false);
    final h = await pumpShell(tester, model: model);
    await startWeekSummary(tester);
    await tapGenerate(tester);

    // 立即切到总结页生成态：进度条 + 已生成/预计还需 + 步骤
    expect(find.byKey(const Key('gen-bar')), findsOneWidget);
    expect(find.byKey(const Key('gen-elapsed')), findsOneWidget);
    expect(find.byKey(const Key('gen-eta')), findsOneWidget);
    expect(find.byKey(const Key('gen-step')), findsOneWidget);
    expect(h.store.stackTop?.type, 'sum');
    // 步骤文案来自生成器的真实阶段推进（请求已发出 → 已到「提炼要点」）
    expect(
      tester.widget<Text>(find.byKey(const Key('gen-step'))).data,
      anyOf('解析来源内容…', '提炼要点与逻辑…'),
    );
    // 计时是真实墙钟（Stopwatch）：让真实时间走 1.1 秒，「已生成 N 秒」才会增长
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    // 生成中的 500ms 展示计时器会 notifyListeners → 让文案按新的秒数重建
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester.widget<Text>(find.byKey(const Key('gen-elapsed'))).data,
      matches(RegExp(r'已生成 [1-9]\d* 秒')),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('gen-eta'))).data,
      contains('预计还需'),
    );

    // 模型返回 → 结果就地填充
    await finishGeneration(tester, model);
    expect(find.byKey(const Key('gen-bar')), findsNothing);
    expect(find.text('项目排期与客户反馈'), findsOneWidget);
    final sub = tester.widget<Text>(find.byKey(const Key('sum-sub'))).data!;
    expect(sub.contains('条记录'), isTrue);
    expect(sub.contains('来源'), isFalse);
    // 6 个 Tab 齐备
    for (final k in [
      'stab-all',
      'stab-ov',
      'stab-map',
      'stab-pt',
      'stab-todo',
      'stab-src',
    ]) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    // 「全部」视图五节齐备；不含 Markdown 原文
    for (final k in ['sec-ov', 'sec-map', 'sec-pt', 'sec-todo', 'sec-src']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.textContaining('# 项目排期'), findsNothing);
    // 全部视图信息点默认收起
    expect(find.byKey(const Key('pt-d-0')), findsNothing);
  });

  // verify.cjs 110-141：目录浮钮、Tab 单显、信息点展开 + 溯源
  testWidgets('toc-float / tabs-single / pt-default-open / point-expand / point-trace', (
    tester,
  ) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);
    expect(find.byKey(const Key('toc-btn')), findsOneWidget);

    // 先切「概览」单显（此时 sec-todo 不存在），目录跳转应先切回「全部」
    await tapTab(tester, const Key('stab-ov'));
    expect(find.byKey(const Key('sec-todo')), findsNothing);
    await tester.tap(find.byKey(const Key('toc-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 菜单入场动画
    expect(find.byKey(const Key('toc-item-sec-todo')), findsOneWidget);
    await tester.tap(find.byKey(const Key('toc-item-sec-todo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('sec-todo')), findsOneWidget);
    expect(find.byKey(const Key('sec-ov')), findsOneWidget);

    // Tab 单显
    await tapTab(tester, const Key('stab-ov'));
    expect(find.byKey(const Key('sec-ov')), findsOneWidget);
    expect(find.byKey(const Key('sec-map')), findsNothing);
    await tapTab(tester, const Key('stab-pt'));
    expect(find.byKey(const Key('sec-pt')), findsOneWidget);
    expect(find.byKey(const Key('sec-ov')), findsNothing);

    // 信息点 Tab 默认全部展开（模型返回了 4 条信息点）
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(Key('pt-d-$i')), findsOneWidget, reason: 'pt-$i');
    }
    await tester.tap(find.byKey(const Key('pt-h-0')));
    await tester.pump();
    expect(find.byKey(const Key('pt-d-0')), findsNothing);
    await tester.tap(find.byKey(const Key('pt-h-0')));
    await tester.pump();
    expect(find.byKey(const Key('pt-d-0')), findsOneWidget);

    // 溯源链接 → 详情（来源来自模型返回的真实记录 id）
    await tester.tap(find.byKey(_srcChipE1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('dt-h3')), findsOneWidget);
    expect(find.text('午后项目方向讨论'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('crumb-dest'))).data,
      '总结',
    );
    expect(find.byKey(const Key('pb-detail')), findsNothing); // 窄屏无面板内返回
  });

  // verify.cjs 147-160：被引用总结 tab + 历史扁平化
  testWidgets('refs-tab / detail-backlink / history-flatten', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    // 从信息点溯源进详情（栈：sum → detail）
    await tapTab(tester, const Key('stab-pt'));
    await tester.tap(find.byKey(_srcChipE1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('det-tab-refs')), findsOneWidget);
    expect(find.text('被引用总结 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('det-tab-refs')));
    await tester.pump();
    expect(find.text('项目排期与客户反馈'), findsOneWidget);
    final sumId = h.store.summaries.first.id;
    // 点引用 → 该总结已在栈内 → 扁平化截断回该层（不纵深）
    await tester.tap(find.byKey(Key('ref-$sumId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sum-title')), findsOneWidget);
    expect(h.store.subStack.length, 1, reason: '历史扁平化：栈应只剩 sum 一层');
    expect(
      tester.widget<Text>(find.byKey(const Key('crumb-dest'))).data,
      'Timeline',
    );
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
    expect(disabledOf(tester, const Key('tab-all')), isFalse);
  });

  // verify.cjs 163-183：来源记录闭环 + 导出（真实导出链路，失败要给原因）
  testWidgets('src-tab-loop / export-sheet', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    // 回到时间轴，展开总结卡进入结果
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final sumCard = find.byKey(Key('card-${h.store.summaries.first.id}'));
    await tester.tap(sumCard); // 生成后默认展开 → 先收起
    await tester.pump();
    await tester.tap(sumCard); // 再展开
    await tester.pump();
    expect(find.byKey(const Key('open-sum')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-sum')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tapTab(tester, const Key('stab-src'));
    expect(find.byKey(const Key('sec-src')), findsOneWidget);
    expect(find.byKey(const Key('sec-ov')), findsNothing);
    await tapInScroll(tester, find.byKey(const Key('src-e1')));
    expect(find.byKey(const Key('dt-h3')), findsOneWidget);
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sum-title')), findsOneWidget); // 返回弹栈至总结

    // 导出：5 种格式 → 真实生成文件并调起系统分享
    await tester.tap(find.byKey(const Key('export-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 菜单入场动画
    for (final f in ['完整文档', 'Markdown', 'PDF', '图片', 'Word 文档']) {
      expect(find.byKey(Key('export-item-$f')), findsOneWidget, reason: f);
    }
    await tester.tap(find.byKey(const Key('export-item-PDF')));
    await tester.pump(); // 菜单关场
    // 真实导出要落盘：测试进程没有存储插件，这一步的失败在真实事件循环上才会回来
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 不允许「假成功」文案；失败必须把原因摆到用户面前
    expect(find.textContaining('已调用系统分享'), findsNothing);
    final errorToast = find.byKey(const Key('toast-error'));
    expect(errorToast, findsOneWidget, reason: '导出失败要给明确原因');
    expect(
      tester.widget<Text>(errorToast).data,
      contains('无法定位导出目录'),
      reason: '原因来自真实导出链路的异常文案',
    );
    await tester.pump(const Duration(seconds: 3)); // toast 退场
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
  });

  // 生成失败：结果页给原因 + 重试/放弃，重试成功后原地变结果
  testWidgets('gen-failed / gen-retry / gen-dismiss', (tester) async {
    // 先让模型返回坏 JSON（解析失败），再让它恢复正常
    final model = SummaryModel(content: kNotJson);
    final h = await pumpShell(tester, model: model);
    await startWeekSummary(tester);
    await tapGenerate(tester);
    await finishGeneration(tester, model);

    expect(find.byKey(const Key('gen-failed')), findsOneWidget);
    expect(find.text('总结没能生成'), findsOneWidget);
    expect(find.textContaining('总结结果格式异常'), findsOneWidget);
    expect(find.byKey(const Key('gen-retry')), findsOneWidget);
    expect(find.byKey(const Key('gen-dismiss')), findsOneWidget);
    expect(h.store.summaries.single.state, SummaryState.failed);

    // 重试：同一张卡重新生成，这次模型正常
    model.content = kSummaryJson;
    await tester.tap(find.byKey(const Key('gen-retry')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('gen-failed')), findsNothing);
    expect(find.byKey(const Key('sum-title')), findsOneWidget);
    expect(find.text('项目排期与客户反馈'), findsOneWidget);
    expect(h.store.summaries.single.state, SummaryState.done);
    expect(h.store.summaries.length, 1, reason: '重试复用同一张卡');
  });

  // 失败卡片在时间轴上也要能重试 / 放弃
  testWidgets('sumcard-failed / sumcard-retry / sumcard-dismiss', (tester) async {
    final model = SummaryModel(content: kNotJson);
    final h = await pumpShell(tester, model: model);
    await startWeekSummary(tester);
    await tapGenerate(tester);
    await finishGeneration(tester, model);

    // 回时间轴：失败卡以卡片形态出现，带内联重试/放弃
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final cardId = h.store.summaries.single.id;
    expect(find.byKey(Key('sumcard-$cardId')), findsOneWidget);
    expect(find.byKey(const Key('sumcard-failed')), findsOneWidget);
    expect(find.byKey(const Key('sumcard-retry')), findsOneWidget);
    expect(find.byKey(const Key('sumcard-dismiss')), findsOneWidget);

    // 放弃：卡片从列表里消失
    await tester.tap(find.byKey(const Key('sumcard-dismiss')));
    await tester.pump();
    expect(find.byKey(Key('sumcard-$cardId')), findsNothing);
    expect(h.store.summaries, isEmpty);
  });

  // 详情页失效记录：历史栈里残留的 id 不红屏，给明确空态 + 返回
  testWidgets('detail-missing / detail-missing-back', (tester) async {
    final h = await pumpShell(tester);
    // 模拟「记录已被删除，但导航栈里还留着它的 id」
    h.store.openDetail('e404');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('detail-missing')), findsOneWidget);
    expect(find.text('这条记录已不在本机'), findsOneWidget);
    expect(find.byKey(const Key('dt-h3')), findsNothing);

    await tester.tap(find.byKey(const Key('detail-missing-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.store.subStack, isEmpty);
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
  });

  // verify.cjs 186-194：取消总结，pending 卡移除、Tab 解锁
  testWidgets('cancel-summary', (tester) async {
    final h = await pumpShell(tester);
    final store = h.store;
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    expect(store.events.length, 6);
    expect(find.byKey(const Key('selbox-e1')), findsOneWidget); // 可见卡片进入勾选态
    await tester.tap(find.byKey(const Key('cancel-summary')));
    await tester.pump();
    expect(store.selMode, isFalse);
    expect(
      store.summaries.where((s) => s.state == SummaryState.pending),
      isEmpty,
    );
    expect(find.byKey(const Key('selbox-e1')), findsNothing);
    expect(find.byKey(const Key('rangebar')), findsNothing);
    expect(find.byKey(const Key('sumbar')), findsNothing);
    expect(disabledOf(tester, const Key('tab-all')), isFalse);
    expect(store.filter, FeedFilter.all);
  });

  // verify.cjs 197-201：Setting 开关（新结构：KeyedSubtree → _RCSwitch → AnimatedContainer）
  testWidgets('setting-toggle / setting-list / setting-about / privacy-entry', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();

    expect(find.byKey(const Key('setting-list')), findsOneWidget);
    // 6 个开关锚点仍在
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(Key('sw-$i')), findsOneWidget, reason: 'sw-$i');
    }

    Color trackColor(Key k) {
      final w = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(k),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (w.decoration! as BoxDecoration).color!;
    }

    final before = trackColor(const Key('sw-0'));
    await tester.tap(find.byKey(const Key('sw-0')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(trackColor(const Key('sw-0')), isNot(before));

    // 关于区块与隐私政策入口
    await tester.drag(
      find.byKey(const Key('setting-list')),
      const Offset(0, -400),
    );
    await tester.pump();
    expect(find.byKey(const Key('setting-about')), findsOneWidget);
    expect(find.byKey(const Key('setting-version')), findsOneWidget);
    expect(find.byKey(const Key('privacy-entry')), findsOneWidget);
  });
}
