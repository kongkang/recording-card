/// 物理按键 × iPhone 操作按钮 → Agent 语音/拍照任务协调器。
///
/// 核心职责：
/// - 监听点一机 V1 等支持可配置按键的 `hardwareButtonEvents` 与 iPhone 操作按钮触发；
/// - `mark` / `recordToggle` 直接转发给 `DeviceStore`；
/// - `agentVoice`：
///   - 若当前已在持续录音（硬件实时流或本机录音），记录 `[tStartMs, tEndMs]` 并优先复用已有润色/原始转写，
///     否则从 `PcmRingBuffer` 零干扰切出对应时间窗音频走端侧识别；
///   - 若当前未在录音，自动拉起临时采集流（优先硬件实时流，无硬件/无流则本机麦克风），
///     识别后关闭临时流，**不启动长期录音、不污染 Timeline**；
///   - Agent 回复与异常均可通过原生 TTS（随 A2DP 耳机或本机扬声器）播报，
///     并维护打断/回声隔离时间戳（`notBeforeMs`）；
/// - `photoRecognize`：调用 `camera_capture_and_fetch` 并走 `AgentChatController.sendPhotoRecognitionMessage`。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/device_store.dart';
import '../audio/live_audio_recorder.dart';
import '../audio/pcm_ring_buffer.dart';
import '../audio/phone_mic_service.dart';
import 'agent_chat_controller.dart';

typedef SliceTranscribeFn = Future<String> Function(
  Float32List samples, {
  int sampleRate,
});

typedef TranscriptLookupFn = Future<String?> Function(
  int startMs,
  int endMs,
);

enum HardwareAgentPhase {
  idle,
  listening,
  transcribing,
  thinking,
  capturingPhoto,
}

class _ActiveVoiceSession {
  _ActiveVoiceSession({
    required this.tStartMs,
    required this.holdMode,
    required this.usedTempCapture,
    this.notBeforeMs,
  });

  final int tStartMs;
  final bool holdMode;
  final bool usedTempCapture;
  final int? notBeforeMs;

  final BytesBuilder tempPcm = BytesBuilder(copy: false);
  int tempSampleRate = 16000;
  StreamSubscription<RealtimeAudioEvent>? hwSub;
  bool usedHwRealtime = false;
  PhoneMicBackend? phoneBackend;
  Timer? maxDurationTimer;
  String? captureError;
}

class HardwareAgentTaskCoordinator extends ChangeNotifier {
  HardwareAgentTaskCoordinator({
    required DeviceStore device,
    required AgentConfigStore agentConfig,
    required AgentChatController agentChat,
    required LiveAudioRecorder liveAudio,
    required SliceTranscribeFn transcribeSamples,
    TranscriptLookupFn? lookupExistingTranscript,
    PhoneMicBackend Function()? phoneMicBackendFactory,
    Future<Directory> Function()? tempDirResolver,
    DateTime Function()? clock,
    Duration postSettleDelay = const Duration(milliseconds: 120),
    Duration maxVoiceTaskDuration = const Duration(seconds: 60),
    Duration transientStatusDuration = const Duration(seconds: 3),
  }) : _device = device,
       _agentConfig = agentConfig,
       _agentChat = agentChat,
       _liveAudio = liveAudio,
       _transcribeSamples = transcribeSamples,
       _lookupExistingTranscript = lookupExistingTranscript,
       _phoneMicBackendFactory =
           phoneMicBackendFactory ?? PlatformPhoneMicBackend.new,
       _tempDirResolver = tempDirResolver,
       _clock = clock ?? DateTime.now,
       _postSettleDelay = postSettleDelay,
       _maxVoiceTaskDuration = maxVoiceTaskDuration,
       _transientStatusDuration = transientStatusDuration {
    _wasAgentSpeaking = _agentChat.isSpeaking;
    _agentChat.addListener(_onAgentChatChanged);
    _buttonSub = _device.hardwareButtonEvents.listen(_onHardwareButtonEvent);
  }

