import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/agent/hardware_agent_task_coordinator.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';

import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _FakeSpeechBackend implements AgentSpeechBackend {
  final StreamController<AgentSpeechEvent> _ctrl =
      StreamController<AgentSpeechEvent>.broadcast();

  bool speaking = false;
  final List<String> spokenTexts = [];
  int stopSpeakCalls = 0;

  @override
  Stream<AgentSpeechEvent> get events => _ctrl.stream;

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async => true;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {
    speaking = true;
    spokenTexts.add(text);
    _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: true));
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakCalls++;
    if (speaking) {
      speaking = false;
      _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: false));
    }
  }

  @override
  void dispose() {
    unawaited(_ctrl.close());
  }
}

class _FakeCompletion implements ChatCompletion {
  _FakeCompletion([this.replyText = '收到，已帮你查好结果。']);

  final String replyText;
  final List<String> userPrompts = [];

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        userPrompts.add(m.content);
        break;
      }
    }
    return jsonEncode({'react': '', 'reply': replyText});
  }
}

class _FakePhoneMicBackend implements PhoneMicBackend {
  _FakePhoneMicBackend(this.chunksToEmit);

  final List<Uint8List> chunksToEmit;
  int startCalls = 0;
  int stopCalls = 0;
  bool active = false;

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
    active = true;
    for (final c in chunksToEmit) {
      onPcm(c);
    }
  }

  @override
  Future<void> stopCapture() async {
    stopCalls++;
    active = false;
  }
}

