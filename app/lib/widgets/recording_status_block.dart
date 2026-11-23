/// Timeline 顶部统一单行状态栏 —— 只做状态展示，不可点击/勾选。
///
/// 统一承接「正在录音 / 正在同步 / 正在转写 / 正在加载 / 整理中断」全部状态，
/// 固定单行高度并在边框底缘/底色上以微弱进度指示表达真实进度，不另起进度条。
/// 勾选总结 / 「总结」Tab 时由 Timeline 直接不渲染（不能把它算进总结源）。
library;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/audio/recording_status.dart';

class RecordingStatusBlock extends StatefulWidget {
  const RecordingStatusBlock({
    super.key,
    this.controller,
    this.syncActive = false,
    this.loadingActive = false,
    this.syncText = '',
    this.syncProgress,
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  final RecordingStatusController? controller;
  final bool syncActive;
  final bool loadingActive;
  final String syncText;
  final double? syncProgress;
  final EdgeInsetsGeometry margin;

  @override
  State<RecordingStatusBlock> createState() => _RecordingStatusBlockState();
}

class _RecordingStatusBlockState extends State<RecordingStatusBlock>
    with SingleTickerProviderStateMixin {
  static const _singleLineStrut = StrutStyle(
    fontSize: 13,
    height: 1.25,
    forceStrutHeight: true,
  );

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final CurvedAnimation _pulseCurve = CurvedAnimation(
    parent: _pulse,
    curve: Curves.easeInOut,
  );
  late final Animation<double> _pulseOpacity = Tween<double>(
    begin: 0.32,
    end: 1.0,
  ).animate(_pulseCurve);

  @override
  void dispose() {
    _pulseCurve.dispose();
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
    final controller = widget.controller;
    if (controller == null) {
      return _buildContent(context);
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final c = context.rc;
    final controller = widget.controller;
    final phase = controller?.phase ?? RecordingPhase.idle;
    final errorTextColor = c.isDark
        ? const Color(0xFFFF6961)
        : const Color(0xFFB00020);
    final syncingDotColor = c.isDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF1D1D1F);

    String? label;
    Color dotColor = syncingDotColor;
    String? subtitle;
    double? progress;
    var isRecording = false;
    var isError = false;

    if (controller != null && phase != RecordingPhase.idle) {
      final pending = controller.pendingSlices;
      final recDetail = controller.detail;
      final syncDone = controller.syncDone;
      final syncTotal = controller.syncTotal;
      final fallbackProgress = widget.syncActive ? widget.syncProgress : null;
      switch (phase) {
        case RecordingPhase.recording:
          isRecording = true;
          label = '正在录音';
          dotColor = const Color(0xFFFF3B30);
          subtitle = syncTotal > 0
              ? '已录 ${_clock(controller.elapsedSeconds)} · 已存 $syncDone/$syncTotal 段'
              : (recDetail != null && recDetail.isNotEmpty
                    ? '已录 ${_clock(controller.elapsedSeconds)} · $recDetail'
                    : '已录 ${_clock(controller.elapsedSeconds)} · 每满 ${controller.transcribeCycleMinutes} 分钟或查看时转写');
          progress = controller.progress;
        case RecordingPhase.syncing:
          label = '正在同步';
          dotColor = syncingDotColor;
          subtitle = (recDetail != null && recDetail.isNotEmpty)
              ? recDetail
              : (widget.syncText.isNotEmpty ? widget.syncText : '正在整理最近一段…');
          progress = controller.progress ?? fallbackProgress;
        case RecordingPhase.transcribing:
          label = '正在转写';
          dotColor = const Color(0xFF34C759);
          subtitle = recDetail != null && recDetail.isNotEmpty
              ? recDetail
              : (pending > 0 ? '剩余 $pending 段' : '本地语音引擎处理中');
          progress = controller.progress ?? fallbackProgress;
        case RecordingPhase.error:
          isError = true;
          label = '录音整理中断';
          dotColor = const Color(0xFFFF3B30);
          final err = controller.lastError;
          subtitle = (err != null && err.isNotEmpty) ? err : '可稍后重试';
          progress = null;
        case RecordingPhase.idle:
          break;
      }
    } else if (widget.syncActive) {
      label = '正在同步';
      dotColor = syncingDotColor;
      subtitle = widget.syncText.isNotEmpty ? widget.syncText : '正在整理最近一段…';
      progress = widget.syncProgress;
    } else if (widget.loadingActive) {
      label = '正在加载';
      dotColor = syncingDotColor;
      subtitle = '正在读取本地录音…';
      progress = null;
    }

    _syncPulse(isRecording ? RecordingPhase.recording : RecordingPhase.idle);
    if (label == null) return const SizedBox.shrink();

    final effectiveProgress =
        (!isError && progress != null && progress.isFinite)
        ? progress.clamp(0.0, 1.0).toDouble()
        : null;

    final dot = Container(
      key: const Key('recording-status-dot'),
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
    );

    return RepaintBoundary(
      child: IgnorePointer(
        child: Padding(
          padding: widget.margin,
          child: Container(
            key: const Key('recording-status-block'),
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
                width: 1.0,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                children: [
                  if (effectiveProgress != null)
                    Positioned.fill(
                      child: AnimatedFractionallySizedBox(
                        key: const Key('recording-status-progress'),
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.centerLeft,
                        widthFactor: effectiveProgress,
                        heightFactor: 1.0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.ok.withValues(
                              alpha: c.isDark ? 0.14 : 0.08,
                            ),
                            border: Border(
                              bottom: BorderSide(
                                color: c.ok.withValues(
                                  alpha: c.isDark ? 0.65 : 0.55,
                                ),
                                width: 2.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 38),
                    child: Center(
                      heightFactor: 1.0,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            if (isRecording)
                              FadeTransition(
                                opacity: _pulseOpacity,
                                child: dot,
                              )
                            else
                              dot,
                            const SizedBox(width: 10),
                            Text(
                              label,
                              key: const Key('recording-status-text'),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              strutStyle: _singleLineStrut,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                                color: isError ? errorTextColor : c.label,
                              ),
                            ),
                            if (subtitle != null && subtitle.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  subtitle,
                                  key: const Key('recording-status-subtitle'),
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  strutStyle: _singleLineStrut,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.25,
                                    color: isError ? errorTextColor : c.sec,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
