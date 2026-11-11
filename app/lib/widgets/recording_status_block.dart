/// Timeline 顶部「正在录音 / 正在同步」状态块 —— 只做状态展示，不可点击/勾选。
///
/// 语义（设计稿注释同款）：设备约 5 分钟产出一个录音切片；每片传完并转写完成后，
/// 会作为「今天」时间轴的第一条记录出现。这块表示**当前录音中、尚未转录的部分**，
/// 不是一条可点记录；积压最多约 30 分钟，日常约 5 分钟一段。
/// 勾选总结 / 「总结」Tab 时由 Timeline 直接不渲染（不能把它算进总结源）。
library;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/audio/recording_status.dart';

class RecordingStatusBlock extends StatefulWidget {
  const RecordingStatusBlock({super.key, required this.controller});

  final RecordingStatusController controller;

  @override
  State<RecordingStatusBlock> createState() => _RecordingStatusBlockState();
}

class _RecordingStatusBlockState extends State<RecordingStatusBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// idle/error 不跑动画，避免空闲页面持续调度帧（测试 pumpAndSettle 也会挂）。
  void _syncPulse(RecordingPhase phase) {
    final shouldPulse = phase == RecordingPhase.recording ||
        phase == RecordingPhase.syncing ||
        phase == RecordingPhase.transcribing;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  static String _clock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final phase = widget.controller.phase;
        _syncPulse(phase);
        if (phase == RecordingPhase.idle) return const SizedBox.shrink();

        final (label, color, icon) = switch (phase) {
          RecordingPhase.recording => (
            '正在录音',
            RCColors.danger,
            Icons.fiber_manual_record,
          ),
          RecordingPhase.syncing => ('正在同步', RCColors.ink, Icons.sync),
          RecordingPhase.transcribing => (
            '正在转写',
            RCColors.okInk,
            Icons.auto_awesome,
          ),
          RecordingPhase.error => (
            '录音整理中断',
            RCColors.danger,
            Icons.error_outline,
          ),
          RecordingPhase.idle => ('', RCColors.sec, Icons.circle),
        };
        final pending = widget.controller.pendingSlices;
        final recDetail = widget.controller.detail;
        final subtitle = switch (phase) {
          RecordingPhase.recording =>
            recDetail != null && recDetail.isNotEmpty
                ? '已录 ${_clock(widget.controller.elapsedSeconds)} · $recDetail'
                : '已录 ${_clock(widget.controller.elapsedSeconds)} · 未转录',
          RecordingPhase.syncing => widget.controller.detail ?? '正在整理最近一段…',
          RecordingPhase.transcribing =>
            recDetail != null && recDetail.isNotEmpty
                ? recDetail
                : (pending > 0 ? '剩余 $pending 段' : null),
          RecordingPhase.error =>
            widget.controller.lastError ?? '可稍后重试',
          RecordingPhase.idle => null,
        };

        return IgnorePointer(
          child: Container(
            key: const Key('recording-status-block'),
            // 由 Timeline 列表统一给左右 22 的边距；这里只管上下留白
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: RCColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: RCColors.sep),
            ),
            child: Row(
              children: [
                FadeTransition(
                  opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 8),
                Text(label,
                    key: const Key('recording-status-text'),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color)),
                if (subtitle != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(subtitle,
                        key: const Key('recording-status-subtitle'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: RCColors.sec)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
