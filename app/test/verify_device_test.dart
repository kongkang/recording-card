// 录音卡状态弹层验收 —— 对齐 prototype/verify.cjs 196-273 段
// （device-sheet / sheet-single-rows / battery-row / rec-clock-tick / clock-stable /
//  rel-sync / sync-now / sync-cooldown / two-stage-fw / fw-lock / wifi-setup / wifi-count）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'test_transitions.dart';

Future<DeviceStore> boot(WidgetTester tester) async {
  final store = AppStore();
  final device = DeviceStore();
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(device.dispose);
  await tester.pumpWidget(MaterialApp(theme: testTheme(), home: AppShell(store: store, device: device)));
  await tester.pump();
  return device;
}

/// 弹层内容可滚动：拖 sheet 卡片直到目标可命中再点
Future<void> tapInSheet(WidgetTester tester, Finder target) async {
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < 15) {
    await tester.drag(find.byKey(const Key('sheet-card')), const Offset(0, -250));
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
}

void main() {
  // verify.cjs 202-220：弹层主页 5 行、录音时钟跳动且定宽、电量行、Wi-Fi 计数
  testWidgets('device-sheet / sheet-single-rows / battery-row / rec-clock-tick / clock-stable / rel-sync / wifi-count', (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    expect(find.byKey(const Key('sheet')), findsOneWidget);
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    // 行内容：已连接 / 可录至 / 电量高
    expect(find.textContaining('已连接'), findsWidgets);
    expect(find.textContaining('可录至'), findsOneWidget);
    expect(find.textContaining('电量高'), findsOneWidget);
    // 三个可点行
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('wifi-row')), findsOneWidget);
    expect(find.textContaining('已配置 · 2 个网络'), findsOneWidget);
    expect(find.byKey(const Key('fw-update')), findsOneWidget);
    // 录音时钟：格式 h:mm:ss，1.3s 后跳动且宽度不变（定宽防抖动）
    final clock = find.byKey(const Key('rec-clock'));
    final t0 = tester.widget<Text>(clock).data!;
    final w0 = tester.getSize(clock).width;
    expect(RegExp(r'^\d+:\d{2}:\d{2}$').hasMatch(t0), isTrue, reason: t0);
    await tester.pump(const Duration(milliseconds: 1300));
    final t1 = tester.widget<Text>(clock).data!;
    expect(t1, isNot(t0));
    expect(tester.getSize(clock).width, w0);
    // 相对时间阶梯文案（同步行整体文案）
    expect(RegExp(r'刚刚|秒前|分钟前')
        .hasMatch(tester.widget<Text>(find.byKey(const Key('sync-txt'))).data ?? ''), isTrue);
    // 电池图标：顶栏胶囊 + 弹层电量行共 2 处
    expect(find.byKey(const Key('batt')), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    expect(find.byKey(const Key('sheet')), findsNothing);
  });

  // verify.cjs 221-230, 244-246：同步三态 + 10 秒冷却
  testWidgets('sync-now / sync-cooldown', (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    expect(find.byKey(const Key('sync-ico-idle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump();
    expect(find.byKey(const Key('sync-ico-busy')), findsOneWidget);
    expect(find.text('正在同步…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byKey(const Key('sync-ico-done')), findsOneWidget);
    expect(find.text('同步成功 · 刚刚'), findsOneWidget);
    // 冷却期内点击无效
    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sync-ico-done')), findsOneWidget);
    // 冷却结束恢复灰态 sync 图标
    await tester.pump(const Duration(seconds: 11));
    expect(find.byKey(const Key('sync-ico-idle')), findsOneWidget);
    expect(find.textContaining('最近同步'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  // verify.cjs 231-243：固件两阶段更新，更新中弹层锁定
  testWidgets('two-stage-fw / fw-lock', (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    expect(find.text('主控芯片'), findsOneWidget);
    expect(find.text('2.1.0 → 2.2.0'), findsOneWidget);
    expect(find.text('1.4.2 → 1.5.0'), findsOneWidget);
    await tapInSheet(tester, find.byKey(const Key('upg-btn')));
    expect(find.byKey(const Key('upg-warn')), findsOneWidget);
    expect(disabledOf(tester, const Key('upg-back')), isTrue); // 更新中禁用返回
    // 点空白处弹层不关闭
    await tester.tapAt(const Offset(20, 40));
    await tester.pump();
    expect(find.byKey(const Key('sheet')), findsOneWidget);
    // 两阶段进度
    await tester.pump(const Duration(milliseconds: 1350));
    expect(tester.widget<Text>(find.byKey(const Key('upg-stage'))).data, '阶段 1/2 · 主控芯片');
    await tester.pump(const Duration(seconds: 2));
    expect(tester.widget<Text>(find.byKey(const Key('upg-stage'))).data, '阶段 2/2 · Wi-Fi 芯片');
    await tester.pump(const Duration(seconds: 5));
    // 完成回主页：已是最新 + 状态行
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.text('已是最新'), findsOneWidget);
    expect(find.text('已更新到 主控 2.2.0 / Wi-Fi 1.5.0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  // verify.cjs 248-273：Wi-Fi 配网（已保存置顶/展开/范围外置灰/直连/新网络保存/计数）
  testWidgets('wifi-setup / wifi-count', (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wifi-row')));
    await tester.pump();
    expect(find.byKey(const Key('dev-wifi')), findsOneWidget);
    // 已保存默认前 3 + 「查看更多已保存（1）」
    expect(find.byKey(const Key('wsaved-HomeWiFi')), findsOneWidget);
    expect(find.byKey(const Key('wsaved-Studio-2.4G')), findsOneWidget);
    expect(find.byKey(const Key('wsaved-Bedroom-2.4G')), findsOneWidget);
    expect(find.byKey(const Key('wsaved-Old-2.4G')), findsNothing);
    expect(find.text('查看更多已保存（1）'), findsOneWidget);
    // 扫描：进行中 → 完成
    expect(find.textContaining('正在扫描'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('扫描完成 · 附近可见 3 个 2.4GHz 网络'), findsOneWidget);
    // 范围外的保存网络置灰（Studio / Bedroom 不在扫描范围）
    expect(find.text('不在范围内'), findsNWidgets(2));
    // 可用网络 3 个 + 仅 2.4GHz 说明
    expect(find.byKey(const Key('witem-HomeWiFi')), findsOneWidget);
    expect(find.byKey(const Key('witem-Office-2.4G')), findsOneWidget);
    expect(find.byKey(const Key('witem-Cafe_Guest')), findsOneWidget);
    expect(find.textContaining('仅支持 2.4GHz'), findsOneWidget);
    // 展开更多已保存
    await tester.tap(find.byKey(const Key('wmore')));
    await tester.pump();
    expect(find.byKey(const Key('wsaved-Old-2.4G')), findsOneWidget);
    // 直连已保存且在范围内的网络
    await tester.tap(find.byKey(const Key('wsaved-HomeWiFi')));
    await tester.pump();
    expect(find.text('正在连接…'), findsWidgets); // 已保存区 + 可用网络区各一处
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('HomeWiFi 连接成功'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    // 新网络：输入密码 → 保存 → 连接并计数
    await tester.tap(find.byKey(const Key('witem-Office-2.4G')));
    await tester.pump();
    expect(find.byKey(const Key('wform-Office-2.4G')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('wifi-pwd')), 'demo-password');
    await tapInSheet(tester, find.byKey(const Key('wifi-connect')));
    expect(find.text('正在验证连接可行性…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Office-2.4G 连接成功'), findsOneWidget);
    // 返回主页：计数刷新为 5
    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.textContaining('5 个网络'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    expect(find.byKey(const Key('sheet')), findsNothing);
  });
}

bool disabledOf(WidgetTester tester, Key key) {
  final w = tester.widget<Widget>(find.byKey(key));
  return switch (w) {
    FilledButton b => b.onPressed == null,
    OutlinedButton b => b.onPressed == null,
    TextButton b => b.onPressed == null,
    _ => false,
  };
}
