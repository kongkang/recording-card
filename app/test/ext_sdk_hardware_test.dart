// 第三方硬件 SDK 包装层（Omi 录音器 CV1 + 飞书录音豆 D3200）全链路验收：
//
// 1. 默认关闭「第三方硬件联动」开关时，扫描严格保持 ReAI 原生 3 款硬件基线，隐藏 Omi-7F20 与 D3200-C3A1，
//    且不通过蓝牙识别 Get-A102；
// 2. 在 Setting →「硬件设备联动 → 第三方硬件联动」开启联动后，胶囊扫描按 RSSI 展示对应设备，
//    并按 DeviceKind.bleShortId 正确剥离 Omi- / D3200- 前缀与对应品类标签；
// 3. 连接 Omi 录音器后，StatusSheet 展示统一录音开关、手动同步行，隐藏 Wi-Fi / 固件更新行，
//    支持远程开关与物理按键事件双向联动，充电/满电显示均不出现「%」或「已充满」；
// 4. 连接飞书录音豆后，远程录音开关与同步行可见，Wi-Fi 和固件行隐藏，识别 .ogg / .opus / .wav 音频文件。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _TrackingLiveActivity extends LiveActivityService {
  _TrackingLiveActivity()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: true,
          supportsDynamicIsland: true,
          supportsActionButton: true,
          areActivitiesEnabled: true,
        ),
      );
}

class _StubPhoneMicBackend implements PhoneMicBackend {
  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {}

  @override
  Future<void> stopCapture() async {}
}