CardSnapshot _dyjSnapshot({bool recording = false}) => CardSnapshot(
  batteryLevel: 85,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '0.8.15',
  fwVersionCode: 815,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_TEST',
  deviceId: 'dyj-test-1',
  deviceKind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

/// 生成 16kHz 16-bit LE 有声正弦 PCM（保证高通去直流与噪声门控后不被当静音滤掉）。
Uint8List _voicedPcm({int samples = 3200}) {
  final out = Uint8List(samples * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final v = (i % 32 < 16) ? 6000 : -6000;
    view.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

void main() {
  testWidgets(
    'Case 1: 默认按键配置与持久化、DYJ V1 弹层入口显隐与修改、iPhone 操作按钮模式切换',
    (tester) async {
      final backing = InMemoryStore();
      final cfg = AgentConfigStore(store: backing);
      await cfg.load();

      expect(cfg.dyjClickAction, HardwareButtonAction.mark);
      expect(cfg.dyjLongPressAction, HardwareButtonAction.agentVoice);
      expect(cfg.dyjDoubleClickAction, HardwareButtonAction.photoRecognize);
      expect(
        cfg.iphoneActionButtonBehavior,
        IphoneActionButtonBehavior.recordToggle,
      );

      // 1) DYJV2 不展示 btn-config
      final v2Device = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: defaultSnapshot),
      );
      await v2Device.restoreLink();
      v2Device.openSheet();

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                StatusSheetOverlay(store: v2Device, agentConfig: cfg),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('btn-config')), findsNothing);
      v2Device.dispose();

      // 2) DYJ_V1 展示 btn-config → 可进二级页修改动作并持久化恢复
      final dyjDevice = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _dyjSnapshot()),
      );
      await dyjDevice.restoreLink();
      dyjDevice.openSheet();

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                StatusSheetOverlay(store: dyjDevice, agentConfig: cfg),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('btn-config')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-config')));
      await tester.pump();

      expect(find.byKey(const Key('btn-config-view')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-click')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-long')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-double')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn-cfg-click-agent_voice')));
      await tester.pump();
      expect(cfg.dyjClickAction, HardwareButtonAction.agentVoice);

      await tester.tap(find.byKey(const Key('btn-cfg-back')));
      await tester.pump();
      expect(find.byKey(const Key('dev-main')), findsOneWidget);

      // 3) iPhone 操作按钮模式切换
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: SettingSubPage(
            subId: 'island',
            agentConfig: cfg,
            standalone: true,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('action-btn-mode-agent')));
      await tester.pump();
      expect(
        cfg.iphoneActionButtonBehavior,
        IphoneActionButtonBehavior.agentVoice,
      );

      final reloaded = AgentConfigStore(store: backing);
      await reloaded.load();
      expect(reloaded.dyjClickAction, HardwareButtonAction.agentVoice);
      expect(
        reloaded.iphoneActionButtonBehavior,
        IphoneActionButtonBehavior.agentVoice,
      );

      reloaded.dispose();
      cfg.dispose();
      dyjDevice.dispose();
    },
  );

  test(
    'Case 2: 持续录音中按 DYJ V1 长按切片 [t_start, t_end] 转写发 Agent + TTS + LED + 单击打重点',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_btn_case2_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      var nowMs = 1500;
      DateTime fakeClock() => DateTime.fromMillisecondsSinceEpoch(nowMs);

      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(initialSnapshot: _dyjSnapshot(recording: true));
      final device = DeviceStore(gateway: gw);
      await device.restoreLink();
      final liveAudio = LiveAudioRecorder(
        gateway: gw,
        baseDir: dir,
        clock: fakeClock,
      );

      // 写入覆盖 [1000..4000ms] 的实时音频到环形缓冲
      final chunk = _voicedPcm(samples: 16000); // 1000ms @ 16kHz
      liveAudio.ringBuffer.append(chunk, endTimestampMs: 2000);
      liveAudio.ringBuffer.append(chunk, endTimestampMs: 3000);
      liveAudio.ringBuffer.append(chunk, endTimestampMs: 4000);

      final speech = _FakeSpeechBackend();
      final completion = _FakeCompletion('今天下午四点有个产品对齐会。');
      final worker = AgentHarnessWorker(
        complete: completion.complete,
        inProcess: true,
      );
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        completion: completion,
        worker: worker,
        agentDirResolver: () async => '',
        clock: fakeClock,
      );

      final slicedCounts = <int>[];
      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        clock: fakeClock,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        transcribeSamples: (samples, {sampleRate = 16000}) async {
          slicedCounts.add(samples.length);
          return '我今天下午有什么日程？';
        },
      );

      // 先测试单击打重点
      gw.pushButtonEvent(gesture: 'click', receivedAtMs: 1200);
      await device.pollEventsNow();
      await Future<void>.delayed(Duration.zero);
      expect(gw.markCalls, 1);

      // 再测试长按语音任务 [1500 .. 3500]
      gw.pushButtonEvent(gesture: 'down', receivedAtMs: 1500);
      gw.pushButtonEvent(
        gesture: 'long_press_start',
        durationMs: 600,
        receivedAtMs: 2100,
      );
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coord.phase, HardwareAgentPhase.listening);

      nowMs = 3500;
      gw.pushButtonEvent(
        gesture: 'long_press_end',
        durationMs: 2000,
        receivedAtMs: 3500,
      );
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(coord.phase, HardwareAgentPhase.idle);
      expect(slicedCounts.length, 1);
      expect(slicedCounts.first, greaterThan(16000));
      expect(
        completion.userPrompts.any((p) => p.contains('我今天下午有什么日程？')),
        isTrue,
      );
      expect(chat.messages.last.text, '今天下午四点有个产品对齐会。');
      expect(speech.spokenTexts, contains('今天下午四点有个产品对齐会。'));
      expect(gw.ledHintModes, ['listening', 'thinking', 'done']);

      coord.dispose();
      await worker.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      speech.dispose();
    },
  );

  test(
    'Case 3: 持续录音若窗口内已有转写文本，直接复用不重复跑端侧转写',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_btn_case3_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(initialSnapshot: _dyjSnapshot(recording: true));
      final device = DeviceStore(gateway: gw);
      await device.restoreLink();
      final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);

      final speech = _FakeSpeechBackend();
      final completion = _FakeCompletion('好的，已帮你在笔记里标出。');
      final worker = AgentHarnessWorker(
        complete: completion.complete,
        inProcess: true,
      );
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        completion: completion,
        worker: worker,
        agentDirResolver: () async => '',
      );

      var transcribeCalls = 0;
      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        lookupExistingTranscript: (startMs, endMs) async => '刚才已经转写好的任务内容',
        transcribeSamples: (samples, {sampleRate = 16000}) async {
          transcribeCalls++;
          return '不应该走到这里';
        },
      );

      gw.pushButtonEvent(
        gesture: 'long_press_start',
        durationMs: 600,
        receivedAtMs: 5000,
      );
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      gw.pushButtonEvent(
        gesture: 'long_press_end',
        durationMs: 1800,
        receivedAtMs: 6200,
      );
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(transcribeCalls, 0);
      expect(
        completion.userPrompts.any((p) => p.contains('刚才已经转写好的任务内容')),
        isTrue,
      );
      expect(speech.spokenTexts, contains('好的，已帮你在笔记里标出。'));

      coord.dispose();
      await worker.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      speech.dispose();
    },
  );

  test(
    'Case 4: 未开启持续录音时按 DYJ V1 长按 → 自动拉起临时实时流并在说完关闭，isRecording 保持 false',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_btn_case4_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(initialSnapshot: _dyjSnapshot(recording: false));
      gw.realtimeEvents.add(
        RealtimeAudioEvent(
          kind: RealtimeAudioKind.audio,
          pcm: _voicedPcm(samples: 3200),
        ),
      );
      final device = DeviceStore(gateway: gw);
      await device.restoreLink();
      final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);

      final speech = _FakeSpeechBackend();
      final completion = _FakeCompletion('临时语音任务已完成，室外现在多云。');
      final worker = AgentHarnessWorker(
        complete: completion.complete,
        inProcess: true,
      );
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        completion: completion,
        worker: worker,
        agentDirResolver: () async => '',
      );

      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        transcribeSamples: (samples, {sampleRate = 16000}) async => '今天北京天气怎么样？',
      );

      gw.pushButtonEvent(
        gesture: 'long_press_start',
        durationMs: 600,
        receivedAtMs: 8000,
      );
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gw.realtimeOpenCalls, 1);

      gw.pushButtonEvent(
        gesture: 'long_press_end',
        durationMs: 1800,
        receivedAtMs: 9200,
      );
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gw.realtimeCloseCalls, 1);
      expect(device.isRecording, isFalse);
      expect(gw.recordCalls, isEmpty);
      expect(
        completion.userPrompts.any((p) => p.contains('今天北京天气怎么样？')),
        isTrue,
      );
      expect(speech.spokenTexts, contains('临时语音任务已完成，室外现在多云。'));

      coord.dispose();
      await worker.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      speech.dispose();
    },
  );

  test(
    'Case 5: DYJ V1 双击触发拍照识别（camera_capture_and_fetch → 多模态识别 → TTS 播报）',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_btn_case5_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(
        initialSnapshot: _dyjSnapshot(recording: false),
        fakeCapturedPhotoBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0xD9]),
      );
      final device = DeviceStore(gateway: gw);
      await device.restoreLink();
      final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);

      final speech = _FakeSpeechBackend();
      final capturedUrls = <String?>[];
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        visionCompletion: (msgs, {String? model}) async {
          capturedUrls.add(msgs.last.imageDataUrl);
          return '这是一杯拿铁咖啡。';
        },
        agentDirResolver: () async => '',
      );

      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        tempDirResolver: () async => dir,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        transcribeSamples: (samples, {sampleRate = 16000}) async => '',
      );

      gw.pushButtonEvent(gesture: 'double_click', receivedAtMs: 10000);
      await device.pollEventsNow();
      await coord.idle;
      await Future<void>.delayed(Duration.zero);

      expect(gw.callLog, contains('camera_capture_and_fetch'));
      expect(capturedUrls.length, 1);
      expect(
        capturedUrls.single,
        startsWith('data:image/jpeg;base64,'),
      );
      expect(chat.messages.last.text, '这是一杯拿铁咖啡。');
      expect(speech.spokenTexts, contains('这是一杯拿铁咖啡。'));

      coord.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      speech.dispose();
    },
  );

  test(
    'Case 6: 未连硬件时触发 iPhone 操作按钮 → 自动开临时本机麦克风，再按停止识别并发 Agent（isPhoneRecording 保持 false）',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_btn_case6_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(initialSnapshot: null);
      final device = DeviceStore(gateway: gw);
      await device.restoreLink();
      final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);

      final mic = _FakePhoneMicBackend([_voicedPcm(samples: 3200)]);
      final speech = _FakeSpeechBackend();
      final completion = _FakeCompletion('已经帮你记下来：周五上午九点去机场。');
      final worker = AgentHarnessWorker(
        complete: completion.complete,
        inProcess: true,
      );
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        completion: completion,
        worker: worker,
        agentDirResolver: () async => '',
      );

      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        phoneMicBackendFactory: () => mic,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        transcribeSamples: (samples, {sampleRate = 16000}) async => '提醒我周五九点去机场',
      );

      // 第一次触发：开始临时采集
      await coord.handleIphoneAgentTrigger();
      expect(coord.phase, HardwareAgentPhase.listening);
      expect(mic.startCalls, 1);
      expect(device.isPhoneRecording, isFalse);

      // 第二次触发：停止临时采集 → 转写 → 发给 Agent → 播报
      await coord.handleIphoneAgentTrigger();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coord.phase, HardwareAgentPhase.idle);
      expect(mic.stopCalls, 1);
      expect(device.isPhoneRecording, isFalse);
      expect(
        completion.userPrompts.any((p) => p.contains('提醒我周五九点去机场')),
        isTrue,
      );
      expect(speech.spokenTexts, contains('已经帮你记下来：周五上午九点去机场。'));

      coord.dispose();
      await worker.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      speech.dispose();
    },
  );

  testWidgets(
    'Case 7: 实时按键 Toast 反馈覆盖单击、双击、长按与 iPhone 操作按钮，并在 AppShell 顶部立即可见',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('rc_btn_case7_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(initialSnapshot: _dyjSnapshot(recording: false));
      final device = DeviceStore(gateway: gw);
      await device.restoreLink();
      final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);

      final mic = _FakePhoneMicBackend([_voicedPcm(samples: 3200)]);
      final speech = _FakeSpeechBackend();
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        agentDirResolver: () async => '',
      );

      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        phoneMicBackendFactory: () => mic,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        transcribeSamples: (samples, {sampleRate = 16000}) async => '',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            store: appStore,
            device: device,
            agentConfig: cfg,
            liveAudio: liveAudio,
            agentChat: chat,
            hardwareAgentCoordinator: coord,
            supportsDynamicIslandOverride: true,
          ),
        ),
      );
      await tester.pump();

      gw.pushButtonEvent(gesture: 'click', receivedAtMs: 11000);
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hw-button-toast')), findsOneWidget);
      expect(find.textContaining('单击 (click)'), findsOneWidget);

      gw.pushButtonEvent(gesture: 'double_click', receivedAtMs: 11200);
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hw-button-toast')), findsOneWidget);
      expect(find.textContaining('双击 (double_click)'), findsOneWidget);

      gw.pushButtonEvent(
        gesture: 'long_press_start',
        durationMs: 600,
        receivedAtMs: 11500,
      );
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hw-button-toast')), findsOneWidget);
      expect(find.textContaining('长按开始 (long_press_start)'), findsOneWidget);

      gw.pushButtonEvent(
        gesture: 'long_press_end',
        durationMs: 1450,
        receivedAtMs: 12950,
      );
      await device.pollEventsNow();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hw-button-toast')), findsOneWidget);
      expect(find.textContaining('长按结束 (long_press_end · 1450ms)'), findsOneWidget);

      unawaited(coord.handleIphoneAgentTrigger());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hw-button-toast')), findsOneWidget);
      expect(find.textContaining('收到操作按钮：触发语音任务'), findsOneWidget);

      // pumpWidget 销毁树后清理内部定时器
      await tester.pumpWidget(const SizedBox.shrink());
      coord.dispose();
      chat.dispose();
      liveAudio.dispose();
      device.dispose();
      cfg.dispose();
      appStore.dispose();
      speech.dispose();
    },
  );
}
