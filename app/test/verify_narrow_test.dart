// 窄屏主线验收 —— 对齐 prototype/verify.cjs（390×844）检查项。
// 命名沿用 verify.cjs 末尾 checks 数组；段落注释标注对应脚本行号。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';

import 'test_transitions.dart';
import 'fixtures/legacy_ui_fixture.dart';

Future<(AppStore, DeviceStore)> boot(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  final store = legacyAppFixture(clock: tester.binding.clock.now);
  final device = legacyDeviceFixture();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(device.dispose);
  addTearDown(store.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      home: AppShell(store: store, device: device),
    ),
  );
  await tester.pump();
  return (store, device);
}

bool disabled(WidgetTester tester, Key key) {
  final w = tester.widget<Widget>(find.byKey(key));
  return switch (w) {
    TextButton b => b.onPressed == null,
    FilledButton b => b.onPressed == null,
    OutlinedButton b => b.onPressed == null,
    _ => false,
  };
}

/// 结果页内容深处的元素：拖动页面滚动区直到可命中再点
Future<void> tapInPage(WidgetTester tester, Finder target) async {
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < 20) {
    // 目标在视口上方→下滚，在下方→上滚
    final c = tester.getCenter(target, warnIfMissed: false);
    await tester.drag(
      find.byKey(const Key('sum-scroll')),
      Offset(0, c.dy < 400 ? 300 : -300),
    );
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
}

