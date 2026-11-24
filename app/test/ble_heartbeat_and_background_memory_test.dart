import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_models.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';

const _v2Card = CardDevice(
  id: 'ble-v2-hb',
  name: 'DYJV2_HB01',
  rssi: -46,
  kind: DeviceKind.cardV2,
);

CardSnapshot _v2Snap({bool recording = true}) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '3.13',
  fwVersionCode: 313,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_HB01',
  deviceId: 'ble-v2-hb',
  deviceKind: DeviceKind.cardV2,
);

class _TimeoutSnapshotGateway extends FakeCardGateway {
  _TimeoutSnapshotGateway({super.initialSnapshot, super.devices});

  int timeoutNextSnapshots = 0;

  @override
  Future<CardSnapshot> snapshot() async {
    if (timeoutNextSnapshots > 0) {
      timeoutNextSnapshots--;
      throw TimeoutException('simulated heartbeat timeout');
    }
    return super.snapshot();
  }
}

class _CountingPhoneMicBackend implements PhoneMicBackend {
  int startCalls = 0;
  int stopCalls = 0;
  bool capturing = false;
  Object? nextStartError;

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
  }) async {
    startCalls++;
    if (nextStartError != null) throw nextStartError!;
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls++;
    capturing = false;
  }
}

class _NoopSpeechEngine implements SpeechEngine {
  int transcribeCalls = 0;

  @override
  Future<void> dispose() async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => [SpeechSpan(0, samples.length)];

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1.0];

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    transcribeCalls++;
    return const AsrResult(
      text: '测试转写片段。',
      tokens: [],
      timestampsMs: [],
      audioMs: 1000,
    );
  }
}

class _StubModelProvider implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/models/asr.onnx',
    tokensPath: '/models/tokens.txt',
    vadPath: '/models/vad.onnx',
  );
}

