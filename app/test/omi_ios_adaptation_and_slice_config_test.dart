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

class _StreamingOmiGateway extends FakeCardGateway {
  _StreamingOmiGateway({super.initialSnapshot});

  final StreamController<RealtimeAudioEvent> audioCtrl =
      StreamController<RealtimeAudioEvent>.broadcast();

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    realtimeOpenCalls++;
    callLog.add('realtime.open');
    return audioCtrl.stream;
  }

  Future<void> disposeStream() => audioCtrl.close();
}

class _StubSpeechBackend implements AgentSpeechBackend {
  final StreamController<AgentSpeechEvent> _ctrl =
      StreamController<AgentSpeechEvent>.broadcast();

  @override
  Stream<AgentSpeechEvent> get events => _ctrl.stream;

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async => true;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  void dispose() {
    unawaited(_ctrl.close());
  }
}

class _StubCompletion implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    return jsonEncode({'react': '', 'reply': 'Omi 语音任务已处理。'});
  }
}

CardSnapshot _omiSnapshot({bool recording = false}) => CardSnapshot(
  batteryLevel: 83,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '3.0.21',
  fwVersionCode: 30021,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'Omi',
  deviceId: 'omi-ios-test-1',
  deviceKind: DeviceKind.omiCv1,
  displayModel: 'Omi 录音器',
  capabilities: HardwareCapabilities.omiCv1,
);

/// 生成可触发有效能量的 16kHz 16-bit LE 周期矩形脉冲（每个采样 2 字节）。
Uint8List _tonedPcmBytes({required int seconds}) {
  final samples = seconds * 16000;
  final out = Uint8List(samples * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    bd.setInt16(i * 2, (i % 32 < 16) ? 5000 : -5000, Endian.little);
  }
  return out;
}

