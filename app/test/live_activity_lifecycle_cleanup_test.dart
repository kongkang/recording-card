/// 灵动岛与锁屏实况全生命周期兜底清理专项回归测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _v2Card = CardDevice(id: 'dev-v2', name: 'DYJV2_T4W25T', rssi: -45);
const _passiveBleCard = CardDevice(
  id: 'dev-passive',
  name: 'OMICV1_01',
  rssi: -50,
  kind: DeviceKind.omiCv1,
  capabilities: HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: false,
    hasFileSync: false,
    hasWifiConfig: false,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: false,
    hasMarkButton: false,
    otaMode: 'none',
  ),
);

CardSnapshot _snap({
  bool recording = false,
  DeviceKind kind = DeviceKind.cardV2,
  HardwareCapabilities? caps,
}) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '3.13',
  fwVersionCode: 313,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: kind == DeviceKind.omiCv1 ? 'OMICV1_01' : 'DYJV2_T4W25T',
  deviceId: kind == DeviceKind.omiCv1 ? 'dev-passive' : 'dev-v2',
  deviceKind: kind,
  capabilities: caps,
);

class _SpyLiveActivity extends LiveActivityService {
  _SpyLiveActivity({
    this.activeState = const ActiveLiveActivityState.inactive(),
  }) : super(
         capabilitiesOverride: const LiveActivityCapabilities(
           supportsLiveActivities: true,
           supportsDynamicIsland: true,
           supportsActionButton: true,
           areActivitiesEnabled: true,
         ),
       );

  ActiveLiveActivityState activeState;
  final List<({String title, String subtitle})> starts = [];
  int stopCount = 0;

  @override
  Future<ActiveLiveActivityState> queryActiveActivity() async => activeState;

  @override
  Future<void> startRecordingActivity({
    required DateTime startedAt,
    String title = '录音卡',
    String subtitle = '本机录音运行中',
  }) async {
    starts.add((title: title, subtitle: subtitle));
  }

  @override
  Future<void> stopLocalRecordingActivity() async {
    stopCount += 1;
    activeState = const ActiveLiveActivityState.inactive();
  }
}

class _ConfigurableMicBackend implements PhoneMicBackend {
  PhoneMicPermission permission = PhoneMicPermission.granted;
  Object? nextStartError;
  bool capturing = false;

  @override
  Future<PhoneMicPermission> checkPermission() async => permission;

  @override
  Future<PhoneMicPermission> requestPermission() async => permission;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    if (nextStartError != null) {
      throw nextStartError!;
    }
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    capturing = false;
  }
}

String _repoRoot() {
  final cwd = Directory.current.path;
  if (cwd.endsWith('/app') || cwd.endsWith(r'\app')) {
    return Directory.current.parent.path;
  }
  return cwd;
}

