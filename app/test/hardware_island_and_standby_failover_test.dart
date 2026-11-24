/// 硬件优先 + 统一灵动岛/锁屏实况 + 本机零功耗待命保底专项验收（2026-11-14）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _card = CardDevice(id: 'dev-v2', name: 'DYJV2_T4W25T', rssi: -48);

CardSnapshot _snap({bool recording = false}) => CardSnapshot(
  batteryLevel: 86,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '3.13',
  fwVersionCode: 313,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_T4W25T',
  deviceId: 'dev-v2',
);

class _RecordingLiveActivitySpy extends LiveActivityService {
  _RecordingLiveActivitySpy()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: true,
          supportsDynamicIsland: true,
          supportsActionButton: true,
          areActivitiesEnabled: true,
        ),
      );

  final List<String> subtitles = [];
  int stopCount = 0;

  @override
  Future<void> startRecordingActivity({
    required DateTime startedAt,
    String title = '录音卡',
    String subtitle = '本机录音运行中',
  }) async {
    subtitles.add(subtitle);
  }

  @override
  Future<void> stopLocalRecordingActivity() async {
    stopCount += 1;
  }
}

class _TrackingPhoneMicBackend implements PhoneMicBackend {
  _TrackingPhoneMicBackend({
    this.permission = PhoneMicPermission.granted,
  });

  PhoneMicPermission permission;
  bool capturing = false;
  int requestCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PhoneMicPermission> checkPermission() async => permission;

  @override
  Future<PhoneMicPermission> requestPermission() async {
    requestCalls += 1;
    permission = PhoneMicPermission.granted;
    return permission;
  }

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    startCalls += 1;
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls += 1;
    capturing = false;
  }
}