  final DeviceStore _device;
  final AgentConfigStore _agentConfig;
  final AgentChatController _agentChat;
  final LiveAudioRecorder _liveAudio;
  final SliceTranscribeFn _transcribeSamples;
  final TranscriptLookupFn? _lookupExistingTranscript;
  final PhoneMicBackend Function() _phoneMicBackendFactory;
  final Future<Directory> Function()? _tempDirResolver;
  final DateTime Function() _clock;
  final Duration _postSettleDelay;
  final Duration _maxVoiceTaskDuration;
  final Duration _transientStatusDuration;

  StreamSubscription<HardwareButtonEvent>? _buttonSub;
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;

  HardwareAgentPhase phase = HardwareAgentPhase.idle;
  String? statusText;
  String? lastButtonToast;
  int buttonToastSeq = 0;

  bool _wasAgentSpeaking = false;
  int? _lastTtsEndedAtMs;
  int? _lastDownAtMs;
  _ActiveVoiceSession? _activeVoice;
  Timer? _statusClearTimer;
  Timer? _buttonToastTimer;

  void _emitButtonToast(String message) {
    if (_disposed) return;
    _buttonToastTimer?.cancel();
    _buttonToastTimer = null;
    lastButtonToast = message;
    buttonToastSeq += 1;
    notifyListeners();
    try {
      unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
    } catch (_) {}
    if (_transientStatusDuration > Duration.zero) {
      final seq = buttonToastSeq;
      _buttonToastTimer = Timer(_transientStatusDuration, () {
        if (_disposed || buttonToastSeq != seq) return;
        lastButtonToast = null;
        notifyListeners();
      });
    }
  }

  HardwareButtonAction _actionForGesture(String gesture) =>
      _device.activeCapabilities.hasConfigurableSwitch
      ? _agentConfig.cardActionForGesture(gesture)
      : _agentConfig.dyjActionForGesture(gesture);

  bool _wasExecutedByFirmware(
    HardwareButtonEvent ev,
    HardwareButtonAction action,
  ) {
    final raw = ev.deviceAction?.trim().toLowerCase() ?? '';
    if (raw.isEmpty || raw == 'none') return false;
    return switch ((raw, action)) {
      ('record_mark', HardwareButtonAction.mark) => true,
      ('record_start', HardwareButtonAction.recordStart) => true,
      ('record_stop', HardwareButtonAction.recordStop) => true,
      ('record_toggle', HardwareButtonAction.recordToggle) => true,
      ('sync_upload', HardwareButtonAction.syncNow) => true,
      _ => false,
    };
  }

  void _sendHardwareHint(
    String? mode, {
    String? oledLine1,
    String? oledLine2,
    int timeoutMs = 4000,
  }) {
    if (_device.activeCapabilities.hasOledDisplay &&
        oledLine1 != null &&
        oledLine1.trim().isNotEmpty) {
      unawaited(
        _device.showCardDisplayPrompt(
          line1: oledLine1,
          line2: oledLine2,
          timeoutMs: timeoutMs,
        ),
      );
      return;
    }
    if (mode != null && mode.isNotEmpty) {
      unawaited(_device.sendDyjLedHint(mode));
    }
  }

  String _formatButtonToast(
    HardwareButtonEvent ev,
    HardwareButtonAction action,
  ) {
    final suffix =
        action == HardwareButtonAction.none ? '' : ' → ${action.label}';
    return switch (ev.gesture) {
      'click' => '收到按键：单击 (click)$suffix',
      'double_click' => '收到按键：双击 (double_click)$suffix',
      'long_press_start' => '收到按键：长按开始 (long_press_start)$suffix',
      'long_press_end' =>
        '收到按键：长按结束 (long_press_end${ev.durationMs != null ? " · ${ev.durationMs}ms" : ""})',
      'long_press' => '收到按键：长按 (long_press)$suffix',
      'switch_on' => '收到拨杆：开启 (switch_on)$suffix',
      'switch_off' => '收到拨杆：关闭 (switch_off)$suffix',
      'down' => '收到按键：按下 (down)',
      'up' => '收到按键：松开 (up)',
      _ => '收到按键：${ev.gesture}$suffix',
    };
  }

