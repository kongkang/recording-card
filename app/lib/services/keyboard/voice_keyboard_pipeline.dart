/// 录音卡语音输入法主应用侧管线：
///
/// 1. 接收键盘传来的 `tStartMs`：校验录音卡正在录音 → 以 ~15Hz 向键盘推送 32 柱极轻波形；
/// 2. 接收键盘传来的 `tEndMs`：停止推波、等待短暂尾音/气口到达后，通过 [BreathBoundarySnapper]
///    在 `[tStartMs - 2s, tEndMs + 2s]` 区间内按能量找气口切片；
/// 3. 按 [LocalModelMemoryGuard] 单槽位原则加载 ASR 转写为原始文本；
/// 4. 转完后立刻做轻量快速润色（4GB/8GB 优先端侧小模型 Qwen3.5-0.8B，老旧机或未就绪自动切云端），
///    将最终文本与耗时回传键盘上屏。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ai/local_llm_models.dart';
import '../ai/local_llm_service.dart';
import '../ai/local_model_memory_guard.dart';
import '../audio/pcm_ring_buffer.dart';
import 'breath_boundary_snapper.dart';
import 'voice_keyboard_ipc.dart';

typedef KeyboardTranscribeFn = Future<String> Function(
  Float32List samples, {
  int sampleRate,
});

typedef KeyboardCloudPolishFn = Future<String> Function(String rawText);

class VoiceKeyboardPipelineService extends ChangeNotifier {
  VoiceKeyboardPipelineService({
    required PcmRingBuffer ringBuffer,
    required bool Function() isRecordingActive,
    required LocalModelMemoryGuard memoryGuard,
    required KeyboardTranscribeFn transcribeSamples,
    required LocalLlmService localLlm,
    required KeyboardCloudPolishFn cloudPolishFallback,
    required bool Function() cloudReady,
    required VoiceKeyboardIpcTransport ipc,
    BreathBoundarySnapper snapper = const BreathBoundarySnapper(),
    Duration trailingSettleWait = const Duration(milliseconds: 350),
    Duration waveformPushInterval = const Duration(milliseconds: 66),
    List<String> Function()? hotwordsResolver,
    DateTime Function()? clock,
  }) : _ringBuffer = ringBuffer,
       _isRecordingActive = isRecordingActive,
       _memoryGuard = memoryGuard,
       _transcribeSamples = transcribeSamples,
       _localLlm = localLlm,
       _cloudPolishFallback = cloudPolishFallback,
       _cloudReady = cloudReady,
       _ipc = ipc,
       _snapper = snapper,
       _trailingSettleWait = trailingSettleWait,
       _waveformPushInterval = waveformPushInterval,
       _hotwordsResolver = hotwordsResolver,
       _clock = clock ?? DateTime.now {
    _cmdSub = _ipc.commands.listen(_onCommand);
  }

  final PcmRingBuffer _ringBuffer;
  final bool Function() _isRecordingActive;
  final LocalModelMemoryGuard _memoryGuard;
  final KeyboardTranscribeFn _transcribeSamples;
  final LocalLlmService _localLlm;
  final KeyboardCloudPolishFn _cloudPolishFallback;
  final bool Function() _cloudReady;
  final VoiceKeyboardIpcTransport _ipc;
  final BreathBoundarySnapper _snapper;
  final Duration _trailingSettleWait;
  final Duration _waveformPushInterval;
  final List<String> Function()? _hotwordsResolver;
  final DateTime Function() _clock;

  StreamSubscription<KeyboardTimestampCommand>? _cmdSub;
  Future<void> _serial = Future<void>.value();
  LocalLlmRoutingOverride polishOverride = LocalLlmRoutingOverride.auto;

  bool _active = false;
  String _sessionToken = '';
  int _tStartMs = 0;
  final List<int> _bars32 = List<int>.filled(32, 0);
  int _lastWavePushMs = 0;
  bool _disposed = false;

  bool get isDictating => _active;
  List<int> get currentBars => List.unmodifiable(_bars32);

  /// 供 `LiveAudioRecorder.onAudioSamples` 调用：仅在键盘激活听写期间计算 1 个字节电平并节流推给键盘。
  void ingestLivePcmFrame(Uint8List pcm16le) {
    if (!_active || pcm16le.length < 2) return;
    final nowMs = _clock().millisecondsSinceEpoch;
    if (_waveformPushInterval > Duration.zero &&
        nowMs - _lastWavePushMs < _waveformPushInterval.inMilliseconds) {
      return;
    }
    _lastWavePushMs = nowMs;

    final level = _computeNormalizedLevel(pcm16le);
    for (var i = 0; i < 31; i++) {
      _bars32[i] = _bars32[i + 1];
    }
    _bars32[31] = level;

    unawaited(
      _ipc.publishWaveform(
        active: true,
        bars32: List<int>.of(_bars32),
        timestampMs: nowMs,
      ),
    );
    notifyListeners();
  }

  static int _computeNormalizedLevel(Uint8List pcm16le) {
    final samples = pcm16le.length ~/ 2;
    if (samples <= 0) return 0;
    final step = math.max(1, samples ~/ 160);
    final view = ByteData.sublistView(pcm16le);
    var sumSq = 0.0;
    var count = 0;
    for (var i = 0; i < samples; i += step) {
      final v = view.getInt16(i * 2, Endian.little) / 32768.0;
      sumSq += v * v;
      count++;
    }
    final rms = count > 0 ? math.sqrt(sumSq / count) : 0.0;
    // 语音正常 RMS 在 0.02~0.35，映射到 0..255 柱高。
    return (rms * 900).round().clamp(4, 255);
  }

