// 录音卡状态弹层验收 —— 对齐 prototype/verify.cjs 196-273 段
// （device-sheet / sheet-single-rows / battery-row / rec-clock-tick / clock-stable /
//  rel-sync / sync-now / sync-cooldown / two-stage-fw / fw-lock / wifi-setup / wifi-count）
//
// 这一轮弹层里的每个值都来自设备真实回报（CardGateway）：电量来自快照、
// 时钟从 0 开始按秒跳、同步真的下发 sync.start 并轮询状态、Wi-Fi 真的下发 ssid/密码、
// 固件两阶段走 ota.main / ota.wifi 流。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/status_sheet.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

/// 弹层内容可滚动：拖 sheet 卡片直到目标可命中再点。
Future<void> tapInSheet(WidgetTester tester, Finder target) async {
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < 15) {
    await tester.drag(
      find.byKey(const Key('sheet-card')),
      const Offset(0, -250),
    );
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
}

/// 起一个「已连接录音卡」的外壳，并打开状态弹层。
Future<ShellHarness> bootConnected(
  WidgetTester tester, {
  FakeCardGateway? gateway,
}) async {
  final g = gateway ?? FakeCardGateway(initialSnapshot: defaultSnapshot);
  final device = DeviceStore(gateway: g);
  final h = await pumpShell(tester, device: device);
  await tester.tap(find.byKey(const Key('hw-capsule')));
  await tester.pump();
  await tester.pump();
  return h;
}