class _NoopLiveActivity extends LiveActivityService {
  _NoopLiveActivity()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: true,
          supportsDynamicIsland: true,
          supportsActionButton: true,
          areActivitiesEnabled: true,
        ),
      );

  @override
  Future<void> startRecordingActivity({
    required DateTime startedAt,
    String title = '录音卡',
    String subtitle = '本机录音运行中',
  }) async {}

  @override
  Future<void> stopLocalRecordingActivity() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('录音期单次心跳超时不立即断连或切本机兜底，连续 2 次超时后再触发重连并仅在重连失败后兜底', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-hb-confirm-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final gw = _TimeoutSnapshotGateway(
      initialSnapshot: _v2Snap(recording: true),
      devices: const [_v2Card],
    );
    final mic = _CountingPhoneMicBackend();
    final device = DeviceStore(
      gateway: gw,
      autoStart: true,
      phoneMicBackend: mic,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: _NoopLiveActivity(),
    );
    addTearDown(device.dispose);

    await device.connectTo(_v2Card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(device.isConnected, isTrue);
    expect(device.isRecording, isTrue);

    // 1) 单次探测超时：保留 BLE 连接，2 秒二次确认若恢复则完全无感，绝不启本机麦克风
    gw.timeoutNextSnapshots = 1;
    await tester.pump(const Duration(seconds: 10));
    expect(device.linkState, LinkState.connected);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.startCalls, 0);

    await tester.pump(const Duration(seconds: 2));
    expect(device.linkState, LinkState.connected);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.startCalls, 0);

    // 2) 连续 2 次心跳探测超时 + 快速直连失败：第 1 次超时(t=20s)仍保持 connected；第 2 次(t=22s)触发重连；重连失败才转交本机保底
    gw.timeoutNextSnapshots = 2;
    gw.failConnect = CardException.disconnected('超出蓝牙范围');
    await tester.pump(const Duration(seconds: 8));
    expect(device.linkState, LinkState.connected);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.startCalls, 0);

    await tester.pump(const Duration(seconds: 2));
    expect(device.linkState, LinkState.reconnecting);
    expect(device.isPhoneRecording, isFalse);
    expect(mic.startCalls, 0);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(device.linkState, LinkState.disconnected);
    expect(device.isPhoneRecording, isTrue);
    expect(mic.startCalls, 1);

    await device.stopPhoneRecording();
    device.dispose();
  });

  testWidgets('挂起待恢复态回到前台时优先尝试 BLE 直连硬件，硬件可达时绝不启动本机麦克风', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-resume-ble-first-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final gw = FakeCardGateway(
      initialSnapshot: _v2Snap(recording: false),
      devices: const [_v2Card],
    );
    final mic = _CountingPhoneMicBackend();
    final device = DeviceStore(
      gateway: gw,
      autoStart: true,
      phoneMicBackend: mic,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: _NoopLiveActivity(),
    );

    await device.connectTo(_v2Card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await device.toggleRecording();
    expect(device.isRecording, isTrue);

    // 模拟后台 BLE 失联 + iOS 560557684 受限导致 _pendingPhoneFailover = true
    mic.nextStartError = PlatformException(
      code: 'phone_mic_start_failed',
      message: 'OSStatus 560557684',
    );
    gw.failConnect = CardException.disconnected('后台暂时失联');
    gw.pushDisconnectedEvent();
    await device.pollEventsNow();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(device.linkState, LinkState.disconnected);
    expect(device.isPendingForegroundPhoneFailover, isTrue);
    expect(device.isPhoneRecording, isFalse);

    // 回到前台前硬件已经恢复且仍在录音：回前台应先直连硬件，跳过本机麦克风启动
    mic.nextStartError = null;
    mic.startCalls = 0;
    gw.failConnect = null;
    gw.current = _v2Snap(recording: true);
    device.handleAppResumed();
    await tester.pump();
    await tester.pump();

    expect(device.linkState, LinkState.connected);
    expect(device.isRecording, isTrue);
    expect(device.isPhoneRecording, isFalse);
    expect(device.isPendingForegroundPhoneFailover, isFalse);
    expect(mic.startCalls, 0);
    device.dispose();
  });

  testWidgets('冷启动 restoreLink 首次失败后仍挂载后台重连队列并在设备就绪后自动接回', (
    tester,
  ) async {
    final kv = InMemoryStore();
    final stateStore = JsonStore(store: kv);
    await stateStore.write(
      'last_device',
      PersistedLastDevice(
        id: _v2Card.id,
        name: _v2Card.name,
        deviceKind: DeviceKind.cardV2,
        wasRecording: true,
        recordingStartedAtMs: DateTime(2026, 11, 24, 20, 0).millisecondsSinceEpoch,
        savedAtMs: DateTime(2026, 11, 24, 20, 1).millisecondsSinceEpoch,
      ).toJson(),
    );

    final gw = FakeCardGateway(
      initialSnapshot: _v2Snap(recording: true),
      devices: const [_v2Card],
    )
      ..failSnapshot = CardException.disconnected('冷启动离线')
      ..failConnect = CardException.disconnected('冷启动广播窗口未命中');

    final device = DeviceStore(
      gateway: gw,
      autoStart: true,
      deferInitialRestore: true,
      stateStore: stateStore,
      backgroundReconnectDelays: const [Duration(seconds: 2)],
    );

    await device.restoreLink();
    expect(device.isConnected, isFalse);
    expect(device.isBackgroundReconnectArmed, isTrue);

    gw.failSnapshot = null;
    gw.failConnect = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(device.isConnected, isTrue);
    expect(device.isRecording, isTrue);
    expect(device.isBackgroundReconnectArmed, isFalse);
    device.dispose();
  });

  test('后台态冻结本地 ONNX 批量转写、暂停 1s 时钟并可挂起重建 Agent Worker', () async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-bg-mem-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final recStore = RecordingStore(
      root: tmpDir,
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    final engine = _NoopSpeechEngine();
    final pipeline = RecordingPipeline(
      gateway: FakeCardGateway(),
      store: recStore,
      engine: engine,
      models: _StubModelProvider(),
      liveAudioBaseDir: tmpDir,
    );
    final summaryGen = SummaryGenerator(
      gateway: await buildModelGateway(
        MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    final appStore = AppStore(loadPersistedState: false)
      ..deferredBatchTranscription = true
      ..transcribeCycleMinutes = 1
      ..attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: summaryGen,
      );
    addTearDown(appStore.dispose);

    // 模拟处于后台并写入 1 分钟实时切片：应只落盘 WAV，不在后台唤醒 ONNX 转写
    appStore.setAppBackgrounded(true);
    final speechSamples = Float32List(16000);
    for (var i = 0; i < speechSamples.length; i++) {
      speechSamples[i] = ((i % 80) - 40) / 80.0 * 0.4;
    }
    final wavPath = '${tmpDir.path}/bg-slice-0.wav';
    await File(wavPath).writeAsBytes(encodeWav(speechSamples), flush: true);
    final saved = await appStore.ingestLiveSlice(
      LiveAudioSlice(
        sessionId: 'bg-s1',
        sliceIndex: 0,
        startAtMs: 1732449600000,
        durationMs: 60000,
        wavPath: wavPath,
      ),
    );
    expect(saved, isNotNull);
    expect(appStore.pendingLocalAudioCount, 1);
    expect(engine.transcribeCalls, 0);

    // 验证非 manual 的后台批量转写被守卫拦截，切回前台后正常执行
    final bgReport = await appStore.transcribeAndOrganizePending(
      reason: 'cycle',
    );
    expect(bgReport.transcribed, 0);
    expect(engine.transcribeCalls, 0);

    appStore.setAppBackgrounded(false);
    final fgReport = await appStore.transcribeAndOrganizePending(
      reason: 'view-resume',
    );
    expect(fgReport.transcribed, 1);
    expect(engine.transcribeCalls, greaterThanOrEqualTo(1));

    // 验证后台暂停 1s 计时器 + 回前台用墙钟对齐耗时
    var clockNow = DateTime(2026, 11, 24, 21, 0, 0);
    final devGw = FakeCardGateway(
      initialSnapshot: _v2Snap(recording: true),
      devices: const [_v2Card],
    );
    final device = DeviceStore(
      gateway: devGw,
      autoStart: true,
      now: () => clockNow,
    );
    addTearDown(device.dispose);
    await device.connectTo(_v2Card);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    device.retainClock();
    final baseSec = device.recSeconds;
    device.handleAppBackgrounded();
    clockNow = clockNow.add(const Duration(seconds: 42));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(device.recSeconds, baseSec);

    device.handleAppResumed();
    expect(device.recSeconds, 42);

    // 验证 AgentHarnessWorker 后台挂起释放后下次仍可无缝重建响应
    final worker = AgentHarnessWorker(
      complete: (msgs, {required model, temperature = 0.3, maxTokens = 2048}) =>
          Future.value('{"react":"👌","reply":"恢复完成"}'),
      inProcess: true,
    );
    await worker.syncCorpus(const []);
    await worker.suspendForBackground();
    final res = await worker.runTurn(
      userText: '在吗',
      history: const [],
      config: const AgentConfigSnapshot(
        model: 'test-model',
        temperature: 0.3,
        agentPrompt: 'prompt',
        enabledSkillRules: [],
        webSearchEnabled: false,
        recordSearchEnabled: false,
        healthAccessEnabled: false,
        customSearchApiUrl: '',
        customSearchApiKey: '',
        activeMcps: [],
        agentDirPath: '',
      ),
      sessionId: 's1',
      userMsgId: 'u1',
      userCreatedAtMs: 1,
    );
    expect(res.error, isNull);
    expect(res.reply, contains('恢复完成'));
    await worker.dispose();
  });
}
