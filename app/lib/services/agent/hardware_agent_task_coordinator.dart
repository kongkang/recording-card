/// 物理按键 × iPhone 操作按钮 → Agent 语音/拍照任务协调器。
///
/// 核心职责：
/// - 监听点一机 V1 等支持可配置按键的 `hardwareButtonEvents` 与 iPhone 操作按钮触发；
/// - `mark` / `recordToggle` 直接转发给 `DeviceStore`；
/// - `agentVoice`：
///   - 若当前已在持续录音（硬件实时流或本机录音），记录 `[tStartMs, tEndMs]` 并优先复用已有润色/原始转写，
///     否则从 `PcmRingBuffer` 零干扰切出对应时间窗音频走端侧识别；
///   - 若当前未在录音，自动拉起临时采集流（优先硬件实时流，异常/无流自动回退本机麦克风），
///     识别后关闭临时流，**不启动长期录音、不污染 Timeline**；
///   - Agent 回复与异常均可通过原生 TTS（随 A2DP 耳机或本机扬声器）播报，
///     并严格维护打断/回声隔离时间戳（`notBeforeMs`）；
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
  bool receivedHwAudio = false;
  bool stopped = false;
  Future<bool>? phoneFallbackFuture;
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

  /// 等待按键广播流派发及当前串行队列中的异步任务全部完成。
  Future<void> get idle async {
    await Future<void>.delayed(Duration.zero);
    await _serial;
    await Future<void>.delayed(Duration.zero);
  }

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
      'down' => '收到按键：按下 (down)',
      'up' => '收到按键：松开 (up)',
      _ => '收到按键：${ev.gesture}$suffix',
    };
  }

  void _onAgentChatChanged() {
    if (_disposed) return;
    final speaking = _agentChat.isSpeaking;
    if (_wasAgentSpeaking && !speaking) {
      final nowMs = _clock().millisecondsSinceEpoch;
      if (_lastTtsEndedAtMs == null || nowMs > _lastTtsEndedAtMs!) {
        _lastTtsEndedAtMs = nowMs;
      }
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

  Future<void> _interruptSpeechIfActive({int? timestampMs}) async {
    if (_agentChat.isSpeaking) {
      await _agentChat.interruptSpeech();
      _lastTtsEndedAtMs = timestampMs ?? _clock().millisecondsSinceEpoch;
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
    final action = _agentConfig.dyjActionForGesture(ev.gesture);
    _emitButtonToast(_formatButtonToast(ev, action));

    // 按下瞬间若正在播报 TTS，立即静默打断并锚定回声隔离水位，防止前 600ms 按住说话被外放声污染
    if (_agentChat.isSpeaking && ev.gesture != 'up') {
      unawaited(_agentChat.interruptSpeech());
      _lastTtsEndedAtMs = ev.receivedAtMs;
    }

    if (ev.gesture == 'down') {
      _lastDownAtMs = ev.receivedAtMs;
      return;
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
            : 600;
        final tStartMs = (downTs != null && (ev.receivedAtMs - downTs) <= 5000)
            ? downTs
            : ev.receivedAtMs - fallbackDur;
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive(timestampMs: ev.receivedAtMs);
            if (_activeVoice != null) return;
            await _startVoiceSession(tStartMs: tStartMs, holdMode: true);
          }),
        );
      } else {
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive(timestampMs: ev.receivedAtMs);
            await _executeImmediateAction(action);
          }),
        );
      }
      return;
    }

    if (ev.gesture == 'click' ||
        ev.gesture == 'double_click' ||
        ev.gesture == 'long_press') {
      if (action == HardwareButtonAction.agentVoice) {
        final triggerMs = ev.receivedAtMs;
        unawaited(
          _enqueue(() async {
            await _interruptSpeechIfActive(timestampMs: triggerMs);
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
            await _interruptSpeechIfActive(timestampMs: ev.receivedAtMs);
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
      await _interruptSpeechIfActive(timestampMs: triggerMs);
      if (_activeVoice != null) {
        await _finishVoiceSession(triggerMs);
      } else if (phase == HardwareAgentPhase.idle) {
        await _startVoiceSession(tStartMs: triggerMs, holdMode: false);
      }
    });
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
    unawaited(_device.sendDyjLedHint('listening'));

    if (useTemp) {
      final started = await _startTempCapture(session);
      if (_disposed || _activeVoice != session) return;
      if (!started) {
        final err = session.captureError ?? '无法启动临时录音采集';
        _activeVoice = null;
        unawaited(_device.sendDyjLedHint('error'));
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
    if (_device.isConnected && _device.activeCapabilities.realtimeAudio) {
      try {
        session.usedHwRealtime = true;
        session.hwSub = _device.gateway.realtimeAudio().listen(
          (ev) {
            if (session.stopped || _disposed) return;
            if (ev.kind == RealtimeAudioKind.audio &&
                ev.pcm != null &&
                ev.pcm!.isNotEmpty) {
              session.receivedHwAudio = true;
              final notBefore = session.notBeforeMs;
              if (notBefore != null &&
                  _clock().millisecondsSinceEpoch < notBefore) {
                return;
              }
              final evenLen = ev.pcm!.length & ~1;
              if (evenLen > 0) {
                session.tempSampleRate = ev.sampleRate;
                session.tempPcm.add(
                  evenLen == ev.pcm!.length
                      ? ev.pcm!
                      : Uint8List.sublistView(ev.pcm!, 0, evenLen),
                );
              }
            } else if (ev.kind == RealtimeAudioKind.closed &&
                !session.receivedHwAudio) {
              unawaited(_fallbackToPhoneMic(session, '硬件实时流未返回音频即关闭'));
            }
          },
          onError: (Object e) {
            session.captureError = '硬件临时采集失败：$e';
            if (!session.receivedHwAudio && !session.stopped && !_disposed) {
              unawaited(_fallbackToPhoneMic(session, '$e'));
            }
          },
        );
        // 让首拍异步微任务先执行：若 realtimeAudio 立即报错或拒绝，直接衔接本机麦克风回退
        await Future<void>.delayed(Duration.zero);
        if (session.phoneFallbackFuture != null) {
          return await session.phoneFallbackFuture!;
        }
        return true;
      } on Object catch (e) {
        await session.hwSub?.cancel();
        session.hwSub = null;
        session.usedHwRealtime = false;
        session.captureError = '$e';
      }
    }

    return _startPhoneMicCapture(session);
  }

  Future<bool> _fallbackToPhoneMic(
    _ActiveVoiceSession session,
    String reason,
  ) {
    if (session.phoneFallbackFuture != null) {
      return session.phoneFallbackFuture!;
    }
    final fut = () async {
      final prevSub = session.hwSub;
      session.hwSub = null;
      session.usedHwRealtime = false;
      if (prevSub != null) {
        try {
          await prevSub.cancel();
        } on Object {
          // best-effort cancel
        }
      }
      if (!_device.isRecording) {
        try {
          await _device.gateway.closeRealtime();
        } on Object {
          // best-effort close
        }
      }
      if (session.stopped || _disposed) return false;
      final ok = await _startPhoneMicCapture(session);
      if (!ok && !_disposed && !session.stopped && _activeVoice == session) {
        final err = session.captureError ?? '无法启动临时录音采集（$reason）';
        _activeVoice = null;
        unawaited(_device.sendDyjLedHint('error'));
        unawaited(_agentChat.speakText(err));
        _setStatus(HardwareAgentPhase.idle, err, transient: true);
      }
      return ok;
    }();
    session.phoneFallbackFuture = fut;
    return fut;
  }

  Future<bool> _startPhoneMicCapture(_ActiveVoiceSession session) async {
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
      if (session.stopped || _disposed) return false;
      session.captureError = null;
      session.tempSampleRate = 16000;
      session.phoneBackend = backend;
      await backend.startCapture(
        (pcm) {
          if (session.stopped || _disposed) return;
          final notBefore = session.notBeforeMs;
          if (notBefore != null &&
              _clock().millisecondsSinceEpoch < notBefore) {
            return;
          }
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
    final pendingFallback = session.phoneFallbackFuture;
    if (pendingFallback != null) {
      try {
        await pendingFallback;
      } on Object {
        // fallback error already handled
      }
    }
    session.stopped = true;
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
    final effectiveStartMs = session.notBeforeMs != null
        ? math.max(session.tStartMs, session.notBeforeMs!)
        : session.tStartMs;
    final effectiveEndMs = math.max(tEndMs, effectiveStartMs);

    if (!session.usedTempCapture) {
      final lookup = _lookupExistingTranscript;
      if (lookup != null) {
        try {
          final found = await lookup(effectiveStartMs, effectiveEndMs);
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
          startMs: effectiveStartMs,
          endMs: effectiveEndMs,
          sampleRate: session.tempSampleRate,
          pcm16le: rawBytes,
        );
      }
    }

    if (transcriptText == null) {
      if (slice == null) {
        unawaited(_device.sendDyjLedHint('error'));
        unawaited(_agentChat.speakText('没有听清，请再说一次'));
        _setStatus(HardwareAgentPhase.idle, '未识别到有效语音', transient: true);
        return;
      }

      _setStatus(HardwareAgentPhase.transcribing, '正在本地识别语音…');
      try {
        transcriptText = (await _transcribeSamples(
          slice.floatSamples,
          sampleRate: slice.sampleRate,
        )).trim();
      } on Object catch (e) {
        unawaited(_device.sendDyjLedHint('error'));
        final msg = '本地语音识别失败：$e';
        unawaited(_agentChat.speakText('本地语音识别失败'));
        _setStatus(HardwareAgentPhase.idle, msg, transient: true);
        return;
      }
    }

    if (transcriptText.isEmpty) {
      unawaited(_device.sendDyjLedHint('error'));
      unawaited(_agentChat.speakText('没有听清，请再说一次'));
      _setStatus(HardwareAgentPhase.idle, '未识别到有效语音', transient: true);
      return;
    }

    _setStatus(HardwareAgentPhase.thinking, '正在向 Agent 发送：$transcriptText');
    unawaited(_device.sendDyjLedHint('thinking'));
    await _agentChat.sendMessage(
      transcriptText,
      viaVoice: true,
      speakReply: true,
      speakError: true,
    );
    if (_disposed) return;

    final err = _agentChat.errorMessage;
    if (err != null && err.isNotEmpty) {
      unawaited(_device.sendDyjLedHint('error'));
      _setStatus(HardwareAgentPhase.idle, err, transient: true);
    } else {
      unawaited(_device.sendDyjLedHint('done'));
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
    unawaited(_device.sendDyjLedHint('thinking'));

    try {
      final dir = _tempDirResolver != null
          ? await _tempDirResolver()
          : await getTemporaryDirectory();
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      final res = await _device.captureAndFetchDyjPhoto(dir: dir.path);
      final dataMap = res['data'] is Map
          ? Map<String, dynamic>.from(res['data'] as Map)
          : null;
      if (res['ok'] == false) {
        final bridgeErr =
            '${res['error'] ?? dataMap?['error'] ?? '设备拍照命令返回失败'}'.trim();
        throw StateError(bridgeErr.isEmpty ? '设备拍照命令返回失败' : bridgeErr);
      }
      final rawPath = (dataMap != null
              ? (dataMap['path'] ?? dataMap['localPath'])
              : null) ??
          res['path'] ??
          res['localPath'];
      final localPath = '${rawPath ?? ''}'.trim();
      if (localPath.isEmpty) {
        final detailErr = '${dataMap?['error'] ?? res['error'] ?? ''}'.trim();
        throw StateError(detailErr.isNotEmpty ? detailErr : '设备未返回照片路径');
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
        unawaited(_device.sendDyjLedHint('error'));
        _setStatus(HardwareAgentPhase.idle, err, transient: true);
      } else {
        unawaited(_device.sendDyjLedHint('done'));
        _setStatus(HardwareAgentPhase.idle, null);
      }
    } on Object catch (e) {
      if (_disposed) return;
      unawaited(_device.sendDyjLedHint('error'));
      final cleanErr = '$e'.replaceFirst(RegExp(r'^Bad state:\s*'), '');
      final msg = '拍照识别失败：$cleanErr';
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