void main() {
  // verify.cjs 202-220：弹层主页 5 行、录音时钟跳动且定宽、电量行、Wi-Fi 计数
  testWidgets(
    'device-sheet / sheet-single-rows / battery-row / rec-clock-tick / clock-stable / rel-sync',
    (tester) async {
      final gateway = FakeCardGateway(
        initialSnapshot: defaultSnapshot,
        wifiCredentials: const [CardWifiCredential(ssid: 'HomeWiFi')],
      );
      await bootConnected(tester, gateway: gateway);

      expect(find.byKey(const Key('sheet')), findsOneWidget);
      expect(find.byKey(const Key('dev-main')), findsOneWidget);
      // 行内容：已连接 / 可录至 / 电量高（来自设备快照）
      expect(find.textContaining('已连接'), findsWidgets);
      expect(find.textContaining('可录至'), findsOneWidget);
      expect(find.textContaining('电量高'), findsOneWidget);
      // 可点行：同步 / 固件；Wi-Fi 行按 2026-11-10 决策整行隐藏（能力未就绪）
      expect(find.byKey(const Key('sync-now')), findsOneWidget);
      expect(find.byKey(const Key('fw-update')), findsOneWidget);
      expect(
        find.byKey(const Key('wifi-row')),
        findsNothing,
        reason: 'Wi-Fi 能力未就绪，整行不应出现',
      );
      // 未同步过：如实说「尚未同步」，不假装刚刚同步
      expect(
        tester.widget<Text>(find.byKey(const Key('sync-txt'))).data,
        '自动同步 · 尚未同步',
      );
      // 打开弹层时仍预取概要到内存（Wi-Fi 数量来自设备凭据），
      // 但 Wi-Fi 行已隐藏，界面上不再显示「已配置 · N 个网络」。
      await tester.pump();
      expect(
        find.textContaining('已配置 · 1 个网络'),
        findsNothing,
        reason: 'Wi-Fi 行隐藏后不应出现在弹层里',
      );
      expect(gateway.snapshotCalls, greaterThan(0));
      expect(
        tester.widget<Text>(find.byKey(const Key('fw-val'))).data,
        '已是最新',
        reason: '服务器 versionCode 不比设备新时不能说有更新',
      );

      // 录音时钟：格式 h:mm:ss，从 0 起跳且宽度不变（定宽防抖动）
      final clock = find.byKey(const Key('rec-clock'));
      final t0 = tester.widget<Text>(clock).data!;
      final w0 = tester.getSize(clock).width;
      expect(RegExp(r'^\d+:\d{2}:\d{2}$').hasMatch(t0), isTrue, reason: t0);
      expect(t0, '00:00:00', reason: '时钟从 0 开始，没有预置的 3:12:15');
      await tester.pump(const Duration(milliseconds: 1300));
      final t1 = tester.widget<Text>(clock).data!;
      expect(t1, isNot(t0));
      expect(tester.getSize(clock).width, w0);

      // 电池图标：顶栏胶囊 + 弹层电量行共 2 处
      expect(find.byKey(const Key('batt')), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('sheet-close')));
      await tester.pump();
      expect(find.byKey(const Key('sheet')), findsNothing);
    },
  );

  // verify.cjs 221-230, 244-246：同步三态 + 10 秒冷却（真实 startSync + 轮询）
  testWidgets('sync-now / sync-cooldown', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: defaultSnapshot);
    await bootConnected(tester, gateway: gateway);

    expect(find.byKey(const Key('sync-ico-idle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump();
    expect(find.byKey(const Key('sync-ico-busy')), findsOneWidget);
    expect(find.text('正在同步…'), findsOneWidget);
    expect(gateway.startSyncCalled, isTrue, reason: '必须真的下发同步命令');

    // 假后端的 syncStatus 立即回报 running=false → 一次轮询（500ms）就完成
    await tester.pump(const Duration(milliseconds: 600));
    expect(gateway.syncStatusCalls, greaterThanOrEqualTo(1));
    expect(find.byKey(const Key('sync-ico-done')), findsOneWidget);
    expect(find.text('同步成功 · 刚刚'), findsOneWidget);

    // 冷却期内点击无效
    final callsBefore = gateway.syncStatusCalls;
    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sync-ico-done')), findsOneWidget);
    expect(gateway.syncStatusCalls, callsBefore, reason: '冷却期不该再发同步请求');

    // 冷却结束恢复灰态 sync 图标
    await tester.pump(const Duration(seconds: 11));
    expect(find.byKey(const Key('sync-ico-idle')), findsOneWidget);
    expect(find.textContaining('手动同步'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  // verify.cjs 231-243：固件两阶段更新（真实 ota 流），更新中弹层锁定
  testWidgets('two-stage-fw / fw-lock', (tester) async {
    final gateway = FakeCardGateway(
      // 固件用例与录音无关：录音中不允许进 DFU（startFwUpdate 有守卫），
      // 所以这里用未录音的卡，不能用默认的录音中快照。
      initialSnapshot: const CardSnapshot(
        batteryLevel: 82,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '2.2.0',
        fwVersionCode: 22,
        wifiVersion: '1.5.0',
        wifiVersionCode: 15,
        deviceName: 'DYJV2_TEST',
        deviceId: 'test-device',
      ),
      devices: const [CardDevice(id: 'test-device', name: 'DYJV2_TEST')],
      mainOta: const CardOtaInfo(
        version: '2.3.0',
        versionCode: 23,
        url: 'https://ota.invalid/main.bin',
      ),
      wifiOta: const CardOtaInfo(
        version: '1.6.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
      mainProgress: const [
        CardProgress(stage: 'dfu', percent: 10, text: '正在写入主控固件…'),
        CardProgress(stage: 'dfu', percent: 90, text: '主控写入完成'),
      ],
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 30, text: '正在下载 Wi-Fi 固件…'),
        CardProgress(stage: 'wifi', percent: 100, text: 'Wi-Fi 固件写入完成'),
      ],
      progressDelay: const Duration(milliseconds: 300),
    );
    await bootConnected(tester, gateway: gateway);
    await tester.pump();

    // 主视图就已预检出「有可用更新」（不必先进二级页）
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-val'))).data,
      '有可用更新',
    );

    // 进更新页看版本对比
    await tapInSheet(tester, find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    expect(find.text('主控芯片'), findsOneWidget);
    expect(find.text('Wi-Fi 芯片'), findsOneWidget);
    // 版本对比只在更新页呈现，且来自真实 otaInfo 回报（设备当前版本 → 服务器最新版本）
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-main-ver'))).data,
      '2.2.0 → 2.3.0',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-wifi-ver'))).data,
      '1.5.0 → 1.6.0',
    );

    await tester.tap(find.byKey(const Key('upg-back')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-val'))).data,
      '有可用更新',
      reason: '服务器 versionCode 比设备新才提示更新',
    );

    // 开始更新 → 弹层锁定
    await tapInSheet(tester, find.byKey(const Key('fw-update')));
    await tester.pump();
    await tapInSheet(tester, find.byKey(const Key('upg-btn')));
    await tester.pump();
    expect(find.byKey(const Key('upg-warn')), findsOneWidget);
    expect(disabledOf(tester, const Key('upg-back')), isTrue); // 更新中禁用返回
    // 点弹层外的空白处：更新中不允许关闭
    await tester.tapAt(const Offset(20, 120));
    await tester.pump();
    expect(find.byKey(const Key('sheet')), findsOneWidget);

    // 阶段 1/2：主控（ota.main 流推进度）
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<Text>(find.byKey(const Key('upg-stage'))).data,
      '阶段 1/2 · 主控芯片',
    );
    expect(find.byKey(const Key('upg-bar')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('upg-state'))).data,
      '正在写入主控固件…',
    );

    // 主控写完 → DFU 后必须重连才能刷 Wi-Fi 模组
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester.widget<Text>(find.byKey(const Key('upg-state'))).data,
      '正在重新连接录音卡…',
    );

    // 阶段 2/2：Wi-Fi 模组
    await tester.pump(const Duration(milliseconds: 2000));
    expect(
      tester.widget<Text>(find.byKey(const Key('upg-stage'))).data,
      '阶段 2/2 · Wi-Fi 芯片',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('upg-state'))).data,
      contains('Wi-Fi 固件'),
    );

    // 完成回主页：已是最新 + 状态行
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-val'))).data,
      '已是最新',
      reason: '更新完 ota 信息清空，不再提示有更新',
    );
    expect(find.text('已更新到 主控 2.2.0 / Wi-Fi 1.5.0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  // verify.cjs 248-273：Wi-Fi 配网（已保存置顶/展开/范围外置灰/直连/新网络保存/计数）
  testWidgets('wifi-setup / wifi-count', (tester) async {
    // Wi-Fi 入口按 owner 决策暂时隐藏；入口恢复时这条用例随之生效
    if (!showWifiRow) return;
    final gateway = FakeCardGateway(
      initialSnapshot: defaultSnapshot,
      wifiCredentials: const [
        CardWifiCredential(ssid: 'HomeWiFi'),
        CardWifiCredential(ssid: 'Studio-2.4G'),
        CardWifiCredential(ssid: 'Bedroom-2.4G'),
        CardWifiCredential(ssid: 'Old-2.4G'),
      ],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'HomeWiFi', rssi: -48, secured: true),
        CardWifiNetwork(ssid: 'Office-2.4G', rssi: -60, secured: true),
        CardWifiNetwork(ssid: 'Cafe_Guest', rssi: -80, secured: false),
      ],
      // 让「正在连接…」「正在验证连接可行性…」这两帧可以被断言
      wifiConnectDelay: const Duration(milliseconds: 300),
    );
    await bootConnected(tester, gateway: gateway);

    await tapInSheet(tester, find.byKey(const Key('wifi-row')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-wifi')), findsOneWidget);

    // 已保存默认前 3 + 「查看更多已保存（1）」
    expect(find.byKey(const Key('wsaved-HomeWiFi')), findsOneWidget);
    expect(find.byKey(const Key('wsaved-Studio-2.4G')), findsOneWidget);
    expect(find.byKey(const Key('wsaved-Bedroom-2.4G')), findsOneWidget);
    expect(find.byKey(const Key('wsaved-Old-2.4G')), findsNothing);
    expect(find.text('查看更多已保存（1）'), findsOneWidget);

    // 扫描完成：网络列表来自设备回报
    expect(find.text('扫描完成 · 附近可见 3 个 2.4GHz 网络'), findsOneWidget);
    // 范围外的保存网络置灰（Studio / Bedroom 不在扫描范围）
    expect(find.text('不在范围内'), findsNWidgets(2));
    expect(find.byKey(const Key('witem-HomeWiFi')), findsOneWidget);
    expect(find.byKey(const Key('witem-Office-2.4G')), findsOneWidget);
    expect(find.byKey(const Key('witem-Cafe_Guest')), findsOneWidget);
    expect(find.textContaining('仅支持 2.4GHz'), findsOneWidget);

    // 展开更多已保存
    await tester.tap(find.byKey(const Key('wmore')));
    await tester.pump();
    expect(find.byKey(const Key('wsaved-Old-2.4G')), findsOneWidget);

    // 直连已保存且在范围内的网络：不下发密码（固件自己管凭据）
    await tester.tap(find.byKey(const Key('wsaved-HomeWiFi')));
    await tester.pump();
    expect(find.text('正在连接…'), findsWidgets); // 已保存区 + 可用网络区各一处
    expect(gateway.lastWifiSsid, 'HomeWiFi');
    expect(gateway.lastWifiPassword, '');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('HomeWiFi 连接成功'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);

    // 新网络：输入密码 → 保存 → 连接并计数
    await tester.tap(find.byKey(const Key('witem-Office-2.4G')));
    await tester.pump();
    expect(find.byKey(const Key('wform-Office-2.4G')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('wifi-pwd')), 'demo-password');
    await tapInSheet(tester, find.byKey(const Key('wifi-connect')));
    expect(find.text('正在验证连接可行性…'), findsOneWidget);
    // 真的把 ssid + 密码下发到设备
    expect(gateway.lastWifiSsid, 'Office-2.4G');
    expect(gateway.lastWifiPassword, 'demo-password');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 返回主页：计数刷新为 5（设备把新网络存进了凭据表）
    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.textContaining('5 个网络'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    expect(find.byKey(const Key('sheet')), findsNothing);
  });

  // 空密码在本地就拦下，不下发到设备
  testWidgets('wifi-empty-password', (tester) async {
    if (!showWifiRow) return;
    final gateway = FakeCardGateway(
      initialSnapshot: defaultSnapshot,
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'Office-2.4G', rssi: -60, secured: true),
      ],
    );
    final h = await bootConnected(tester, gateway: gateway);
    await tapInSheet(tester, find.byKey(const Key('wifi-row')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('witem-Office-2.4G')));
    await tester.pump();
    await tapInSheet(tester, find.byKey(const Key('wifi-connect')));
    await tester.pump();

    expect(gateway.lastWifiSsid, isNull, reason: '空密码不该发到设备');
    expect(h.device.wifiError, '请输入网络密码');
    expect(h.device.wifiJoining, isFalse);

    // 收尾：关弹层（录音时钟定时器只在弹层打开时跑）
    h.device.closeSheet();
    await tester.pump();
  });
}
