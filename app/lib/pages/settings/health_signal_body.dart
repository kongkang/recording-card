/// 设置里的「行为与健康信号」：总开关和本机已采集明细。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/agent_config_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/health/health_signal_controller.dart';
import '../../widgets/rc_switch.dart';

class HealthSignalSettingsBody extends StatefulWidget {
  const HealthSignalSettingsBody({super.key, required this.controller});

  final HealthSignalController controller;

  @override
  State<HealthSignalSettingsBody> createState() =>
      _HealthSignalSettingsBodyState();
}

class _HealthSignalSettingsBodyState extends State<HealthSignalSettingsBody> {
  bool _busyToggle = false;

  HealthSignalController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    unawaited(_controller.refreshPresentation());
  }

  @override
  void didUpdateWidget(HealthSignalSettingsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != _controller) {
      oldWidget.controller.removeListener(_onChanged);
      _controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (_busyToggle) return;
    if (_controller.enabled) {
      setState(() => _busyToggle = true);
      await _controller.setEnabled(false);
      if (mounted) setState(() => _busyToggle = false);
      return;
    }
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('health-perm-guide'),
        title: const Text('一次授权健康数据'),
        content: const Text(
          '系统会用同一页列出这个 App 可以读取的健康类型，包括比较敏感的类型。'
          '请在下一页点「允许」，或把列表里的开关全部打开。'
          '没有打开的类型不会采集。数据只留在这台手机，不会上传。'
          '位置会再单独询问，用来和录音时间对齐。',
        ),
        actions: [
          TextButton(
            key: const Key('health-perm-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('health-perm-continue'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续授权'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() => _busyToggle = true);
    await _controller.setEnabled(true);
    if (mounted) setState(() => _busyToggle = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final on = _controller.enabled;
    final rows = _controller.rows;
    final clinical = _controller.platformInfo?.clinicalRecords ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.sep),
          ),
          child: GestureDetector(
            key: const Key('health-sync-row'),
            behavior: HitTestBehavior.opaque,
            onTap: _busyToggle ? null : () => unawaited(_toggle()),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '同步位置与健康信号',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '仅存本机 · 随录音自动记录',
                          style: TextStyle(fontSize: 12, color: c.sec),
                        ),
                        if (_controller.statusMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _controller.statusMessage!,
                            key: const Key('health-status-line'),
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: c.sec,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  KeyedSubtree(
                    key: const Key('health-sync-switch'),
                    child: RCSwitch(
                      on: on,
                      busy: _busyToggle || _controller.busy,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              '最近采集数据',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c.sec,
              ),
            ),
            const Spacer(),
            Text(
              '共 ${_controller.sampleCount} 条',
              key: const Key('health-count'),
              style: TextStyle(
                fontSize: 12,
                color: c.sec,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          key: const Key('health-location-card'),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.sep),
          ),
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    on ? '还没有采集到数据' : '打开开关后，已授权的数据会在这里出现',
                    key: const Key('health-empty'),
                    style: TextStyle(fontSize: 13, color: c.sec),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      Container(
                        key: Key('health-item-$i'),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: i == rows.length - 1
                                  ? Colors.transparent
                                  : c.sep,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 44,
                              child: Text(
                                rows[i].timeLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.sec,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: c.bg,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                rows[i].kind,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: c.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                rows[i].metric,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: c.ink,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                rows[i].meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(fontSize: 12, color: c.sec),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        if (!clinical) ...[
          const SizedBox(height: 12),
          Text(
            '临床病历未接入：当前签名没有 Clinical Health Records 权限，不会读取医院 CDA 病历。',
            key: const Key('health-clinical-note'),
            style: TextStyle(fontSize: 12, height: 1.4, color: c.sec),
          ),
        ],
      ],
    );
  }
}

/// 开发者模式里才显示的切片长度、采样间隔和相位。不改合并 / 分段算法。
class HealthSamplingDevSection extends StatelessWidget {
  const HealthSamplingDevSection({super.key, required this.config});

  final AgentConfigStore config;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '采集节拍（发布前隐藏）',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: c.sec,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.sep),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '默认都是 1 分钟。录音切片长度只保存配置，现有实时切片、合并和分段仍按代码里的 1 分钟窗口运行。健康采样间隔和相位会用于本机健康与位置采集，让取样落在窗口后半段，避开前半段转写。',
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
              const SizedBox(height: 12),
              _Meter(
                title: '录音切片长度',
                valueKey: const Key('dev-slice-seconds-value'),
                valueLabel: AgentConfigStore.formatSampleWindow(
                  config.recordingSliceSeconds,
                ),
                primary: primary,
                presets: const [60, 300],
                presetKey: (seconds) => Key('dev-slice-preset-$seconds'),
                selected: config.recordingSliceSeconds,
                onPreset: (seconds) =>
                    unawaited(config.setRecordingSliceSeconds(seconds)),
                sliderKey: const Key('dev-slice-slider'),
                sliderValue: config.recordingSliceSeconds.toDouble(),
                onSlide: (value) =>
                    unawaited(config.setRecordingSliceSeconds(value.round())),
              ),
              Divider(height: 18, color: c.sep),
              _Meter(
                title: '健康采样间隔',
                valueKey: const Key('dev-health-interval-value'),
                valueLabel: AgentConfigStore.formatSampleWindow(
                  config.healthSampleIntervalSeconds,
                ),
                primary: primary,
                presets: const [60, 300],
                presetKey: (seconds) =>
                    Key('dev-health-interval-preset-$seconds'),
                selected: config.healthSampleIntervalSeconds,
                onPreset: (seconds) =>
                    unawaited(config.setHealthSampleIntervalSeconds(seconds)),
                sliderKey: const Key('dev-health-interval-slider'),
                sliderValue: config.healthSampleIntervalSeconds.toDouble(),
                onSlide: (value) => unawaited(
                  config.setHealthSampleIntervalSeconds(value.round()),
                ),
              ),
              Divider(height: 18, color: c.sep),
              _PhaseMeter(config: config, primary: primary),
            ],
          ),
        ),
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.title,
    required this.valueKey,
    required this.valueLabel,
    required this.primary,
    required this.presets,
    required this.presetKey,
    required this.selected,
    required this.onPreset,
    required this.sliderKey,
    required this.sliderValue,
    required this.onSlide,
  });

  final String title;
  final Key valueKey;
  final String valueLabel;
  final Color primary;
  final List<int> presets;
  final Key Function(int seconds) presetKey;
  final int selected;
  final ValueChanged<int> onPreset;
  final Key sliderKey;
  final double sliderValue;
  final ValueChanged<double> onSlide;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
            ),
            Text(
              valueLabel,
              key: valueKey,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final seconds in presets)
              ChoiceChip(
                key: presetKey(seconds),
                label: Text(AgentConfigStore.formatSampleWindow(seconds)),
                selected: selected == seconds,
                onSelected: (_) => onPreset(seconds),
              ),
          ],
        ),
        Slider(
          key: sliderKey,
          min: 60,
          max: 600,
          divisions: 9,
          value: sliderValue.clamp(60, 600),
          label: AgentConfigStore.formatSampleWindow(sliderValue.round()),
          onChanged: onSlide,
        ),
      ],
    );
  }
}

class _PhaseMeter extends StatelessWidget {
  const _PhaseMeter({required this.config, required this.primary});

  final AgentConfigStore config;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final maxPhase = config.healthSampleIntervalSeconds - 1;
    final phase = config.healthSamplePhaseSeconds.clamp(0, maxPhase);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '窗口内相位',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
            ),
            Text(
              '${config.healthSamplePhaseSeconds} 秒',
              key: const Key('dev-health-phase-value'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final seconds in const [0, 30])
              if (seconds < config.healthSampleIntervalSeconds)
                ChoiceChip(
                  key: Key('dev-health-phase-preset-$seconds'),
                  label: Text('$seconds 秒'),
                  selected: config.healthSamplePhaseSeconds == seconds,
                  onSelected: (_) =>
                      unawaited(config.setHealthSamplePhaseSeconds(seconds)),
                ),
          ],
        ),
        Slider(
          key: const Key('dev-health-phase-slider'),
          min: 0,
          max: maxPhase.toDouble(),
          divisions: maxPhase > 0 ? maxPhase : null,
          value: phase.toDouble(),
          label: '$phase 秒',
          onChanged: (value) =>
              unawaited(config.setHealthSamplePhaseSeconds(value.round())),
        ),
      ],
    );
  }
}