  void _onAgentChatChanged() {
    if (_disposed) return;
    final speaking = _agentChat.isSpeaking;
    if (_wasAgentSpeaking && !speaking) {
      _lastTtsEndedAtMs = _clock().millisecondsSinceEpoch;
    }
    _wasAgentSpeaking = speaking;
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _serial.then((_) async {
      if (_disposed) return;
      await task();
    });
    _serial = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  Future<void> _interruptSpeechIfActive() async {
    if (_agentChat.isSpeaking) {
      await _agentChat.interruptSpeech();
      _lastTtsEndedAtMs = _clock().millisecondsSinceEpoch;
    }
  }

  void _setStatus(
    HardwareAgentPhase nextPhase,
    String? text, {
    bool transient = false,
  }) {
    if (_disposed) return;
    _statusClearTimer?.cancel();
    _statusClearTimer = null;
    phase = nextPhase;
    statusText = text;
    notifyListeners();
    if (transient && text != null && _transientStatusDuration > Duration.zero) {
      _statusClearTimer = Timer(_transientStatusDuration, () {
        if (_disposed) return;
        if (phase == HardwareAgentPhase.idle && statusText == text) {
          statusText = null;
          notifyListeners();
        }
      });
    }
  }

  void _onHardwareButtonEvent(HardwareButtonEvent ev) {
    if (_disposed) return;
    final action = _actionForGesture(ev.gesture);
    _emitButtonToast(_formatButtonToast(ev, action));

    if (ev.gesture == 'down') {
      _lastDownAtMs = ev.receivedAtMs;
      return;
    }

    if (_agentChat.isSpeaking && ev.gesture != 'up') {
      unawaited(_agentChat.interruptSpeech());
      _lastTtsEndedAtMs = ev.receivedAtMs;
    }

    if (ev.gesture == 'long_press_end' || ev.gesture == 'up') {
      unawaited(
        _enqueue(() async {
          final active = _activeVoice;
          if (active != null && active.holdMode) {
            await _finishVoiceSession(ev.receivedAtMs);
          }
        }),
      );
      return;
    }

    if (action == HardwareButtonAction.none) return;

    if (ev.gesture == 'long_press_start') {
      if (action == HardwareButtonAction.agentVoice) {
        final downTs = _lastDownAtMs;
        final fallbackDur = (ev.durationMs != null && ev.durationMs! > 0)
            ? ev.durationMs!
            : 800;
        final tStartMs = (downTs != null && (ev.receivedAtMs - downTs) <= 5000)
            ? downTs
            : ev.receivedAtMs - fallbackDur;
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive();
            if (_activeVoice != null) return;
            await _startVoiceSession(tStartMs: tStartMs, holdMode: true);
          }),
        );
      } else {
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive();
            if (_wasExecutedByFirmware(ev, action)) {
              await _handleFirmwareExecutedAction(ev, action);
            } else {
              await _executeImmediateAction(action);
            }
          }),
        );
      }
      return;
    }

    if (ev.gesture == 'click' ||
        ev.gesture == 'double_click' ||
        ev.gesture == 'long_press' ||
        ev.gesture == 'switch_on' ||
        ev.gesture == 'switch_off') {
      if (_wasExecutedByFirmware(ev, action)) {
        unawaited(
          _enqueue(() async {
            await _handleFirmwareExecutedAction(ev, action);
          }),
        );
      } else if (action == HardwareButtonAction.agentVoice) {
        final triggerMs = ev.receivedAtMs;
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive();
            if (_activeVoice != null) {
              await _finishVoiceSession(triggerMs);
            } else if (phase == HardwareAgentPhase.idle) {
              await _startVoiceSession(tStartMs: triggerMs, holdMode: false);
            }
          }),
        );
      } else {
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive();
            await _executeImmediateAction(action);
          }),
        );
      }
    }
  }

  /// iPhone 操作按钮或悬浮胶囊触发「向 Agent 发送语音任务」（按一次开始，再按停止并发送）。
  Future<void> handleIphoneAgentTrigger() {
    _emitButtonToast('收到操作按钮：触发语音任务');
    final triggerMs = _clock().millisecondsSinceEpoch;
    return _enqueue(() async {
      await _interruptSpeechIfActive();
      if (_activeVoice != null) {
        await _finishVoiceSession(triggerMs);
      } else if (phase == HardwareAgentPhase.idle) {
        await _startVoiceSession(tStartMs: triggerMs, holdMode: false);
      }
    });
  }

  Future<void> _handleFirmwareExecutedAction(
    HardwareButtonEvent ev,
    HardwareButtonAction action,
  ) async {
    switch (action) {
      case HardwareButtonAction.mark:
        _setStatus(HardwareAgentPhase.idle, '已打重点标记', transient: true);
        if (_device.activeCapabilities.hasOledDisplay) {
          unawaited(
            _device.showCardDisplayPrompt(
              line1: '已打重点',
              line2: '标记成功',
              timeoutMs: 2500,
            ),
          );
        }
      case HardwareButtonAction.recordStart:
      case HardwareButtonAction.recordStop:
      case HardwareButtonAction.recordToggle:
        if ((action == HardwareButtonAction.recordStart &&
                !_device.isRecording) ||
            (action == HardwareButtonAction.recordStop &&
                _device.isRecording)) {
          await _device.refreshFromDevice();
        }
        if (_device.activeCapabilities.hasOledDisplay &&
            !_device.hasRecentHardwareRecordOledPrompt) {
          final isSwitch =
              ev.gesture == 'switch_on' || ev.gesture == 'switch_off';
          final line1 = _device.isRecording ? '录音中' : '未录音';
          final line2 = isSwitch
              ? (ev.gesture == 'switch_on' ? '拨杆已开' : '拨杆已关')
              : '按键触发';
          unawaited(
            _device.showCardDisplayPrompt(
              line1: line1,
              line2: line2,
              timeoutMs: 3000,
            ),
          );
        }
      case HardwareButtonAction.syncNow:
        _setStatus(
          HardwareAgentPhase.idle,
          '硬件已触发同步上传',
          transient: true,
        );
        if (_device.activeCapabilities.hasOledDisplay) {
          unawaited(
            _device.showCardDisplayPrompt(
              line1: '开始同步',
              line2: '上传中',
              timeoutMs: 3000,
            ),
          );
        }
      case HardwareButtonAction.photoRecognize:
      case HardwareButtonAction.agentVoice:
      case HardwareButtonAction.none:
        break;
    }
  }

  Future<void> _executeImmediateAction(HardwareButtonAction action) async {
    switch (action) {
      case HardwareButtonAction.mark:
        final err = await _device.markNow();
        _setStatus(
          HardwareAgentPhase.idle,
          err ?? '已打重点标记',
          transient: true,
        );
        if (_device.activeCapabilities.hasOledDisplay) {
          unawaited(
            _device.showCardDisplayPrompt(
              line1: err == null ? '已打重点' : '打重点失败',
              line2: err == null ? '标记成功' : null,
              timeoutMs: 2500,
            ),
          );
        }
      case HardwareButtonAction.syncNow:
        if (_device.activeCapabilities.hasOledDisplay) {
          unawaited(
            _device.showCardDisplayPrompt(
              line1: '正在同步',
              line2: '同步数据中',
              timeoutMs: 3000,
            ),
          );
        }
        if (_device.isRecording && _liveAudio.isRunning) {
          final flushed = await _liveAudio.flushActiveSlice();
          _setStatus(
            HardwareAgentPhase.idle,
            flushed ? '已同步当前片段' : '已触发立即同步',
            transient: true,
          );
          if (_device.activeCapabilities.hasOledDisplay) {
            unawaited(
              _device.showCardDisplayPrompt(
                line1: '已同步',
                line2: '片段已生成',
                timeoutMs: 3000,
              ),
            );
          }
        } else {
          await _device.syncNow(manual: true);
          final err = _device.syncError;
          _setStatus(
            HardwareAgentPhase.idle,
            err ?? '已触发立即同步',
            transient: true,
          );
          if (_device.activeCapabilities.hasOledDisplay) {
            unawaited(
              _device.showCardDisplayPrompt(
                line1: err == null ? '同步完成' : '同步失败',
                line2: err == null ? '数据已更新' : '请重试',
                timeoutMs: 3000,
              ),
            );
          }
        }
      case HardwareButtonAction.recordStart:
        if (_device.isConnected) {
          await _device.setRecordingState(true);
        } else {
          await _device.startPhoneRecording(
            islandEnabled: _agentConfig.islandEnabled,
          );
        }
      case HardwareButtonAction.recordStop:
        if (_device.isConnected) {
          await _device.setRecordingState(false);
        } else {
          await _device.stopPhoneRecording();
        }
      case HardwareButtonAction.recordToggle:
        if (_device.isConnected) {
          await _device.toggleRecording();
        } else {
          await _device.togglePhoneRecording(
            islandEnabled: _agentConfig.islandEnabled,
          );
        }
      case HardwareButtonAction.photoRecognize:
        await _handlePhotoRecognize();
      case HardwareButtonAction.agentVoice:
      case HardwareButtonAction.none:
        break;
    }
  }

  PcmRingBuffer? _activeContinuousRing() {
    if (_device.isRecording && _device.activeCapabilities.realtimeAudio) {
      return _liveAudio.ringBuffer;
    }
    if (_device.isPhoneRecording) {
      return _device.phoneRingBuffer;
    }
    return null;
  }

  Future<void> _startVoiceSession({
    required int tStartMs,
    required bool holdMode,
  }) async {
    final continuousRing = _activeContinuousRing();
    final useTemp = continuousRing == null;
    final session = _ActiveVoiceSession(
      tStartMs: tStartMs,
      holdMode: holdMode,
      usedTempCapture: useTemp,
      notBeforeMs: _lastTtsEndedAtMs,
    );
    _activeVoice = session;

    _setStatus(
      HardwareAgentPhase.listening,
      holdMode ? '正在聆听语音任务（松开手指发送）…' : '正在聆听语音任务（再按发送）…',
    );
    _sendHardwareHint('listening', oledLine1: '请说话', oledLine2: '聆听中');

    if (useTemp) {
      final started = await _startTempCapture(session);
      if (_disposed || _activeVoice != session) return;
      if (!started) {
        final err = session.captureError ?? '无法启动临时录音采集';
        _activeVoice = null;
        _sendHardwareHint(
          'error',
          oledLine1: '未听清',
          oledLine2: '请重试',
          timeoutMs: 2500,
        );
        unawaited(_agentChat.speakText(err));
        _setStatus(HardwareAgentPhase.idle, err, transient: true);
        return;
      }
    }

    if (!holdMode && _maxVoiceTaskDuration > Duration.zero) {
      session.maxDurationTimer = Timer(_maxVoiceTaskDuration, () {
        if (_disposed || _activeVoice != session) return;
        unawaited(
          _enqueue(() async {
            if (_activeVoice == session) {
              await _finishVoiceSession(_clock().millisecondsSinceEpoch);
            }
          }),
        );
      });
    }
  }

  Future<bool> _startTempCapture(_ActiveVoiceSession session) async {
    if (_device.isConnected &&
        _device.activeCapabilities.hasStandaloneRealtimeStream) {
      try {
        session.usedHwRealtime = true;
        session.hwSub = _device.gateway.realtimeAudio().listen(
          (ev) {
            if (ev.kind == RealtimeAudioKind.audio &&
                ev.pcm != null &&
                ev.pcm!.isNotEmpty) {
              final evenLen = ev.pcm!.length & ~1;
              if (evenLen > 0) {
                session.tempSampleRate = ev.sampleRate;
                session.tempPcm.add(
                  evenLen == ev.pcm!.length
                      ? ev.pcm!
                      : Uint8List.sublistView(ev.pcm!, 0, evenLen),
                );
              }
            }
          },
          onError: (Object e) {
            session.captureError = '硬件临时采集失败：$e';
          },
        );
        return true;
      } on Object catch (e) {
        await session.hwSub?.cancel();
        session.hwSub = null;
        session.usedHwRealtime = false;
        session.captureError = '$e';
      }
    }

    final backend = _phoneMicBackendFactory();
    try {
      var perm = await backend.checkPermission();
      if (perm == PhoneMicPermission.notDetermined) {
        perm = await backend.requestPermission();
      }
      if (perm != PhoneMicPermission.granted) {
        session.captureError = '需要开启麦克风权限才能发送语音任务';
        return false;
      }
      session.phoneBackend = backend;
      await backend.startCapture(
        (pcm) {
          final evenLen = pcm.length & ~1;
          if (evenLen > 0) {
            session.tempPcm.add(
              evenLen == pcm.length ? pcm : Uint8List.sublistView(pcm, 0, evenLen),
            );
          }
        },
        onError: (err) {
          session.captureError = err;
        },
      );
      return true;
    } on Object catch (e) {
      session.captureError = '临时麦克风启动失败：$e';
      return false;
    }
  }

  Future<void> _stopTempCapture(_ActiveVoiceSession session) async {
    if (session.usedHwRealtime) {
      await session.hwSub?.cancel();
      session.hwSub = null;
      if (!_device.isRecording) {
        try {
          await _device.gateway.closeRealtime();
        } on Object {
          // best-effort close
        }
      }
    }
    final phone = session.phoneBackend;
    if (phone != null) {
      session.phoneBackend = null;
      try {
        await phone.stopCapture();
      } on Object {
        // best-effort stop
      }
    }
  }

  Future<void> _finishVoiceSession(int tEndMs) async {
    final session = _activeVoice;
    if (session == null) return;
    session.maxDurationTimer?.cancel();
    session.maxDurationTimer = null;
    _activeVoice = null;

    if (_postSettleDelay > Duration.zero) {
      await Future<void>.delayed(_postSettleDelay);
      if (_disposed) {
        if (session.usedTempCapture) await _stopTempCapture(session);
        return;
      }
    }

    String? transcriptText;
    PcmWindowSlice? slice;

    if (!session.usedTempCapture) {
      final lookup = _lookupExistingTranscript;
      if (lookup != null) {
        try {
          final found = await lookup(session.tStartMs, tEndMs);
          if (found != null && found.trim().isNotEmpty) {
            transcriptText = found.trim();
          }
        } on Object {
          // 查询既有转写失败时回退音频切片识别
        }
      }
      if (transcriptText == null) {
        final ring = _activeContinuousRing();
        slice = ring?.slice(
          startMs: session.tStartMs,
          endMs: math.max(tEndMs, session.tStartMs),
          preRollMs: 300,
          postRollMs: 250,
          notBeforeMs: session.notBeforeMs,
        );
      }
    } else {
      await _stopTempCapture(session);
      final rawBytes = session.tempPcm.takeBytes();
      if (rawBytes.length >= PcmRingBuffer.minSliceBytes) {
        slice = PcmWindowSlice(
          startMs: session.tStartMs,
          endMs: math.max(tEndMs, session.tStartMs),
          sampleRate: session.tempSampleRate,
          pcm16le: rawBytes,
        );
      }
    }

    if (transcriptText == null) {
      if (slice == null) {
        _sendHardwareHint(
          'error',
          oledLine1: '未听清',
          oledLine2: '请重试',
          timeoutMs: 2500,
        );
        unawaited(_agentChat.speakText('没有听清，请再说一次'));
        _setStatus(HardwareAgentPhase.idle, '未识别到有效语音', transient: true);
        return;
      }

      _setStatus(HardwareAgentPhase.transcribing, '正在本地识别语音…');
      _sendHardwareHint(null, oledLine1: '正在识别', oledLine2: '请稍候');
      try {
        transcriptText = (await _transcribeSamples(
          slice.floatSamples,
          sampleRate: slice.sampleRate,
        )).trim();
      } on Object catch (e) {
        _sendHardwareHint(
          'error',
          oledLine1: '未听清',
          oledLine2: '请重试',
          timeoutMs: 2500,
        );
        final msg = '本地语音识别失败：$e';
        unawaited(_agentChat.speakText('本地语音识别失败'));
        _setStatus(HardwareAgentPhase.idle, msg, transient: true);
        return;
      }
    }

    if (transcriptText.isEmpty) {
      _sendHardwareHint(
        'error',
        oledLine1: '未听清',
        oledLine2: '请重试',
        timeoutMs: 2500,
      );
      unawaited(_agentChat.speakText('没有听清，请再说一次'));
      _setStatus(HardwareAgentPhase.idle, '未识别到有效语音', transient: true);
      return;
    }

    _setStatus(HardwareAgentPhase.thinking, '正在向 Agent 发送：$transcriptText');
    _sendHardwareHint('thinking', oledLine1: '思考中', oledLine2: '正在回复');
    await _agentChat.sendMessage(
      transcriptText,
      viaVoice: true,
      speakReply: true,
      speakError: true,
    );
    if (_disposed) return;

    final err = _agentChat.errorMessage;
    if (err != null && err.isNotEmpty) {
      _sendHardwareHint(
        'error',
        oledLine1: '未听清',
        oledLine2: '请重试',
        timeoutMs: 2500,
      );
      _setStatus(HardwareAgentPhase.idle, err, transient: true);
    } else {
      _sendHardwareHint(
        'done',
        oledLine1: '已回复',
        oledLine2: '请查收',
        timeoutMs: 3000,
      );
      _setStatus(HardwareAgentPhase.idle, null);
    }
  }

  Future<void> _handlePhotoRecognize() async {
    if (!_device.isConnected || !_device.activeCapabilities.hasCameraMedia) {
      const msg = '请先连接支持拍照的点一机设备';
      unawaited(_agentChat.speakText(msg));
      _setStatus(HardwareAgentPhase.idle, msg, transient: true);
      return;
    }

    _setStatus(HardwareAgentPhase.capturingPhoto, '正在拍照并拉取画面…');
    _sendHardwareHint('thinking', oledLine1: '思考中', oledLine2: '正在回复');

    try {
      final dir = _tempDirResolver != null
          ? await _tempDirResolver()
          : await getTemporaryDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final res = await _device.captureAndFetchDyjPhoto(dir: dir.path);
      final localPath = '${res['localPath'] ?? ''}'.trim();
      if (localPath.isEmpty) {
        throw StateError('设备未返回照片路径');
      }
      final bytes = await File(localPath).readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('照片文件为空');
      }
      if (_disposed) return;

      _setStatus(HardwareAgentPhase.thinking, '正在识别画面内容…');
      await _agentChat.sendPhotoRecognitionMessage(
        jpegBytes: bytes,
        speakReply: true,
        speakError: true,
      );
      if (_disposed) return;

      final err = _agentChat.errorMessage;
      if (err != null && err.isNotEmpty) {
        _sendHardwareHint(
          'error',
          oledLine1: '未听清',
          oledLine2: '请重试',
          timeoutMs: 2500,
        );
        _setStatus(HardwareAgentPhase.idle, err, transient: true);
      } else {
        _sendHardwareHint(
          'done',
          oledLine1: '已回复',
          oledLine2: '请查收',
          timeoutMs: 3000,
        );
        _setStatus(HardwareAgentPhase.idle, null);
      }
    } on Object catch (e) {
      if (_disposed) return;
      _sendHardwareHint(
        'error',
        oledLine1: '未听清',
        oledLine2: '请重试',
        timeoutMs: 2500,
      );
      final msg = '拍照识别失败：$e';
      unawaited(_agentChat.speakText('拍照识别失败，请稍后重试'));
      _setStatus(HardwareAgentPhase.idle, msg, transient: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _statusClearTimer?.cancel();
    _statusClearTimer = null;
    _buttonToastTimer?.cancel();
    _buttonToastTimer = null;
    final active = _activeVoice;
    _activeVoice = null;
    if (active != null) {
      active.maxDurationTimer?.cancel();
      if (active.usedTempCapture) {
        unawaited(_stopTempCapture(active));
      }
    }
    _agentChat.removeListener(_onAgentChatChanged);
    unawaited(_buttonSub?.cancel());
    super.dispose();
  }
}
