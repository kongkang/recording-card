// 系统已连本机 BLE 设备捞回展示与蓝灯排查指引验收：
//
// 1. CardDevice 默认 systemConnected == false，CardDevice.fromJson 正确解析布尔字段；
// 2. 扫描到 systemConnected: true 的硬件（如被本机其他 App 占用的 Omi）时展示「已连本机」标签，点选可直接建连；
// 3. 普通广播设备（systemConnected: false）不展示「已连本机」；
// 4. 超过 60 秒扫描过期后，systemConnected 设备同样置灰显示「已过期」、隐藏「已连本机」且点击无效；
// 5. 空列表时展示完整蓝灯排查提示 dev-blue-led-hint；非空列表底部展示紧凑提示 dev-connect-troubleshoot-hint，且 390×844 / 320×640 无溢出。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

CardSnapshot _connectedOmiSnapshot() => const CardSnapshot(
  batteryLevel: 78,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '3.0.21',
  fwVersionCode: 3021,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'Omi-7F20',
  deviceId: 'omi-sys-1',
  deviceKind: DeviceKind.omiCv1,
  displayModel: 'Omi 录音器',
  capabilities: HardwareCapabilities.omiCv1,
);

void main() {
  test('CardDevice 默认 systemConnected 为 false，fromJson 正确解析', () {
    const def = CardDevice(id: 'a', name: 'DYJV2_0001');
    expect(def.systemConnected, isFalse);

    final parsedTrue = CardDevice.fromJson(const {
      'id': 'omi-1',
      'name': 'Omi-7F20',
      'rssi': -55,
      'deviceKind': 'omi_cv1',
      'systemConnected': true,
    });
    expect(parsedTrue.systemConnected, isTrue);
    expect(parsedTrue.deviceKind, DeviceKind.omiCv1);

    final parsedOmitted = CardDevice.fromJson(const {
      'id': 'v2-1',
      'name': 'DYJV2_9920',
      'rssi': -48,
    });
    expect(parsedOmitted.systemConnected, isFalse);
  });

  testWidgets('已连本机设备展示「已连本机」胶囊且可直接接管，普通广播设备不展示', (
    tester,
  ) async {
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(
          id: 'omi-sys-1',
          name: 'Omi-7F20',
          rssi: -55,
          kind: DeviceKind.omiCv1,
          displayModel: 'Omi 录音器',
          capabilities: HardwareCapabilities.omiCv1,
          systemConnected: true,
        ),
        CardDevice(id: 'v2-live', name: 'DYJV2_9920', rssi: -60),
      ],
      connectResult: _connectedOmiSnapshot(),
    );
    final device = DeviceStore(gateway: gateway);
    await device.setExtHardwareEnabled(omi: true);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-item-omi-sys-1')), findsOneWidget);
    expect(find.byKey(const Key('dev-sys-conn-omi-sys-1')), findsOneWidget);
    expect(find.text('已连本机'), findsOneWidget);
    expect(find.byKey(const Key('dev-sys-conn-v2-live')), findsNothing);
    expect(find.byKey(const Key('dev-connect-troubleshoot-hint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dev-item-omi-sys-1')));
    await tester.pump();
    await tester.pump();

    expect(gateway.connectCalls, 1);
    expect(device.isConnected, isTrue);
    expect(device.activeKind, DeviceKind.omiCv1);
  });

  testWidgets('60 秒扫描过期后：systemConnected 设备置灰显示「已过期」并隐藏「已连本机」，点击无效', (
    tester,
  ) async {
    var fakeNow = DateTime(2026, 11, 24, 17, 0, 0);
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(
          id: 'omi-sys-1',
          name: 'Omi-7F20',
          rssi: -55,
          kind: DeviceKind.omiCv1,
          systemConnected: true,
        ),
      ],
    );
    final device = DeviceStore(gateway: gateway, now: () => fakeNow);
    await device.setExtHardwareEnabled(omi: true);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-sys-conn-omi-sys-1')), findsOneWidget);

    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));

    expect(device.isBleScanExpired, isTrue);
    expect(find.byKey(const Key('dev-sys-conn-omi-sys-1')), findsNothing);
    expect(find.byKey(const Key('dev-expired-omi-sys-1')), findsOneWidget);
    expect(find.text('已过期'), findsOneWidget);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-omi-sys-1'))).onTap,
      isNull,
    );

    await tester.tap(find.byKey(const Key('dev-item-omi-sys-1')));
    await tester.pump();
    expect(gateway.connectCalls, 0);
    expect(device.isConnected, isFalse);
  });

  testWidgets('扫描为空时展示蓝灯排查完整提示 dev-blue-led-hint', (tester) async {
    final gateway = FakeCardGateway(devices: const []);
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-scan-empty')), findsOneWidget);
    expect(find.byKey(const Key('dev-blue-led-hint')), findsOneWidget);
    final hint = tester.widget<Text>(find.byKey(const Key('dev-blue-led-hint')));
    expect(hint.data, contains('蓝灯常亮'));
    expect(hint.data, contains('按住按键插充电线硬复位'));
    expect(find.byKey(const Key('dev-connect-troubleshoot-hint')), findsNothing);
  });

  Future<void> verifyViewportNoOverflow(
    WidgetTester tester,
    Size viewport,
  ) async {
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(
          id: 'omi-long-name',
          name: 'Omi-LongWearableName-7F20AA',
          rssi: -55,
          kind: DeviceKind.omiCv1,
          displayModel: 'Omi 录音器',
          systemConnected: true,
        ),
      ],
    );
    final device = DeviceStore(gateway: gateway);
    await device.setExtHardwareEnabled(omi: true);
    await pumpShell(tester, size: viewport, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-sys-conn-omi-long-name')), findsOneWidget);
    expect(find.byKey(const Key('dev-connect-troubleshoot-hint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  testWidgets('极窄屏 320×640 展示「已连本机」及底部蓝灯提示无溢出', (tester) async {
    await verifyViewportNoOverflow(tester, const Size(320, 640));
  });

  testWidgets('标准屏 390×844 展示「已连本机」及底部蓝灯提示无溢出', (tester) async {
    await verifyViewportNoOverflow(tester, const Size(390, 844));
  });
}