Future<({
  AppStore store,
  AgentConfigStore agentConfig,
  DeviceStore device,
  FakeCardGateway gateway,
})> _pumpExtShell(
  WidgetTester tester, {
  bool initialOmiEnabled = false,
  bool initialFeishuEnabled = false,
}) async {
  final model = SummaryModel();
  final store = AppStore(
    events: seedEvents,
    generator: await model.generator(),
    loadPersistedState: false,
  );
  final agentConfig = AgentConfigStore();
  if (initialOmiEnabled) {
    await agentConfig.setOmiLinkEnabled(true);
  }
  if (initialFeishuEnabled) {
    await agentConfig.setFeishuLinkEnabled(true);
  }
  final gateway = FakeCardGateway(
    devices: const [
      CardDevice(
        id: 'v2',
        name: 'DYJV2_T4W25T',
        rssi: -48,
        kind: DeviceKind.cardV2,
      ),
      CardDevice(
        id: 'getseed-ignored',
        name: 'Get-A102',
        rssi: -52,
      ),
      CardDevice(
        id: 'omi-1',
        name: 'Omi-7F20',
        rssi: -61,
        kind: DeviceKind.omiCv1,
      ),
      CardDevice(
        id: 'feishu-1',
        name: 'D3200-C3A1',
        rssi: -55,
        kind: DeviceKind.feishuD3200,
      ),
      CardDevice(
        id: 'v1',
        name: 'DYJ_B7K9Q2',
        rssi: -67,
        kind: DeviceKind.dyjV1,
      ),
      CardDevice(
        id: 'kbd',
        name: 'REAI_VB_L3M8N1',
        rssi: -83,
        kind: DeviceKind.boardV21,
      ),
    ],
  );
  final device = DeviceStore(
    gateway: gateway,
    liveActivityService: _TrackingLiveActivity(),
    phoneMicBackend: _StubPhoneMicBackend(),
  );
  await device.setExtHardwareEnabled(
    omi: initialOmiEnabled,
    feishu: initialFeishuEnabled,
  );

  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(device.dispose);
  addTearDown(store.dispose);
  addTearDown(agentConfig.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      home: AppShell(
        store: store,
        device: device,
        agentConfig: agentConfig,
        supportsDynamicIslandOverride: true,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  return (
    store: store,
    agentConfig: agentConfig,
    device: device,
    gateway: gateway,
  );
}

void main() {
  testWidgets('默认关闭第三方硬件联动时扫描严格保持 ReAI 原生 3 款硬件基线', (tester) async {
    final env = await _pumpExtShell(tester);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(env.device.discovered.map((d) => d.id).toList(), [
      'v2',
      'v1',
      'kbd',
    ]);
    expect(find.byKey(const Key('dev-item-getseed-ignored')), findsNothing);
    expect(find.byKey(const Key('dev-item-omi-1')), findsNothing);
    expect(find.byKey(const Key('dev-item-feishu-1')), findsNothing);
  });

  testWidgets('在 Setting 开启第三方硬件联动后扫描发现 Omi 录音器并移除 Get 笔记卡蓝牙入口', (
    tester,
  ) async {
    final env = await _pumpExtShell(tester);

    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-ext-hw')),
      220,
      scrollable: find.descendant(
        of: find.byKey(const Key('setting-list')),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.byKey(const Key('sv-exthw')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('sv-exthw'))).data, '未开启');

    await tester.tap(find.byKey(const Key('set-ext-hw')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ext-getseed-card')), findsNothing);
    expect(find.byKey(const Key('ext-getseed-switch')), findsNothing);
    expect(find.byKey(const Key('ext-omi-card')), findsOneWidget);
    expect(find.byKey(const Key('ext-feishu-card')), findsOneWidget);
    expect(find.byKey(const Key('ext-feishu-beta')), findsOneWidget);
    expect(find.byKey(const Key('ext-iflytek-card')), findsOneWidget);
    expect(find.byKey(const Key('ext-iflytek-switch')), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ext-omi-switch')));
    await tester.pump();
    expect(env.agentConfig.omiLinkEnabled, isTrue);

    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-exthw'))).data,
      '已开启 1 款',
    );

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(DeviceKind.fromBleName('Get-A102'), isNull);
    expect(env.device.discovered.map((d) => d.id).toList(), [
      'v2',
      'omi-1',
      'v1',
      'kbd',
    ]);
    expect(find.byKey(const Key('dev-item-getseed-ignored')), findsNothing);
    expect(find.byKey(const Key('dev-kind-omi-1')), findsOneWidget);
    expect(find.text('Omi 录音器'), findsOneWidget);
    expect(find.text('7F20'), findsOneWidget);
  });

  test('CardFile 识别 .ogg / .opus / .sbc / .wav 音频扩展名与讯飞 A1 广播短名', () {
    const oggFile = CardFile(name: '20261115_101500.ogg', size: 4096);
    const opusFile = CardFile(name: 'segment_001.opus', size: 2048);
    const sbcFile = CardFile(name: '2026_11_22_14_24_51.sbc', size: 12288);
    const wavFile = CardFile(name: 'clip.wav', size: 8192);
    expect(oggFile.isOgg, isTrue);
    expect(oggFile.isAudioRecording, isTrue);
    expect(opusFile.isOgg, isTrue);
    expect(opusFile.isAudioRecording, isTrue);
    expect(sbcFile.isSbc, isTrue);
    expect(sbcFile.isAudioRecording, isTrue);
    expect(wavFile.isWav, isTrue);
    expect(wavFile.isAudioRecording, isTrue);
    expect(DeviceKind.fromBleName('讯飞录音笔A1_11E0'), DeviceKind.iflytekA1);
    expect(DeviceKind.fromBleName('IFLYTEK_A1_ABCD'), DeviceKind.iflytekA1);
    expect(DeviceKind.bleShortId('讯飞录音笔A1_11E0'), '11E0');
    expect(DeviceKind.bleShortId('IFLYTEK_A1_ABCD'), 'ABCD');
    expect(DeviceKind.fromCode('iflytek_a1'), DeviceKind.iflytekA1);
  });

  testWidgets('连接 Omi 录音器：展示统一录音开关、物理按键联动及无百分比/已充满红线', (
    tester,
  ) async {
    final env = await _pumpExtShell(
      tester,
      initialOmiEnabled: true,
    );
    env.gateway.connectResult = const CardSnapshot(
      batteryLevel: 88,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '3.0.20',
      fwVersionCode: 3020,
      wifiVersion: '',
      wifiVersionCode: 0,
      deviceName: 'Omi-7F20',
      deviceId: 'omi-1',
      deviceKind: DeviceKind.omiCv1,
      displayModel: 'Omi 录音器',
      capabilities: HardwareCapabilities.omiCv1,
    );

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('dev-item-omi-1')));
    await tester.pump();
    await tester.pump();

    expect(env.device.isConnected, isTrue);
    expect(env.device.activeKind, DeviceKind.omiCv1);
    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);
    expect(find.byKey(const Key('rec-physical-only')), findsNothing);
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('wifi-row')), findsNothing);
    expect(find.byKey(const Key('fw-update')), findsNothing);
    expect(find.byKey(const Key('phone-rec-row')), findsNothing);

    // 推入 100% 充电事件，确认电量展示无 % 或「已充满」
    env.gateway.pushPowerEvent(level: 100, charging: true);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('已充满'), findsNothing);

    // 远程开关启停录音
    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump();
    expect(env.gateway.recordCalls, ['start']);
    expect(env.device.isRecording, isTrue);

    // 设备侧物理按键事件同样可翻转录音状态
    env.gateway.pushVoiceKeyEvent(pressed: true);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(env.gateway.recordCalls, ['start', 'stop']);
    expect(env.device.isRecording, isFalse);

    // 关闭弹层停止定时轮询
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
  });

  testWidgets('连接飞书录音豆：远程录音开关与同步行可见，Wi-Fi 和固件行隐藏', (tester) async {
    final env = await _pumpExtShell(
      tester,
      initialFeishuEnabled: true,
    );
    env.gateway.connectResult = const CardSnapshot(
      batteryLevel: 80,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '04.92',
      fwVersionCode: 492,
      wifiVersion: '',
      wifiVersionCode: 0,
      deviceName: 'D3200-C3A1',
      deviceId: 'feishu-1',
      deviceKind: DeviceKind.feishuD3200,
      displayModel: '飞书录音豆',
      capabilities: HardwareCapabilities.feishuD3200,
    );

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(env.device.discovered.map((d) => d.id).toList(), [
      'v2',
      'feishu-1',
      'v1',
      'kbd',
    ]);
    expect(find.text('C3A1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dev-item-feishu-1')));
    await tester.pump();
    await tester.pump();

    expect(env.device.isConnected, isTrue);
    expect(env.device.activeKind, DeviceKind.feishuD3200);
    expect(find.text('飞书录音豆'), findsOneWidget);
    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);
    expect(find.byKey(const Key('rec-physical-only')), findsNothing);
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('wifi-row')), findsNothing);
    expect(find.byKey(const Key('fw-update')), findsNothing);
    expect(find.byKey(const Key('phone-rec-row')), findsNothing);

    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump();
    expect(env.gateway.recordCalls, ['start']);
  });

  testWidgets('开启讯飞智能录音笔 A1 联动：过滤开关、短名、状态能力裁剪与关停断连', (tester) async {
    final env = await _pumpExtShell(tester);
    env.gateway.devices = [
      ...env.gateway.devices,
      const CardDevice(
        id: 'iflytek-1',
        name: '讯飞录音笔A1_11E0',
        rssi: -45,
        kind: DeviceKind.iflytekA1,
      ),
    ];

    // 默认未开启时严格过滤掉 A1
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-item-iflytek-1')), findsNothing);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();

    // 进入 Setting → 第三方硬件联动，开启讯飞智能录音笔 A1
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-ext-hw')),
      220,
      scrollable: find.descendant(
        of: find.byKey(const Key('setting-list')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.tap(find.byKey(const Key('set-ext-hw')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ext-iflytek-switch')));
    await tester.pump();
    expect(env.agentConfig.iflytekA1LinkEnabled, isTrue);
    expect(env.device.iflytekA1LinkEnabled, isTrue);

    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-exthw'))).data,
      '已开启 1 款',
    );

    // 打开胶囊扫描可见 iflytek-1，短名为 11E0，标签为 讯飞智能录音笔 A1
    env.gateway.connectResult = const CardSnapshot(
      batteryLevel: 85,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '1.0.15',
      fwVersionCode: 1015,
      wifiVersion: '',
      wifiVersionCode: 0,
      deviceName: '讯飞录音笔A1_11E0',
      deviceId: 'iflytek-1',
      deviceKind: DeviceKind.iflytekA1,
      displayModel: '讯飞智能录音笔 A1',
      capabilities: HardwareCapabilities.iflytekA1,
    );

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(env.device.discovered.map((d) => d.id).toList(), [
      'iflytek-1',
      'v2',
      'v1',
      'kbd',
    ]);
    expect(find.byKey(const Key('dev-kind-iflytek-1')), findsOneWidget);
    expect(find.text('讯飞智能录音笔 A1'), findsOneWidget);
    expect(find.text('11E0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dev-item-iflytek-1')));
    await tester.pump();
    await tester.pump();

    expect(env.device.isConnected, isTrue);
    expect(env.device.activeKind, DeviceKind.iflytekA1);
    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);
    expect(find.byKey(const Key('rec-physical-only')), findsNothing);
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('wifi-row')), findsNothing);
    expect(find.byKey(const Key('fw-update')), findsNothing);
    expect(find.byKey(const Key('phone-rec-row')), findsNothing);

    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump();
    expect(env.gateway.recordCalls, ['start']);
    expect(env.device.isRecording, isTrue);

    env.gateway.pushVoiceKeyEvent(pressed: true);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(env.gateway.recordCalls, ['start', 'stop']);
    expect(env.device.isRecording, isFalse);

    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();

    // 确认 Setting 摘要反映当前已连接讯飞智能录音笔 A1，且关闭开关时自动断连
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-exthw'))).data,
      '已连接 讯飞智能录音笔 A1',
    );
    await tester.tap(find.byKey(const Key('set-ext-hw')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ext-iflytek-switch')));
    await tester.pump();
    await tester.pump();
    expect(env.agentConfig.iflytekA1LinkEnabled, isFalse);
    expect(env.device.isConnected, isFalse);
  });
}
