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
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/agent/hardware_agent_task_coordinator.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/device/oled_bitmap_renderer.dart';

import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _FakeSpeechBackend implements AgentSpeechBackend {
  final StreamController<AgentSpeechEvent> _ctrl =
      StreamController<AgentSpeechEvent>.broadcast();

  bool speaking = false;
  final List<String> spokenTexts = [];

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
  _FakeCompletion([this.replyText = '收到，已帮你处理完成。']);

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
    for (final c in chunksToEmit) {
      onPcm(c);
    }
  }

  @override
  Future<void> stopCapture() async {
    stopCalls++;
  }
}

class _FakeOledRenderer implements OledBitmapRenderer {
  int renderCalls = 0;

  @override
  Future<Uint8List> renderText({required String line1, String? line2}) async {
    renderCalls++;
    return FlutterOledBitmapRenderer.renderFallbackBitmap360(
      line1: line1,
      line2: line2,
    );
  }
}

class _HoldingRealtimeGateway extends FakeCardGateway {
  _HoldingRealtimeGateway({required super.initialSnapshot});

  final StreamController<RealtimeAudioEvent> rtCtrl =
      StreamController<RealtimeAudioEvent>.broadcast();

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    realtimeOpenCalls++;
    callLog.add('realtime.open');
    return rtCtrl.stream;
  }

  @override
  Future<void> closeRealtime() async {
    await super.closeRealtime();
    if (!rtCtrl.isClosed) {
      await rtCtrl.close();
    }
  }
}

CardSnapshot _cardV2Snapshot({
  bool recording = false,
  String deviceName = 'DYJV2_A9B8',
}) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '0.3.9',
  fwVersionCode: 309,
  wifiVersion: '0.2.1',
  wifiVersionCode: 201,
  deviceName: deviceName,
  deviceId: 'card-v2-test-1',
  deviceKind: DeviceKind.cardV2,
  capabilities: HardwareCapabilities.cardV2,
);