File _repoFile(String relPath) => File('${_repoRoot()}/$relPath');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. 未录音离开 App 清理灵动岛且同轮后台去重', () {
    testWidgets('未连设备未录音：hidden -> paused 仅清理 1 次，回前台再离 App 再清理 1 次', (
      tester,
    ) async {
      final liveAct = _SpyLiveActivity();
      final device = DeviceStore(
        gateway: FakeCardGateway(),
        liveActivityService: liveAct,
      );
      await pumpShell(tester, device: device);
      expect(liveAct.stopCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(liveAct.stopCount, 1);

      // 同一轮离场连续触发 hidden -> paused 不重复发送 stop
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(liveAct.stopCount, 1);

      // 回到前台后再次离开 App，可再次兜底清理
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(liveAct.stopCount, 2);
    });

    testWidgets('已连硬件但未录音（recording=false）：离开 App 触发清理灵动岛', (
      tester,
    ) async {
      final gw = FakeCardGateway(
        initialSnapshot: _snap(recording: false),
        devices: const [_v2Card],
      );
      final liveAct = _SpyLiveActivity();
      final device = DeviceStore(gateway: gw, liveActivityService: liveAct);

      await device.connectTo(_v2Card);
      await pumpShell(tester, device: device);
      expect(device.isConnected, isTrue);
      expect(device.isRecording, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(liveAct.stopCount, 1);
    });
  });

  group('2. 录音中离开 App 保留灵动岛实况', () {
    testWidgets('本机录音中 / 蓝牙硬件录音中 / 手表保底录音中切后台不关闭灵动岛', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-la-keep-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      // A) 本机录音中
      final micA = _ConfigurableMicBackend();
      final liveA = _SpyLiveActivity();
      final devA = DeviceStore(
        gateway: FakeCardGateway(),
        phoneMicBackend: micA,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveA,
      );
      await pumpShell(tester, device: devA);
      expect(await devA.startPhoneRecording(), isTrue);
      expect(liveA.stopCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(liveA.stopCount, 0);
      await devA.stopPhoneRecording();

      // B) 蓝牙硬件录音中
      final gwB = FakeCardGateway(
        initialSnapshot: _snap(recording: false),
        devices: const [_v2Card],
      );
      final liveB = _SpyLiveActivity();
      final devB = DeviceStore(
        gateway: gwB,
        phoneMicBackend: _ConfigurableMicBackend(),
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveB,
      );
      await devB.connectTo(_v2Card);
      await pumpShell(tester, device: devB);
      await devB.toggleRecording();
      expect(devB.isRecording, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(liveB.stopCount, 0);
      await devB.toggleRecording();

      // C) 手表保底录音中
      final gwC = FakeCardGateway(
        initialSnapshot: _snap(recording: false),
        devices: const [_v2Card],
      );
      final liveC = _SpyLiveActivity();
      final watchBackend = FakeWatchBridgeBackend(
        initialStatus: const WatchBridgeStatus(
          supported: true,
          paired: true,
          watchAppInstalled: true,
          reachable: true,
          watchName: '我的手表',
        ),
      );
      final watchSvc = WatchHardwareService(backend: watchBackend);
      addTearDown(watchSvc.dispose);
      await watchSvc.setLinkEnabled(true);
      final devC = DeviceStore(
        gateway: gwC,
        autoStart: true,
        phoneMicBackend: _ConfigurableMicBackend(),
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveC,
        watchHardware: watchSvc,
      );
      await devC.connectTo(_v2Card);
      await pumpShell(tester, device: devC);
      await devC.toggleRecording();
      gwC.failConnect = CardException.disconnected('超出蓝牙距离');
      gwC.pushDisconnectedEvent();
      await devC.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(devC.isWatchFallbackRecording, isTrue);
      final stopsBeforeBg = liveC.stopCount;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(liveC.stopCount, stopsBeforeBg);
      await devC.stopWatchFailoverRecording();
      devC.dispose();
    });
  });

  group('3. 停录、断连保底失败、重连空闲、关闭提示与 Watch 停录收口', () {
    testWidgets('硬件掉线且保底启动抛出非可重试错（phone_mic_start_failed）立刻停止灵动岛', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-la-fail-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: _snap(recording: false),
        devices: const [_v2Card],
      );
      final mic = _ConfigurableMicBackend();
      final liveAct = _SpyLiveActivity();
      final device = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: mic,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveAct,
      );

      await device.connectTo(_v2Card);
      await pumpShell(tester, device: device);
      await device.toggleRecording();
      expect(device.isRecording, isTrue);
      expect(liveAct.stopCount, 0);

      mic.nextStartError = PlatformException(
        code: 'phone_mic_start_failed',
        message: '麦克风输入格式不可用',
      );
      gw.failConnect = CardException.disconnected('超出距离');
      gw.pushDisconnectedEvent();
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(device.isPhoneRecording, isFalse);
      expect(device.isPendingForegroundPhoneFailover, isFalse);
      expect(liveAct.stopCount, greaterThanOrEqualTo(1));
      device.dispose();
    });

    test('LiveActivityService 经 MethodChannel 发送正确的 isRecording 标记', () async {
      const channel = MethodChannel('com.reai.recordingcard/live_activity_unit');
      final startPayloads = <Map<Object?, Object?>>[];
      var stopCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          startPayloads.add(call.arguments as Map<Object?, Object?>);
        } else if (call.method == 'stop') {
          stopCalls += 1;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final svc = LiveActivityService(channel: channel);
      final now = DateTime(2026, 11, 23, 1, 0);

      await svc.startLocalRecordingActivity(startedAt: now);
      await svc.startHardwareRecordingActivity(
        startedAt: now,
        deviceLabel: 'V2',
      );
      await svc.startPendingFailoverRecordingActivity(startedAt: now);
      // 下一次普通启动必须自动恢复为 isRecording: true
      await svc.startFailoverRecordingActivity(startedAt: now);
      await svc.stopLocalRecordingActivity();

      expect(startPayloads.length, 4);
      expect(startPayloads[0]['isRecording'], isTrue);
      expect(startPayloads[1]['isRecording'], isTrue);
      expect(startPayloads[2]['isRecording'], isFalse);
      expect(startPayloads[2]['subtitle'], contains('轻点打开恢复本机录音'));
      expect(startPayloads[3]['isRecording'], isTrue);
      expect(stopCalls, 1);
    });

    testWidgets('560557684 pendingFailover 下重连空闲硬件 / dismissDisconnectNotice / 切后台 / stopPhoneRecording 均停止灵动岛', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-la-pending-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      Future<DeviceStore> setupPendingDevice(_SpyLiveActivity liveAct) async {
        final gw = FakeCardGateway(
          initialSnapshot: _snap(recording: false),
          devices: const [_v2Card],
        );
        final mic = _ConfigurableMicBackend();
        final device = DeviceStore(
          gateway: gw,
          autoStart: true,
          phoneMicBackend: mic,
          phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
          liveActivityService: liveAct,
        );
        await device.connectTo(_v2Card);
        await device.toggleRecording();
        mic.nextStartError = PlatformException(
          code: 'phone_mic_background_restricted',
          message: 'OSStatus 560557684',
        );
        gw.failConnect = CardException.disconnected('超出距离');
        gw.pushDisconnectedEvent();
        await device.pollEventsNow();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(device.isPendingForegroundPhoneFailover, isTrue);
        return device;
      }

      // 1) 重连到不支持远程启录的空闲设备（handoff 跳过且硬件未录）-> 清除 pending 并停止灵动岛
      final live1 = _SpyLiveActivity();
      final gw1 = FakeCardGateway(
        initialSnapshot: _snap(recording: false),
        devices: const [_v2Card, _passiveBleCard],
      );
      final mic1 = _ConfigurableMicBackend();
      final dev1 = DeviceStore(
        gateway: gw1,
        autoStart: true,
        phoneMicBackend: mic1,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: live1,
      );
      addTearDown(dev1.dispose);
      await dev1.connectTo(_v2Card);
      await dev1.toggleRecording();
      mic1.nextStartError = PlatformException(
        code: 'phone_mic_background_restricted',
        message: 'OSStatus 560557684',
      );
      gw1.failConnect = CardException.disconnected('超出距离');
      gw1.pushDisconnectedEvent();
      await dev1.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(dev1.isPendingForegroundPhoneFailover, isTrue);

      gw1.failConnect = null;
      gw1.current = _snap(
        recording: false,
        kind: DeviceKind.omiCv1,
        caps: _passiveBleCard.capabilities,
      );
      await dev1.connectTo(_passiveBleCard);
      expect(dev1.isPendingForegroundPhoneFailover, isFalse);
      expect(live1.stopCount, greaterThanOrEqualTo(1));
      dev1.dispose();

      // 2) 用户关闭断连提示条 -> 清除 pending 并停止灵动岛
      final live2 = _SpyLiveActivity();
      final dev2 = await setupPendingDevice(live2);
      final stopsBeforeDismiss = live2.stopCount;
      dev2.dismissDisconnectNotice();
      expect(dev2.isPendingForegroundPhoneFailover, isFalse);
      expect(live2.stopCount, stopsBeforeDismiss + 1);
      dev2.dispose();

      // 3) pendingFailover 下直接离开 App 切后台 -> 立即停止灵动岛
      final live3 = _SpyLiveActivity();
      final dev3 = await setupPendingDevice(live3);
      final stopsBeforeBg = live3.stopCount;
      dev3.handleAppBackgrounded();
      expect(live3.stopCount, stopsBeforeBg + 1);
      dev3.dispose();

      // 4) stopPhoneRecording 在 !_phoneRecording && _pendingPhoneFailover 时仍停止灵动岛
      final live4 = _SpyLiveActivity();
      final dev4 = await setupPendingDevice(live4);
      final stopsBeforeStop = live4.stopCount;
      await dev4.stopPhoneRecording();
      expect(dev4.isPendingForegroundPhoneFailover, isFalse);
      expect(live4.stopCount, stopsBeforeStop + 1);
      dev4.dispose();
    });

    testWidgets('手表保底停止时即使蓝牙已连（未录音）仍停止灵动岛', (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-la-watch-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: _snap(recording: false),
        devices: const [_v2Card, _passiveBleCard],
      );
      final liveAct = _SpyLiveActivity();
      final watchBackend = FakeWatchBridgeBackend(
        initialStatus: const WatchBridgeStatus(
          supported: true,
          paired: true,
          watchAppInstalled: true,
          reachable: true,
          watchName: '我的手表',
        ),
      );
      final watchSvc = WatchHardwareService(backend: watchBackend);
      addTearDown(watchSvc.dispose);
      await watchSvc.setLinkEnabled(true);

      final device = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: _ConfigurableMicBackend(),
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
        liveActivityService: liveAct,
        watchHardware: watchSvc,
      );
      addTearDown(device.dispose);

      await device.connectTo(_v2Card);
      await device.toggleRecording();
      gw.failConnect = CardException.disconnected('超出蓝牙距离');
      gw.pushDisconnectedEvent();
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(device.isWatchFallbackRecording, isTrue);

      // 连上一台空闲且无远程启录能力的蓝牙硬件，此时手表保底仍在录
      gw.failConnect = null;
      gw.current = _snap(
        recording: false,
        kind: DeviceKind.omiCv1,
        caps: _passiveBleCard.capabilities,
      );
      await device.connectTo(_passiveBleCard);
      expect(device.isConnected, isTrue);
      expect(device.isRecording, isFalse);
      expect(device.isWatchFallbackRecording, isTrue);

      // 手表侧主动停录：即使此时 BLE 处于空闲已连接状态，仍必须停止灵动岛
      final stopsBefore = liveAct.stopCount;
      watchBackend.emitStatus(
        const WatchBridgeStatus(
          supported: true,
          paired: true,
          watchAppInstalled: true,
          reachable: true,
          isRecording: false,
          watchName: '我的手表',
        ),
      );
      await tester.pump();
      expect(device.isWatchFallbackRecording, isFalse);
      expect(liveAct.stopCount, stopsBefore + 1);
      device.dispose();
    });

    test('冷启动 restoreLink() 无法连回上次设备但系统遗留硬件灵动岛实况时，自动熄灭孤儿实况', () async {
      final now = DateTime(2026, 11, 23, 10, 30, 0);
      final stateStore = JsonStore(store: InMemoryStore());
      await stateStore.write(
        'last_device',
        PersistedLastDevice(
          id: _v2Card.id,
          name: _v2Card.name,
          deviceKind: DeviceKind.cardV2,
          wasRecording: true,
          recordingStartedAtMs: now
              .subtract(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
          savedAtMs: now.subtract(const Duration(minutes: 9)).millisecondsSinceEpoch,
        ).toJson(),
      );

      final gw = FakeCardGateway(devices: const [_v2Card])
        ..failConnect = CardException.disconnected('设备已关机或不在身边');
      final liveAct = _SpyLiveActivity(
        activeState: ActiveLiveActivityState(
          active: true,
          id: 'la-hw-orphan',
          title: '录音卡',
          subtitle: '录音卡 V2 · 蓝牙录音中',
          startedAtMs: now
              .subtract(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
          isRecording: true,
        ),
      );

      final device = DeviceStore(
        gateway: gw,
        liveActivityService: liveAct,
        phoneMicBackend: _ConfigurableMicBackend(),
        stateStore: stateStore,
        now: () => now,
      );
      addTearDown(device.dispose);

      await device.restoreLink();

      expect(device.isConnected, isFalse);
      expect(device.hasActiveRecording, isFalse);
      expect(liveAct.stopCount, greaterThanOrEqualTo(1));
    });
  });

  group('4. iOS 原生 LiveActivityBridge 与 AppDelegate 源码契约', () {
    test('LiveActivityBridge 保留 activeActivity 对账且串行锁序+后台收口+16.2 守卫齐全，AppDelegate 不抢跑清理', () {
      final appDelegate = _repoFile('app/ios/Runner/AppDelegate.swift')
          .readAsStringSync();
      final bridge = _repoFile('app/ios/Runner/LiveActivityBridge.swift')
          .readAsStringSync();

      // 不可在 AppDelegate 冷启动时抢跑销毁，以免破坏 PR #123 restoreLink() 的 queryActiveActivity() 对账
      expect(
        appDelegate.contains('cleanupOrphanedActivitiesIfIdle'),
        isFalse,
      );

      for (final token in const [
        'case "activeActivity":',
        'activeActivityPayload()',
        'willResignActiveNotification',
        'didEnterBackgroundNotification',
        'willTerminateNotification',
        'operationSeq',
        'activeSessionDesired',
        'lastOperationTask',
        'beginBackgroundTask',
        'args?["isRecording"] as? Bool',
        'dropFirst()',
      ]) {
        expect(bridge, contains(token));
      }

      // IPHONEOS_DEPLOYMENT_TARGET = 15.0：`.stale` 必须在 `if #available(iOS 16.2, *)` 守卫内部
      final staleIdx = bridge.indexOf('state == .stale');
      expect(staleIdx, greaterThan(0));
      final guardWindowStart = (staleIdx - 120).clamp(0, staleIdx);
      expect(
        bridge.substring(guardWindowStart, staleIdx),
        contains('#available(iOS 16.2, *)'),
      );
    });
  });
}
