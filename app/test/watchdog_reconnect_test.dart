// 连接的看门狗与自动重连验收（owner 2026-11-10 定稿）。
//
// 规则：
// 1. 未连接：胶囊灰点 + 「无设备」（电量位置改文字，不出电池图标）；
// 2. 每 30 秒空闲才探一次；这 30 秒内有任何蓝牙传输就顺延；
// 3. 探不通一次即判掉线 → 胶囊蓝点「连接中…」→ 直连上次设备（不扫描）只试一次；
// 4. 重连成功回绿/橙，失败回灰「无设备」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/tokens.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _card = CardDevice(id: 'dev-1', name: 'DYJV2_TEST', rssi: -50);

CardSnapshot _snap({bool recording = false}) => CardSnapshot(
  batteryLevel: 82,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_TEST',
  deviceId: 'dev-1',
);

Color? _dotColor(WidgetTester tester) {
  final f = find.byKey(const Key('capsule-dot'));
  if (f.evaluate().isEmpty) return null;
  return (tester.widget<Container>(f).decoration as BoxDecoration?)?.color;
}

/// 起一个「已连上」的 store：autoStart 打开才能跑到看门狗。
Future<DeviceStore> _connectedStore(WidgetTester tester, FakeCardGateway gw) async {
  final store = DeviceStore(gateway: gw, autoStart: true);
  await store.restoreLink();
  await store.connectTo(_card);
  // 等连接后的收尾（时间同步 + 刷新）跑完，测试才面对"稳定已连接"状态
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return store;
}

void main() {
  testWidgets('未连接：灰点 + 「无设备」，不出电池图标', (tester) async {
    final device = DeviceStore(gateway: FakeCardGateway());
    await pumpShell(tester, device: device);

    expect(find.byKey(const Key('capsule-off')), findsOneWidget, reason: '灰空心点');
    expect(find.text('无设备'), findsOneWidget);
    expect(find.byKey(const Key('batt')), findsNothing, reason: '没设备不画电池');
    expect(_dotColor(tester), isNull);
  });

  testWidgets('30 秒内有过蓝牙传输：看门狗顺延，不额外探测', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _snap(),
      devices: const [_card],
    );
    final store = await _connectedStore(tester, gw);

    // 纯空闲 35 秒：看门狗应当自己探一次
    await tester.pump(const Duration(seconds: 35));
    final afterIdle = gw.snapshotCalls;
    expect(afterIdle, greaterThan(0));

    // 中途做一次真实命令（算活动）：之后 20 秒内不该再探
    await tester.pump(const Duration(seconds: 20));
    await store.refreshFromDevice();
    final afterCommand = gw.snapshotCalls;
    await tester.pump(const Duration(seconds: 20));
    expect(
      gw.snapshotCalls,
      afterCommand,
      reason: '刚有传输，30 秒期限顺延，不该再探',
    );

    // 再走满 30 秒空闲 → 看门狗应重新探一次
    await tester.pump(const Duration(seconds: 15));
    expect(gw.snapshotCalls, greaterThan(afterCommand), reason: '空闲满 30 秒要探');

    store.dispose();
  });

  testWidgets('探不通一次即自动重连，直连成功回已连接', (tester) async {
    final gw = FakeCardGateway(initialSnapshot: _snap(), devices: const [_card]);
    final store = await _connectedStore(tester, gw);
    final scanBefore = gw.scanCalls;

    // 到 30 秒那一次探测时设备才失联；之后恢复可读 → 重连应成功
    for (var s = 0; s < 30; s += 5) {
      gw.failSnapshot = s >= 25 ? CardException.disconnected() : null;
      await tester.pump(const Duration(seconds: 5));
    }
    expect(store.linkState, LinkState.reconnecting);

    // 重连成功后快照恢复正常
    gw.failSnapshot = null;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(store.linkState, LinkState.connected, reason: '重连成功后应回到已连接');
    expect(gw.connectCalls, 2, reason: '首次连接 + 看门狗重连各一次');
    expect(gw.disconnectCalls, 1, reason: '判定掉线先真的释放旧链路');
    expect(gw.disconnectCallsAtConnect, [0, 1],
        reason: '重连前必须先 disconnect，不能只改 UI 状态');
    expect(
      gw.scanCalls,
      scanBefore,
      reason: '重连必须直连上次设备，不能靠扫描（已连接设备不广播）',
    );

    // 重连成功后看门狗要重新值班：再空闲 30 秒应继续探测
    final snapshotsAfterReconnect = gw.snapshotCalls;
    await tester.pump(const Duration(seconds: 35));
    expect(
      gw.snapshotCalls,
      greaterThan(snapshotsAfterReconnect),
      reason: '重连成功后必须重启心跳，不能从此没人探测',
    );

    store.dispose();
  });

  testWidgets('重连中显示蓝点「连接中…」，重连失败回灰点「无设备」', (tester) async {
    final gw = FakeCardGateway(initialSnapshot: _snap(), devices: const [_card]);
    final device = await _connectedStore(tester, gw);
    await pumpShell(tester, device: device);
    expect(find.text('无设备'), findsNothing);

    // 掉线 + 重连也失败
    gw.failSnapshot = CardException.disconnected();
    gw.failConnect = CardException.disconnected();
    // 看门狗在空闲满 30 秒后的那次节拍触发；分步推进才能抓到蓝点那一帧
    for (var s = 0; s < 30; s += 5) {
      await tester.pump(const Duration(seconds: 5));
    }
    expect(device.linkState, LinkState.reconnecting);
    expect(_dotColor(tester), RCColors.info, reason: '重连中是蓝点');
    expect(find.text('连接中…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(device.linkState, LinkState.disconnected, reason: '只重试一次');
    expect(find.text('无设备'), findsOneWidget);
    expect(find.byKey(const Key('capsule-off')), findsOneWidget);
    expect(gw.connectCalls, 2, reason: '一次成功连接 + 一次失败重连，不再多试');
    expect(gw.disconnectCalls, 2,
        reason: '判定掉线释放一次；重连失败后再清一次半开连接');
  });
}
