// 验收脚本缺口补齐 —— prototype/verify.cjs 的 55 个 check 中，
// action-card / filter / row-inline-actions / tabs-sticky / no-overflow
// 此前未在 Flutter 测试名中显式出现。本文件逐项建立等价断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'test_transitions.dart';

Future<(AppStore, DeviceStore)> boot(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  final store = AppStore();
  final device = DeviceStore();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(device.dispose);
  await tester.pumpWidget(
      MaterialApp(theme: testTheme(), home: AppShell(store: store, device: device)));
  await tester.pump();
  return (store, device);
}

/// 生成一次本周总结并停在结果页
Future<void> generateWeekSummary(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('summary-start')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('chip-week')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('generate-summary')));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(seconds: 7));
  await tester.pump();
}

void main() {
  // verify.cjs check: action-card —— 生成期间时间轴 Action Card 同步进度，完成后可进结果
  testWidgets('action-card / generating-progress / done-open', (tester) async {
    final (_, _) = await boot(tester);
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chip-week')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-summary')));
    await tester.pump(const Duration(milliseconds: 400));
    // 生成页 → 返回时间轴，Action Card 应仍在生成态
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('sumcard-generating')), findsOneWidget);
    expect(find.byKey(const Key('sumcard-prog')), findsOneWidget);
    // 6s 完成后就地变 done，出现查看结果入口
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    expect(find.byKey(const Key('sumcard-generating')), findsNothing);
    expect(find.byKey(const Key('sumcard-done')), findsOneWidget);
    expect(find.byKey(const Key('open-sum')), findsOneWidget);
  });

  // verify.cjs check: filter —— 全部 / 记录 / 总结三档筛选
  testWidgets('filter / feed filters by tab', (tester) async {
    final (store, _) = await boot(tester);
    await tester.tap(find.byKey(const Key('tab-event')));
    await tester.pump();
    expect(store.filter, FeedFilter.event);
    expect(find.byKey(const Key('card-e1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab-summary')));
    await tester.pump();
    expect(store.filter, FeedFilter.summary);
    expect(find.byKey(const Key('card-e1')), findsNothing);
    expect(find.text('该筛选下暂无内容。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab-all')));
    await tester.pump();
    expect(store.filter, FeedFilter.all);
    expect(find.byKey(const Key('card-e1')), findsOneWidget);
  });

  // verify.cjs check: row-inline-actions —— 同步 / Wi-Fi / 固件三行行内可点，
  // › 只用于二级页（Wi-Fi / 固件），同步行不出现 ›。
  testWidgets('row-inline-actions / chevrons-only-second-level', (tester) async {
    final (_, device) = await boot(tester);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('wifi-row')), findsOneWidget);
    expect(find.byKey(const Key('fw-update')), findsOneWidget);
    expect(find.byKey(const Key('rowchev-wifi')), findsOneWidget);
    expect(find.byKey(const Key('rowchev-fw')), findsOneWidget);
    expect(find.byKey(const Key('rowchev-sync')), findsNothing);

    await tester.tap(find.byKey(const Key('wifi-row')));
    await tester.pump();
    expect(device.view, DeviceView.wifi);
    await tester.pump(const Duration(milliseconds: 1300)); // 扫描 timer 收敛
    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    expect(device.view, DeviceView.main);

    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    expect(device.view, DeviceView.upg);
    device.closeSheet(); // 停掉弹层时钟，避免测试结束挂 timer
    await tester.pump();
  });

  // verify.cjs check: tabs-sticky —— 滚动结果页时 Tab 栏持续吸顶
  testWidgets('tabs-sticky / pinned while scrolling', (tester) async {
    await boot(tester);
    await generateWeekSummary(tester);
    final before = tester.getTopLeft(find.byKey(const Key('stabs'))).dy;
    await tester.drag(
        find.byKey(const Key('sum-scroll')), const Offset(0, -700));
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const Key('stabs'))).dy;
    expect(after, lessThanOrEqualTo(before));
    expect(after, lessThan(80), reason: '应吸顶在顶栏下方，实际 $after');
    expect(find.byKey(const Key('stabs')), findsOneWidget);
  });

  // verify.cjs check: no-overflow —— 320 宽窄屏下时间轴与结果页不溢出
  testWidgets('no-overflow / 320 width', (tester) async {
    await boot(tester, size: const Size(320, 844));
    expect(tester.takeException(), isNull);
    await generateWeekSummary(tester);
    expect(tester.takeException(), isNull);
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
  });
}
