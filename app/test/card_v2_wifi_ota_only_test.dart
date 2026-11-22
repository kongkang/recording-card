// 录音卡 V2 Wi-Fi 默认隐藏、仅 Wi-Fi 升级时出现与全路径自动关闭回归测试。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _cardV2Dev = CardDevice(
  id: 'v2-dev',
  name: 'DYJV2_WIFI_TEST',
  rssi: -42,
);

const _dyjV1Dev = CardDevice(
  id: 'v1-dev',
  name: 'DYJ_V1_001',
  rssi: -46,
  kind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

CardSnapshot _v2Snap({
  int fwCode = 22,
  int wifiCode = 15,
  bool wifiOpen = false,
}) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: wifiOpen,
  recording: false,
  fwVersion: '2.$fwCode.0',
  fwVersionCode: fwCode,
  wifiVersion: '1.$wifiCode.0',
  wifiVersionCode: wifiCode,
  deviceName: _cardV2Dev.name,
  deviceId: _cardV2Dev.id,
  deviceKind: DeviceKind.cardV2,
  capabilities: HardwareCapabilities.cardV2,
);

CardSnapshot _v1Snap() => const CardSnapshot(
  batteryLevel: 90,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '0.8.14',
  fwVersionCode: 814,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_V1_001',
  deviceId: 'v1-dev',
  deviceKind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

class _ControlledWifiGateway extends FakeCardGateway {
  _ControlledWifiGateway({
    super.initialSnapshot,
    super.devices,
    super.wifiNetworks,
    super.wifiCredentials,
    super.wifiOta,
  });

  Completer<void>? holdOpenWifi;
  Completer<void>? holdConnectWifi;
  int connectWifiCalls = 0;

  @override
  Future<void> openWifi() async {
    final gate = holdOpenWifi;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    await super.openWifi();
  }

  @override
  Future<void> connectWifi(String ssid, String password) async {
    connectWifiCalls++;
    final gate = holdConnectWifi;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    await super.connectWifi(ssid, password);
  }
}

void main() {
  testWidgets('CardV2 无 Wi-Fi 更新时：主弹层与固件更新页均隐藏 Wi-Fi 入口', (tester) async {
    final mainOnlyGw = FakeCardGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      mainOta: const CardOtaInfo(
        version: '2.23.0',
        versionCode: 23,
        url: 'https://ota.invalid/main.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '1.15.0',
        versionCode: 15,
        url: 'https://ota.invalid/wifi.bin',
      ),
    );
    final mainOnlyStore = DeviceStore(gateway: mainOnlyGw);
    await pumpShell(tester, device: mainOnlyStore);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wifi-row')), findsNothing);
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    expect(find.byKey(const Key('upg-wifi-row')), findsNothing);
    await tester.tap(find.byKey(const Key('upg-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  testWidgets('CardV2 主弹层隐藏 Wi-Fi 行；仅 Wi-Fi 有更新时出现在固件页，返回直达固件页', (
    tester,
  ) async {
    final wifiUpdGw = FakeCardGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiCredentials: const [CardWifiCredential(ssid: 'HomeWiFi')],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'HomeWiFi', rssi: -45, secured: true),
      ],
      mainOta: const CardOtaInfo(
        version: '2.22.0',
        versionCode: 22,
        url: 'https://ota.invalid/main.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
    );
    final wifiUpdStore = DeviceStore(gateway: wifiUpdGw);
    await pumpShell(tester, device: wifiUpdStore);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wifi-row')), findsNothing);
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('upg-wifi-row')), findsOneWidget);
    await tester.tap(find.byKey(const Key('upg-wifi-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dev-wifi')), findsOneWidget);
    expect(find.textContaining('仅用于 Wi-Fi 固件升级'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    await tester.tap(find.byKey(const Key('upg-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  testWidgets('点一机 V1 主弹层仍保留 Wi-Fi 行，返回回到主视图', (tester) async {
    final v1Gw = FakeCardGateway(
      initialSnapshot: _v1Snap(),
      devices: const [_dyjV1Dev],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'Office-2.4G', rssi: -55, secured: true),
      ],
    );
    final v1Store = DeviceStore(gateway: v1Gw);
    await pumpShell(tester, device: v1Store);
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('wifi-row')), findsOneWidget);
    await tester.tap(find.byKey(const Key('wifi-row')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-wifi')), findsOneWidget);

    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  testWidgets('缺口 1：openWifi/wifiJoining 在途时提前退出，结束后自动 closeWifi', (
    tester,
  ) async {
    // (a) wifiScan() 在途等待 openWifi() 时用户关闭弹层
    final gwScan = _ControlledWifiGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
    )..holdOpenWifi = Completer<void>();

    final scanStore = DeviceStore(gateway: gwScan);
    await pumpShell(tester, device: scanStore);
    scanStore.openSheet();
    await tester.pump();
    scanStore.showView(DeviceView.wifi, wifiReturnTo: DeviceView.upg);
    await tester.pump();
    expect(gwScan.closeWifiCalls, 0);

    scanStore.closeSheet();
    gwScan.holdOpenWifi!.complete();
    await tester.pump();
    await tester.pump();

    expect(gwScan.openWifiCalls, 1);
    expect(gwScan.closeWifiCalls, 1);
    expect(scanStore.deviceWifiOpen, isFalse);

    // (b) wifiConnectSaved 在途等待 connectWifi() 时用户切回主页
    final gwJoinSaved = _ControlledWifiGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiCredentials: const [CardWifiCredential(ssid: 'HomeWiFi')],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'HomeWiFi', rssi: -45, secured: true),
      ],
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
    );
    final savedStore = DeviceStore(gateway: gwJoinSaved);
    await pumpShell(tester, device: savedStore);
    savedStore.openSheet();
    await tester.pump();
    savedStore.showView(DeviceView.wifi, wifiReturnTo: DeviceView.upg);
    await tester.pump();
    await tester.pump();
    expect(savedStore.deviceWifiOpen, isTrue);

    gwJoinSaved.holdConnectWifi = Completer<void>();
    unawaited(savedStore.wifiConnectSaved('HomeWiFi'));
    await tester.pump();
    expect(savedStore.wifiJoining, isTrue);

    savedStore.showView(DeviceView.main);
    expect(gwJoinSaved.closeWifiCalls, 0, reason: '等待在途连网结束后立即关闭');
    gwJoinSaved.holdConnectWifi!.complete();
    await tester.pump();
    await tester.pump();

    expect(gwJoinSaved.closeWifiCalls, 1);
    expect(savedStore.deviceWifiOpen, isFalse);
    savedStore.closeSheet();
    await tester.pump();

    // (c) wifiJoinNew 在途等待 connectWifi() 时用户关掉弹层：关闭 Wi-Fi 且不再多余重扫
    final gwJoinNew = _ControlledWifiGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'Office-2.4G', rssi: -50, secured: true),
      ],
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
    );
    final newStore = DeviceStore(gateway: gwJoinNew);
    await pumpShell(tester, device: newStore);
    newStore.openSheet();
    await tester.pump();
    newStore.showView(DeviceView.wifi, wifiReturnTo: DeviceView.upg);
    await tester.pump();
    await tester.pump();
    newStore.wifiPick('Office-2.4G');

    gwJoinNew.holdConnectWifi = Completer<void>();
    unawaited(newStore.wifiJoinNew('secret123'));
    await tester.pump();
    expect(newStore.wifiJoining, isTrue);

    newStore.closeSheet();
    gwJoinNew.holdConnectWifi!.complete();
    await tester.pump();
    await tester.pump();

    expect(gwJoinNew.connectWifiCalls, 1);
    expect(gwJoinNew.closeWifiCalls, 1);
    expect(newStore.deviceWifiOpen, isFalse);
  });

  testWidgets('缺口 2：停留在 Wi-Fi 设置页切后台（paused）立即自动关闭 Wi-Fi', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
    );
    final store = DeviceStore(gateway: gw);
    await pumpShell(tester, device: store);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('upg-wifi-row')));
    await tester.pump();
    await tester.pump();
    expect(store.deviceWifiOpen, isTrue);
    expect(gw.closeWifiCalls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(gw.closeWifiCalls, 1);
    expect(store.deviceWifiOpen, isFalse);
    expect(store.wifiStateText, contains('后台'));

    store.closeSheet();
    await tester.pump();
  });

  testWidgets('缺口 3：Wi-Fi 页与配网回升级页长时间未操作自动关闭 Wi-Fi', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'Studio-2.4G', rssi: -45, secured: true),
      ],
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
    );
    final store = DeviceStore(
      gateway: gw,
      wifiIdleCloseTimeout: const Duration(milliseconds: 80),
    );
    await pumpShell(tester, device: store);

    // (a) 停留在 _WifiView 空闲超时
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('upg-wifi-row')));
    await tester.pump();
    await tester.pump();
    expect(store.deviceWifiOpen, isTrue);

    await tester.pump(const Duration(milliseconds: 120));
    expect(gw.closeWifiCalls, 1);
    expect(store.deviceWifiOpen, isFalse);
    expect(store.wifiStateText, contains('自动关闭'));

    // (b) 重新扫码连网后返回 dev-upg：短暂保活便于点升级，超过空闲窗仍自动关闭
    await store.wifiScan();
    store.wifiPick('Studio-2.4G');
    await store.wifiJoinNew('pass-1234');
    await tester.pump();
    expect(store.deviceWifiOpen, isTrue);
    expect(store.wifiLast, 'Studio-2.4G');

    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    expect(store.deviceWifiOpen, isTrue, reason: '刚配完网回升级页允许短暂保活');
    expect(gw.closeWifiCalls, 1);

    await tester.pump(const Duration(milliseconds: 120));
    expect(gw.closeWifiCalls, 2);
    expect(store.deviceWifiOpen, isFalse);

    store.closeSheet();
    await tester.pump();
  });

  testWidgets('缺口 4 & 5：主动断开关闭 Wi-Fi；升级页返回主视图立即关闭、开始更新后关闭', (
    tester,
  ) async {
    final gw = FakeCardGateway(
      initialSnapshot: _v2Snap(fwCode: 22, wifiCode: 15),
      devices: const [_cardV2Dev],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'Studio-2.4G', rssi: -45, secured: true),
      ],
      postWifiOtaSnapshot: _v2Snap(fwCode: 22, wifiCode: 16, wifiOpen: false),
      mainOta: const CardOtaInfo(
        version: '2.22.0',
        versionCode: 22,
        url: 'https://ota.invalid/main.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '1.16.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 100, text: 'Wi-Fi 升级完成'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    await pumpShell(tester, device: store);

    // 路径 A：在升级页配完网未点升级直接退回主视图 → 立即自动关闭 Wi-Fi
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('upg-wifi-row')));
    await tester.pump();
    await tester.pump();
    store.wifiPick('Studio-2.4G');
    await store.wifiJoinNew('pass-1234');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    expect(store.deviceWifiOpen, isTrue);

    await tester.tap(find.byKey(const Key('upg-back')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(gw.closeWifiCalls, 1);
    expect(store.deviceWifiOpen, isFalse);

    // 路径 B：在升级页配网后直接点开始更新 → 升级完成 restoreWifiOpen=false 且隐藏入口
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('upg-wifi-row')));
    await tester.pump();
    await tester.pump();
    store.wifiPick('Studio-2.4G');
    await store.wifiJoinNew('pass-1234');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('upg-btn')));
    await tester.pump();
    await tester.pump();
    expect(store.fwStage, FwStage.done);
    expect(gw.lastOtaWifiRestoreOpen, isFalse);
    expect(store.deviceWifiOpen, isFalse);

    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('upg-wifi-row')), findsNothing);

    // 路径 C：打开 Wi-Fi 后直接断开连接 → teardown 先关 Wi-Fi
    await tester.tap(find.byKey(const Key('upg-back')));
    await tester.pump();
    store.showView(DeviceView.wifi, wifiReturnTo: DeviceView.upg);
    await tester.pump();
    await tester.pump();
    expect(store.deviceWifiOpen, isTrue);
    final beforeDisconnectClose = gw.closeWifiCalls;
    await store.disconnectSafely();
    await tester.pump();
    expect(gw.closeWifiCalls, greaterThan(beforeDisconnectClose));
  });
}
