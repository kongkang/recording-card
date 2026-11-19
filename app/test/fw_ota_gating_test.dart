// 固件按模块独立门控 OTA + v0.0.8 网关新能力单测/组件测试。
//
// 覆盖四类核心升级场景：
// ① 仅主控有更新 → 只跑 ota.main + 重连 + 刷新快照，不进 ota.wifi；
// ② 仅 Wi-Fi 有更新 → 跳过 ota.main 和重连，直接跑 ota.wifi + 刷新快照；
// ③ 双模块均有更新 → 依次跑 ota.main → 重连 → ota.wifi → 刷新快照；
// ④ Wi-Fi 未连路由器报错 → 给出可操作引导（去设置 Wi-Fi）并在配网后重试成功；
// ⑤ reai-card-sdk v0.0.8：startRecording(durationSecs) 与 takeOldestFile。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _card = CardDevice(id: 'dev-ota', name: 'DYJV2_OTA_TEST', rssi: -45);

CardSnapshot _cardSnap({
  String fwVersion = '0.3.12',
  int fwVersionCode = 312,
  String wifiVersion = '0.1.4',
  int wifiVersionCode = 104,
  bool wifiOpen = false,
}) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: wifiOpen,
  recording: false,
  fwVersion: fwVersion,
  fwVersionCode: fwVersionCode,
  wifiVersion: wifiVersion,
  wifiVersionCode: wifiVersionCode,
  deviceName: _card.name,
  deviceId: _card.id,
);