Uint8List _voicedPcm({int samples = 3200}) {
  final out = Uint8List(samples * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final v = (i % 32 < 16) ? 6000 : -6000;
    view.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) break;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'Case 1: 首次连接 CardV2 且硬件未配置时自动写入默认按键/拨杆绑定并展示「已连接 + 型号短号」OLED 提示',
    () async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      expect(cfg.cardClickAction, HardwareButtonAction.mark);
      expect(cfg.cardDoubleClickAction, HardwareButtonAction.syncNow);
      expect(cfg.cardLongPressAction, HardwareButtonAction.agentVoice);
      expect(cfg.cardSwitchOnAction, HardwareButtonAction.recordStart);
      expect(cfg.cardSwitchOffAction, HardwareButtonAction.recordStop);
      expect(cfg.cardControlsUserConfigured, isFalse);

      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(deviceName: 'DYJV2_9F42'),
      );
      final oled = _FakeOledRenderer();
      final device = DeviceStore(
        gateway: gw,
        agentConfig: cfg,
        oledRenderer: oled,
      );
      addTearDown(() {
        device.dispose();
        cfg.dispose();
      });

      const scannedDevice = CardDevice(
        id: 'card-v2-test-1',
        name: 'DYJV2_9F42',
        rssi: -52,
        kind: DeviceKind.cardV2,
      );
      await device.connectTo(scannedDevice);
      await Future<void>.delayed(Duration.zero);

      expect(gw.cardControlsGetCalls, 1);
      expect(gw.cardControlsSetCalls.length, 1);
      expect(gw.cardControls['btnSingle'], 'record_mark');
      expect(gw.cardControls['btnDouble'], 'app_sync');
      expect(gw.cardControls['btnLongPress'], 'agent_voice');
      expect(gw.cardControls['btnLongRelease'], 'none');
      expect(gw.cardControls['switchOn'], 'record_start');
      expect(gw.cardControls['switchOff'], 'record_stop');

      expect(oled.renderCalls, greaterThanOrEqualTo(1));
      expect(gw.displayShowCalls, isNotEmpty);
      final connectPrompt = gw.displayShowCalls.first;
      expect(connectPrompt['lines'], ['已连接', '9F42']);
      final decodedBitmap = base64Decode(
        connectPrompt['bitmapBase64'] as String,
      );
      expect(decodedBitmap.length, oledBitmapBytes);
    },
  );

  test(
    'Case 2: 硬件已有自定义按键绑定且 App 未个性配置时，连接后回读硬件 KV 到 App 而不覆盖设备',
    () async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      expect(cfg.cardControlsUserConfigured, isFalse);

      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(),
        initialCardControls: const {
          'btnSingle': 'record_toggle',
          'btnDouble': 'record_mark',
          'btnLongPress': 'app_sync',
          'switchOn': 'agent_voice',
          'switchOff': 'none',
        },
      );
      final device = DeviceStore(gateway: gw, agentConfig: cfg);
      addTearDown(() {
        device.dispose();
        cfg.dispose();
      });

      await device.restoreLink();
      await Future<void>.delayed(Duration.zero);

      expect(gw.cardControlsGetCalls, 1);
      expect(gw.cardControlsSetCalls, isEmpty);
      expect(cfg.cardClickAction, HardwareButtonAction.recordToggle);
      expect(cfg.cardDoubleClickAction, HardwareButtonAction.mark);
      expect(cfg.cardLongPressAction, HardwareButtonAction.syncNow);
      expect(cfg.cardSwitchOnAction, HardwareButtonAction.agentVoice);
      expect(cfg.cardSwitchOffAction, HardwareButtonAction.none);
      expect(cfg.cardControlsUserConfigured, isTrue);
    },
  );

  testWidgets(
    'Case 3: StatusSheet 「按键行为设置」展示 5 项按键/拨杆、修改即时同步与 OLED 提示、支持重置默认与持久化',
    (tester) async {
      final backing = InMemoryStore();
      final cfg = AgentConfigStore(store: backing);
      await cfg.load();

      final gw = FakeCardGateway(initialSnapshot: _cardV2Snapshot());
      final device = DeviceStore(gateway: gw, agentConfig: cfg);
      await device.restoreLink();
      await tester.pump();
      device.openSheet();

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                StatusSheetOverlay(store: device, agentConfig: cfg),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('btn-config')), findsOneWidget);
      expect(find.text('按键行为设置'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn-config')));
      await tester.pump();

      expect(find.byKey(const Key('btn-config-view')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-click')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-double')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-long')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-switch_on')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-switch_off')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-reset-default')), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('btn-cfg-double_click-record_toggle')),
      );
      await tester.tap(
        find.byKey(const Key('btn-cfg-double_click-record_toggle')),
      );
      await tester.pump();
      await tester.pump();

      expect(cfg.cardDoubleClickAction, HardwareButtonAction.recordToggle);
      expect(cfg.cardControlsUserConfigured, isTrue);
      expect(gw.cardControls['btnDouble'], 'record_toggle');
      expect(gw.displayShowCalls.last['lines'], ['按键已设置', '录音']);

      await tester.ensureVisible(
        find.byKey(const Key('btn-cfg-switch_on-agent_voice')),
      );
      await tester.tap(find.byKey(const Key('btn-cfg-switch_on-agent_voice')));
      await tester.pump();
      await tester.pump();

      expect(cfg.cardSwitchOnAction, HardwareButtonAction.agentVoice);
      expect(gw.cardControls['switchOn'], 'agent_voice');

      final reloaded = AgentConfigStore(store: backing);
      await reloaded.load();
      expect(
        reloaded.cardDoubleClickAction,
        HardwareButtonAction.recordToggle,
      );
      expect(reloaded.cardSwitchOnAction, HardwareButtonAction.agentVoice);
      expect(reloaded.cardControlsUserConfigured, isTrue);

      await tester.ensureVisible(
        find.byKey(const Key('btn-cfg-reset-default')),
      );
      await tester.tap(find.byKey(const Key('btn-cfg-reset-default')));
      await tester.pump();
      await tester.pump();

      expect(cfg.cardDoubleClickAction, HardwareButtonAction.syncNow);
      expect(cfg.cardSwitchOnAction, HardwareButtonAction.recordStart);
      expect(gw.cardControls['btnSingle'], 'record_mark');
      expect(gw.cardControls['btnDouble'], 'app_sync');
      expect(gw.cardControls['btnLongPress'], 'agent_voice');
      expect(gw.cardControls['switchOn'], 'record_start');
      expect(gw.cardControls['switchOff'], 'record_stop');
      expect(gw.displayShowCalls.last['lines'], ['按键已重置', '已恢复默认']);

      reloaded.dispose();
      device.dispose();
      cfg.dispose();
    },
  );

  test(
    'Case 4: 单击打重点不重复调 mark()、双击立即同步（空闲走 syncNow，录音中切出实况片段）、长按把长按窗内容发给 Agent + OLED 阶段提示',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_cardv2_case4_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      var nowMs = 2000;
      DateTime fakeClock() => DateTime.fromMillisecondsSinceEpoch(nowMs);

      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);

      final pcmChunk = _voicedPcm(samples: 16000); // 1000ms @ 16kHz
      final gw = _HoldingRealtimeGateway(
        initialSnapshot: _cardV2Snapshot(recording: false),
      );
      var manualBleSyncCalls = 0;
      final device = DeviceStore(gateway: gw, agentConfig: cfg)
        ..onManualBleSync = () async {
          manualBleSyncCalls++;
          return null;
        };
      await device.restoreLink();
      await Future<void>.delayed(Duration.zero);

      final mic = _FakePhoneMicBackend([_voicedPcm(samples: 8000)]);
      final liveAudio = LiveAudioRecorder(
        gateway: gw,
        baseDir: dir,
        clock: fakeClock,
      );
      final speech = _FakeSpeechBackend();
      final completion = _FakeCompletion('好的，已查询完成。');
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

      final coord = HardwareAgentTaskCoordinator(
        device: device,
        agentConfig: cfg,
        agentChat: chat,
        liveAudio: liveAudio,
        phoneMicBackendFactory: () => mic,
        clock: fakeClock,
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
        maxVoiceTaskDuration: Duration.zero,
        transcribeSamples: (samples, {sampleRate = 16000}) async =>
            '帮我记一下明早十点开会',
      );
      addTearDown(() async {
        await liveAudio.stop();
        if (!gw.rtCtrl.isClosed) {
          await gw.rtCtrl.close();
        }
        coord.dispose();
        chat.dispose();
        speech.dispose();
        appStore.dispose();
        device.dispose();
        cfg.dispose();
      });

      // 4a) 单击 Mark（固件已原生执行 record_mark）：不重复调用 gateway.mark()，更新状态 + 中文 OLED
      gw.pushButtonEvent(
        gesture: 'click',
        deviceAction: 'record_mark',
        source: 'card_v2_button',
        receivedAtMs: 2100,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () =>
            coord.statusText == '已打重点标记' &&
            (gw.displayShowCalls.last['lines'] as List?)?.first == '已打重点',
      );
      expect(gw.markCalls, 0);
      expect(coord.statusText, '已打重点标记');
      expect(gw.displayShowCalls.last['lines'], ['已打重点', '标记成功']);

      // 4b) 空闲态双击立即同步（app_sync）：走 device.syncNow(manual: true) + OLED 提示
      gw.pushButtonEvent(
        gesture: 'double_click',
        deviceAction: 'app_sync',
        source: 'card_v2_button',
        receivedAtMs: 2200,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () => gw.displayShowCalls.any((c) {
          final lines = c['lines'] as List?;
          return lines != null && lines.first == '同步完成';
        }),
      );
      expect(manualBleSyncCalls, 1);
      expect(
        gw.displayShowCalls.any((c) {
          final lines = c['lines'] as List?;
          return lines != null && lines.first == '同步完成';
        }),
        isTrue,
      );

      // 4c) 空闲态长按语音发 Agent：CardV2 不含独立实时流 -> 走手机临时麦克风而非调用 realtimeAudio()
      final rtOpenBefore = gw.realtimeOpenCalls;
      gw.pushButtonEvent(
        gesture: 'long_press_start',
        deviceAction: 'agent_voice',
        source: 'card_v2_button',
        receivedAtMs: 2400,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () =>
            mic.startCalls == 1 &&
            gw.displayShowCalls.any((c) => (c['lines'] as List).first == '请说话'),
      );
      expect(gw.realtimeOpenCalls, rtOpenBefore);
      expect(mic.startCalls, 1);
      expect(
        gw.displayShowCalls.any((c) => (c['lines'] as List).first == '请说话'),
        isTrue,
      );

      nowMs = 3200;
      gw.pushButtonEvent(
        gesture: 'long_press_end',
        deviceAction: 'agent_voice',
        source: 'card_v2_button',
        receivedAtMs: 3200,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () =>
            completion.userPrompts.isNotEmpty &&
            (gw.displayShowCalls.last['lines'] as List?)?.first == '已回复',
      );

      expect(mic.stopCalls, 1);
      expect(completion.userPrompts.last, contains('帮我记一下明早十点开会'));
      expect(speech.spokenTexts.last, '好的，已查询完成。');
      expect(
        gw.displayShowCalls.any((c) => (c['lines'] as List).first == '正在识别'),
        isTrue,
      );
      expect(
        gw.displayShowCalls.any((c) => (c['lines'] as List).first == '思考中'),
        isTrue,
      );
      expect(gw.displayShowCalls.last['lines'], ['已回复', '请查收']);

      // 4d) 正在持续录音中双击立即同步 & 长按切环形缓冲
      gw.current = _cardV2Snapshot(recording: true);
      await device.refreshFromDevice();
      final sliceFuture = liveAudio.slices.first;
      await liveAudio.start();
      gw.rtCtrl.add(const RealtimeAudioEvent(kind: RealtimeAudioKind.open));
      gw.rtCtrl.add(
        RealtimeAudioEvent(
          kind: RealtimeAudioKind.audio,
          pcm: pcmChunk,
          sampleRate: 16000,
        ),
      );
      gw.rtCtrl.add(
        RealtimeAudioEvent(
          kind: RealtimeAudioKind.audio,
          pcm: pcmChunk,
          sampleRate: 16000,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      gw.pushButtonEvent(
        gesture: 'double_click',
        deviceAction: 'app_sync',
        source: 'card_v2_button',
        receivedAtMs: 4000,
      );
      await device.pollEventsNow();
      final flushedSlice = await sliceFuture.timeout(
        const Duration(seconds: 2),
      );
      await _waitUntil(
        () => (gw.displayShowCalls.last['lines'] as List?)?.first == '已同步',
      );
      expect(flushedSlice.durationMs, greaterThan(0));
      expect(coord.statusText, '已同步当前片段');
      expect(gw.displayShowCalls.last['lines'], ['已同步', '片段已生成']);

      // 4e) 持续录音中长按直接从 liveAudio.ringBuffer 切片，不再开临时麦克风
      liveAudio.ringBuffer.append(
        _voicedPcm(samples: 16000),
        endTimestampMs: 5000,
      );
      liveAudio.ringBuffer.append(
        _voicedPcm(samples: 16000),
        endTimestampMs: 6000,
      );
      final micCallsBefore = mic.startCalls;
      nowMs = 4900;
      gw.pushButtonEvent(
        gesture: 'long_press_start',
        deviceAction: 'agent_voice',
        source: 'card_v2_button',
        receivedAtMs: 4900,
      );
      await device.pollEventsNow();
      await _waitUntil(() => coord.phase == HardwareAgentPhase.listening);
      expect(mic.startCalls, micCallsBefore);

      nowMs = 6000;
      gw.pushButtonEvent(
        gesture: 'long_press_end',
        deviceAction: 'agent_voice',
        source: 'card_v2_button',
        receivedAtMs: 6000,
      );
      await device.pollEventsNow();
      await _waitUntil(() => completion.userPrompts.length >= 2);
      expect(completion.userPrompts.length, 2);

      // 4f) CardV2 实机固件发送 gesture='long_press' + 'long_press_end' 同样按住即录、松开即发
      liveAudio.ringBuffer.append(
        _voicedPcm(samples: 16000),
        endTimestampMs: 7000,
      );
      liveAudio.ringBuffer.append(
        _voicedPcm(samples: 16000),
        endTimestampMs: 8000,
      );
      nowMs = 7000;
      gw.pushButtonEvent(
        gesture: 'long_press',
        deviceAction: 'agent_voice',
        source: 'card_v2_button',
        receivedAtMs: 7000,
      );
      await device.pollEventsNow();
      await _waitUntil(() => coord.phase == HardwareAgentPhase.listening);

      nowMs = 8000;
      gw.pushButtonEvent(
        gesture: 'long_press_end',
        deviceAction: 'agent_voice',
        source: 'card_v2_button',
        receivedAtMs: 8000,
      );
      await device.pollEventsNow();
      await _waitUntil(() => completion.userPrompts.length >= 3);
      expect(completion.userPrompts.length, 3);
    },
  );

  test(
    'Case 5: 蓝牙软件开关优先于物理拨杆、拨杆依状态/屏幕变化跟随不重发指令，且全流程展示中文 OLED',
    () async {
      final dir = await Directory.systemTemp.createTemp('rc_cardv2_case5_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      final appStore = AppStore(loadPersistedState: false);
      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(recording: false),
      );
      final device = DeviceStore(gateway: gw, agentConfig: cfg);
      await device.restoreLink();
      await Future<void>.delayed(Duration.zero);

      final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);
      final speech = _FakeSpeechBackend();
      final completion = _FakeCompletion();
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
        transcribeSamples: (samples, {sampleRate = 16000}) async => '',
        postSettleDelay: Duration.zero,
        transientStatusDuration: Duration.zero,
      );
      addTearDown(() async {
        coord.dispose();
        chat.dispose();
        speech.dispose();
        appStore.dispose();
        device.dispose();
        cfg.dispose();
      });

      int startCalls() => gw.callLog.where((e) => e == 'record.start').length;
      int stopCalls() => gw.callLog.where((e) => e == 'record.stop').length;

      // 5a) 软件蓝牙开录优先：即便物理拨杆当前状态不同步，调用 toggleRecording() 发显式 startRecording 并写中文屏幕
      final startErr = await device.toggleRecording();
      await _waitUntil(
        () => (gw.displayShowCalls.last['lines'] as List?)?.first == '开始录音',
      );
      expect(startErr, isNull);
      expect(device.isRecording, isTrue);
      expect(startCalls(), 1);
      expect(gw.displayShowCalls.last['lines'], ['开始录音', '蓝牙开启']);

      // 5b) 此时用户从“关”拨到“开”：状态原本已在录音（无边沿变化），不重发 startRecording，并显示确认屏幕
      gw.pushToggleSwitchEvent(
        position: 'on',
        deviceAction: 'record_start',
        receivedAtMs: 5100,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () => (gw.displayShowCalls.last['lines'] as List?)?.first == '录音中',
      );
      expect(startCalls(), 1);
      expect(device.isRecording, isTrue);
      expect(gw.displayShowCalls.last['lines'], ['录音中', '拨杆已开']);

      // 5c) 拨杆关闭：硬件推送 RECORD_STATUS(recording=false, reason=switch) + TOGGLE_SWITCH(off, record_stop)
      //     状态与屏幕跟随停录且不重发 stopRecording
      final stopsBeforeSwitchOff = stopCalls();
      gw.pushRecordEvent(recording: false, reason: 'switch');
      gw.pushToggleSwitchEvent(
        position: 'off',
        deviceAction: 'record_stop',
        receivedAtMs: 5200,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () => (gw.displayShowCalls.last['lines'] as List?)?.first == '停止录音',
      );
      expect(device.isRecording, isFalse);
      expect(stopCalls(), stopsBeforeSwitchOff);
      expect(gw.displayShowCalls.last['lines'], ['停止录音', '拨杆关闭']);

      // 5d) 拨杆重新打开：跟随硬件状态变化为录音中，显示「开始录音 / 拨杆开启」
      final startsBeforeSwitchOn = startCalls();
      gw.pushRecordEvent(recording: true, reason: 'switch');
      gw.pushToggleSwitchEvent(
        position: 'on',
        deviceAction: 'record_start',
        receivedAtMs: 5300,
      );
      await device.pollEventsNow();
      await _waitUntil(
        () => (gw.displayShowCalls.last['lines'] as List?)?.first == '开始录音',
      );
      expect(device.isRecording, isTrue);
      expect(startCalls(), startsBeforeSwitchOn);
      expect(gw.displayShowCalls.last['lines'], ['开始录音', '拨杆开启']);

      // 5e) 拨杆仍在“开”的位置时，软件蓝牙开关强制停录：保证成功且写「停止录音 / 已保存」
      final stopErr = await device.setRecordingState(false);
      await _waitUntil(
        () => (gw.displayShowCalls.last['lines'] as List?)?.first == '停止录音',
      );
      expect(stopErr, isNull);
      expect(device.isRecording, isFalse);
      expect(stopCalls(), stopsBeforeSwitchOff + 1);
      expect(gw.displayShowCalls.last['lines'], ['停止录音', '已保存']);
    },
  );

  test(
    'Case 6: packRgbaToOledBitmap360 按 SSD1306 页列顺序（bit 0 为页顶行）准确输出 360 字节单色位图',
    () {
      final rgba = Uint8List(oledWidth * oledHeight * 4);
      void setPixel(int x, int y, {int rgb = 255}) {
        final idx = (y * oledWidth + x) * 4;
        rgba[idx] = rgb;
        rgba[idx + 1] = rgb;
        rgba[idx + 2] = rgb;
        rgba[idx + 3] = 255;
      }

      // Page 0 top row (y=0, col=0 -> byte 0, bit 0) & row 2 (y=2, col=0 -> byte 0, bit 2)
      setPixel(0, 0);
      setPixel(0, 2);
      // Page 4 bottom-most row (y=39 = 4*8 + 7, col=71 -> byte 4*72 + 71 = 359, bit 7)
      setPixel(71, 39);
      // Below threshold pixel should stay off
      setPixel(10, 8, rgb: 50);

      final packed = packRgbaToOledBitmap360(rgba);
      expect(packed.length, oledBitmapBytes);
      expect(packed[0], (1 << 0) | (1 << 2));
      expect(packed[1 * oledWidth + 10], 0);
      expect(packed[oledBitmapBytes - 1], 1 << 7);
    },
  );
}
