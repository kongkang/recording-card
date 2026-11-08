// 宽屏双栏验收 —— 对齐 prototype/verify.cjs 277-338 段
// （wide-two-pane / wide-list-stays / wide-crumb-off / pane-back / wide-flatten /
//  fresh-from-list / session-restore）
//
// 数据与生成都走这一轮的真实链路：记录集注入、总结由真实 SummaryGenerator 生成，
// 会话恢复用 exportState/restoreState（对应原型的 sessionStorage）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';

import 'support/harness.dart';

const _wide = Size(900, 1100);

/// 生成一条总结（默认「本周」范围）并回到时间轴。
void main() {
  // verify.cjs 277-302：双栏、左栏常显、固定高度、空态、面包屑停用
  testWidgets('wide-two-pane / wide-list-stays / wide-crumb-off', (tester) async {
    await pumpShell(tester, size: _wide);
    expect(find.byKey(const Key('empty-pane')), findsOneWidget);
    expect(find.byKey(const Key('bottom-nav')), findsOneWidget);
    final hh = tester.getSize(find.byKey(const Key('app-header'))).height;
    expect(hh >= 54 && hh <= 58, isTrue, reason: '宽屏 header ≈56，实际 $hh');
    final nh = tester.getSize(find.byKey(const Key('bottom-nav'))).height;
    expect(nh >= 54 && nh <= 58, isTrue, reason: '宽屏 nav ≈56，实际 $nh');

    // 左栏常显 + 右栏空态
    expect(find.byKey(const Key('tab-all')), findsOneWidget);
    await tester.tap(find.byKey(const Key('card-e1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e1')));
    await tester.pump();
    expect(find.byKey(const Key('dt-h3')), findsOneWidget);
    expect(find.byKey(const Key('card-e1')), findsOneWidget); // 左栏 Timeline 仍在
    expect(find.byKey(const Key('empty-pane')), findsNothing);
    expect(find.byKey(const Key('bottom-nav')), findsOneWidget);

    // 宽屏面包屑停用（恒显标题），栈底时无面板内返回
    expect(find.byKey(const Key('crumb-back')), findsNothing);
    expect(find.byKey(const Key('app-title')), findsOneWidget);
    expect(find.byKey(const Key('pb-detail')), findsNothing);

    // 回根：右栏恢复空态
    await tester.tap(find.byKey(const Key('nav-timeline')));
    await tester.pump();
    expect(find.byKey(const Key('empty-pane')), findsOneWidget);
    expect(find.byKey(const Key('dt-h3')), findsNothing);
  });

  // verify.cjs 303-328：嵌套 → 面板内返回 → 扁平化 → 左栏点击根级重置
  testWidgets('pane-back / wide-flatten / fresh-from-list', (tester) async {
    final h = await pumpShell(tester, size: _wide);
    await generateWeekSummary(tester, h.model);
    expect(find.byKey(const Key('sum-title')), findsOneWidget);
    expect(find.byKey(const Key('pb-sum')), findsNothing); // 栈单层无返回

    // 溯源进详情 → 面板内「返回总结」
    await tapTab(tester, const Key('stab-src'));
    expect(find.byKey(const Key('sec-src')), findsOneWidget);
    await tester.tap(find.byKey(const Key('src-e1')).hitTestable().first);
    await tester.pump();
    expect(find.byKey(const Key('dt-h3')), findsOneWidget);
    final pb = find.byKey(const Key('pb-detail'));
    expect(pb, findsOneWidget);
    expect(find.textContaining('返回总结'), findsOneWidget);
    await tester.tap(pb);
    await tester.pump();
    expect(find.byKey(const Key('sum-title')), findsOneWidget);

    // 再跳详情 → 被引用总结 → 扁平化回总结（不纵深）
    await tapTab(tester, const Key('stab-src'));
    await tester.tap(find.byKey(const Key('src-e1')).hitTestable().first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('det-tab-refs')));
    await tester.pump();
    final sumId = h.store.summaries.first.id;
    await tester.tap(find.byKey(Key('ref-$sumId')));
    await tester.pump();
    expect(find.byKey(const Key('sum-title')), findsOneWidget);
    expect(h.store.subStack.length, 1, reason: '扁平化截断为单层');
    expect(find.byKey(const Key('pb-sum')), findsNothing);

    // 直接点左侧列表（根级新选择）→ 栈重置单层，无「返回记录」
    await tester.tap(find.byKey(const Key('card-e4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e4')));
    await tester.pump();
    expect(find.text('与运维确认发布窗口'), findsWidgets); // 左栏卡片 + 右栏详情同名
    expect(find.byKey(const Key('pb-detail')), findsNothing);
    expect(h.store.subStack.length, 1);
  });

  // verify.cjs 329-338：会话恢复（右栏页面 + 总结卡保留）
  testWidgets('session-restore', (tester) async {
    final h = await pumpShell(tester, size: _wide);

    // 生成两张总结（卡片 id 用毫秒时间戳，两次之间让真实时间走一点确保不同）
    for (var i = 0; i < 2; i++) {
      await generateWeekSummary(tester, h.model);
      expect(h.store.summaries.first.state, SummaryState.done);
      await tester.tap(find.byKey(const Key('nav-timeline')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3)),
      );
    }
    expect(
      h.store.summaries.map((s) => s.id).toSet().length,
      2,
      reason: '两张卡必须是不同 id',
    );

    // 选中 e4 进详情
    await tester.tap(find.byKey(const Key('card-e4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e4')));
    await tester.pump();
    expect(find.text('与运维确认发布窗口'), findsWidgets);

    // 导出会话 → 新 store 恢复 → 重建外壳（同标签页刷新等价）
    final exported = h.store.exportState();
    final restored = AppStore(events: seedEvents, loadPersistedState: false)
      ..restoreState(exported);
    await pumpShell(tester, size: _wide, store: restored);

    // 右栏恢复到详情页，栈单层无面板返回
    expect(find.text('与运维确认发布窗口'), findsWidgets);
    expect(find.byKey(const Key('pb-detail')), findsNothing);

    await tester.tap(find.byKey(const Key('nav-timeline')));
    await tester.pump();
    expect(find.byKey(const Key('empty-pane')), findsOneWidget);

    // 已生成总结卡保留 2 张
    final doneCards = restored.summaries
        .where((s) => s.state == SummaryState.done)
        .toList();
    expect(doneCards.length, 2);
    for (final s in doneCards) {
      expect(find.byKey(Key('card-${s.id}')), findsOneWidget);
    }
  });
}
