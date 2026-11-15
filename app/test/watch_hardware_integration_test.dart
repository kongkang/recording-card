// Apple Watch 独立采集硬件协同全链路验收：
//
// 1. 默认关闭「Apple Watch 联动」时，扫描列表严格保持已有三款 BLE 硬件（DYJV2_* / DYJ_* / REAI_VB_*），
//    原有行为 100% 不变；
// 2. 在 Setting →「硬件设备联动 → Apple Watch 联动」开启联动后，状态卡片如实呈现配对/装端/高中低档位电量
//    （严禁出现百分比数字或「已充满」）与表盘组件三步指引；右上角胶囊扫描同时发现 4 款硬件并展示 Apple Watch；
// 3. 连接 Apple Watch 后，StatusSheet 展示统一录音开关、电量、手动同步，按能力矩阵隐藏 Wi-Fi / 固件更新
//    且隐藏独立「本机录音」行；双向启停同步刷新灵动岛（Apple Watch）与正计时，原生切片推入即触发
//    AppStore.ingestLiveSlice 并完成 ack，意外失联立即触发手机本机零功耗待命保底接力。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _WatchSpyAppStore extends AppStore {
  _WatchSpyAppStore({
    required super.events,
    required super.generator,
  }) : super(loadPersistedState: false);

  final List<LiveAudioSlice> ingestedSlices = [];

  @override
  Future<RecordingFile?> ingestLiveSlice(LiveAudioSlice slice) async {
    ingestedSlices.add(slice);
    return super.ingestLiveSlice(slice);
  }
}

class _TrackingLiveActivityService extends LiveActivityService {
  _TrackingLiveActivityService()
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

class _SpyPhoneMicBackend implements PhoneMicBackend {
  PhoneMicPermission permission = PhoneMicPermission.granted;
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
    startCalls += 1;
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls += 1;
    capturing = false;
  }
}

Future<({
  _WatchSpyAppStore store,
  AgentConfigStore agentConfig,
  DeviceStore device,
  FakeWatchBridgeBackend watchBackend,
  _TrackingLiveActivityService liveActivity,
  _SpyPhoneMicBackend phoneMic,
})> _pumpWatchShell(
  WidgetTester tester, {
  List<CardDevice> bleDevices = const [
    CardDevice(id: 'kbd', name: 'REAI_VB_8801', rssi: -48),
    CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -56),
    CardDevice(id: 'v1', name: 'DYJ_001A', rssi: -68),
  ],
  bool bleAvailable = true,
  bool initialWatchLinkEnabled = false,
}) async {
  final model = SummaryModel();
  final store = _WatchSpyAppStore(
    events: seedEvents,
    generator: await model.generator(),
  );
  final agentConfig = AgentConfigStore();
  if (initialWatchLinkEnabled) {
    await agentConfig.setWatchLinkEnabled(true);
  }
  final sliceTmpDir = Directory.systemTemp.createTempSync('rc-watch-mic-');
  addTearDown(() {
    if (sliceTmpDir.existsSync()) sliceTmpDir.deleteSync(recursive: true);
  });
  final watchBackend = FakeWatchBridgeBackend();
  final watchService = WatchHardwareService(backend: watchBackend);
  final liveActivity = _TrackingLiveActivityService();
  final phoneMic = _SpyPhoneMicBackend();
  final device = DeviceStore(
    gateway: FakeCardGateway(devices: bleDevices, available: bleAvailable),
    watchHardware: watchService,
    liveActivityService: liveActivity,
    phoneMicBackend: phoneMic,
    phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => sliceTmpDir),
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
    watchBackend: watchBackend,
    liveActivity: liveActivity,
    phoneMic: phoneMic,
  );
}

