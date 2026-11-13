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

  /// 仅录音中让圆点脉冲呼吸；其余静态显示（测试 pumpAndSettle 不会挂死）。
  void _syncPulse(RecordingPhase phase) {
    final shouldPulse = phase == RecordingPhase.recording;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 1.0;
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
        final c = context.rc;
        final phase = widget.controller.phase;
        _syncPulse(phase);
        if (phase == RecordingPhase.idle) return const SizedBox.shrink();

        final isError = phase == RecordingPhase.error;
        final errorTextColor = c.isDark
            ? const Color(0xFFFF6961)
            : const Color(0xFFB00020);
        final syncingDotColor = c.isDark
            ? const Color(0xFFF5F5F7)
            : const Color(0xFF1D1D1F);

        final (label, dotColor) = switch (phase) {
          RecordingPhase.recording => ('正在录音', const Color(0xFFFF3B30)),
          RecordingPhase.syncing => ('正在同步', syncingDotColor),
          RecordingPhase.transcribing => ('正在转写', const Color(0xFF34C759)),
          RecordingPhase.error => ('录音整理中断', const Color(0xFFFF3B30)),
          RecordingPhase.idle => ('', c.sec),
        };
        final pending = widget.controller.pendingSlices;
        final recDetail = widget.controller.detail;
        final subtitle = switch (phase) {
          RecordingPhase.recording =>
            recDetail != null && recDetail.isNotEmpty
                ? '已录 ${_clock(widget.controller.elapsedSeconds)} · $recDetail'
                : '已录 ${_clock(widget.controller.elapsedSeconds)} · 每满 1 分钟本地转写',
          RecordingPhase.syncing => widget.controller.detail ?? '正在整理最近一段…',
          RecordingPhase.transcribing =>
            recDetail != null && recDetail.isNotEmpty
                ? recDetail
                : (pending > 0 ? '剩余 $pending 段' : '本地语音引擎处理中'),
          RecordingPhase.error => widget.controller.lastError ?? '可稍后重试',
          RecordingPhase.idle => null,
        };

        final dot = Container(
          key: const Key('recording-status-dot'),
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        );

        return IgnorePointer(
          child: Container(
            key: const Key('recording-status-block'),
            // 由 Timeline 列表统一给左右 22 的边距；这里只管上下留白；样式 1:1 对齐原型 `.live`
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: isError
                  ? (c.isDark
                        ? const Color(0xFF2C1517)
                        : const Color(0xFFFFF8F7))
                  : c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isError
                    ? (c.isDark
                          ? const Color(0xFF6E2A2E)
                          : const Color(0xFFFFD2CE))
                    : c.sep,
                width: isError ? 1.0 : 0.5,
              ),
            ),
            child: Row(
              children: [
                if (phase == RecordingPhase.recording)
                  FadeTransition(
                    opacity: Tween<double>(begin: 0.32, end: 1.0).animate(_pulse),
                    child: dot,
                  )
                else
                  dot,
                const SizedBox(width: 10),
                Text(
                  label,
                  key: const Key('recording-status-text'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isError ? errorTextColor : c.label,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      subtitle,
                      key: const Key('recording-status-subtitle'),
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: isError ? errorTextColor : c.sec,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
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
