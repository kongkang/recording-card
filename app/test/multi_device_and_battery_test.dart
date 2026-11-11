// 三硬件 SDK 统一解耦 / 能力矩阵裁剪 / 电量事件驱动 / 物理语音键验收。
//
// 覆盖：
// 1. 扫描统一发现三类自有硬件（DYJV2_* 录音卡 V2 / DYJ_* 点一机 V1 / REAI_VB_* 语音AI键盘 V2.1），
//    过滤无关蓝牙设备，按 RSSI 从强到弱排序并渲染型号标签 `dev-kind-*`；
// 2. StatusSheet 按 HardwareCapabilities 动态裁剪：
//    - 录音卡 V2：显示可录至、同步、Wi-Fi、固件两阶段更新；
//    - 点一机 V1：显示可录至、同步、Wi-Fi，隐藏双芯片固件更新；
//    - 语音AI键盘 V2.1：无机身存储，隐藏可录至、同步、Wi-Fi、固件，仅保留统一录音开关；
// 3. 电量红线：事件驱动 `power` 通知实时更新充电态与高中低三档，严禁出现百分比数字或「已充满」；
// 4. 语音AI键盘物理语音键事件 `voice_key` 联动统一录音开关；
// 5. CardFile.isAudioRecording 同时兼容 `.APM`（录音卡 V2）与 `.AMR`（点一机 V1）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