void main() {
  testWidgets('默认关闭 Apple Watch 联动时扫描列表严格保持 3 款 BLE 硬件', (tester) async {
    final env = await _pumpWatchShell(tester);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(env.device.discovered.map((d) => d.id).toList(), ['kbd', 'v2', 'v1']);
    expect(
      find.byKey(const Key('dev-kind-${WatchHardwareService.watchDeviceId}')),
      findsNothing,
    );
  });

  testWidgets('在 Setting 开启 Apple Watch 联动后加入四硬件扫描并完成能力裁剪', (
    tester,
  ) async {
    final env = await _pumpWatchShell(tester);

    // 进入 Setting → Apple Watch 联动
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-apple-watch')),
      220,
      scrollable: find.descendant(
        of: find.byKey(const Key('setting-list')),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.text('未开启'), findsWidgets);
    await tester.tap(find.byKey(const Key('set-apple-watch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('watch-link-status-card')), findsOneWidget);
    expect(find.byKey(const Key('watch-complication-guide')), findsOneWidget);
    expect(find.byKey(const Key('watch-install-guide-banner')), findsNothing);
    // 模拟已配对但手表尚未安装表端应用：展示开发者模式与 Watch App 安装指引
    env.watchBackend.emitStatus(
      env.watchBackend.currentStatus.copyWith(watchAppInstalled: false),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('watch-install-guide-banner')), findsOneWidget);
    env.watchBackend.emitStatus(
      env.watchBackend.currentStatus.copyWith(watchAppInstalled: true),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('watch-install-guide-banner')), findsNothing);
    // 电量禁止出现 % 或「已充满」
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('已充满'), findsNothing);
    expect(find.text('电量高'), findsOneWidget);

    await tester.tap(find.byKey(const Key('watch-link-switch')));
    await tester.pump();
    await tester.pump();
    expect(env.agentConfig.watchLinkEnabled, isTrue);

    // 返回并打开胶囊扫描：3 BLE + 1 Apple Watch 共 4 款硬件
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(env.device.discovered.length, 4);
    expect(
      env.device.discovered.any((d) => d.deviceKind == DeviceKind.appleWatch),
      isTrue,
    );
    expect(
      find.byKey(const Key('dev-kind-${WatchHardwareService.watchDeviceId}')),
      findsOneWidget,
    );

    // 连接 Apple Watch 并检查 StatusSheet 能力裁剪
    await tester.tap(
      find.byKey(const Key('dev-item-${WatchHardwareService.watchDeviceId}')),
    );
    await tester.pump();
    await tester.pump();

    expect(env.device.isConnected, isTrue);
    expect(env.device.activeKind, DeviceKind.appleWatch);
    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.byKey(const Key('rec-toggle')), findsOneWidget);
    expect(find.byKey(const Key('batt-eta')), findsOneWidget);
    expect(find.textContaining('可录至'), findsOneWidget);
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
    expect(find.byKey(const Key('wifi-row')), findsNothing);
    expect(find.byKey(const Key('fw-update')), findsNothing);
    expect(find.byKey(const Key('phone-rec-row')), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('Apple Watch 双向控制、本地 WAV 切片入库及断连本机零功耗待命接力', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-watch-slice-');
    addTearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });
    final wavFile = File('${tmpDir.path}/watch-01.wav');
    wavFile.writeAsBytesSync(encodeWav(Float32List(16000))); // 1s 16kHz mono PCM

    final env = await _pumpWatchShell(
      tester,
      initialWatchLinkEnabled: true,
    );

    // 通过胶囊扫码并连接 Apple Watch
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('dev-item-${WatchHardwareService.watchDeviceId}')),
    );
    await tester.pump();
    await tester.pump();
    expect(env.device.activeKind, DeviceKind.appleWatch);

    // 1) 从手机切换开启录音 -> 手表与灵动岛同步激活
    await tester.tap(find.byKey(const Key('rec-toggle')));
    await tester.pump();
    await tester.pump();

    expect(env.watchBackend.startCalls, 1);
    expect(env.device.isRecording, isTrue);
    expect(
      env.liveActivity.subtitles.any((s) => s.contains('Apple Watch')),
      isTrue,
    );

    // 2) 表端推回本地转码后的 16kHz WAV 切片 -> 自动触发 AppStore.ingestLiveSlice 并回执 ack
    env.watchBackend.pushReadySlice(
      WatchPendingSlicePayload(
        sliceId: 'slice-w1',
        sessionId: 'watch-sess-1',
        sliceIndex: 0,
        startAtMs: 1_794_758_400_000,
        durationMs: 1_000,
        wavPath: wavFile.path,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(env.store.ingestedSlices.length, 1);
    expect(env.store.ingestedSlices.first.wavPath, wavFile.path);
    expect(env.store.ingestedSlices.first.sliceKeyOverride, 'watch_slice-w1');
    expect(env.watchBackend.ackedSliceIds, contains('slice-w1'));

    // 3) 录音期间模拟手表意外失去通信连接 -> 立即切换至手机本机零功耗待命保底录音
    env.watchBackend.simulateReachable(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(env.device.isFailoverPhoneRecording, isTrue);
    expect(env.phoneMic.startCalls, 1);

    // 停掉保底录音以免留下周期定时器影响测试退出
    await env.device.stopPhoneRecording();
    await tester.pump();
  });

  testWidgets('Setting → Apple Watch 联动页保持三卡片极简结构，支持连接切换与拉取待传录音', (
    tester,
  ) async {
    final env = await _pumpWatchShell(
      tester,
      initialWatchLinkEnabled: true,
    );

    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-apple-watch')),
      220,
      scrollable: find.descendant(
        of: find.byKey(const Key('setting-list')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.tap(find.byKey(const Key('set-apple-watch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('watch-link-toggle-row')), findsOneWidget);
    expect(find.byKey(const Key('watch-link-status-card')), findsOneWidget);
    expect(find.byKey(const Key('watch-complication-guide')), findsOneWidget);
    expect(find.byKey(const Key('watch-remote-card')), findsNothing);
    expect(find.byKey(const Key('watch-slices-card')), findsNothing);

    await tester.tap(find.byKey(const Key('watch-connect-btn')));
    await tester.pump();
    await tester.pump();

    expect(env.device.isConnected, isTrue);
    expect(env.device.activeKind, DeviceKind.appleWatch);
    expect(find.text('断开手表连接'), findsOneWidget);
    expect(find.byKey(const Key('watch-link-hint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('watch-flush-btn')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('watch-link-hint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('watch-connect-btn')));
    await tester.pump();
    await tester.pump();
    expect(env.device.isConnected, isFalse);
    expect(find.text('设为当前录音硬件'), findsOneWidget);
  });
}
