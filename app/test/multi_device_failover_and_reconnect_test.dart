import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/platform/local_notification_service.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _bleCard = CardDevice(id: 'dev-v2', name: 'DYJV2_T4W25T', rssi: -45);

CardSnapshot _bleSnap({bool recording = false}) => CardSnapshot(
  batteryLevel: 85,
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

class _SpyLiveActivityService extends LiveActivityService {
  _SpyLiveActivityService()
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

class _SpyLocalNotificationBackend implements LocalNotificationBackend {
  final List<({String id, String title, String body, bool urgent})> sent = [];
  int cancelCalls = 0;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> notify({
    required String id,
    required String title,
    required String body,
    bool urgent = false,
  }) async {
    sent.add((id: id, title: title, body: body, urgent: urgent));
    return true;
  }

  @override
  Future<void> cancel(String id) async {
    cancelCalls++;
  }
}

class _ConfigurablePhoneMicBackend implements PhoneMicBackend {
  PhoneMicPermission permission = PhoneMicPermission.granted;
  Object? nextStartError;
  bool capturing = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PhoneMicPermission> checkPermission() async => permission;

  @override
  Future<PhoneMicPermission> requestPermission() async => permission;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    startCalls++;
    if (nextStartError != null) {
      throw nextStartError!;
    }
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls++;
    capturing = false;
  }
}

void main() {
  testWidgets(
    'Test A: OSStatus 560557684 后台受限不报原始错误，挂起待接力发紧急通知并切回前台零点击恢复',
    (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-560557684-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: _bleSnap(recording: false),
        devices: const [_bleCard],
      );
      final mic = _ConfigurablePhoneMicBackend();
      final notifBackend = _SpyLocalNotificationBackend();
      final liveAct = _SpyLiveActivityService();

      final device = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: mic,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveAct,
        localNotifications: LocalNotificationService(backend: notifBackend),
      );

      await device.connectTo(_bleCard);
      await pumpShell(tester, device: device);
      await device.toggleRecording();
      await tester.pump();
      expect(device.isRecording, isTrue);
      expect(device.isPhoneStandbyArmed, isTrue);

      // 模拟 App 在后台触发蓝牙掉线，iOS 拒绝启动后台音频会话并返回 OSStatus 560557684
      mic.nextStartError = PlatformException(
        code: 'phone_mic_start_failed',
        message: '未能完成操作。（OSStatus错误560557684。）',
      );
      gw.failConnect = CardException.disconnected('超出距离');
      gw.pushDisconnectedEvent();
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(device.isPhoneRecording, isFalse);
      expect(device.isPendingForegroundPhoneFailover, isTrue);
      expect(device.isPhoneStandbyArmed, isTrue);
      expect(device.phoneRecordingError, isNotNull);
      expect(device.phoneRecordingError!.contains('560557684'), isFalse);
      expect(device.phoneRecordingError!.contains('PlatformException'), isFalse);
      expect(notifBackend.sent, isNotEmpty);
      expect(notifBackend.sent.last.urgent, isTrue);
      expect(liveAct.subtitles.last, contains('轻点打开恢复本机录音'));
      expect(find.byKey(const Key('capsule-failover-pending')), findsOneWidget);
      expect(find.byKey(const Key('ble-disconnect-toast')), findsOneWidget);

      // 用户点击通知或切回前台：立即零点击自动启动手机本机录音
      mic.nextStartError = null;
      device.handleAppResumed();
      await tester.pump();
      await tester.pump();

      expect(device.isPhoneRecording, isTrue);
      expect(device.isFailoverPhoneRecording, isTrue);
      expect(device.isPendingForegroundPhoneFailover, isFalse);
      expect(mic.capturing, isTrue);
      expect(find.byKey(const Key('capsule-phone-rec')), findsOneWidget);

      await device.stopPhoneRecording();
      device.dispose();
    },
  );

  testWidgets(
    'Test B & C: BLE -> Apple Watch -> 手机本机级联兜底，双路严格上限 <=2 且 Watch/手机互斥',
    (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-cascade-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: _bleSnap(recording: false),
        devices: const [_bleCard],
      );
      final mic = _ConfigurablePhoneMicBackend();
      final notifBackend = _SpyLocalNotificationBackend();
      final liveAct = _SpyLiveActivityService();
      final watchBackend = FakeWatchBridgeBackend(
        initialStatus: const WatchBridgeStatus(
          supported: true,
          paired: true,
          watchAppInstalled: true,
          reachable: true,
          watchName: '我的手表 S10',
        ),
      );
      final watchSvc = WatchHardwareService(backend: watchBackend);
      addTearDown(watchSvc.dispose);
      await watchSvc.setLinkEnabled(true);

      final device = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: mic,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveAct,
        localNotifications: LocalNotificationService(backend: notifBackend),
        watchHardware: watchSvc,
      );

      await device.connectTo(_bleCard);
      await pumpShell(tester, device: device);
      await device.setWatchLinkEnabled(true);
      await tester.pump();
      await device.toggleRecording();
      await tester.pump();
      expect(device.activeRecordingLaneCount, 1);

      // 1) BLE 断开且 Watch 在场：优先启动 Watch 接力（手机不启）
      gw.failConnect = CardException.disconnected('超出蓝牙距离');
      gw.pushDisconnectedEvent();
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(device.isWatchFallbackRecording, isTrue);
      expect(device.isPhoneRecording, isFalse);
      expect(device.activeRecordingLaneCount, 1);
      expect(mic.capturing, isFalse);
      expect(device.disconnectNotice, contains('Apple Watch'));
      expect(notifBackend.sent.last.body, contains('Apple Watch'));
      expect(liveAct.subtitles.last, contains('Apple Watch 接力录音中'));
      expect(find.byKey(const Key('capsule-watch-rec')), findsOneWidget);

      // 2) 打开弹层验证 Watch/手机互斥展示
      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      expect(find.byKey(const Key('ble-disconnect-banner')), findsOneWidget);
      expect(find.byKey(const Key('watch-failover-row')), findsOneWidget);
      expect(find.byKey(const Key('phone-rec-row')), findsNothing);

      // 3) 若用户手动切本机或 Watch 也失联：Watch -> Phone 无缝级联接力，且总路数 <= 2
      watchBackend.simulateUnexpectedDisconnect();
      await tester.pump();
      await tester.pump();

      expect(device.isWatchFallbackRecording, isFalse);
      expect(device.isPhoneRecording, isTrue);
      expect(device.activeRecordingLaneCount, 1);
      expect(device.activeRecordingLaneCount <= 2, isTrue);
      expect(mic.capturing, isTrue);

      await device.stopPhoneRecording();
      device.dispose();
    },
  );

  testWidgets(
    'Test D: 主动关停录音 / 安全断开 / 退出登录不触发兜底且不挂起后台重连',
    (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-explicit-stop-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: _bleSnap(recording: false),
        devices: const [_bleCard],
      );
      final mic = _ConfigurablePhoneMicBackend();
      final device = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: mic,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      );

      await device.connectTo(_bleCard);
      await device.toggleRecording();
      expect(device.isRecording, isTrue);

      // 1) 手动关录音
      await device.toggleRecording();
      expect(device.isRecording, isFalse);
      expect(device.isPhoneRecording, isFalse);
      expect(device.isWatchFallbackRecording, isFalse);
      expect(device.isBackgroundReconnectArmed, isFalse);

      // 2) 再开录后安全断开
      await device.toggleRecording();
      await device.disconnectSafely();
      expect(device.isPhoneRecording, isFalse);
      expect(device.isWatchFallbackRecording, isFalse);
      expect(device.isBackgroundReconnectArmed, isFalse);

      // 3) 退出登录收口
      await device.connectTo(_bleCard);
      await device.toggleRecording();
      await device.stopAllRecordingsForSignOut();
      expect(device.isRecording, isFalse);
      expect(device.isPhoneRecording, isFalse);
      expect(device.isBackgroundReconnectArmed, isFalse);
      expect(mic.capturing, isFalse);
      device.dispose();
    },
  );

  testWidgets(
    'Test E: 后台自动重连成功后停用伴随兜底并按录音状态触发或延后离线数据拉取同步',
    (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-autorec-sync-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: _bleSnap(recording: false),
        devices: const [_bleCard],
      );
      final mic = _ConfigurablePhoneMicBackend();
      final notifBackend = _SpyLocalNotificationBackend();
      final device = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: mic,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        localNotifications: LocalNotificationService(backend: notifBackend),
        backgroundReconnectDelays: const [Duration(seconds: 5)],
      );
      addTearDown(device.dispose);

      var syncCallbackCalls = 0;
      device.onBleReconnectedNeedSync = (_) async => syncCallbackCalls++;

      await device.connectTo(_bleCard);
      await device.toggleRecording();
      expect(device.isRecording, isTrue);

      // 掉线并进入手机保底
      gw.failConnect = CardException.disconnected('暂时离开蓝牙范围');
      gw.pushDisconnectedEvent();
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(device.linkState, LinkState.disconnected);
      expect(device.isPhoneRecording, isTrue);
      expect(device.isBackgroundReconnectArmed, isTrue);

      // 情形 1：设备回到范围，且恢复连接后继续实时流录音 -> 停掉本机麦克风，登记 _pendingPostReconnectSync 供停录后拉离线文件
      gw.failConnect = null;
      gw.current = _bleSnap(recording: true);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      expect(device.isConnected, isTrue);
      expect(device.isRecording, isTrue);
      expect(device.isPhoneRecording, isFalse);
      expect(device.activeRecordingLaneCount, 1);
      expect(device.consumePendingPostReconnectSync(), isTrue);
      expect(syncCallbackCalls, 0);
      expect(notifBackend.sent.last.title, contains('已重新连接'));

      // 情形 2：停止录音处于待机态后断线重连（未在实时流录音） -> 立即触发 onBleReconnectedNeedSync
      await device.toggleRecording();
      await tester.pump();
      expect(device.isRecording, isFalse);

      gw.failConnect = CardException.disconnected('休眠重连测试');
      gw.pushDisconnectedEvent();
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      gw.failConnect = null;
      gw.current = _bleSnap(recording: false);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      expect(device.isConnected, isTrue);
      expect(device.isRecording, isFalse);
      expect(syncCallbackCalls, 1);

      await device.disconnectSafely();
      device.dispose();
    },
  );
}