void main() {
  testWidgets('扫描识别三款自有硬件（录音卡V2 / 点一机V1 / 语音AI键盘V2.1），按 RSSI 排序并过滤外部设备', (
    tester,
  ) async {
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(id: 'v1', name: 'DYJ_001A', rssi: -68),
        CardDevice(id: 'noise1', name: 'AirPods Pro', rssi: -35),
        CardDevice(id: 'kbd', name: 'REAI_VB_8801', rssi: -48),
        CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -56),
      ],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(device.discovered.map((d) => d.id).toList(), ['kbd', 'v2', 'v1']);
    expect(find.text('AirPods Pro'), findsNothing);

    expect(find.byKey(const Key('dev-kind-kbd')), findsOneWidget);
    expect(find.byKey(const Key('dev-kind-v2')), findsOneWidget);
    expect(find.byKey(const Key('dev-kind-v1')), findsOneWidget);
    expect(find.text('语音AI键盘 V2.1'), findsOneWidget);
    expect(find.text('录音卡 V2'), findsOneWidget);
    expect(find.text('点一机 V1'), findsOneWidget);

    final kbdY = tester.getTopLeft(find.text('REAI_VB_8801')).dy;
    final v2Y = tester.getTopLeft(find.text('DYJV2_9920')).dy;
    final v1Y = tester.getTopLeft(find.text('DYJ_001A')).dy;
    expect(kbdY < v2Y && v2Y < v1Y, isTrue, reason: '按信号由强到弱排列');
  });

  testWidgets('能力矩阵裁剪：语音AI键盘隐藏可录至/同步/Wi-Fi/固件，点一机V1隐藏双阶段固件，录音卡V2完整呈现', (
    tester,
  ) async {
    const kbdDev = CardDevice(id: 'kbd', name: 'REAI_VB_8801', rssi: -46);
    const dyjDev = CardDevice(id: 'v1', name: 'DYJ_001A', rssi: -52);
    const cardDev = CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -55);

    final gateway = FakeCardGateway(
      initialSnapshot: const CardSnapshot(
        batteryLevel: 85,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '0.3.8',
        fwVersionCode: 38,
        wifiVersion: '1.2.0',
        wifiVersionCode: 12,
        deviceName: 'REAI_VB_8801',
        deviceId: 'kbd',
      ),
      devices: const [kbdDev, dyjDev, cardDev],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    // 1) 连接语音AI键盘 V2.1
    await device.connectTo(kbdDev);
    await tester.pump();
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();

    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);
    expect(find.byKey(const Key('batt-eta')), findsOneWidget);
    expect(find.textContaining('可录至'), findsNothing, reason: '键盘无存储不估算可录时长');
    expect(find.byKey(const Key('sync-now')), findsNothing);
    expect(find.byKey(const Key('wifi-row')), findsNothing);
    expect(find.byKey(const Key('fw-update')), findsNothing);

    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    await device.disconnectDevice();
    await tester.pump();

    // 2) 连接点一机 V1
    await device.connectTo(dyjDev);
    await tester.pump();
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();

    expect(device.activeCapabilities.hasCameraMedia, isTrue);
    expect(device.activeCapabilities.hasWifiConfig, isTrue);
    expect(find.textContaining('可录至'), findsOneWidget);
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('fw-update')), findsNothing, reason: '点一机不支持双芯片OTA');

    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    await device.disconnectDevice();
    await tester.pump();

    // 3) 连接录音卡 V2
    await device.connectTo(cardDev);
    await tester.pump();
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();

    expect(device.activeCapabilities.hasDualChipOta, isTrue);
    expect(find.textContaining('可录至'), findsOneWidget);
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('fw-update')), findsOneWidget);
  });

  testWidgets('电量事件驱动更新与设计红线：支持充电中/高/中/低档切换，严禁出现百分比数字与「已充满」', (
    tester,
  ) async {
    const cardDev = CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -50);
    final gateway = FakeCardGateway(
      initialSnapshot: const CardSnapshot(
        batteryLevel: 28,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '2.2.0',
        fwVersionCode: 22,
        wifiVersion: '1.5.0',
        wifiVersionCode: 15,
        deviceName: 'DYJV2_9920',
        deviceId: 'v2',
      ),
      devices: const [cardDev],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);
    await device.connectTo(cardDev);
    await tester.pump();

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();

    String batteryRowText() =>
        tester.widget<Text>(find.byKey(const Key('batt-eta'))).data ?? '';

    expect(batteryRowText(), contains('电量中'));
    expect(batteryRowText(), isNot(contains('%')));
    expect(batteryRowText(), isNot(contains('已充满')));

    // 插上电源：推送充电事件 → 立即显示「充电中」
    gateway.pushPowerEvent(level: 65, charging: true);
    await device.pollEventsNow();
    await tester.pump();
    expect(batteryRowText(), contains('充电中'));
    expect(batteryRowText(), isNot(contains('%')));

    // 充饱停充（100%, charging=false）→ 显示「电量高」，不出现「已充满」或「100%」
    gateway.pushPowerEvent(level: 100, charging: false);
    await device.pollEventsNow();
    await tester.pump();
    expect(batteryRowText(), contains('电量高'));
    expect(batteryRowText(), isNot(contains('100')));
    expect(batteryRowText(), isNot(contains('%')));
    expect(batteryRowText(), isNot(contains('已充满')));

    // 低电量事件（15%）→ 切到「电量低」
    gateway.pushPowerEvent(level: 15, charging: false);
    await device.pollEventsNow();
    await tester.pump();
    expect(batteryRowText(), contains('电量低'));
    expect(batteryRowText(), isNot(contains('15%')));
  });

  test('语音AI键盘物理语音键事件联动录音开关 + CardFile 兼容 .APM 与 .AMR', () async {
    const kbdDev = CardDevice(id: 'kbd', name: 'REAI_VB_8801', rssi: -46);
    final gateway = FakeCardGateway(
      initialSnapshot: const CardSnapshot(
        batteryLevel: 90,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '0.3.5',
        fwVersionCode: 35,
        wifiVersion: '',
        wifiVersionCode: 0,
        deviceName: 'REAI_VB_8801',
        deviceId: 'kbd',
      ),
      devices: const [kbdDev],
    );
    final device = DeviceStore(gateway: gateway);
    addTearDown(device.dispose);

    await device.connectTo(kbdDev);
    expect(device.isRecording, isFalse);

    gateway.pushVoiceKeyEvent(pressed: true);
    await device.pollEventsNow();
    // 等待异步 toggleRecording 完成
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(device.isRecording, isTrue);

    gateway.pushVoiceKeyEvent(pressed: true);
    await device.pollEventsNow();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(device.isRecording, isFalse);

    const apm = CardFile(name: '20261111120000_0001.APM', size: 1024);
    const amr = CardFile(name: '20261111120500.amr', size: 2048);
    const jpg = CardFile(name: 'IMG_0001.JPG', size: 4096);
    expect(apm.isAudioRecording, isTrue);
    expect(amr.isAudioRecording, isTrue);
    expect(jpg.isAudioRecording, isFalse);
  });
}