void main() {
  testWidgets('① 仅主控有更新：只升级主控、重连刷新版本号、跳过 Wi-Fi 阶段并展示已是最新', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.12',
        fwVersionCode: 312,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
      ),
      devices: const [_card],
      postMainOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
      ),
      clearAfterMainOta: true,
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      mainProgress: const [
        CardProgress(stage: 'dfu', percent: 50, text: '正在写入主控固件…'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    await pumpShell(tester, device: store);
    await store.connectTo(_card);
    await store.checkFirmware();
    await tester.pump();

    expect(store.mainNeedsUpdate, isTrue);
    expect(store.wifiNeedsUpdate, isFalse);
    expect(store.fwAvailable, isTrue);
    expect(store.mainVersionCompare, '0.3.12 → 0.3.17');
    expect(store.wifiVersionCompare, '0.1.4 · 已是最新');

    // 打开更新页核对文案
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-main-ver'))).data,
      '0.3.12 → 0.3.17',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-wifi-ver'))).data,
      '0.1.4 · 已是最新',
    );

    final done = store.startFwUpdate();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await done;
    await tester.pump();

    expect(gw.callLog, contains('ota.main'));
    expect(gw.callLog, contains('connect'));
    expect(gw.callLog, isNot(contains('ota.wifi')));
    expect(store.fwStage, FwStage.done);
    expect(store.fwVersion, '0.3.17');
    expect(store.fwVersionCode, 317);
    expect(store.fwAvailable, isFalse);
    expect(store.fwValText, '已是最新');

    store.closeSheet();
    await tester.pump();
  });

  testWidgets('② 仅 Wi-Fi 有更新：跳过主控 DFU 与重连，直接升级 Wi-Fi 并刷新版本号', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
      ),
      devices: const [_card],
      postWifiOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
      ),
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 80, text: 'Wi-Fi 模组写入中…'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.restoreLink();
    await store.checkFirmware();

    expect(store.mainNeedsUpdate, isFalse);
    expect(store.wifiNeedsUpdate, isTrue);
    expect(store.mainVersionCompare, '0.3.17 · 已是最新');
    expect(store.wifiVersionCompare, '0.1.3 → 0.1.4');

    gw.callLog.clear();
    await store.startFwUpdate();

    expect(gw.callLog, isNot(contains('ota.main')));
    expect(gw.callLog, isNot(contains('connect')));
    expect(gw.callLog, contains('ota.wifi'));
    expect(gw.callLog, contains('snapshot'));
    expect(store.fwStage, FwStage.done);
    expect(store.wifiVersion, '0.1.4');
    expect(store.wifiVersionCode, 104);
    expect(store.fwAvailable, isFalse);
    expect(store.fwValText, '已是最新');
  });

  testWidgets('③ 双模块均有更新：主控升级重连后继续 Wi-Fi 升级并刷新双版本', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.12',
        fwVersionCode: 312,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
      ),
      devices: const [_card],
      postMainOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
      ),
      postWifiOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
      ),
      clearAfterMainOta: true,
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      mainProgress: const [
        CardProgress(stage: 'dfu', percent: 90, text: '主控写入中…'),
      ],
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 100, text: 'Wi-Fi 写入完成'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.restoreLink();
    await store.checkFirmware();

    final done = store.startFwUpdate();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await done;

    final iMain = gw.callLog.indexOf('ota.main');
    final iConn = gw.callLog.indexOf('connect');
    final iWifi = gw.callLog.indexOf('ota.wifi');
    expect(iMain, isNonNegative);
    expect(iConn, greaterThan(iMain));
    expect(iWifi, greaterThan(iConn));
    expect(store.fwStage, FwStage.done);
    expect(store.fwVersion, '0.3.17');
    expect(store.wifiVersion, '0.1.4');
    expect(store.fwAvailable, isFalse);
  });

  testWidgets('④ Wi-Fi 未连路由器失败后给出配网入口，配网成功可重试完成升级', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
      ),
      devices: const [_card],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'Studio-2.4G', rssi: -45, secured: true),
      ],
      postWifiOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
      ),
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      failWifiOta: const CardException(
        CardErrorKind.device,
        '录音卡尚未配置 Wi-Fi 网络，请先在录音卡弹层「Wi-Fi」中连接 2.4GHz 路由器后再升级',
      ),
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 100, text: 'Wi-Fi 升级完成'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    await pumpShell(tester, device: store);
    await store.connectTo(_card);
    await tester.pump();

    // 打开弹层进固件升级页
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();

    // 点开始更新 → 触发 Wi-Fi 未配网错误
    await tester.tap(find.byKey(const Key('upg-btn')));
    await tester.pump();
    await tester.pump();
    expect(store.fwStage, FwStage.failed);
    expect(store.fwError, contains('Wi-Fi'));
    expect(find.byKey(const Key('fw-error')), findsOneWidget);
    expect(find.byKey(const Key('upg-goto-wifi')), findsOneWidget);

    // 点「去设置 Wi-Fi ›」跳去配网页面连接路由器
    await tester.tap(find.byKey(const Key('upg-goto-wifi')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-wifi')), findsOneWidget);

    await tester.tap(find.byKey(const Key('witem-Studio-2.4G')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('wifi-pwd')), 'secret123');
    await tester.tap(find.byKey(const Key('wifi-connect')));
    await tester.pump();
    await tester.pump();
    expect(gw.lastWifiSsid, 'Studio-2.4G');

    // 清除失败注入，回到固件升级页重试 → 成功
    gw.failWifiOta = null;
    await tester.tap(find.byKey(const Key('wifi-back')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('upg-btn')));
    await tester.pump();
    await tester.pump();

    expect(store.fwStage, FwStage.done);
    expect(store.wifiVersion, '0.1.4');
    expect(store.fwValText, '已是最新');

    store.closeSheet();
    await tester.pump();
  });

  test('⑤ v0.0.8 网关新能力：durationSecs 分片时长透传 + takeOldestFile 按最旧文件取回 + encryption 识别', () async {
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(),
      deviceFiles: const [
        CardFile(name: '20261113_0001.APM', size: 1024),
        CardFile(name: '20261113_0002.APM', size: 2048),
      ],
    );

    await gw.startRecording(durationSecs: 300);
    expect(gw.lastStartDurationSecs, 300);
    expect(gw.callLog, contains('record.start'));

    final first = await gw.takeOldestFile('/tmp/rec');
    final second = await gw.takeOldestFile('/tmp/rec');
    expect(first.originalName, '20261113_0001.APM');
    expect(second.originalName, '20261113_0002.APM');
    await expectLater(
      gw.takeOldestFile('/tmp/rec'),
      throwsA(isA<CardException>()),
    );

    final wpa = CardWifiNetwork.fromJson({
      'ssid': 'Office',
      'rssi': -50,
      'encryption': 'WPA2',
    });
    final open = CardWifiNetwork.fromJson({
      'ssid': 'Cafe',
      'rssi': -65,
      'encryption': 'OPEN',
    });
    expect(wpa.secured, isTrue);
    expect(open.secured, isFalse);
  });

  testWidgets('⑥ Wi-Fi 初始关闭时升级：自动开启并在成功与失败后均恢复关闭', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
        wifiOpen: false,
      ),
      devices: const [_card],
      postWifiOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
        wifiOpen: true, // 即便升级中途曾打开，结束后也应回到 false
      ),
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      failWifiOta: const CardException(CardErrorKind.device, '下载超时'),
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 40, text: 'Wi-Fi 模组写入中…'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.restoreLink();
    await store.checkFirmware();
    expect(store.deviceWifiOpen, isFalse);

    // 失败场景：自动开启过，失败退出前恢复关闭
    await store.startFwUpdate();
    expect(store.fwStage, FwStage.failed);
    expect(gw.lastOtaWifiRestoreOpen, isFalse);
    expect(gw.openWifiCalls, greaterThanOrEqualTo(1));
    expect(gw.closeWifiCalls, greaterThanOrEqualTo(1));
    expect(store.deviceWifiOpen, isFalse);

    // 清除故障重试成功：结束后仍恢复为关闭
    gw.failWifiOta = null;
    await store.startFwUpdate();
    expect(store.fwStage, FwStage.done);
    expect(gw.lastOtaWifiRestoreOpen, isFalse);
    expect(gw.openWifiCalls, greaterThanOrEqualTo(2));
    expect(gw.closeWifiCalls, greaterThanOrEqualTo(2));
    expect(store.deviceWifiOpen, isFalse);
  });

  testWidgets('⑦ Wi-Fi 初始开启时升级：单 Wi-Fi / 双模块 / 仅主控均恢复开启模式', (tester) async {
    // (a) 双模块升级：Stage 1 主控 DFU 重启后 wifiOpen=false，Stage 2 仍按 priorWifiOpen=true 还原为开启
    final dualGw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.12',
        fwVersionCode: 312,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
        wifiOpen: true,
      ),
      devices: const [_card],
      postMainOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.3',
        wifiVersionCode: 103,
        wifiOpen: false, // 主控 DFU 重启后硬件默认关闭
      ),
      postWifiOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
        wifiOpen: false,
      ),
      clearAfterMainOta: true,
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      progressDelay: Duration.zero,
    );
    final dualStore = DeviceStore(gateway: dualGw);
    addTearDown(dualStore.dispose);
    await dualStore.restoreLink();
    await dualStore.checkFirmware();
    expect(dualStore.deviceWifiOpen, isTrue);

    final doneDual = dualStore.startFwUpdate();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await doneDual;

    expect(dualStore.fwStage, FwStage.done);
    expect(dualGw.lastOtaWifiRestoreOpen, isTrue);
    expect(dualStore.deviceWifiOpen, isTrue);

    // (b) 仅主控升级且初始 Wi-Fi 开启：重连后自动恢复 openWifi
    final mainOnlyGw = FakeCardGateway(
      initialSnapshot: _cardSnap(
        fwVersion: '0.3.12',
        fwVersionCode: 312,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
        wifiOpen: true,
      ),
      devices: const [_card],
      postMainOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
        wifiOpen: false,
      ),
      clearAfterMainOta: true,
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      progressDelay: Duration.zero,
    );
    final mainOnlyStore = DeviceStore(gateway: mainOnlyGw);
    addTearDown(mainOnlyStore.dispose);
    await mainOnlyStore.restoreLink();
    await mainOnlyStore.checkFirmware();
    expect(mainOnlyStore.deviceWifiOpen, isTrue);

    final doneMain = mainOnlyStore.startFwUpdate();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await doneMain;

    expect(mainOnlyStore.fwStage, FwStage.done);
    expect(mainOnlyGw.callLog, contains('wifi.open'));
    expect(mainOnlyGw.callLog, isNot(contains('ota.wifi')));
    expect(mainOnlyStore.deviceWifiOpen, isTrue);
  });

  test('蓝牙短编号解析与 connectedDisplayName：去掉产品前缀，保留原始 connectedName', () {
    expect(DeviceKind.bleShortId('DYJV2_A1B2C3'), 'A1B2C3');
    expect(DeviceKind.bleShortId('REAI_VB_8801'), '8801');
    expect(DeviceKind.bleShortId('DYJ_001A'), '001A');
    expect(DeviceKind.bleShortId('CUSTOM_NAME'), 'CUSTOM_NAME');

    const dev = CardDevice(id: 'dev-1', name: 'DYJV2_A1B2C3', rssi: -50);
    expect(dev.shortName, 'A1B2C3');
  });

  testWidgets(
    '连接即拉齐快照 + 固件检查完成前显示「正在检查…」+ 被动读取 Wi-Fi 凭据不开 Wi-Fi',
    (tester) async {
      final otaCompleter = Completer<CardOtaInfo>();
      final gateway = FakeCardGateway(
        devices: const [
          CardDevice(id: 'dev-ota', name: 'DYJV2_T4W25T', rssi: -45),
        ],
        connectResult: _cardSnap(
          fwVersion: '0.3.12',
          fwVersionCode: 312,
          wifiVersion: '0.1.3',
          wifiVersionCode: 103,
        ),
        connectReturnsSnapshot: false,
        wifiCredentials: const [CardWifiCredential(ssid: 'OfficeWiFi')],
      );
      gateway.otaInfoOverride = (module) => otaCompleter.future;

      final store = DeviceStore(gateway: gateway);
      await pumpShell(tester, device: store);

      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('T4W25T'));
      await tester.pump();
      await tester.pump();

      // 原始名称保留，UI 只展示后缀短号；即使 connect() 返回 null 也通过 snapshot() 补齐电量与版本
      expect(store.connectedName, 'DYJV2_T4W25T');
      expect(store.connectedDisplayName, 'T4W25T');
      expect(find.text('T4W25T'), findsOneWidget);
      expect(store.battery, 88);
      expect(store.fwVersionCode, 312);
      expect(store.wifiVersionCode, 103);

      // OTA 查询尚未返回：必须显示「正在检查…」，不能误报「已是最新」
      expect(store.fwValText, '正在检查…');
      expect(find.text('正在检查…'), findsOneWidget);
      expect(find.text('已是最新'), findsNothing);

      // 预取凭据使用 passive: true，不主动开 ESP32 Wi-Fi
      expect(gateway.lastWifiCredentialsPassive, isTrue);
      expect(gateway.openWifiCalls, 0);

      // 完成 OTA 查询：立即切为「有可用更新」
      otaCompleter.complete(
        const CardOtaInfo(
          version: '0.3.17',
          versionCode: 317,
          url: 'https://ota.invalid/317.zip',
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(store.fwValText, '有可用更新');
      expect(find.text('有可用更新'), findsOneWidget);
    },
  );

  testWidgets('未知固件版本号(0)不误判更新，且 checkFirmware 网络失败显式报「检查失败」', (tester) async {
    const ota = CardOtaInfo(
      version: '0.3.17',
      versionCode: 317,
      url: 'https://ota.invalid/317.zip',
    );
    expect(ota.isNewerThan(0), isFalse);
    expect(ota.isNewerThan(312), isTrue);

    final gateway = FakeCardGateway(
      initialSnapshot: _cardSnap(),
      devices: const [_card],
    );
    gateway.failMainOtaInfo = const CardException(
      CardErrorKind.device,
      'network error',
    );
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);

    await store.restoreLink();
    final fut = store.checkFirmware();
    await tester.pump(const Duration(milliseconds: 300));
    await fut;

    expect(store.fwStage, FwStage.failed);
    expect(store.fwValText, '检查失败');
  });

  testWidgets('⑧ ota.main 失败清句柄后自动扫描回连 DFU_DYJ，界面可直接重试刷完', (
    tester,
  ) async {
    const dfuDev = CardDevice(id: 'dev-dfu', name: 'DFU_DYJ', rssi: -42);
    final dfuSnap = CardSnapshot(
      batteryLevel: 0,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '恢复模式',
      fwVersionCode: 1,
      wifiVersion: '',
      wifiVersionCode: 0,
      deviceName: 'DFU_DYJ',
      deviceId: 'dev-dfu',
      hasBattery: false,
      deviceKind: DeviceKind.cardV2,
      displayModel: '录音卡 V2（恢复模式）',
      capabilities: const HardwareCapabilities(
        realtimeAudio: false,
        hasOnboardStorage: false,
        hasFileSync: false,
        hasWifiConfig: false,
        hasCameraMedia: false,
        hasPhysicalRecordToggle: false,
        hasRemoteRecordControl: false,
        hasMarkButton: false,
        otaMode: 'dual_chip',
      ),
    );
    final initialSnap = _cardSnap(
      fwVersion: '0.3.12',
      fwVersionCode: 312,
      wifiVersion: '0.1.4',
      wifiVersionCode: 104,
    );
    final updatedSnap = _cardSnap(
      fwVersion: '0.3.17',
      fwVersionCode: 317,
      wifiVersion: '0.1.4',
      wifiVersionCode: 104,
    );

    final gw = FakeCardGateway(
      initialSnapshot: initialSnap,
      devices: const [_card],
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      progressDelay: Duration.zero,
    );

    var otaAttempts = 0;
    gw.otaMainOverride = () async* {
      otaAttempts++;
      if (otaAttempts == 1) {
        // 真实桥进入 DFU 前会 take() 走 active device，导致 snapshot() 报断开
        gw.current = null;
        gw.devices = const [dfuDev];
        yield const CardProgress(
          stage: 'dfu',
          percent: 30,
          text: '正在写入主控固件…',
        );
        throw CardException.timeout('DFU packet write 超时');
      }
      gw.current = null;
      gw.devices = const [_card];
      yield const CardProgress(stage: 'dfu', percent: 100, text: '主控写入完成');
    };
    gw.connectOverride = (id, {name, deviceKind}) async {
      final snap = id == dfuDev.id
          ? dfuSnap
          : (otaAttempts >= 2 ? updatedSnap : initialSnap);
      gw.current = snap;
      return snap;
    };

    final store = DeviceStore(gateway: gw);
    await pumpShell(tester, device: store);
    await store.connectTo(_card);
    await store.checkFirmware();
    await tester.pump();

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    await tester.pump();

    // 第 1 次点击开始更新：注入写超时失败，DeviceStore 应自动回连到 DFU_DYJ，保持可重试态
    await tester.tap(find.byKey(const Key('upg-btn')));
    await tester.pump();
    await tester.pump();

    expect(store.fwStage, FwStage.failed);
    expect(store.isConnected, isTrue);
    expect(store.connectedName, 'DFU_DYJ');
    expect(store.fwVersionCode, 1);
    expect(store.fwAvailable, isTrue);
    expect(find.byKey(const Key('fw-error')), findsOneWidget);

    // 第 2 次直接点击重试按钮：续传完成，回连至正常模式 DYJV2_OTA_TEST
    await tester.tap(find.byKey(const Key('upg-btn')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(otaAttempts, 2);
    expect(store.fwStage, FwStage.done);
    expect(store.connectedName, _card.name);
    expect(store.fwVersion, '0.3.17');
    expect(store.fwVersionCode, 317);

    store.closeSheet();
    await tester.pump();
  });

  testWidgets('⑨ 直连 DFU_DYJ 恢复模式：主控升级回连后若发现 Wi-Fi 落后则自动接力 Stage 2', (
    tester,
  ) async {
    const dfuDev = CardDevice(id: 'dev-dfu', name: 'DFU_DYJ', rssi: -40);
    final dfuSnap = CardSnapshot(
      batteryLevel: 0,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '恢复模式',
      fwVersionCode: 1,
      wifiVersion: '',
      wifiVersionCode: 0,
      deviceName: 'DFU_DYJ',
      deviceId: 'dev-dfu',
      hasBattery: false,
      deviceKind: DeviceKind.cardV2,
      displayModel: '录音卡 V2（恢复模式）',
      capabilities: const HardwareCapabilities(
        realtimeAudio: false,
        hasOnboardStorage: false,
        hasFileSync: false,
        hasWifiConfig: false,
        hasCameraMedia: false,
        hasPhysicalRecordToggle: false,
        hasRemoteRecordControl: false,
        hasMarkButton: false,
        otaMode: 'dual_chip',
      ),
    );
    final postMainSnap = _cardSnap(
      fwVersion: '0.3.17',
      fwVersionCode: 317,
      wifiVersion: '0.1.3',
      wifiVersionCode: 103,
    );
    final postWifiSnap = _cardSnap(
      fwVersion: '0.3.17',
      fwVersionCode: 317,
      wifiVersion: '0.1.4',
      wifiVersionCode: 104,
    );

    final gw = FakeCardGateway(
      initialSnapshot: dfuSnap,
      devices: const [dfuDev],
      postWifiOtaSnapshot: postWifiSnap,
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 100, text: 'Wi-Fi 升级完成'),
      ],
      progressDelay: Duration.zero,
    );
    gw.otaMainOverride = () async* {
      gw.current = null;
      gw.devices = const [_card];
      yield const CardProgress(stage: 'dfu', percent: 100, text: '主控恢复完成');
    };
    gw.connectOverride = (id, {name, deviceKind}) async {
      final snap = id == dfuDev.id ? dfuSnap : postMainSnap;
      gw.current = snap;
      return snap;
    };

    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.connectTo(dfuDev);
    await store.checkFirmware();

    expect(store.connectedName, 'DFU_DYJ');
    expect(store.mainNeedsUpdate, isTrue);
    expect(store.wifiNeedsUpdate, isFalse);

    final done = store.startFwUpdate();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await done;

    expect(gw.callLog, contains('ota.main'));
    expect(gw.callLog, contains('ota.wifi'));
    expect(store.fwStage, FwStage.done);
    expect(store.connectedName, _card.name);
    expect(store.fwVersion, '0.3.17');
    expect(store.wifiVersion, '0.1.4');
  });

  testWidgets('⑩ 升级期间忽略轮询中的 disconnected 事件，不误触发掉线重连', (tester) async {
    final otaGate = Completer<void>();
    final gw = FakeCardGateway(
      initialSnapshot: _cardSnap(),
      devices: const [_card],
      postMainOtaSnapshot: _cardSnap(
        fwVersion: '0.3.17',
        fwVersionCode: 317,
      ),
      mainOta: const CardOtaInfo(
        version: '0.3.17',
        versionCode: 317,
        url: 'https://ota.invalid/main_317.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '0.1.4',
        versionCode: 104,
        url: 'https://ota.invalid/wifi_104.bin',
      ),
      progressDelay: Duration.zero,
    );
    gw.otaMainOverride = () async* {
      yield const CardProgress(stage: 'dfu', percent: 40, text: '写入中…');
      await otaGate.future;
    };

    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.connectTo(_card);
    await store.checkFirmware();

    final done = store.startFwUpdate();
    await tester.pump();
    expect(store.fwUpdating, isTrue);

    gw.pushDisconnectedEvent();
    await store.pollEventsNow();

    expect(store.linkState, LinkState.connected);
    expect(gw.connectCalls, 1);

    otaGate.complete();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await done;
    expect(store.fwStage, FwStage.done);
  });
}
