import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

CardSnapshot _connectedDyjSnapshot(String id, String name) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '0.8.15',
  fwVersionCode: 815,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: name,
  deviceId: id,
  deviceKind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

const _scanDevices = [
  CardDevice(
    id: 'dyj-a',
    name: 'DYJ_A101',
    rssi: -48,
    kind: DeviceKind.dyjV1,
    capabilities: HardwareCapabilities.dyjV1,
  ),
  CardDevice(
    id: 'v2-b',
    name: 'DYJV2_B202',
    rssi: -61,
    kind: DeviceKind.cardV2,
    capabilities: HardwareCapabilities.cardV2,
  ),
  CardDevice(
    id: 'kbd-c',
    name: 'REAI_VB_C303',
    rssi: -74,
    kind: DeviceKind.boardV21,
    capabilities: HardwareCapabilities.boardV21,
  ),
];

void main() {
  testWidgets(
    '点选蓝牙设备后立即放大选中项并隐藏其余未选设备，连接成功后进入已连接视图',
    (tester) async {
      final connectGate = Completer<CardSnapshot?>();
      final gateway = FakeCardGateway(devices: _scanDevices)
        ..connectOverride =
            (deviceId, {name, deviceKind}) => connectGate.future;
      final device = DeviceStore(gateway: gateway);
      await pumpShell(tester, device: device);

      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('dev-item-dyj-a')), findsOneWidget);
      expect(find.byKey(const Key('dev-item-v2-b')), findsOneWidget);
      expect(find.byKey(const Key('dev-item-kbd-c')), findsOneWidget);

      final idleSize = tester.getSize(find.byKey(const Key('dev-item-dyj-a')));

      await tester.tap(find.byKey(const Key('dev-item-dyj-a')));
      await tester.pump();

      expect(device.linkState, LinkState.connecting);
      expect(device.connectingDevice?.id, 'dyj-a');

      // 未被选中的其他设备立即消失，只保留被点选设备的放大连接动画卡
      expect(find.byKey(const Key('dev-item-v2-b')), findsNothing);
      expect(find.byKey(const Key('dev-item-kbd-c')), findsNothing);
      expect(
        find.byKey(const Key('dev-connecting-card-dyj-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('dev-connecting-progress-dyj-a')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dev-item-dyj-a')), findsOneWidget);

      final connectingSize = tester.getSize(
        find.byKey(const Key('dev-connecting-card-dyj-a')),
      );
      expect(connectingSize.height, greaterThan(idleSize.height));

      // 推进动画帧（雷达波纹 + 放大弹性 + 进度条）
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('dev-connecting-card-dyj-a')),
        findsOneWidget,
      );

      // 完成连接并切入已连接主视图
      connectGate.complete(_connectedDyjSnapshot('dyj-a', 'DYJ_A101'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(device.linkState, LinkState.connected);
      expect(device.connectingDevice, isNull);
      expect(find.byKey(const Key('dev-connecting-card-dyj-a')), findsNothing);
      expect(find.byKey(const Key('dev-main')), findsOneWidget);
    },
  );

  testWidgets(
    '连接失败后清除放大连接态并恢复全部候选列表以供重新选择',
    (tester) async {
      final connectGate = Completer<CardSnapshot?>();
      final gateway = FakeCardGateway(devices: _scanDevices)
        ..connectOverride =
            (deviceId, {name, deviceKind}) => connectGate.future;
      final device = DeviceStore(gateway: gateway);
      await pumpShell(tester, device: device);

      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('dev-item-dyj-a')));
      await tester.pump();

      expect(
        find.byKey(const Key('dev-connecting-card-dyj-a')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dev-item-v2-b')), findsNothing);
      expect(find.byKey(const Key('dev-item-kbd-c')), findsNothing);

      connectGate.completeError(
        const CardException(CardErrorKind.device, '握手超时，请重试'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(device.linkState, LinkState.disconnected);
      expect(device.connectingDevice, isNull);
      expect(find.byKey(const Key('dev-connecting-card-dyj-a')), findsNothing);
      expect(find.text('握手超时，请重试'), findsOneWidget);
      expect(find.byKey(const Key('dev-item-dyj-a')), findsOneWidget);
      expect(find.byKey(const Key('dev-item-v2-b')), findsOneWidget);
      expect(find.byKey(const Key('dev-item-kbd-c')), findsOneWidget);
    },
  );
}
