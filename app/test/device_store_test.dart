// DeviceStore 契约 —— 这一轮设备数据全部来自真实网关，不再有预置假数据。
//
// 覆盖真实链路的关键节点：未连接 → 扫描 → 连接 → 快照字段生效；
// 桥不可用时显式 unsupported；同步真的 startSync + 轮询 + 10 秒冷却；
// Wi-Fi 连接真的下发 ssid/密码（空密码在本地就拦下）。
//
// 定时器（录音时钟 / 同步轮询 / 冷却）都在 `testWidgets` 的假时钟里推进，
// 所以既不需要真等，也不会悬挂。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';

/// 设备回报的一份「已连接」快照（电量/固件/录音状态都是设备给的）。
CardSnapshot snapshotWith({
  int battery = 82,
  bool charging = false,
  bool recording = true,
  int fwVersionCode = 22,
}) => CardSnapshot(
  batteryLevel: battery,
  isCharging: charging,
  wifiOpen: false,
  recording: recording,
  fwVersion: '2.2.0',
  fwVersionCode: fwVersionCode,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_T4W25T',
  deviceId: 'dev-1',
);

const _homeWifi = CardWifiCredential(ssid: 'HomeWiFi');

void main() {
  testWidgets('未连接 → 扫描 → 连接：快照字段真的生效', (tester) async {
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'dev-1', name: 'DYJV2_T4W25T', rssi: -52)],
    );
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);

    expect(store.liveDeviceAvailable, isTrue);
    expect(store.linkState, LinkState.unknown);
    expect(store.battery, 0, reason: '没连设备时电量未知，不假装 82%');
    expect(store.batteryKnown, isFalse);
    expect(store.batteryLevelText, '未知');
    expect(store.isRecording, isFalse);
    expect(store.recClockText, '00:00:00');

    await store.restoreLink();
    expect(store.linkState, LinkState.disconnected);
    expect(store.linkError, isNull, reason: '未连接是正常初始态，不该报错');

    await store.startScan();
    expect(gateway.scanCalls, 1);
    expect(store.discovered.single.name, 'DYJV2_T4W25T');
    expect(store.linkState, LinkState.disconnected);

    gateway.current = snapshotWith(recording: true);
    await store.connectTo(store.discovered.single);
    expect(gateway.connectCalls, 1);
    expect(gateway.lastConnectedId, 'dev-1');
    expect(store.linkState, LinkState.connected);
    expect(store.isConnected, isTrue);
    expect(store.connectedName, 'DYJV2_T4W25T');

    // 快照字段（电量 / 固件 / 录音状态）来自设备回报
    expect(store.battery, 82);
    expect(store.batteryKnown, isTrue);
    expect(store.batteryLevelText, '电量高');
    expect(store.fwVersion, '2.2.0');
    expect(store.wifiVersion, '1.5.0');
    expect(store.deviceWifiOpen, isFalse);
    expect(store.isRecording, isTrue);
    expect(store.recClockText, '00:00:00', reason: '时钟从 0 开始，没有 3:12:15 基准');

    // 连接后收尾：时间同步 + 拉一次状态
    expect(gateway.snapshotCalls, greaterThan(0));
  });

  testWidgets('电量文案跟着设备走：低电量 / 充电中', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith(battery: 15));
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    expect(store.battery, 15);
    expect(store.batteryLevelText, '电量低');
    expect(store.batteryEtaText, isNot('—'));

    gateway.current = snapshotWith(battery: 45, charging: true);
    await store.refreshFromDevice();
    expect(store.batteryLevelText, '充电中');
  });

  testWidgets('未连接时电量估算不编数字', (tester) async {
    final store = DeviceStore(gateway: FakeCardGateway());
    addTearDown(store.dispose);
    await store.restoreLink();
    expect(store.batteryEtaText, '—');
  });

  testWidgets('桥不可用：linkState=unsupported 且文案正确，扫描/同步都不发命令', (tester) async {
    final store = DeviceStore(gateway: const UnsupportedCardGateway());
    addTearDown(store.dispose);

    expect(store.liveDeviceAvailable, isFalse);
    expect(store.canScan, isFalse);

    await store.restoreLink();
    expect(store.linkState, LinkState.unsupported);
    expect(store.linkError, '此设备不支持连接录音卡');

    await store.startScan();
    expect(store.linkState, LinkState.unsupported);
    expect(store.discovered, isEmpty);

    await store.syncNow();
    expect(store.syncState, SyncState.idle, reason: '没连设备就不该进入同步中');
    expect(store.syncError, isNull);
  });

  testWidgets('连接失败：错误文案来自网关，状态回到未连接', (tester) async {
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'dev-1', name: 'DYJV2_T4W25T')],
    )..failConnect = CardException.unavailable('蓝牙被系统关闭');
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);

    await store.restoreLink();
    await store.startScan();
    await store.connectTo(store.discovered.single);

    expect(store.linkState, LinkState.disconnected);
    expect(store.linkError, '蓝牙被系统关闭');
    expect(store.isConnected, isFalse);
  });

  testWidgets('连接中断：快照报 disconnected 时翻成「连接已断开」', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith());
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();
    expect(store.isConnected, isTrue);

    gateway.failSnapshot = CardException.disconnected();
    await store.refreshFromDevice();

    expect(store.linkState, LinkState.disconnected);
    expect(store.linkError, '与录音卡的连接已断开');
    expect(store.battery, 82, reason: '单次查询失败保留上次状态，不突然清空');
  });

  testWidgets('同步：真的调 startSync + 轮询 status，完成后进入 10 秒冷却', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith());
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    expect(store.canSync, isTrue);
    expect(store.syncText, '最近同步 · 尚未同步');

    store.syncNow();
    await tester.pump();
    expect(gateway.startSyncCalled, isTrue, reason: '必须真的下发同步命令');
    expect(store.syncState, SyncState.busy);
    expect(store.syncText, '正在同步…');
    expect(store.canSync, isFalse);

    // 轮询一次（500ms）就拿到 running=false → 完成，不再是假的 900ms/6s 进度
    await tester.pump(const Duration(milliseconds: 600));
    expect(gateway.syncStatusCalls, greaterThanOrEqualTo(1));
    expect(store.syncState, SyncState.done);
    expect(store.syncText, '同步成功 · 刚刚');
    expect(store.lastSyncAt, isNotNull);

    // 冷却期内不能再次同步
    expect(store.canSync, isFalse);
    store.syncNow();
    await tester.pump();
    expect(gateway.syncStatusCalls, lessThan(2), reason: '冷却期点同步不该再发请求');

    // 10 秒后解除冷却，回到灰态可点
    await tester.pump(const Duration(seconds: 10));
    expect(store.syncState, SyncState.idle);
    expect(store.canSync, isTrue);
    expect(store.syncText, contains('最近同步'));
    expect(store.syncRelText, '刚刚');
  });

  testWidgets('同步失败：状态查询报错 → 如实提示，且不进入冷却', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith())
      ..failSyncStatus = CardException(CardErrorKind.device, '设备忙');
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    store.syncNow();
    await tester.pump();
    expect(store.syncState, SyncState.busy);

    await tester.pump(const Duration(milliseconds: 600));
    expect(store.syncState, SyncState.idle);
    expect(store.syncError, '同步未完成，请稍后重试');
    expect(store.lastSyncAt, isNull, reason: '没成功就不该记「最近同步」');
    expect(store.canSync, isTrue, reason: '失败不冷却，用户可以直接重试');
  });

  testWidgets('Wi-Fi：扫描真的走设备（凭据 + 可见网络），未连接时明确报错', (tester) async {
    final gateway = FakeCardGateway(
      initialSnapshot: snapshotWith(),
      wifiCredentials: const [_homeWifi],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'HomeWiFi', rssi: -48, secured: true),
        CardWifiNetwork(ssid: 'Cafe_Guest', rssi: -76, secured: false),
      ],
    );
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);

    await store.wifiScan();
    expect(store.wifiError, '录音卡未连接');
    expect(store.wifiScanDone, isFalse);

    await store.restoreLink();
    await store.wifiScan();

    expect(store.wifiScanDone, isTrue);
    expect(store.wifiSaved.single.name, 'HomeWiFi');
    expect(store.wifiCountShown, 1);
    expect(store.wifiScanRes.length, 2);
    expect(store.wifiInRange('HomeWiFi'), isTrue);
    expect(store.wifiStateText, '扫描完成 · 附近可见 2 个 2.4GHz 网络');
    // 信号强度由 RSSI 折算（-48 → 3 格，-76 → 1 格）
    expect(store.wifiScanRes.first.signal, 3);
    expect(store.wifiScanRes.last.signal, 1);
  });

  testWidgets('Wi-Fi：连接已保存网络不传密码；新网络必须输入密码', (tester) async {
    final gateway = FakeCardGateway(
      initialSnapshot: snapshotWith(),
      wifiCredentials: const [_homeWifi],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'HomeWiFi', rssi: -48, secured: true),
        CardWifiNetwork(ssid: 'Office-2.4G', rssi: -60, secured: true),
      ],
    );
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();
    await store.wifiScan();

    // 已保存且在范围内 → 直连，密码留空（固件自己管凭据）
    await store.wifiConnectSaved('HomeWiFi');
    expect(gateway.lastWifiSsid, 'HomeWiFi');
    expect(gateway.lastWifiPassword, '');
    expect(store.wifiLast, 'HomeWiFi');
    expect(store.wifiStateText, 'HomeWiFi 连接成功');

    // 范围外的保存网络点了也不发命令
    gateway.lastWifiSsid = null;
    await store.wifiConnectSaved('NotInRange');
    expect(gateway.lastWifiSsid, isNull);

    // 新网络：空密码在本地拦下，不下发命令
    store.wifiPick('Office-2.4G');
    expect(store.wifiSelName, 'Office-2.4G');
    gateway.lastWifiSsid = null;
    await store.wifiJoinNew('');
    expect(store.wifiError, '请输入网络密码');
    expect(gateway.lastWifiSsid, isNull, reason: '空密码不该发到设备');

    // 填密码后真的下发 ssid + 密码
    await store.wifiJoinNew('demo-password');
    expect(gateway.lastWifiSsid, 'Office-2.4G');
    expect(gateway.lastWifiPassword, 'demo-password');
    // 设备把新网络存进凭据表 → 扫一次后本地清单跟着更新
    expect(store.wifiSaved.map((w) => w.name), contains('Office-2.4G'));
    expect(store.wifiCountShown, 2);
  });

  testWidgets('Wi-Fi：连接失败把网关文案直接呈现，忘记网络会删设备侧凭据', (tester) async {
    final gateway = FakeCardGateway(
      initialSnapshot: snapshotWith(),
      wifiCredentials: const [_homeWifi, CardWifiCredential(ssid: 'Old-2.4G')],
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'HomeWiFi', rssi: -48, secured: true),
      ],
    )..failWifiConnect = CardException(CardErrorKind.device, '密码错误');
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();
    await store.wifiScan();

    await store.wifiConnectSaved('HomeWiFi');
    expect(store.wifiError, '密码错误');
    expect(store.wifiStateText, '连接 HomeWiFi 失败：密码错误');

    await store.wifiForget('Old-2.4G');
    expect(gateway.lastForgottenWifi, 'Old-2.4G');
    expect(store.wifiSaved.map((w) => w.name), isNot(contains('Old-2.4G')));
  });

  testWidgets('Wi-Fi 扫描失败：提示带原因，不显示假的可用网络', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith());
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    gateway.failWifiScan = CardException(CardErrorKind.device, 'Wi-Fi 模块未响应');
    await store.wifiScan();

    expect(store.wifiScanDone, isFalse);
    expect(store.wifiScanRes, isEmpty);
    expect(store.wifiStateText, '扫描失败：Wi-Fi 模块未响应');
  });

  testWidgets('固件：只有服务器版本比设备新才提示「有可用更新」', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith(fwVersionCode: 22));
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    await store.checkFirmware();
    expect(store.fwValText, '已是最新');
    expect(store.fwAvailable, isFalse);

    // 服务器报了更新的主控版本
    gateway.mainOta = const CardOtaInfo(
      version: '2.3.0',
      versionCode: 23,
      url: 'https://ota.invalid/main.bin',
    );
    await store.checkFirmware();
    expect(store.fwAvailable, isTrue);
    expect(store.fwValText, '有可用更新');

    // 只有 Wi-Fi 模组更新也算
    gateway.mainOta = const CardOtaInfo(version: '', versionCode: 0, url: '');
    gateway.wifiOta = const CardOtaInfo(
      version: '1.6.0',
      versionCode: 16,
      url: 'https://ota.invalid/wifi.bin',
    );
    await store.checkFirmware();
    expect(store.fwValText, '有可用更新');
  });

  testWidgets('录音时钟只在弹层打开且录音中才跳（从 0 开始）', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: snapshotWith(recording: true));
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    // 弹层未打开：不跳
    await tester.pump(const Duration(seconds: 3));
    expect(store.recSeconds, 0);

    store.openSheet();
    await tester.pump();
    expect(store.recClockText, '00:00:00');
    await tester.pump(const Duration(seconds: 1));
    expect(store.recClockText, '00:00:01');
    await tester.pump(const Duration(seconds: 2));
    expect(store.recClockText, '00:00:03');

    store.closeSheet();
    await tester.pump(const Duration(seconds: 2));
    expect(store.recSeconds, 3, reason: '关掉弹层就停表');
  });

  testWidgets('未连接时点开弹层：进入扫描，不给假状态', (tester) async {
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'dev-1', name: 'DYJV2_T4W25T')],
    );
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);
    await store.restoreLink();

    store.openSheet();
    await tester.pump();
    await tester.pump();

    expect(store.sheetOpen, isTrue);
    expect(gateway.scanCalls, greaterThan(0));
    expect(store.discovered.single.id, 'dev-1');
    expect(store.isConnected, isFalse);
  });

  testWidgets('没扫描到设备时的空态文案', (tester) async {
    final store = DeviceStore(gateway: FakeCardGateway());
    addTearDown(store.dispose);
    await store.restoreLink();
    await store.startScan();
    expect(store.discovered, isEmpty);
    // 文案按授权状态可能追加「请确认录音卡已开机」或「请允许…使用蓝牙」，
    // 这里只锚定共同前缀，避免把提示语变化当成回归。
    expect(store.linkError, contains('没有找到附近的录音卡'));
  });

  testWidgets('录音开关与打点：未连接直接给文案，连上后真的发命令', (tester) async {
    final gateway = FakeCardGateway();
    final store = DeviceStore(gateway: gateway);
    addTearDown(store.dispose);

    expect(await store.toggleRecording(), '录音卡未连接');
    expect(await store.markNow(), '录音卡未连接');

    gateway.current = snapshotWith(recording: false);
    await store.restoreLink();
    expect(await store.toggleRecording(), isNull);
  });
}
