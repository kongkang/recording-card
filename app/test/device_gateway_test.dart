// 设备网关验收（TDD）—— CardGateway 注入 Fake，验证真实快照字段
// （电量/充电/固件/Wi-Fi/录音态）被 DeviceStore 消费，以及 scan→connect 链路。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/kv_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'test_transitions.dart';

class FakeCardGateway implements CardGateway {
  FakeCardGateway({
    this.snapshot,
    this.devices = const [],
    this.available = true,
  });

  CardSnapshot? snapshot;
  List<String> devices;
  @override
  bool available;
  int scanCalls = 0;
  int connectCalls = 0;
  String? lastConnected;

  @override
  Future<CardSnapshot?> status() async => snapshot;

  @override
  Future<List<String>> scan({int timeoutMs = 3000}) async {
    scanCalls++;
    return devices;
  }

  @override
  Future<CardSnapshot?> connect(String deviceId) async {
    connectCalls++;
    lastConnected = deviceId;
    return snapshot;
  }
}

const _snapshot = CardSnapshot(
  batteryLevel: 35,
  isCharging: false,
  wifiOpen: true,
  recording: false,
  fwVersion: '9.9.9',
  wifiVersion: '8.8.8',
);

void main() {
  test('refreshFromDevice 应用电量/充电/录音/双固件版本', () async {
    final gateway = FakeCardGateway(snapshot: _snapshot);
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);

    await device.refreshFromDevice();

    expect(device.battery, 35);
    expect(device.batteryLevelText, '电量中');
    expect(device.recording, isFalse);
    expect(device.fwVersionText, '9.9.9');
    expect(device.wifiVersionText, '8.8.8');
  });

  test('scan → connect 成功：记录设备 id 并应用快照', () async {
    final gateway = FakeCardGateway(devices: ['card-1'], snapshot: _snapshot);
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);

    expect(await device.scanDevices(), ['card-1']);
    expect(gateway.scanCalls, 1);
    expect(await device.connectDevice('card-1'), isTrue);
    expect(gateway.lastConnected, 'card-1');
    expect(device.connectedDeviceId, 'card-1');
    expect(device.connectionText, '已连接 · 蓝牙');
    expect(device.battery, 35);
  });

  test('网关不可用不扫描不连接', () async {
    final gateway = FakeCardGateway(available: false, devices: ['card-1']);
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);

    expect(await device.scanDevices(), isEmpty);
    expect(await device.connectDevice('card-1'), isFalse);
    expect(gateway.scanCalls, 0);
    expect(gateway.connectCalls, 0);
    expect(device.connectedDeviceId, isNull);
  });

  test('网关可用但连接失败：不伪装已连接', () async {
    final gateway = FakeCardGateway(snapshot: null);
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);

    expect(await device.connectDevice('card-1'), isFalse);
    expect(device.connectedDeviceId, isNull);
    expect(device.connectionText, '未连接');
  });

  test('ensureConnected 无上次设备：扫描并连接第一个', () async {
    final gateway =
        FakeCardGateway(devices: ['card-1', 'card-2'], snapshot: _snapshot);
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);

    await device.ensureConnected();

    expect(gateway.scanCalls, 1);
    expect(gateway.lastConnected, 'card-1');
    expect(device.connectedDeviceId, 'card-1');
  });

  test('ensureConnected 有上次设备：直连且不再扫描', () async {
    final kv = MemoryKvStore();
    final first = DeviceStore(
      gateway: FakeCardGateway(devices: ['card-1'], snapshot: _snapshot),
      storage: kv,
    );
    await first.ensureConnected();
    first.dispose();

    final gateway = FakeCardGateway(devices: ['card-9'], snapshot: _snapshot);
    final restored = DeviceStore(gateway: gateway, storage: kv);
    addTearDown(restored.dispose);
    await restored.ensureConnected();

    expect(gateway.scanCalls, 0);
    expect(gateway.lastConnected, 'card-1');
    expect(restored.connectedDeviceId, 'card-1');
  });

  test('ensureConnected 已连接：只刷新状态不重复扫描', () async {
    final gateway = FakeCardGateway(devices: ['card-1'], snapshot: _snapshot);
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);
    await device.ensureConnected();

    await device.ensureConnected();
    expect(gateway.scanCalls, 1);
    expect(gateway.connectCalls, 1);
  });

  testWidgets('状态弹层消费真实快照：录音态 / 电量 / 固件版本', (tester) async {
    final gateway =
        FakeCardGateway(devices: ['card-1'], snapshot: _snapshot);
    final device = DeviceStore(gateway: gateway);
    final store = AppStore();
    addTearDown(device.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: testTheme(),
      home: AppShell(store: store, device: device),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.text('已停止'), findsOneWidget);
    expect(find.textContaining('电量中'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    expect(find.textContaining('9.9.9 → 2.2.0'), findsOneWidget);
    expect(find.textContaining('8.8.8 → 1.5.0'), findsOneWidget);

    device.closeSheet();
    await tester.pump();
  });
}