/// 横向 Tab 栏可能滚动裁剪：拖到可命中再点（吸顶 sliver 重建需补一帧）
Future<void> tapTab(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < 10) {
    await tester.drag(
      find.byKey(const Key('stab-strip')),
      const Offset(-120, 0),
    );
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  // verify.cjs 33-44：固定高度顶栏、底栏、tab 文案、根页 crumb 隐藏、无模拟标注、电池胶囊仅图标
  testWidgets(
    'fixed-chrome / crumb-root-hidden / battery-capsule / no-sim-labels',
    (tester) async {
      await boot(tester);
      expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
      expect(find.byKey(const Key('nav-setting')), findsOneWidget);
      // 设计稿首页有 .tl-head 大标题 + 底栏同一文案，故为两处
      expect(find.byKey(const Key('timeline-title')), findsOneWidget);
      expect(find.text('Timeline'), findsNWidgets(2));
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
      // 胶囊内不得出现数字（电量不显百分比）
      for (final t in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('hw-capsule')),
          matching: find.byType(Text),
        ),
      )) {
        expect(RegExp(r'\d').hasMatch(t.data ?? ''), isFalse);
      }
    },
  );

  // verify.cjs 47-64：卡片展开/收起 → 详情 → 原始数据 → 顶栏返回
  testWidgets(
    'two-line-card / expand-collapse / detail-entry / subpage-hides-nav / detail-tabs-raw',
    (tester) async {
      await boot(tester);
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
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.text('午后项目方向讨论'), findsOneWidget);
      expect(find.byKey(const Key('nav-timeline')), findsNothing); // 子页隐藏底栏
      expect(find.byKey(const Key('crumb-back')), findsOneWidget);
      expect(find.byKey(const Key('crumb-dest')), findsOneWidget);
      expect(find.text('Timeline'), findsOneWidget);
      expect(
        find.byKey(const Key('det-tab-refs')),
        findsNothing,
      ); // 无引用时隐藏第三 tab
      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pump();
      expect(find.textContaining('啊不对'), findsOneWidget); // 原始数据保留语气词
      await tester.tap(find.byKey(const Key('det-tab-dlg')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(const Key('nav-timeline')), findsOneWidget); // 返回后底栏恢复
    },
  );

  // verify.cjs 67-87：勾选模式锁定 Tab + 范围全选 + 底部操作栏两行
  testWidgets(
    'select-mode / tabs-lock-on-summary / range-* / tap-toggle / sumbar-rows',
    (tester) async {
      final (store, _) = await boot(tester);
      await tester.tap(find.byKey(const Key('summary-start')));
      await tester.pump();
      expect(disabled(tester, const Key('tab-all')), isTrue);
      expect(disabled(tester, const Key('tab-summary')), isTrue);
      expect(disabled(tester, const Key('tab-event')), isFalse);
      expect(store.filter, FeedFilter.event);
      expect(store.events.length, 6); // 6 条记录进入勾选模式
      expect(store.selIds, isEmpty);
      expect(find.byKey(const Key('rangebar')), findsOneWidget);
      expect(find.byKey(const Key('sumbar')), findsOneWidget);
      int count() => store.selCount; // UI 计数行同步断言
      await tester.tap(find.byKey(const Key('chip-today')));
      await tester.pump();
      expect(count(), 3, reason: '今日 = e1 e2 e3');
      expect(find.text('已选 3 项'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chip-week')));
      await tester.pump();
      expect(count(), 5, reason: '本周 = 今日 3 + 昨天 + 本周一');
      await tester.tap(find.byKey(const Key('chip-month')));
      await tester.pump();
      expect(count(), 6);
      await tester.tap(find.byKey(const Key('chip-none')));
      await tester.pump();
      expect(count(), 0);
      await tester.tap(find.byKey(const Key('chip-week')));
      await tester.pump();
      expect(count(), 5);
      expect(find.text('已选 5 项'), findsOneWidget);
      expect(find.text('生成总结'), findsOneWidget);
      expect(disabled(tester, const Key('generate-summary')), isFalse);
      // 手动点选切换（卡片可见区）
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      expect(count(), 4);
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      expect(count(), 5);
    },
  );

  // verify.cjs 90-107：生成 → 进度/秒数/步骤 → 完成就地填充结果
  testWidgets(
    'gen-status-view / generate-progress / sum-tabs / default-all-view',
    (tester) async {
      final (store, _) = await boot(tester);
      await tester.tap(find.byKey(const Key('summary-start')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chip-week')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('generate-summary')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      // 立即切到总结页生成态
      expect(find.byKey(const Key('gen-elapsed')), findsOneWidget);
      expect(find.byKey(const Key('gen-eta')), findsOneWidget);
      expect(find.byKey(const Key('gen-step')), findsOneWidget);
      expect(store.stackTop?.type, 'sum');
      await tester.pump(const Duration(milliseconds: 1350));
      expect(
        tester.widget<Text>(find.byKey(const Key('gen-elapsed'))).data,
        matches(RegExp(r'已生成 [1-9]\d* 秒')),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('gen-eta'))).data,
        contains('预计时长未知'),
      );
      // 6s 完成后结果就地填充
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      expect(find.text('项目排期与客户反馈'), findsOneWidget);
      final sub = tester.widget<Text>(find.byKey(const Key('sum-sub'))).data!;
      expect(sub.contains('条记录'), isTrue);
      expect(sub.contains('来源'), isFalse);
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
    },
  );

  // verify.cjs 110-141：目录浮钮、Tab 单显、信息点展开 + 溯源
  testWidgets(
    'toc-float / tabs-single / pt-default-open / point-expand / point-trace',
    (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('summary-start')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chip-week')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('generate-summary')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
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
      // 目录点击回到「全部」并定位段落
      expect(find.byKey(const Key('sec-todo')), findsOneWidget);
      expect(find.byKey(const Key('sec-ov')), findsOneWidget);
      // Tab 单显
      await tapTab(tester, const Key('stab-ov'));
      expect(find.byKey(const Key('sec-ov')), findsOneWidget);
      expect(find.byKey(const Key('sec-map')), findsNothing);
      await tapTab(tester, const Key('stab-pt'));
      expect(find.byKey(const Key('sec-pt')), findsOneWidget);
      expect(find.byKey(const Key('sec-ov')), findsNothing);
      // 信息点 Tab 默认全部展开
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(Key('pt-d-$i')), findsOneWidget, reason: 'pt-$i');
      }
      await tester.tap(find.byKey(const Key('pt-h-0')));
      await tester.pump();
      expect(find.byKey(const Key('pt-d-0')), findsNothing);
      await tester.tap(find.byKey(const Key('pt-h-0')));
      await tester.pump();
      expect(find.byKey(const Key('pt-d-0')), findsOneWidget);
      // 溯源链接 → 详情
      await tester.tap(find.byKey(const Key('srcchip-e1-14:20—14:27')));
      await tester.pump();
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.text('午后项目方向讨论'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('crumb-dest'))).data,
        '总结',
      );
      expect(find.byKey(const Key('pb-detail')), findsNothing); // 窄屏无面板内返回
    },
  );

  // verify.cjs 147-160：被引用总结 tab + 历史扁平化
  testWidgets('refs-tab / detail-backlink / history-flatten', (tester) async {
    final (store, _) = await boot(tester);
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chip-week')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-summary')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    // 从信息点溯源进详情（栈：sum → detail）
    await tapTab(tester, const Key('stab-pt'));
    await tester.tap(find.byKey(const Key('srcchip-e1-14:20—14:27')));
    await tester.pump();
    expect(find.byKey(const Key('det-tab-refs')), findsOneWidget);
    expect(find.text('被引用总结 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('det-tab-refs')));
    await tester.pump();
    expect(find.text('项目排期与客户反馈'), findsOneWidget);
    final sumId = store.summaries.first.id;
    // 点引用 → 该总结已在栈内 → 扁平化截断回该层（不纵深）
    await tester.tap(find.byKey(Key('ref-$sumId')));
    await tester.pump();
    expect(find.byKey(const Key('sum-title')), findsOneWidget);
    expect(store.subStack.length, 1, reason: '历史扁平化：栈应只剩 sum 一层');
    expect(
      tester.widget<Text>(find.byKey(const Key('crumb-dest'))).data,
      'Timeline',
    );
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
    expect(disabled(tester, const Key('tab-all')), isFalse);
  });

  // verify.cjs 163-183：来源记录闭环 + 导出
  testWidgets('src-tab-loop / export-sheet', (tester) async {
    final (store, _) = await boot(tester);
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chip-week')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-summary')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    // 回到时间轴，展开总结卡进入结果
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final sumCard = find.byKey(Key('card-${store.summaries.first.id}'));
    await tester.tap(sumCard); // 收起（生成后默认展开）
    await tester.pump();
    await tester.tap(sumCard); // 再展开
    await tester.pump();
    expect(find.byKey(const Key('open-sum')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-sum')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tapTab(tester, const Key('stab-src'));
    expect(find.byKey(const Key('sec-src')), findsOneWidget);
    expect(find.byKey(const Key('sec-ov')), findsNothing);
    await tapInPage(tester, find.byKey(const Key('src-e1')));
    expect(find.byKey(const Key('dt-h3')), findsOneWidget);
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('sum-title')), findsOneWidget); // 返回弹栈至总结
    // 导出：5 种格式 → 调起系统分享
    await tester.tap(find.byKey(const Key('export-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 菜单入场动画
    for (final f in ['完整文档', 'Markdown', 'PDF', '图片', 'Word 文档']) {
      expect(find.byKey(Key('export-item-$f')), findsOneWidget, reason: f);
    }
    await tester.tap(find.byKey(const Key('export-item-PDF')));
    await tester.pump(); // 菜单关场
    await tester.pump(
      const Duration(milliseconds: 300),
    ); // then 回调 → SnackBar 入场
    expect(find.text('已打开系统分享 · PDF'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); // toast 退场，避免悬挂 timer
    expect(find.byKey(const Key('crumb-back')), findsOneWidget);
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
  });

  // verify.cjs 186-194：取消总结，pending 卡移除、Tab 解锁
  testWidgets('cancel-summary', (tester) async {
    final (store, _) = await boot(tester);
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
    expect(disabled(tester, const Key('tab-all')), isFalse);
    expect(store.filter, FeedFilter.all);
  });

  // verify.cjs 197-201：Setting 开关
  testWidgets('setting-toggle', (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();
    final sw = find.byKey(const Key('sw-0'));
    Color color(Key k) {
      final w = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(k),
          matching: find.byType(AnimatedContainer).first,
        ),
      );
      return (w.decoration as BoxDecoration).color!;
    }

    final before = color(const Key('sw-0'));
    await tester.tap(sw);
    await tester.pump(const Duration(milliseconds: 200));
    expect(color(const Key('sw-0')), isNot(before));
  });
}
