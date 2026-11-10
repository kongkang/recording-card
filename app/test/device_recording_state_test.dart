// 设备侧按键/开关开始录音后，手机界面必须跟上（2026-11-10 真机暴露的缺陷）。
//
// 真实现象：卡上屏幕显示"正在录音"，手机弹层却一直是"未录音"，点开关也没反应。
// 根因（已定位）：快照里 `record.isRecording` 才是录音状态，
// 早前代码把 `state.recordRealtimeEnabled`（实时流开关）误当录音标志，
// 于是设备侧开录 → App 永远读不到 recording=true。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/tokens.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

/// 已连接但**未录音**的初始快照（defaultSnapshot 默认是录音中，不适合这条用例）。
const _idle = CardSnapshot(
  batteryLevel: 80,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_TEST',
  deviceId: 'test-device',
);

Color? _dotColor(WidgetTester tester) {
  final f = find.byKey(const Key('capsule-dot'));
  if (f.evaluate().isEmpty) return null;
  return (tester.widget<Container>(f).decoration as BoxDecoration?)?.color;
}

void main() {
  test('录音状态只认 record.isRecording，不把实时流开关当录音', () {
    // 设备回：未录音，但实时流开关开着
    final snap = CardSnapshot.fromJson({
      'battery': {'level': 80},
      'state': {'wifiOpen': false, 'recordRealtimeEnabled': true},
      'record': {'isRecording': false, 'realtimeEnabled': true},
    });
    expect(snap.recording, isFalse, reason: '实时流开着不等于正在录音');
    expect(snap.realtimeEnabled, isTrue);
  });

  test('设备回 isRecording=true 时录音状态为真，并带上会话与来源', () {
    final snap = CardSnapshot.fromJson({
      'battery': {'level': 80},
      'state': {'wifiOpen': false, 'recordRealtimeEnabled': false},
      'record': {
        'isRecording': true,
        'realtimeEnabled': false,
        'reason': 'button',
        'session': 'A1B2C3D4',
      },
    });
    expect(snap.recording, isTrue);
    expect(snap.recordSession, 'A1B2C3D4');
    expect(snap.recordReason, 'button');
  });

  testWidgets('弹层打开期间，设备侧开始录音后界面自动切到「录音中」', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: _idle);
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    expect(find.text('未录音'), findsOneWidget);

    // 用户直接在卡上拨动拨杆：设备**主动推送**录音状态，不需要我们轮询
    gateway.pushRecordEvent(recording: true, reason: 'switch');
    gateway.current = pressedOnDeviceSnapshot;
    // 200ms 一次取队列 → 半秒内必须跟上（延迟要远小于轮询周期）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      find.text('录音中'),
      findsOneWidget,
      reason: '设备侧拨杆开录是主动推送，界面必须在一个取队列周期内跟上',
    );
    expect(find.byKey(const Key('rec-clock')), findsOneWidget);
    expect(_dotColor(tester), RCColors.ok, reason: '录音中应是绿点');
    expect(device.isRecording, isTrue);

    // 收尾：关掉弹层让轮询定时器停下（真实交互里用户也会关）
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  testWidgets('关闭弹层后停止取事件，不再反复拉取', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: _idle);
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    final callsAfterClose = gateway.pullEventCalls;
    await tester.pump(const Duration(seconds: 2));
    expect(
      gateway.pullEventCalls,
      callsAfterClose,
      reason: '弹层关掉就不该继续取事件（省电）',
    );
  });

  test('未连设备时同步被拒绝，且不把状态打成错误', () async {
    final store = AppStore(events: const [], loadPersistedState: false);
    store.deviceConnected = () => false;
    final error = await store.syncRecordings();
    expect(error, contains('未连接录音卡'));
  });

  test('连着设备时允许同步（守卫不误伤）', () async {
    final store = AppStore(events: const [], loadPersistedState: false);
    store.deviceConnected = () => true;
    // 没有流水线时会返回"未就绪"而不是"未连接"——说明没被设备守卫挡住
    final error = await store.syncRecordings();
    expect(error, isNot(contains('未连接录音卡')));
  });
}