void main() {
  group('Omi iOS 按键安全适配（禁用长按防 3s 关机）', () {
    test('能力矩阵、默认按键与长按/无摄像头拍照拦截及持久化', () async {
      expect(HardwareCapabilities.omiCv1.hasConfigurableButtons, isTrue);
      expect(HardwareCapabilities.omiCv1.hasMarkButton, isTrue);
      expect(HardwareCapabilities.omiCv1.hasCameraMedia, isFalse);

      final store = InMemoryStore();
      final cfg = AgentConfigStore(store: store);
      addTearDown(cfg.dispose);
      await cfg.load();

      expect(cfg.omiClickAction, HardwareButtonAction.mark);
      expect(cfg.omiDoubleClickAction, HardwareButtonAction.recordToggle);
      expect(cfg.omiButtonSummary, '单击重点 · 双击录音（禁用长按）');

      // Omi 不支持长按（防 3 秒关机误触）
      expect(
        cfg.buttonActionForDevice(DeviceKind.omiCv1, 'long_press_start'),
        HardwareButtonAction.none,
      );
      expect(
        cfg.buttonActionForDevice(DeviceKind.omiCv1, 'long_press'),
        HardwareButtonAction.none,
      );
      expect(
        cfg.buttonActionForDevice(DeviceKind.omiCv1, 'single_tap'),
        HardwareButtonAction.mark,
      );
      expect(
        cfg.buttonActionForDevice(DeviceKind.omiCv1, 'double_tap'),
        HardwareButtonAction.recordToggle,
      );

      // setOmiButtonAction 拦截 long_press 与 photoRecognize
      await cfg.setOmiButtonAction(
        'long_press',
        HardwareButtonAction.agentVoice,
      );
      await cfg.setOmiButtonAction(
        'click',
        HardwareButtonAction.photoRecognize,
      );
      expect(cfg.omiClickAction, HardwareButtonAction.mark);

      await cfg.setOmiButtonAction(
        'double_click',
        HardwareButtonAction.agentVoice,
      );
      await cfg.setRecordingSliceSeconds(300);

      final reloaded = AgentConfigStore(store: store);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(
        reloaded.omiDoubleClickAction,
        HardwareButtonAction.agentVoice,
      );
      expect(reloaded.recordingSliceSeconds, 300);
      expect(reloaded.recordingSliceDuration, const Duration(minutes: 5));
    });

    testWidgets('Omi 状态弹层按键配置视图隐藏长按与拍照并展示 3s 关机警示', (
      tester,
    ) async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      addTearDown(cfg.dispose);
      await cfg.load();

      final omiDev = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _omiSnapshot()),
      );
      addTearDown(omiDev.dispose);
      await omiDev.restoreLink();
      omiDev.openSheet();

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                StatusSheetOverlay(store: omiDev, agentConfig: cfg),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('btn-config')), findsOneWidget);
      expect(find.text('已设置 2 项'), findsOneWidget);
      expect(find.textContaining('禁用长按'), findsNothing);

      await tester.tap(find.byKey(const Key('btn-config')));
      await tester.pump();

      expect(find.byKey(const Key('btn-config-view')), findsOneWidget);
      expect(find.textContaining('禁用长按'), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-click')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-double')), findsOneWidget);
      expect(find.byKey(const Key('btn-cfg-long')), findsNothing);
      expect(find.byKey(const Key('btn-cfg-omi-no-long')), findsOneWidget);
      expect(
        find.byKey(const Key('btn-cfg-click-photo_recognize')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('btn-cfg-double_click-photo_recognize')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('btn-cfg-double_click-agent_voice')));
      await tester.pump();
      expect(cfg.omiDoubleClickAction, HardwareButtonAction.agentVoice);
    });

    test('Omi 协调器忽略长按、单击同步写入切片 marksMs、双击支持语音任务', () async {
      final dir = await Directory.systemTemp.createTemp('rc_omi_btn_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      var nowMs = 1000;
      DateTime fakeClock() => DateTime.fromMillisecondsSinceEpoch(nowMs);

      final cfg = AgentConfigStore(store: InMemoryStore());
      addTearDown(cfg.dispose);
      await cfg.load();

      final appStore = AppStore(loadPersistedState: false);
      addTearDown(appStore.dispose);
      final gw = _StreamingOmiGateway(
        initialSnapshot: _omiSnapshot(recording: true),
      );
      addTearDown(gw.disposeStream);
      final device = DeviceStore(gateway: gw);
      addTearDown(device.dispose);
      await device.restoreLink();

      final slices = <LiveAudioSlice>[];
      final liveAudio = LiveAudioRecorder(
        gateway: gw,
        baseDir: dir,
        sliceDuration: const Duration(seconds: 5),
        onSliceReady: slices.add,
        clock: fakeClock,
      );
      addTearDown(liveAudio.dispose);
      await liveAudio.start();
      // 注入 2 秒音频，使 marksMs 落点处于当前切片中间
      final chunk = _tonedPcmBytes(seconds: 2);
      gw.audioCtrl.add(
        RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: chunk),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final speech = _StubSpeechBackend();
      addTearDown(speech.dispose);
      final completion = _StubCompletion();
      final worker = AgentHarnessWorker(
        complete: completion.complete,
        inProcess: true,
      );
      addTearDown(() => worker.dispose());
      final chat = AgentChatController(
        appStore: appStore,
        agentConfig: cfg,
        speech: speech,
        completion: completion,
        worker: worker,
        agentDirResolver: () async => '',
        clock: fakeClock,
      );
      addTearDown(chat.dispose);

      var voiceTranscribed = 0;
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
          voiceTranscribed++;
          return '记一下待办';
        },
      );
      addTearDown(coord.dispose);

      // 1) 长按手势对 Omi 完全免疫：无 Toast、无语音监听、无 LED 呼叫
      gw.pushButtonEvent(gesture: 'long_press_start', receivedAtMs: 1200);
      await device.pollEventsNow();
      await Future<void>.delayed(Duration.zero);
      expect(coord.lastButtonToast, isNull);
      expect(coord.phase, HardwareAgentPhase.idle);

      // 2) 单击（single_tap）触发重点标记，并记录进当前实时切片 marksMs
      gw.pushButtonEvent(gesture: 'single_tap', receivedAtMs: 2000);
      await device.pollEventsNow();
      await Future<void>.delayed(Duration.zero);
      expect(gw.markCalls, 1);
      expect(coord.lastButtonToast, contains('单击'));

      // 停录封口切片，校验 marksMs 已附着到切片元数据
      await liveAudio.stop();
      await liveAudio.pendingSliceWrites;
      expect(slices.length, 1);
      expect(slices.first.marksMs, [2000]);

      // 3) 切换双击为语音任务，验证双击启停语音任务且不会下发 DYJ LED 指示
      await cfg.setOmiButtonAction(
        'double_click',
        HardwareButtonAction.agentVoice,
      );
      await liveAudio.start();
      nowMs = 3000;
      liveAudio.ringBuffer.append(
        _tonedPcmBytes(seconds: 2),
        endTimestampMs: 4000,
      );
      gw.pushButtonEvent(gesture: 'double_tap', receivedAtMs: 3000);
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coord.phase, HardwareAgentPhase.listening);

      nowMs = 4500;
      gw.pushButtonEvent(gesture: 'double_tap', receivedAtMs: 4500);
      await device.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(coord.phase, HardwareAgentPhase.idle);
      expect(voiceTranscribed, 1);
      expect(gw.ledHintModes, isEmpty);
      await liveAudio.stop();
    });
  });

  group('可配置实时录音切片窗口（1 分钟 / 5 分钟 / 动态缩窗即时切分）', () {
    test('LiveAudioRecorder 按 5 分钟切分且运行中缩窗立即冲刷', () async {
      final dir = await Directory.systemTemp.createTemp('rc_live_slice_cfg_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final gw = _StreamingOmiGateway(
        initialSnapshot: _omiSnapshot(recording: true),
      );
      addTearDown(gw.disposeStream);

      final slices = <LiveAudioSlice>[];
      final recorder = LiveAudioRecorder(
        gateway: gw,
        baseDir: dir,
        sliceDuration: const Duration(minutes: 5),
        onSliceReady: slices.add,
      );
      addTearDown(recorder.dispose);
      await recorder.start();

      // 连续注入 2 分钟高能无停顿音频：在 5 分钟设置下尚未触发切分
      gw.audioCtrl.add(
        RealtimeAudioEvent(
          kind: RealtimeAudioKind.audio,
          pcm: _tonedPcmBytes(seconds: 60),
        ),
      );
      gw.audioCtrl.add(
        RealtimeAudioEvent(
          kind: RealtimeAudioKind.audio,
          pcm: _tonedPcmBytes(seconds: 60),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await recorder.pendingSliceWrites;
      expect(slices, isEmpty);

      // 动态改回 1 分钟（60s）窗口：已缓冲的 120s 应立刻被切出 2 片 60s WAV
      recorder.setSliceDuration(const Duration(minutes: 1));
      await recorder.pendingSliceWrites;
      expect(slices.length, 2);
      expect(slices[0].durationMs, 60000);
      expect(slices[1].durationMs, 60000);

      await recorder.stop();
    });

    test('PhoneMicRecorder 支持动态调整切片窗口（5 分钟与缩窗即时冲刷）', () async {
      final dir = await Directory.systemTemp.createTemp('rc_phone_slice_cfg_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final recorder = PhoneMicRecorder(
        sliceDuration: const Duration(minutes: 5),
        sliceRootDir: () async => dir,
      );
      final emitted = <LiveAudioSlice>[];
      final sub = recorder.slices.listen(emitted.add);
      addTearDown(() async {
        await sub.cancel();
        recorder.dispose();
      });

      await recorder.start(
        startedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      // 注入 20 秒连续音频（在 5 分钟设置下不切分）
      recorder.ingestPcm(_tonedPcmBytes(seconds: 20));
      await recorder.pendingSliceWrites;
      expect(emitted, isEmpty);

      // 运行中调短为 10 秒：立即切出 2 片 10 秒 WAV
      recorder.setSliceDuration(const Duration(seconds: 10));
      await recorder.pendingSliceWrites;
      expect(emitted.length, 2);
      expect(emitted[0].durationMs, 10000);
      expect(emitted[1].durationMs, 10000);

      await recorder.stop();
    });

    testWidgets('SettingSubPage(dev) 暴露 1/2/5/10/15 分钟预设并实时联动 AppShell 设备切片时长', (
      tester,
    ) async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      addTearDown(cfg.dispose);
      await cfg.load();
      expect(cfg.recordingSliceSeconds, 60);

      final appStore = AppStore(loadPersistedState: false);
      addTearDown(appStore.dispose);
      final device = DeviceStore(gateway: FakeCardGateway());
      addTearDown(device.dispose);

      // 先测试 AppShell 对齐初始与后续变更
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: appStore,
            device: device,
            agentConfig: cfg,
            supportsDynamicIslandOverride: false,
          ),
        ),
      );
      await tester.pump();
      expect(device.recordingSliceDuration, const Duration(seconds: 60));

      await cfg.setRecordingSliceSeconds(300);
      await tester.pump();
      expect(device.recordingSliceDuration, const Duration(minutes: 5));

      // 再渲染开发者/分段设置子页（无需开启 developerMode 也可直接调节切片时长）
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: SettingSubPage(subId: 'dev', agentConfig: cfg),
        ),
      );
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('dev-slice-seconds-value'))).data,
        '5 分钟',
      );
      expect(find.byKey(const Key('dev-slice-preset-60')), findsOneWidget);
      expect(find.byKey(const Key('dev-slice-preset-300')), findsOneWidget);
      expect(find.byKey(const Key('dev-slice-preset-600')), findsOneWidget);
      expect(find.byKey(const Key('dev-slice-slider')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dev-slice-preset-60')));
      await tester.pump();
      expect(cfg.recordingSliceSeconds, 60);
      expect(
        tester.widget<Text>(find.byKey(const Key('dev-slice-seconds-value'))).data,
        '1 分钟',
      );
    });
  });
}
