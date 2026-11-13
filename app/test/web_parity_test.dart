// 与官方 web 控制台（reai-card-sdk `examples/dyj_web.rs` + `dyj_web.html`）对齐的回归。
//
// 参考实现已经在这台机器上连真卡跑通（扫描/连接/状态/电池/存储），App 这边逐条对齐；
// 每条用例对应一处真实差异，修复前必须是红的。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';

import 'support/fake_gateway.dart';
import 'support/fake_recordings.dart';
import 'support/harness.dart';

const _card = CardDevice(id: 'dev-1', name: 'DYJV2_TEST', rssi: -50);

CardSnapshot _snap({bool recording = false, int battery = 80}) => CardSnapshot(
  batteryLevel: battery,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_TEST',
  deviceId: 'dev-1',
);

void main() {
  test('STORAGE：SDK 只回 total/used，free 必须由差值推出', () {
    final snap = CardSnapshot.fromJson({
      'battery': {'level': 67},
      'state': {'wifiOpen': false},
      'info': {},
      'storage': {'total': 7373, 'used': 569},
      'record': {'isRecording': false},
    });

    expect(snap.storageTotalMb, 7373);
    expect(snap.storageFreeMb, 6804, reason: '7373 - 569；SDK 没有 free 字段');
  });

  testWidgets('电量读不到时显示未知，不把 0 冒充成 1%', (tester) async {
    final gw = FakeCardGateway(initialSnapshot: _snap(battery: 0));
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);

    await store.restoreLink();

    expect(store.batteryKnown, isFalse, reason: '没读到 level 就是未知');
    expect(store.batteryLevelText, '未知');
  });

  test('BATTERY 字段缺失 → hasBattery=false，不冒充电量', () {
    final snap = CardSnapshot.fromJson({
      'state': {'wifiOpen': false},
      'record': {'isRecording': false},
    });

    expect(snap.hasBattery, isFalse);
    expect(snap.batteryLevel, 0);
  });

  testWidgets('快照部分失败：读不到电量时保留上次值，不抹成未知', (tester) async {
    final gw = FakeCardGateway(initialSnapshot: _snap(battery: 82));
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.restoreLink();
    expect(store.battery, 82);

    // 下一次快照丢了 BATTERY（部分失败）：已知电量必须留住
    gw.current = CardSnapshot.fromJson({'record': {'isRecording': false}});
    await store.refreshFromDevice();

    expect(store.batteryKnown, isTrue, reason: '单次查询失败不该清掉已知状态');
    expect(store.battery, 82);
    expect(store.fwVersion, '2.2.0', reason: '部分失败也不该清掉固件版本');
    // 注意这里没有预取过 ota 信息（_otaMainInfo 为 null）→ fwAvailable 恒 false；
    // 这条断言锚的是 fwVersionCode 不被抹成 0：一旦被抹，预取后就会误报「有可用更新」
    expect(store.fwVersionCode, 22);
  });

  testWidgets('连接返回空快照：仍然算已连接，并补一次状态读取', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _snap(),
      devices: const [_card],
      // 真实桥在 connect 里只回 connected，不预拉状态
      connectReturnsSnapshot: false,
    );
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);

    await store.startScan();
    await store.connectTo(store.discovered.single);
    expect(store.linkState, LinkState.connected);

    await tester.pump();
    expect(gw.snapshotCalls, greaterThan(0), reason: '连上后必须自己补一次状态');
    expect(store.batteryKnown, isTrue);
    expect(store.battery, 80);
  });

  testWidgets('固件第二阶段：主控 DFU 后必须重新 connect 才能进第二阶段', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _snap(),
      devices: const [_card],
      connectResult: _snap(),
      mainOta: const CardOtaInfo(
        version: '2.3.0',
        versionCode: 23,
        url: 'https://ota.invalid/main.zip',
      ),
      wifiOta: const CardOtaInfo(
        version: '1.6.0',
        versionCode: 16,
        url: 'https://ota.invalid/wifi.bin',
      ),
      mainProgress: const [
        CardProgress(stage: 'dfu', percent: 50, text: '写入主控'),
      ],
      wifiProgress: const [
        CardProgress(stage: 'wifi', percent: 100, text: '写入 Wi-Fi'),
      ],
      // 主控 DFU 完成后设备复位，旧快照/句柄失效
      clearAfterMainOta: true,
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.restoreLink();

    final done = store.startFwUpdate();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    await done;

    expect(store.fwStage, FwStage.done, reason: '主控升级后应能重连并完成 Wi-Fi 阶段');
    expect(gw.callLog, contains('ota.wifi'));
    // restoreLink 不走 connect；这一次 connect 必须发生在主控 DFU 之后（第二阶段重连）
    expect(
      gw.callLog.indexOf('connect'),
      greaterThan(gw.callLog.indexOf('ota.main')),
      reason: 'DFU 后必须重新 connect，不能只 scan',
    );
  });

  testWidgets('设备推送录音错误码：弹层要给出原因，不能静默', (tester) async {
    final gw = FakeCardGateway(initialSnapshot: _snap());
    final device = DeviceStore(gateway: gw);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    gw.pushRecordError(code: -2);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(device.recordingError, contains('-2'));
    expect(find.byKey(const Key('rec-error')), findsOneWidget);
  });

  testWidgets('录音中不允许升级固件：拒绝并说明，不进 DFU', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: _snap(recording: true),
      devices: const [_card],
      mainProgress: const [
        CardProgress(stage: 'dfu', percent: 10, text: '写入主控'),
      ],
      progressDelay: Duration.zero,
    );
    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.restoreLink();
    expect(store.isRecording, isTrue);

    await store.startFwUpdate();

    expect(store.fwUpdating, isFalse);
    expect(store.fwStage, FwStage.idle, reason: '不该进入升级流程');
    expect(store.fwError, contains('停止录音'));
    expect(gw.callLog, isNot(contains('ota.main')), reason: '不能带着录音进 DFU');
  });

  testWidgets('停止录音：立即关实时流且不自动拉取文件，手动补同步在关流之后执行', (tester) async {
    final gw = FakeCardGateway(initialSnapshot: _snap(), devices: const [_card]);
    final sync = await FakeRecordingSync.create(result: const [], callLog: gw.callLog);
    final store = AppStore(
      events: const [],
      recordings: sync,
      loadPersistedState: false,
    );
    final device = DeviceStore(gateway: gw);
    await device.startScan();
    await device.connectTo(device.discovered.single);
    final live = _FakeLiveAudio(gw);

    await pumpShell(tester, store: store, device: device, liveAudio: live);
    await device.toggleRecording(); // 开始
    await tester.pump();
    await device.toggleRecording(); // 停止 → 仅收尾实时流，不自动拉取设备文件
    await tester.pump();

    final close = gw.callLog.indexOf('realtime.close');
    expect(close, isNonNegative, reason: '停止录音必须关实时开关');
    expect(gw.callLog.indexOf('sync'), -1, reason: '停止录音不应自动触发 BLE 文件同步');

    await store.syncRecordings(); // 手动补传离线录音
    await tester.pump();
    final started = gw.callLog.indexOf('sync');
    expect(started, greaterThan(close), reason: '手动取文件前实时流已关闭');
  });
}

/// 不碰磁盘的实时流替身：只记录开/关顺序。
///
/// widget 测试里真实 [LiveAudioRecorder] 要建目录/开文件，假时钟下会等不到 IO；
/// 这两条用例验证的是「外壳与设备命令的先后顺序」，不需要真的落音频。
class _FakeLiveAudio extends LiveAudioRecorder {
  _FakeLiveAudio(this.gw) : super(gateway: gw);

  final FakeCardGateway gw;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    gw.realtimeOpenCalls++;
    gw.callLog.add('realtime.open');
  }

  @override
  Future<LiveSession?> stop() async {
    if (!_running) return null;
    _running = false;
    gw.realtimeCloseCalls++;
    gw.callLog.add('realtime.close');
    return null;
  }
}