  void _onCommand(KeyboardTimestampCommand cmd) {
    _serial = _serial.then((_) => _handleCommand(cmd)).catchError((Object e) {
      debugPrint('[voice-kbd] 处理键盘命令异常：$e');
    });
  }

  Future<void> handleCommandNow(KeyboardTimestampCommand cmd) =>
      _handleCommand(cmd);

  Future<void> _handleCommand(KeyboardTimestampCommand cmd) async {
    if (_disposed) return;
    switch (cmd.type) {
      case VoiceKeyboardCommandType.start:
        if (!_isRecordingActive()) {
          _active = false;
          await _ipc.publishResult(
            KeyboardDictationResult(
              status: 'error',
              sessionToken: cmd.sessionToken,
              error: '请先在录音卡中开启录音后再使用语音输入法',
            ),
          );
          return;
        }
        _active = true;
        _sessionToken = cmd.sessionToken;
        _tStartMs = cmd.timestampMs;
        _lastWavePushMs = 0;
        _bars32.fillRange(0, 32, 8);
        await _ipc.publishWaveform(
          active: true,
          bars32: List<int>.of(_bars32),
          timestampMs: cmd.timestampMs,
        );
        await _ipc.publishResult(
          KeyboardDictationResult(
            status: 'recording',
            sessionToken: _sessionToken,
          ),
        );
        notifyListeners();

      case VoiceKeyboardCommandType.cancel:
        _active = false;
        _bars32.fillRange(0, 32, 0);
        await _ipc.publishWaveform(
          active: false,
          bars32: List<int>.of(_bars32),
          timestampMs: cmd.timestampMs,
        );
        await _ipc.publishResult(
          KeyboardDictationResult(
            status: 'idle',
            sessionToken: cmd.sessionToken.isNotEmpty
                ? cmd.sessionToken
                : _sessionToken,
          ),
        );
        notifyListeners();

      case VoiceKeyboardCommandType.stop:
        if (!_active && cmd.sessionToken != _sessionToken) return;
        _active = false;
        final token = cmd.sessionToken.isNotEmpty
            ? cmd.sessionToken
            : _sessionToken;
        final tStart = _tStartMs;
        final tEnd = cmd.timestampMs >= tStart ? cmd.timestampMs : tStart;
        final pipelineStartMs = _clock().millisecondsSinceEpoch;

        _bars32.fillRange(0, 32, 0);
        await _ipc.publishWaveform(
          active: false,
          bars32: List<int>.of(_bars32),
          timestampMs: tEnd,
        );
        await _ipc.publishResult(
          KeyboardDictationResult(
            status: 'processing',
            sessionToken: token,
          ),
        );
        notifyListeners();

        // 给蓝牙尾部音频与后气口留短暂到达窗口
        if (_trailingSettleWait > Duration.zero) {
          await Future<void>.delayed(_trailingSettleWait);
        }

        final snapped = _snapper.snapAndSlice(
          _ringBuffer,
          tStartMs: tStart,
          tEndMs: tEnd,
          maxSearchMs: 2000,
        );
        if (snapped == null) {
          await _ipc.publishResult(
            KeyboardDictationResult(
              status: 'error',
              sessionToken: token,
              error: '这段时间窗内未获取到有效录音音频',
              elapsedMs: _clock().millisecondsSinceEpoch - pipelineStartMs,
            ),
          );
          return;
        }

        try {
          // 1) 单槽位申请 ASR，先转写为原始口语文本
          await _memoryGuard.acquire(
            LocalHeavyModelSlot.asr,
            reason: 'voice_keyboard_asr',
          );
          final rawText = (await _transcribeSamples(
            snapped.slice.floatSamples,
            sampleRate: snapped.slice.sampleRate,
          )).trim();
          if (rawText.isEmpty) {
            await _ipc.publishResult(
              KeyboardDictationResult(
                status: 'error',
                sessionToken: token,
                error: '未识别到有效语音内容',
                elapsedMs: _clock().millisecondsSinceEpoch - pipelineStartMs,
              ),
            );
            return;
          }

          // 2) 转写后立刻做极速文本润色（自动按机型决定端侧小模型 vs 云端）
          final polishOutcome = await _localLlm.polishShortText(
            rawText,
            cloudFallback: _cloudPolishFallback,
            cloudReady: _cloudReady(),
            hotwords: _hotwordsResolver?.call() ?? const [],
            override: polishOverride,
            unloadAfterCompactDevice: true,
          );

          await _ipc.publishResult(
            KeyboardDictationResult(
              status: 'done',
              sessionToken: token,
              text: polishOutcome.text,
              rawText: rawText,
              routeLabel: polishOutcome.route.label,
              elapsedMs: _clock().millisecondsSinceEpoch - pipelineStartMs,
            ),
          );
        } on Object catch (e) {
          await _ipc.publishResult(
            KeyboardDictationResult(
              status: 'error',
              sessionToken: token,
              error: '语音输入处理失败：$e',
              elapsedMs: _clock().millisecondsSinceEpoch - pipelineStartMs,
            ),
          );
        } finally {
          // 在紧凑机型或空闲时主动卸掉重模型保后台安全
          if (_localLlm.deviceTier != DeviceLlmCapabilityTier.fullLocal) {
            await _memoryGuard.releaseAll(reason: 'voice_keyboard_finished');
          }
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_cmdSub?.cancel());
    super.dispose();
  }
}
