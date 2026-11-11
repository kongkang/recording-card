// 连接 / 录音 / 自动同步流程验收。
//
// 设计目标（owner 2026-11-09）：
// - 未连接是默认态：点胶囊进入「连接录音卡」扫描流程；
// - 扫描只列 DYJ 系列，按信号从强到弱（离得近的在上）；
// - 连上后默认未录音；录音状态行本身是开关，打开后正计时，关闭动画过渡；
// - 停止录音自动同步最新录音，Timeline 顶部保留「正在同步」直到完成；
// - 状态块只出现在「全部/记录」内容顶部，总结 Tab 与勾选态不出现。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/recording_sync_service.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

CardSnapshot _connected({bool recording = false}) => CardSnapshot(
  batteryLevel: 82,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_TEST',
  deviceId: 'test-device',
);

/// 记录 syncRecordings 调用次数，不真正跑管线。
class _SyncSpy extends AppStore {
  _SyncSpy() : super(events: const [], loadPersistedState: false);

  int syncCalls = 0;

  @override
  Future<String?> syncRecordings() async {
    syncCalls++;
    return null;
  }
}

Finder _statusBlock() => find.byKey(const Key('recording-status-block'));

/// 顶栏胶囊圆点颜色：绿=录音中，橙=已连接待机，null=未连接（灰空心）。
Color? _dotColor(WidgetTester tester) {
  final f = find.byKey(const Key('capsule-dot'));
  if (f.evaluate().isEmpty) return null;
  final box = tester.widget<Container>(f);
  return (box.decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('未连接点胶囊：只列 DYJ 设备，按 RSSI 从强到弱', (tester) async {
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(id: 'far', name: 'DYJV2_FAR', rssi: -88),
        CardDevice(id: 'other', name: 'JBL Speaker', rssi: -40),
        CardDevice(id: 'near', name: 'DYJV2_NEAR', rssi: -45),
        CardDevice(id: 'mid', name: 'DYJV2_MID', rssi: -70),
      ],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('capsule-off')), findsOneWidget);
    expect(_dotColor(tester), isNull, reason: '未连接不显示实心点/电量');
    expect(device.discovered.map((d) => d.id), ['near', 'mid', 'far']);
    expect(gateway.scanCalls, greaterThan(0));
    expect(find.byKey(const Key('dev-connect')), findsOneWidget);
    expect(find.text('JBL Speaker'), findsNothing);

    final nearY = tester.getTopLeft(find.text('DYJV2_NEAR')).dy;
    final midY = tester.getTopLeft(find.text('DYJV2_MID')).dy;
    final farY = tester.getTopLeft(find.text('DYJV2_FAR')).dy;
    expect(nearY < midY && midY < farY, isTrue, reason: '信号强的排上面');
  });

  testWidgets('连上后默认未录音；开关开始录音并正计时，关闭回未录音', (tester) async {
    final gateway = FakeCardGateway(initialSnapshot: _connected());
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    // 连接成功但还没录音：顶栏橙点（待机），状态行给开关而不是假装录音中
    expect(_dotColor(tester), RCColors.warn);
    expect(find.text('未录音'), findsOneWidget);
    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('录音中'), findsOneWidget);
    expect(find.byKey(const Key('rec-clock')), findsOneWidget);
    expect(_dotColor(tester), RCColors.ok, reason: '录音中才是绿点心跳');

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('00:00:02'), findsOneWidget);

    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未录音'), findsOneWidget);
    expect(find.byKey(const Key('rec-clock')), findsNothing);
    expect(_dotColor(tester), RCColors.warn, reason: '停止后回到橙色待机');
    // 用明确的 start/stop，而不是 toggle：状态不一致时 toggle 会把"开"变成"停"
    expect(gateway.recordCalls, ['start', 'stop']);
  });

  testWidgets('已连接设备层展示设备基本信息；停止录音只封口本地实时流，不自动蓝牙拉文件', (
    tester,
  ) async {
    final gateway = FakeCardGateway(initialSnapshot: _connected(recording: true));
    final device = DeviceStore(gateway: gateway);
    final store = _SyncSpy();
    final controller = RecordingStatusController();
    addTearDown(controller.dispose);
    await pumpShell(
      tester,
      store: store,
      device: device,
      recordingStatus: controller,
    );

    expect(controller.phase, RecordingPhase.recording);
    expect(store.syncCalls, 0);

    // 打开设备管理弹层：展示所连设备名称与固件信息
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    expect(find.text('DYJV2_TEST'), findsOneWidget);
    expect(find.textContaining('固件 2.2.0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();

    // 用户关掉录音 → 只收尾本地实时流，不再自动拉取录音卡上的 .APM 文件
    await device.toggleRecording();
    await tester.pump();
    await tester.pump();
    expect(store.syncCalls, 0, reason: '停止录音不应再自动触发蓝牙文件拉取');
    expect(controller.phase, RecordingPhase.idle);
  });

  testWidgets('同步状态提示互斥：顶部状态块激活时不叠加第二条 sync-banner', (
    tester,
  ) async {
    final gateway = FakeCardGateway(initialSnapshot: _connected(recording: false));
    final device = DeviceStore(gateway: gateway);
    final store = AppStore(events: const [], loadPersistedState: false);
    final controller = RecordingStatusController();
    addTearDown(controller.dispose);
    await pumpShell(
      tester,
      store: store,
      device: device,
      recordingStatus: controller,
    );

    // 模拟流水线同步进行中：store.syncStage 非空且顶部状态块处于 syncing
    store
      ..syncStage = SyncStage.listing
      ..syncProgress = 0.4
      ..syncText = '正在取回 TEST.APM（1/2）';
    controller.startSync(detail: '正在取回 TEST.APM（1/2）');
    store.notifyListeners();
    await tester.pump();

    expect(_statusBlock(), findsOneWidget);
    expect(find.text('正在同步'), findsOneWidget);
    expect(
      find.byKey(const Key('sync-banner')),
      findsNothing,
      reason: '顶部状态块已在展示同步进度时，不得同时出现冲突的 sync-banner',
    );
  });

  testWidgets('状态块只在全部/记录顶部；总结 Tab 和勾选态隐藏', (tester) async {
    final device = DeviceStore(
      gateway: FakeCardGateway(initialSnapshot: _connected(recording: true)),
    );
    await pumpShell(tester, device: device);

    expect(_statusBlock(), findsOneWidget);
    expect(find.text('正在录音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab-summary')));
    await tester.pump();
    expect(_statusBlock(), findsNothing);

    await tester.tap(find.byKey(const Key('tab-event')));
    await tester.pump();
    expect(_statusBlock(), findsOneWidget);

    // 勾选总结时也收起，保证总结源列表干净
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    expect(_statusBlock(), findsNothing);
  });
}
