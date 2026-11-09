/// 录音状态机 —— 录音 / 切片待转录计数 / 错误呈现，独立于 UI 与 BLE 实现。
///
/// 只维护可观察状态；真实录音、上传、转写由上层驱动并在关键节点回调。
/// 所有状态变化（phase / pendingSlices / lastError）都会 [notifyListeners]，
/// 无变化时静默，便于 UI 与测试按次数断言。
library;

import 'package:flutter/foundation.dart';

enum RecordingPhase { idle, recording, syncing, transcribing, error }

class RecordingStatusController extends ChangeNotifier {
  RecordingPhase _phase = RecordingPhase.idle;
  String? _lastError;
  String? _detail;
  int _pendingSlices = 0;
  int _elapsedSeconds = 0;

  /// 用户是否仍处于一次录音会话中；转录完成回到 recording 还是 idle 由它决定。
  bool _sessionActive = false;

  RecordingPhase get phase => _phase;

  /// 最近一次错误文案；新录音开始时清空。
  String? get lastError => _lastError;

  /// 当前阶段的可读细节（同步到哪一步 / 剩余多少段）。
  String? get detail => _detail;

  /// 已收到但尚未完成转录的切片数。
  int get pendingSlices => _pendingSlices;

  /// 本次录音已持续秒数（由设备时钟同步进来）。
  int get elapsedSeconds => _elapsedSeconds;

  bool get isRecording => _phase == RecordingPhase.recording;

  bool get isTranscribing => _phase == RecordingPhase.transcribing;

  /// 开始（或重启）一次录音会话，清空上一轮错误与待处理计数。
  void startRecording() {
    _sessionActive = true;
    _elapsedSeconds = 0;
    _commit(
      phase: RecordingPhase.recording,
      pendingSlices: 0,
      clearError: true,
      clearDetail: true,
    );
  }

  /// 停止录音：回到 idle 并把待处理计数归零，避免遗留切片继续触发状态。
  void stopRecording() {
    _sessionActive = false;
    _commit(phase: RecordingPhase.idle, pendingSlices: 0, clearDetail: true);
  }

  /// 停止录音后进入自动同步：在拉取/转写/整理完成前保持可见。
  ///
  /// 同步是录音会话的收尾阶段：sessionActive 置 false，管线跑完后
  /// updateQueue(active:false) 才会收起到 idle，而不是回到「正在录音」。
  /// 设备约 5 分钟一个切片，积压最多约 30 分钟；同步期间顶部状态块
  /// 表示「最近一段尚未转录完成」。
  void startSync({String detail = '正在整理最近一段…'}) {
    _sessionActive = false;
    _commit(phase: RecordingPhase.syncing, detail: detail, clearError: true);
  }

  /// 同步/处理进度：文案来自真实管线（下载 → 切片 → 转写 → 润色 → 分段）。
  void updateSync(String detail, {int? remaining}) {
    _commit(
      phase: RecordingPhase.syncing,
      detail: detail,
      pendingSlices: remaining,
    );
  }

  /// 设备计时同步：Timeline 顶部状态块据此显示「已录 h:mm:ss」。
  void updateElapsed(int seconds) {
    final next = seconds < 0 ? 0 : seconds;
    if (next == _elapsedSeconds) return;
    _elapsedSeconds = next;
    notifyListeners();
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
    if (active) {
      _commit(
        phase: RecordingPhase.syncing,
        detail: '正在整理最近一段…',
        pendingSlices: pending,
      );
      return;
    }
    _commit(
      phase: _sessionActive ? RecordingPhase.recording : RecordingPhase.idle,
      pendingSlices: pending,
      clearDetail: true,
    );
  }

  void _commit({
    RecordingPhase? phase,
    int? pendingSlices,
    String? lastError,
    String? detail,
    bool clearError = false,
    bool clearDetail = false,
  }) {
    final phaseBefore = _phase;
    final pendingBefore = _pendingSlices;
    final errorBefore = _lastError;
    final detailBefore = _detail;

    if (phase != null) _phase = phase;
    if (pendingSlices != null) {
      _pendingSlices = pendingSlices < 0 ? 0 : pendingSlices;
    }
    if (clearDetail) {
      _detail = null;
    } else if (detail != null) {
      _detail = detail;
    }
    if (clearError) {
      _lastError = null;
    } else if (lastError != null) {
      _lastError = lastError;
    }

    final changed = _phase != phaseBefore ||
        _pendingSlices != pendingBefore ||
        _lastError != errorBefore ||
        _detail != detailBefore;
    if (changed) notifyListeners();
  }
}