void main() {
  testWidgets('1. 未连硬件展示独立本机录音行；已连硬件隐藏本机录音行，硬件录音点亮灵动岛实况且不双端并行耗电', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-standby-ui-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final gw = FakeCardGateway(devices: const [_card]);
    final mic = _TrackingPhoneMicBackend(
      permission: PhoneMicPermission.notDetermined,
    );
    final liveAct = _RecordingLiveActivitySpy();
    final device = DeviceStore(
      gateway: gw,
      phoneMicBackend: mic,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: liveAct,
    );

    await pumpShell(tester, device: device);

    // 未连接态弹层展示独立「本机录音」行
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-connect')), findsOneWidget);
    expect(find.byKey(const Key('phone-rec-row')), findsOneWidget);

    // 连接硬件后，隐藏「本机录音」行，仅保留硬件「录音状态」开关
    gw.current = _snap(recording: false);
    await tester.tap(find.byKey(const Key('dev-item-dev-v2')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.byKey(const Key('phone-rec-row')), findsNothing);
    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);

    // 打开硬件蓝牙录音：点亮灵动岛/锁屏实况 + 预热麦克风授权 + 挂起零功耗待命（手机麦克风不采集）
    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump();
    expect(device.isRecording, isTrue);
    expect(device.isPhoneStandbyArmed, isTrue);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.capturing, isFalse, reason: '蓝牙正常录音期间手机麦克风绝不并行采集');
    expect(mic.requestCalls, 1, reason: '前台开录预检麦克风权限供后续后台断连保底使用');
    expect(liveAct.subtitles, isNotEmpty);
    expect(liveAct.subtitles.last, contains('蓝牙录音中'));

    // 用户手动关闭硬件录音：解除待命并关闭灵动岛实况，不自动开启本机录音
    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump();
    expect(device.isRecording, isFalse);
    expect(device.isPhoneStandbyArmed, isFalse);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.startCalls, 0);
    expect(liveAct.stopCount, greaterThanOrEqualTo(1));
  });

  testWidgets('2. 蓝牙硬件意外断连（失联/没电/丢失）自动开启本机保底录音；手动安全断开不触发', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-failover-drop-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final gw = FakeCardGateway(
      initialSnapshot: _snap(recording: false),
      devices: const [_card],
    );
    final mic = _TrackingPhoneMicBackend();
    final liveAct = _RecordingLiveActivitySpy();
    final recStatus = RecordingStatusController();
    addTearDown(recStatus.dispose);

    final device = DeviceStore(
      gateway: gw,
      autoStart: true,
      phoneMicBackend: mic,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: liveAct,
    );

    await device.connectTo(_card);
    await pumpShell(tester, device: device, recordingStatus: recStatus);

    // 开启硬件录音（待命保底已挂起，手机麦克风未运行）
    await device.toggleRecording();
    await tester.pump();
    expect(device.isRecording, isTrue);
    expect(device.isPhoneStandbyArmed, isTrue);
    expect(device.isPhoneRecording, isFalse);
    expect(recStatus.phase, RecordingPhase.recording);

    // 发生意外断连（具备板载存储的硬件先快速直连重连，不立即抢启手机麦克风）
    gw.failConnect = CardException.disconnected('设备超出范围');
    gw.pushDisconnectedEvent();
    await device.pollEventsNow();
    await tester.pump();
    expect(device.linkState, LinkState.reconnecting);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.capturing, isFalse);

    // 快速直连重连确认失败落回未连接态后：再拉起手机本机保底，顶栏胶囊展示「本机录音」，Timeline 录音块不中断，灵动岛切换为保底实况
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(device.linkState, LinkState.disconnected);
    expect(device.isPhoneRecording, isTrue);
    expect(device.isFailoverPhoneRecording, isTrue);
    expect(mic.capturing, isTrue);
    expect(recStatus.phase, RecordingPhase.recording);
    expect(find.byKey(const Key('capsule-phone-rec')), findsOneWidget);
    expect(liveAct.subtitles.last, contains('本机保底录音中'));

    // 硬件恢复供电/回到身边并重新连接（硬件本身仍在录音）：自动停掉手机麦克风退回零功耗待命
    gw.failConnect = null;
    gw.current = _snap(recording: true);
    await device.connectTo(_card);
    await tester.pump();
    expect(device.isConnected, isTrue);
    expect(device.isRecording, isTrue);
    expect(device.isPhoneRecording, isFalse);
    expect(device.isPhoneStandbyArmed, isTrue);
    expect(mic.capturing, isFalse);
    expect(liveAct.subtitles.last, contains('蓝牙录音中'));

    // 用户手动点击安全断开连接：停止硬件录音并解除待命，绝不触发本机保底录音
    await device.disconnectSafely();
    await tester.pump();
    expect(device.isConnected, isFalse);
    expect(device.isPhoneStandbyArmed, isFalse);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.capturing, isFalse);
  });

  testWidgets('3. 瞬时蓝牙抖动重连成功自动退回零功耗待命；硬件故障报错自停同样触发本机保底；连卡前本机录音自动交接给硬件', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-handover-cases-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final gw = FakeCardGateway(
      initialSnapshot: _snap(recording: false),
      devices: const [_card],
    );
    final mic = _TrackingPhoneMicBackend();
    final liveAct = _RecordingLiveActivitySpy();
    final device = DeviceStore(
      gateway: gw,
      phoneMicBackend: mic,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: liveAct,
    );
    addTearDown(device.dispose);

    // A) 未连硬件时开启独立「本机录音」→ 随后连接待机硬件：自动将录音交接给硬件并停掉手机麦克风
    await device.startPhoneRecording();
    expect(device.isPhoneRecording, isTrue);
    expect(mic.capturing, isTrue);

    await device.connectTo(_card);
    expect(device.isConnected, isTrue);
    expect(device.isRecording, isTrue, reason: '连接硬件后自动接管正在进行的录音');
    expect(device.isPhoneRecording, isFalse, reason: '已连硬件后关闭手机高功耗麦克风');
    expect(device.isPhoneStandbyArmed, isTrue);
    expect(mic.capturing, isFalse);

    // B) 瞬时断连但 400ms 重连成功（硬件仍在录）：硬件本地可持续存储，瞬时重连期间不误启手机麦克风
    gw.pushDisconnectedEvent();
    await device.pollEventsNow();
    await tester.pump();
    expect(device.linkState, LinkState.reconnecting);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.capturing, isFalse);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(device.linkState, LinkState.connected);
    expect(device.isRecording, isTrue);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.capturing, isFalse);
    expect(mic.startCalls, 1, reason: '整个瞬时断连→重连过程不应新增启动手机麦克风');
    expect(device.isPhoneStandbyArmed, isTrue);

    // C) 硬件端上报故障错误码自停（如 SD 卡异常 error=2）：自动触发本机录音保底防丢
    gw.pushRecordError(code: 2);
    await device.pollEventsNow();
    await tester.pump();
    expect(device.isRecording, isFalse);
    expect(device.isPhoneRecording, isTrue);
    expect(device.isFailoverPhoneRecording, isTrue);
    expect(mic.capturing, isTrue);
    expect(device.recordingError, contains('错误码 2'));

    await device.stopPhoneRecording();
  });
}
