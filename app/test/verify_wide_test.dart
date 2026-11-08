// 宽屏双栏验收 —— 对齐 prototype/verify.cjs 277-338 段
// （wide-two-pane / wide-list-stays / wide-crumb-off / pane-back / wide-flatten /
//  fresh-from-list / session-restore）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'test_transitions.dart';

Future<AppStore> boot(WidgetTester tester) async {
  final store = AppStore();
  final device = DeviceStore();
  tester.view.physicalSize = const Size(900, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(device.dispose);
  await tester.pumpWidget(MaterialApp(theme: testTheme(), home: AppShell(store: store, device: device)));
  await tester.pump();
  return store;
}

Future<void> tapTab(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < 10) {
    await tester.drag(find.byKey(const Key('stab-strip')), const Offset(-120, 0));
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  // verify.cjs 277-302：双栏、左栏常显、固定高度、空态、面包屑停用
  testWidgets('wide-two-pane / wide-list-stays / wide-crumb-off', (tester) async {
    await boot(tester);
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
    final store = await boot(tester);
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chip-week')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-summary')));
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
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
    final sumId = store.summaries.first.id;
    await tester.tap(find.byKey(Key('ref-$sumId')));
    await tester.pump();
    expect(find.byKey(const Key('sum-title')), findsOneWidget);
    expect(store.subStack.length, 1, reason: '扁平化截断为单层');
    expect(find.byKey(const Key('pb-sum')), findsNothing);
    // 直接点左侧列表（根级新选择）→ 栈重置单层，无「返回记录」
    await tester.tap(find.byKey(const Key('card-e4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e4')));
    await tester.pump();
    expect(find.text('与运维确认发布窗口'), findsWidgets); // 左栏卡片 + 右栏详情同名

    expect(find.byKey(const Key('pb-detail')), findsNothing);
    expect(store.subStack.length, 1);
  });

  // verify.cjs 329-338：会话恢复（右栏页面 + 总结卡保留）
  testWidgets('session-restore', (tester) async {
    final store = await boot(tester);
    // 生成两张总结
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('summary-start')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chip-week')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('generate-summary')));
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-timeline')));
      await tester.pump();
    }
    // 选中 e4 进详情
    await tester.tap(find.byKey(const Key('card-e4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e4')));
    await tester.pump();
    expect(find.text('与运维确认发布窗口'), findsWidgets); // 左栏卡片 + 右栏详情同名

    // 导出会话 → 新 store 恢复 → 重建外壳（同标签页刷新等价）
    final exported = store.exportState();
    final store2 = AppStore()..restoreState(exported);
    final device2 = DeviceStore();
    addTearDown(device2.dispose);
    await tester.pumpWidget(MaterialApp(theme: testTheme(), home: AppShell(store: store2, device: device2)));
    await tester.pump();
    // 右栏恢复到详情页，栈单层无面板返回
    expect(find.text('与运维确认发布窗口'), findsWidgets); // 左栏卡片 + 右栏详情同名

    expect(find.byKey(const Key('pb-detail')), findsNothing);
    await tester.tap(find.byKey(const Key('nav-timeline')));
    await tester.pump();
    expect(find.byKey(const Key('empty-pane')), findsOneWidget);
    // 已生成总结卡保留 2 张
    final doneCards = store2.summaries.where((s) => s.state.name == 'done');
    expect(doneCards.length, 2);
    for (final s in doneCards) {
      expect(find.byKey(Key('card-${s.id}')), findsOneWidget);
    }
  });
}
