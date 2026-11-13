// 设计对照修正的三条回归：事件是列表行 / 目录与 Tab 同点吸附 / 未连接进扫描。
//
// 这一轮补充：总结内容来自真实生成器，未连接设备的扫描/连接走真实网关命令。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/tokens.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

void main() {
  testWidgets('事件是时间轴列表行，只有总结挂卡片底板', (tester) async {
    final h = await pumpShell(tester);
    // 事件条目：内容区不画卡片底板
    final cards = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byKey(const Key('timeline-item-e1')),
            matching: find.byType(Container),
          ),
        )
        .where((c) {
          final d = c.decoration;
          return d is BoxDecoration && d.color == RCColors.card;
        });
    expect(cards, isEmpty, reason: '事件行不该有卡片底板');

    await generateWeekSummary(tester, h.model);
    final sumId = h.store.summaries.first.id;
    h.store.goBack(); // 回到 Timeline 才看得到总结卡本体
    await tester.pump();
    final surface = tester.widget<Container>(find.byKey(Key('sumcard-$sumId')));
    final deco = surface.decoration! as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(12));
    expect(deco.boxShadow, isNull, reason: '设计稿的总结卡没有阴影');
  });

  testWidgets('目录按钮停在概览行右侧，滚动后与 Tab 栏同点吸附', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);
    final tabs0 = tester.getTopLeft(find.byKey(const Key('stabs'))).dy;
    final toc0 = tester.getTopLeft(find.byKey(const Key('toc-btn'))).dy;
    // 静止态：目录在 Tab 栏下方，不压 Tab、不压标题
    expect(toc0, greaterThan(tabs0 + 46), reason: '目录不得遮挡 Tab 栏');

    await tester.drag(
      find.byKey(const Key('sum-scroll')),
      const Offset(0, -400),
    );
    await tester.pump();
    final tabs1 = tester.getTopLeft(find.byKey(const Key('stabs'))).dy;
    final toc1 = tester.getTopLeft(find.byKey(const Key('toc-btn'))).dy;
    expect(tabs1, lessThan(tabs0), reason: 'Tab 栏应已吸顶');
    // 吸附后仍保持「Tab 栏下沿 + 10」这段固定距离
    expect(toc1 - tabs1, closeTo(56, 2));
    expect(toc1, greaterThan(tabs1 + 46), reason: '吸附态也不得压住 Tab');
  });

  testWidgets('未连接时点右上角进入扫描，选中设备后连上并显示真实状态', (tester) async {
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'dev-1', name: 'DYJV2_T4W25T')],
    );
    final device = DeviceStore(gateway: gateway);
    final h = await pumpShell(tester, device: device);

    // 未连接：胶囊只显示灰点
    expect(find.byKey(const Key('capsule-off')), findsOneWidget);
    expect(device.isConnected, isFalse);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-connect')), findsOneWidget);
    expect(gateway.scanCalls, greaterThan(0), reason: '点开即进入扫描流程');
    expect(find.text('T4W25T'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dev-item-dev-1')));
    await tester.pump();
    await tester.pump();

    expect(gateway.connectCalls, 1);
    expect(gateway.lastConnectedId, 'dev-1');
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.byKey(const Key('dev-bt-icon')), findsOneWidget);
    expect(find.byKey(const Key('dev-header-kind')), findsOneWidget);
    expect(find.byKey(const Key('capsule-off')), findsNothing);
    // 状态值来自设备快照（默认 82% → 电量高）
    expect(find.textContaining('电量高'), findsOneWidget);
    expect(h.device.isRecording, isTrue);

    // 收尾：关掉弹层（录音时钟定时器只在弹层打开时跑）
    h.device.closeSheet();
    await tester.pump();
  });
}
