import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/system_speech_client.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/fake_gateway.dart';

class _SpyRestoreGateway extends FakeCardGateway {
  _SpyRestoreGateway({
    super.devices,
    this.snapshotOnConnect,
  });

  final CardSnapshot? snapshotOnConnect;
  bool throwDisconnectedOnNextSnapshot = false;
  final List<String> connectedIds = [];

  @override
  Future<CardSnapshot?> connect(
    String id, {
    String? name,
    String? deviceKind,
  }) async {
    connectedIds.add(id);
    final res = await super.connect(id, name: name, deviceKind: deviceKind);
    if (snapshotOnConnect != null) {
      current = snapshotOnConnect!;
      return snapshotOnConnect!;
    }
    return res;
  }

  @override
  Future<CardSnapshot> snapshot() async {
    if (throwDisconnectedOnNextSnapshot) {
      throwDisconnectedOnNextSnapshot = false;
      throw CardException.disconnected();
    }
    return super.snapshot();
  }
}

class _FakePhoneMicBackend implements PhoneMicBackend {
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

class _FakeLiveActivityService extends LiveActivityService {
  _FakeLiveActivityService({
    ActiveLiveActivityState initialActive =
        const ActiveLiveActivityState.inactive(),
  }) : activeState = initialActive,
       super(
         capabilitiesOverride: const LiveActivityCapabilities(
           supportsLiveActivities: true,
           supportsDynamicIsland: true,
           supportsActionButton: true,
           areActivitiesEnabled: true,
         ),
       );

  ActiveLiveActivityState activeState;
  int startCalls = 0;
  int stopCalls = 0;
  DateTime? lastStartedAt;
  String? lastSubtitle;

  @override
  Future<ActiveLiveActivityState> queryActiveActivity() async => activeState;

  @override
  Future<void> startRecordingActivity({
    required DateTime startedAt,
    String title = '录音卡',
    String subtitle = '本机录音运行中',
  }) async {
    startCalls++;
    lastStartedAt = startedAt;
    lastSubtitle = subtitle;
    activeState = ActiveLiveActivityState(
      active: true,
      id: 'fake-la-1',
      title: title,
      subtitle: subtitle,
      startedAtMs: startedAt.millisecondsSinceEpoch,
      isRecording: true,
    );
  }

