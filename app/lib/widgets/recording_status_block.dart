/// Timeline 顶部「正在录音」状态块 —— 只做状态展示，不可点击；
/// idle 时完全收起，不占布局。
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
        phase == RecordingPhase.processing ||
        phase == RecordingPhase.transcribing;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
    }
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
          RecordingPhase.recording => ('正在录音', RCColors.danger, Icons.fiber_manual_record),
          RecordingPhase.processing =>
            ('正在处理录音', RCColors.ink, Icons.graphic_eq),
          RecordingPhase.transcribing =>
            ('正在转写', RCColors.okInk, Icons.auto_awesome),
          RecordingPhase.error =>
            ('录音整理中断', RCColors.danger, Icons.error_outline),
          RecordingPhase.idle => ('', RCColors.sec, Icons.circle),
        };
        final pending = widget.controller.pendingSlices;
        final subtitle = phase == RecordingPhase.transcribing && pending > 0
            ? '剩余 $pending 段'
            : phase == RecordingPhase.error
                ? (widget.controller.lastError ?? '可稍后重试')
                : null;

        return IgnorePointer(
          child: Container(
            key: const Key('recording-status-block'),
            margin: const EdgeInsets.fromLTRB(22, 8, 22, 0),
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
