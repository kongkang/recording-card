/// 录音状态机 —— 录音 / 切片待转录计数 / 错误呈现，独立于 UI 与 BLE 实现。
///
/// 只维护可观察状态；真实录音、上传、转写由上层驱动并在关键节点回调。
/// 所有状态变化（phase / pendingSlices / lastError）都会 [notifyListeners]，
/// 无变化时静默，便于 UI 与测试按次数断言。
library;

import 'package:flutter/foundation.dart';

enum RecordingPhase { idle, recording, processing, transcribing, error }

class RecordingStatusController extends ChangeNotifier {
  RecordingPhase _phase = RecordingPhase.idle;
  String? _lastError;
  int _pendingSlices = 0;

  /// 用户是否仍处于一次录音会话中；转录完成回到 recording 还是 idle 由它决定。
  bool _sessionActive = false;

  RecordingPhase get phase => _phase;

  /// 最近一次错误文案；新录音开始时清空。
  String? get lastError => _lastError;

  /// 已收到但尚未完成转录的切片数。
  int get pendingSlices => _pendingSlices;

  bool get isRecording => _phase == RecordingPhase.recording;

  bool get isTranscribing => _phase == RecordingPhase.transcribing;

  /// 开始（或重启）一次录音会话，清空上一轮错误与待处理计数。
  void startRecording() {
    _sessionActive = true;
    _commit(
      phase: RecordingPhase.recording,
      pendingSlices: 0,
      clearError: true,
    );
  }

  /// 停止录音：回到 idle 并把待处理计数归零，避免遗留切片继续触发状态。
  void stopRecording() {
    _sessionActive = false;
    _commit(phase: RecordingPhase.idle, pendingSlices: 0);
  }

  /// 收到一片新音频：仅录音态计数，其他状态（转写中 / 错误 / 空闲）忽略。
  void onSliceReceived() {
    if (_phase != RecordingPhase.recording) return;
    _commit(pendingSlices: _pendingSlices + 1);
  }

  /// 开始一轮转录。
  void onTranscriptionStarted() {
    _commit(phase: RecordingPhase.transcribing);
  }

  /// 一片转录完成：递减 pending；仍有积压保持 transcribing，清空后回录音态；
  /// 若录音已停止则回 idle。已完成数超出待处理数时按 0 处理。
  void onTranscriptionCompleted() {
    final pending = _pendingSlices > 0 ? _pendingSlices - 1 : 0;
    _commit(
      phase: pending > 0
          ? RecordingPhase.transcribing
          : (_sessionActive ? RecordingPhase.recording : RecordingPhase.idle),
      pendingSlices: pending,
    );
  }

  /// 进入错误态并保留可读信息；pending 保持不变，便于重试后继续消费。
  void onError(Object error) {
    _commit(phase: RecordingPhase.error, lastError: error.toString());
  }

  /// 处理管线直接更新队列：剩余片数 + 是否仍在处理。
  ///
  /// 与 [onSliceReceived]/[onTranscriptionCompleted] 的区别是它不做"逐片
  /// 增减"的假设，适合"同步过程中一次拿到总片数"的批处理路径。
  void updateQueue({required int remaining, required bool active}) {
    final pending = remaining < 0 ? 0 : remaining;
    final phase = active
        ? RecordingPhase.transcribing
        : (_sessionActive ? RecordingPhase.recording : RecordingPhase.idle);
    _commit(phase: phase, pendingSlices: pending);
  }

  void _commit({
    RecordingPhase? phase,
    int? pendingSlices,
    String? lastError,
    bool clearError = false,
  }) {
    final phaseBefore = _phase;
    final pendingBefore = _pendingSlices;
    final errorBefore = _lastError;

    if (phase != null) _phase = phase;
    if (pendingSlices != null) {
      _pendingSlices = pendingSlices < 0 ? 0 : pendingSlices;
    }
    if (clearError) {
      _lastError = null;
    } else if (lastError != null) {
      _lastError = lastError;
    }

    final changed = _phase != phaseBefore ||
        _pendingSlices != pendingBefore ||
        _lastError != errorBefore;
    if (changed) notifyListeners();
  }
}