  @override
  Future<void> stopLocalRecordingActivity() async {
    stopCalls++;
    activeState = const ActiveLiveActivityState.inactive();
  }
}

CardSnapshot _bleSnapshot({
  required String id,
  required String name,
  required bool recording,
}) => CardSnapshot(
  batteryLevel: 76,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '1.0.5',
  fwVersionCode: 105,
  wifiVersion: '1.0.1',
  wifiVersionCode: 101,
  deviceName: name,
  deviceId: id,
  deviceKind: DeviceKind.cardV2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const devV2 = CardDevice(
    id: 'ble-uuid-v2',
    name: 'DYJV2_A1B2C3',
    rssi: -48,
    kind: DeviceKind.cardV2,
  );

  group('状态持久化与重启/回前台优先恢复', () {
    test('上次连接为 Apple Watch 且灵动岛录音中时，优先无扫描恢复 Watch 并接续计时与拉片', () async {
      final now = DateTime(2026, 11, 22, 20, 0, 0);
      final startedAt = now.subtract(const Duration(minutes: 2));
      final kv = InMemoryStore();
      final stateStore = JsonStore(store: kv);
      await stateStore.write(
        'last_device',
        PersistedLastDevice(
          id: WatchHardwareService.watchDeviceId,
          name: '我的手表',
          deviceKind: DeviceKind.appleWatch,
          displayModel: 'Apple Watch',
          wasRecording: true,
          recordingStartedAtMs: startedAt.millisecondsSinceEpoch,
          savedAtMs: now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch,
        ).toJson(),
      );

      final watchBackend = FakeWatchBridgeBackend(
        initialStatus: WatchBridgeStatus(
          supported: true,
          paired: true,
          watchAppInstalled: true,
          complicationEnabled: true,
          reachable: true,
          isRecording: true,
          sessionId: 'watch-s1',
          startedAtMs: startedAt.millisecondsSinceEpoch,
          batteryLevel: 85,
          pendingCount: 2,
          watchName: '我的手表',
          watchVersion: '11.1',
        ),
      );
      final watchService = WatchHardwareService(backend: watchBackend);
      final liveActivity = _FakeLiveActivityService(
        initialActive: ActiveLiveActivityState(
          active: true,
          id: 'la-watch',
          title: '录音卡',
          subtitle: 'Apple Watch · 蓝牙录音中',
          startedAtMs: startedAt.millisecondsSinceEpoch,
          isRecording: true,
        ),
      );
      final gw = _SpyRestoreGateway(devices: const [devV2]);

      final device = DeviceStore(
        gateway: gw,
        watchHardware: watchService,
        liveActivityService: liveActivity,
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
        initialWatchLinkEnabled: true,
        deferInitialRestore: true,
        now: () => now,
      );
      addTearDown(() async {
        device.dispose();
        watchService.dispose();
      });

      await device.setWatchLinkEnabled(true);
      await device.restoreLink();

      expect(device.isConnected, isTrue);
      expect(device.activeKind, DeviceKind.appleWatch);
      expect(device.isRecording, isTrue);
      expect(device.recSeconds, 120);
      expect(gw.scanCalls, 0);
      expect(watchBackend.flushCalls, greaterThanOrEqualTo(1));
    });

    test('上次连接为蓝牙硬件且灵动岛保持录音态：重启直接按缓存 ID 恢复，零扫描并接续耗时', () async {
      var now = DateTime(2026, 11, 22, 20, 10, 0);
      final kv = InMemoryStore();
      final stateStore = JsonStore(store: kv);
      final gw1 = _SpyRestoreGateway(
        devices: const [devV2],
        snapshotOnConnect: _bleSnapshot(
          id: devV2.id,
          name: devV2.name,
          recording: true,
        ),
      );
      final la1 = _FakeLiveActivityService();
      final devFirst = DeviceStore(
        gateway: gw1,
        liveActivityService: la1,
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
        now: () => now,
      );
      await devFirst.connectTo(devV2);
      await Future<void>.delayed(Duration.zero);
      expect(devFirst.isConnected, isTrue);
      expect(devFirst.isRecording, isTrue);
      devFirst.dispose();

      // 模拟后台 3 分钟后应用重启或回到前台重建 Store
      final recStart = now;
      now = now.add(const Duration(minutes: 3));
      final gw2 = _SpyRestoreGateway(
        devices: const [devV2],
        snapshotOnConnect: _bleSnapshot(
          id: devV2.id,
          name: devV2.name,
          recording: true,
        ),
      );
      final la2 = _FakeLiveActivityService(
        initialActive: ActiveLiveActivityState(
          active: true,
          id: 'la-ble',
          title: '录音卡',
          subtitle: '录音卡 V2 ${devV2.shortName} · 蓝牙录音中',
          startedAtMs: recStart.millisecondsSinceEpoch,
          isRecording: true,
        ),
      );
      final devRestored = DeviceStore(
        gateway: gw2,
        liveActivityService: la2,
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
        deferInitialRestore: true,
        now: () => now,
      );
      addTearDown(devRestored.dispose);

      await devRestored.restoreLink();

      expect(devRestored.linkState, LinkState.connected);
      expect(devRestored.connectedName, devV2.name);
      expect(devRestored.isRecording, isTrue);
      expect(devRestored.recSeconds, 180);
      expect(gw2.scanCalls, 0);
      expect(gw2.connectCalls, 1);
      expect(gw2.connectedIds, [devV2.id]);
    });

    test('硬件在后台期间已停止录音：重连后自动拉取漏传数据并熄灭过期灵动岛', () async {
      final now = DateTime(2026, 11, 22, 20, 20, 0);
      final kv = InMemoryStore();
      final stateStore = JsonStore(store: kv);
      await stateStore.write(
        'last_device',
        PersistedLastDevice(
          id: devV2.id,
          name: devV2.name,
          deviceKind: DeviceKind.cardV2,
          wasRecording: true,
          recordingStartedAtMs: now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
          savedAtMs: now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
        ).toJson(),
      );

      final gw = _SpyRestoreGateway(
        devices: const [devV2],
        snapshotOnConnect: _bleSnapshot(
          id: devV2.id,
          name: devV2.name,
          recording: false,
        ),
      );
      final la = _FakeLiveActivityService(
        initialActive: ActiveLiveActivityState(
          active: true,
          id: 'la-stale',
          title: '录音卡',
          subtitle: '录音卡 V2 · 蓝牙录音中',
          startedAtMs: now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
          isRecording: true,
        ),
      );
      var syncCalls = 0;
      final device = DeviceStore(
        gateway: gw,
        liveActivityService: la,
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
        onAutoSyncMissedData: () async {
          syncCalls++;
          return null;
        },
        now: () => now,
      );
      addTearDown(device.dispose);

      await device.restoreLink();
      await Future<void>.delayed(Duration.zero);

      expect(device.isConnected, isTrue);
      expect(device.isRecording, isFalse);
      expect(syncCalls, 1);
      expect(la.stopCalls, greaterThanOrEqualTo(1));
      expect(gw.scanCalls, 0);
    });

    test('用户主动 disconnectSafely 清除持久化缓存，下次重启不擅自回连', () async {
      final kv = InMemoryStore();
      final stateStore = JsonStore(store: kv);
      final gw = _SpyRestoreGateway(
        devices: const [devV2],
        snapshotOnConnect: _bleSnapshot(
          id: devV2.id,
          name: devV2.name,
          recording: false,
        ),
      );
      final device1 = DeviceStore(
        gateway: gw,
        liveActivityService: _FakeLiveActivityService(),
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
      );
      await device1.connectTo(devV2);
      await Future<void>.delayed(Duration.zero);
      expect(await stateStore.read('last_device'), isNotNull);

      await device1.disconnectSafely();
      await Future<void>.delayed(Duration.zero);
      expect(await stateStore.read('last_device'), isNull);
      device1.dispose();

      final gw2 = _SpyRestoreGateway(devices: const [devV2]);
      final device2 = DeviceStore(
        gateway: gw2,
        liveActivityService: _FakeLiveActivityService(),
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
      );
      addTearDown(device2.dispose);
      await device2.restoreLink();

      expect(device2.linkState, LinkState.disconnected);
      expect(gw2.connectCalls, 0);
      expect(gw2.scanCalls, 0);
    });

    test('handleAppResumed 支持静默断连重连、3 秒防死循环冷却并清理孤立本机灵动岛', () async {
      var now = DateTime(2026, 11, 22, 20, 30, 0);
      final kv = InMemoryStore();
      final stateStore = JsonStore(store: kv);
      final gw = _SpyRestoreGateway(
        devices: const [devV2],
        snapshotOnConnect: _bleSnapshot(
          id: devV2.id,
          name: devV2.name,
          recording: false,
        ),
      );
      final la = _FakeLiveActivityService();
      final device = DeviceStore(
        gateway: gw,
        liveActivityService: la,
        phoneMicBackend: _FakePhoneMicBackend(),
        stateStore: stateStore,
        now: () => now,
      );
      addTearDown(device.dispose);

      // 1) 已连接状态回到前台，探测发现静默断连 -> 触发直连恢复且绝不死循环扫描
      await device.connectTo(devV2);
      await Future<void>.delayed(Duration.zero);
      final connectsBefore = gw.connectCalls;
      gw.throwDisconnectedOnNextSnapshot = true;

      device.handleAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 550));

      expect(device.isConnected, isTrue);
      expect(gw.connectCalls, greaterThan(connectsBefore));
      expect(gw.scanCalls, 0);

      // 2) 未连接态短时间内连续两次回前台：3 秒冷却内不重复请求重连，也不清除缓存
      await device.dropToDisconnectedForTest(gw);
      now = now.add(const Duration(seconds: 5));
      gw.failConnect = CardException.disconnected();
      final prevConnects = gw.connectCalls;
      device.handleAppResumed();
      device.handleAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gw.failConnect = null;

      expect(gw.connectCalls, prevConnects + 1);
      expect(gw.scanCalls, 0);
      expect(await stateStore.read('last_device'), isNotNull);

      // 3) 无可恢复设备且手机没在录音，但系统遗留本机灵动岛 -> 恢复检查时自动熄灭
      await device.disconnectSafely();
      await Future<void>.delayed(Duration.zero);
      la.activeState = const ActiveLiveActivityState(
        active: true,
        id: 'la-phone-orphan',
        title: '录音卡',
        subtitle: '本机录音运行中',
        startedAtMs: 1700000000000,
        isRecording: true,
      );
      await device.restoreLink();
      await Future<void>.delayed(Duration.zero);
      expect(la.stopCalls, greaterThanOrEqualTo(1));
    });
  });

  group('内存回收辅助能力（防 iOS 后台被杀）', () {
    test('RecordingStore.clearMemoryCache 可清空内存缓存且不影响重新读盘', () async {
      final root = await Directory.systemTemp.createTemp('rc-mem-store-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = RecordingStore(
        root: root,
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      await store.save(
        RecordingFile(
          deviceName: 'DYJV2_TEST.APM',
          session: 'S1',
          seq: 1,
          startAtMs: 1730000000000,
          apmPath: '/tmp/a.apm',
          wavPath: '/tmp/a.wav',
          durationMs: 1000,
          stage: RecordingStage.ready,
          createdAtMs: 1730000001000,
        ),
      );
      expect((await store.loadAll()).length, 1);

      store.clearMemoryCache();
      final reloaded = await store.loadAll();
      expect(reloaded.length, 1);
      expect(reloaded.first.deviceName, 'DYJV2_TEST.APM');
    });

    test('LocalAsrService 与 RoutingSpeechEngine 的 releaseMemory 在空闲态可安全调用', () async {
      final local = LocalAsrService(
        idleReleaseDelay: const Duration(milliseconds: 50),
      );
      final routing = RoutingSpeechEngine(
        localEngine: local,
        systemSpeech: SystemSpeechClient(),
      );

      expect(local.hasActiveWorker, isFalse);
      await local.releaseMemory();
      await routing.releaseMemory();
      await routing.dispose();
    });
  });
}

extension _DeviceStoreTestHelper on DeviceStore {
  Future<void> dropToDisconnectedForTest(_SpyRestoreGateway gw) async {
    // 模拟意外失联（非用户主动点击断开）：保留缓存以便回前台重连，但当前链路为 disconnected。
    gw.failConnect = CardException.disconnected();
    gw.throwDisconnectedOnNextSnapshot = true;
    await refreshFromDevice();
    await Future<void>.delayed(const Duration(milliseconds: 550));
    gw.failConnect = null;
  }
}
