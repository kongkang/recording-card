/// Setting 二级配置页 —— 本地语音引擎 / 云端模型设置 / Agent 预设与提示词 / 扩展能力（Skills · Tools · MCP）。
///
/// 窄屏由外层 `AppShell` 顶栏面包屑（`‹ Setting`）返回；宽屏置于右栏；
/// 无 `StoreScope` 的独立挂载场景（如单页测试）自动提供顶部返回栏。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/agent_config_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/transcribe/asr_models.dart';
import '../../services/transcribe/model_manager_controller.dart';
import '../../widgets/rc_switch.dart';
import '../../widgets/store_scope.dart';

class SettingSubPage extends StatelessWidget {
  const SettingSubPage({
    super.key,
    required this.subId,
    required this.agentConfig,
    this.modelManager,
    this.showPaneBack = false,
    this.standalone = false,
  });

  final String subId; // 'local' | 'cloud' | 'prompts' | 'ext'
  final AgentConfigStore agentConfig;
  final ModelManagerController? modelManager;
  final bool showPaneBack;
  final bool standalone;

  String get _title => switch (subId) {
    'local' => '本地语音引擎',
    'cloud' => '云端模型设置',
    'prompts' => '预设风格与提示词',
    'ext' => '扩展能力（Skills · Tools · MCP）',
    _ => '设置详情',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final appStore = StoreScope.maybeOf(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: standalone
          ? AppBar(
              backgroundColor: c.bg,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              leadingWidth: 108,
              leading: TextButton.icon(
                key: const Key('standalone-crumb-back'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.chevron_left, size: 18, color: c.label),
                label: Text(
                  'Setting',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.label,
                  ),
                ),
              ),
            )
          : null,
      body: ColoredBox(
        key: const Key('p-setsub'),
        color: c.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showPaneBack && appStore != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('pb-setsub'),
                  onPressed: appStore.goBack,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('返回 Setting'),
                  style: TextButton.styleFrom(
                    foregroundColor: c.sec,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                key: Key('setsub-scroll-$subId'),
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 40),
                children: [
                  Text(
                    _title,
                    key: const Key('setsub-title'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: c.label,
                    ),
                  ),
                  const SizedBox(height: 14),
                  switch (subId) {
                    'local' => _LocalEngineBody(controller: modelManager),
                    'cloud' => _CloudModelBody(config: agentConfig),
                    'prompts' => _AgentPromptsBody(config: agentConfig),
                    'ext' => _AgentExtensionsBody(config: agentConfig),
                    _ => const SizedBox.shrink(),
                  },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 1) 本地语音引擎 ──────────────────────────────────────────

class _LocalEngineBody extends StatefulWidget {
  const _LocalEngineBody({required this.controller});

  final ModelManagerController? controller;

  @override
  State<_LocalEngineBody> createState() => _LocalEngineBodyState();
}

class _LocalEngineBodyState extends State<_LocalEngineBody> {
  String? _verifyHint;

  @override
  void initState() {
    super.initState();
    final ctrl = widget.controller;
    if (ctrl != null && !ctrl.hasStatuses) {
      unawaited(ctrl.refresh());
    }
  }

  Future<void> _verifyNow(ModelManagerController ctrl) async {
    await ctrl.refresh();
    if (!mounted) return;
    setState(() {
      _verifyHint = ctrl.allReady
          ? '校验完成：三大端侧模型文件完整可用'
          : '校验完成：部分模型尚未安装，点击右侧可补齐';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final ctrl = widget.controller;
    final specs =
        ctrl?.specs ??
        const [senseVoiceSpec, sileroVadSpec, campplusEmbeddingSpec];

    Widget content() {
      final allReady = ctrl?.allReady ?? false;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: allReady ? RCColors.ok : RCColors.warn,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        allReady ? '离线语音管线已就绪' : '离线语音管线待补齐模型',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.label,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '录音在手机本地按「Silero VAD 切分有效人声 → SenseVoice 离线转写文字 → CAM++ 声纹聚类区分说话人」三步流水线执行。音频切片与声纹向量全程留在本机，不上传云端。',
                  style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _SubSectionLabel('端侧模型分工（共 ${specs.length} 项）'),
          for (final spec in specs) ...[
            const SizedBox(height: 10),
            _buildSpecCard(context, spec, ctrl),
          ],
          if (ctrl != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          ctrl.allReady
                              ? '本地转写已就绪'
                              : (ctrl.configured
                                    ? '本地模型未安装，无法转录'
                                    : '模型下载服务未配置'),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: c.sec,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('local-verify-btn'),
                        onPressed: ctrl.busy ? null : () => _verifyNow(ctrl),
                        child: const Text('校验完整性'),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        key: const Key('model-install-all'),
                        onPressed: ctrl.busy || !ctrl.configured
                            ? null
                            : () => unawaited(ctrl.installAll()),
                        child: Text(ctrl.allReady ? '重新下载' : '下载'),
                      ),
                    ],
                  ),
                  if (_verifyHint != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _verifyHint!,
                      key: const Key('local-verify-hint'),
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                  ],
                  if (ctrl.busy) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: ctrl.progress > 0 ? ctrl.progress : null,
                      minHeight: 4,
                      backgroundColor: c.sep,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ctrl.text,
                      key: const Key('model-progress-text'),
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                  ],
                  if (ctrl.error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      ctrl.error!,
                      key: const Key('model-error'),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: c.danger,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    }

    if (ctrl == null) return content();
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => content(),
    );
  }

  Widget _buildSpecCard(
    BuildContext context,
    ModelSpec spec,
    ModelManagerController? ctrl,
  ) {
    final c = context.rc;
    final status = ctrl?.statusFor(spec);
    final installed = status?.installed ?? false;
    final meta = _roleMeta(spec);
    final sizeText = installed
        ? _formatBytes(status?.presentBytes ?? 0)
        : meta.expectedSize;

    return Container(
      key: Key('model-row-${spec.id}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  meta.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: installed
                      ? const Color(0xFFE8F5EA)
                      : const Color(0xFFF0F0EC),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  installed ? '已就绪' : (spec.bundled ? '随包内置' : '未安装'),
                  style: TextStyle(
                    fontSize: 11,
                    color: installed ? RCColors.okInk : c.sec,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${meta.stageTag} · $sizeText',
            style: TextStyle(fontSize: 12, color: c.sec),
          ),
          const SizedBox(height: 8),
          Text(
            meta.explanation,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: c.ink),
          ),
          if (ctrl != null && installed && !spec.bundled) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: Key('model-delete-${spec.id}'),
                onPressed: ctrl.busy ? null : () => unawaited(ctrl.delete(spec)),
                style: TextButton.styleFrom(
                  foregroundColor: c.sec,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('删除模型文件'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static ({String title, String stageTag, String expectedSize, String explanation})
  _roleMeta(ModelSpec spec) {
    if (spec.id == senseVoiceSpec.id) {
      return (
        title: 'SenseVoice Small INT8（离线语音转写）',
        stageTag: '阶段 2 · 语音转文字主模型',
        expectedSize: '约 230MB',
        explanation:
            '阿里 FunAudioLLM 多语种离线识别模型（sherpa-onnx INT8 量化版），负责把切好的语音段在手机本地转成中英文本并标注语气情绪。',
      );
    }
    if (spec.id == sileroVadSpec.id) {
      return (
        title: 'Silero VAD（语音活动检测）',
        stageTag: '阶段 1 · 人声与静音切分',
        expectedSize: '随包约 1.8MB',
        explanation:
            '轻量级人声活动检测模型（随安装包内置），先滤除长静音并按停顿切出单句边界，避免把空白噪音送进主模型产生幻觉词。',
      );
    }
    if (spec.id == campplusEmbeddingSpec.id) {
      return (
        title: '3D-Speaker CAM++（声纹特征嵌入）',
        stageTag: '阶段 3 · 说话人聚类推测',
        expectedSize: '约 27MB',
        explanation:
            '达摩院 3D-Speaker 声纹特征提取模型，在本机对每句话提取声学向量并聚类区分「说话人 1 / 2（推测）」，不断言真实身份且不上传声纹。',
      );
    }
    return (
      title: spec.displayName,
      stageTag: '端侧语音组件',
      expectedSize: _formatBytes(spec.totalBytes),
      explanation: '本地离线语音处理组件。',
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '—';
    final mb = bytes / (1024 * 1024);
    return mb >= 100
        ? '${mb.toStringAsFixed(0)}MB'
        : '${mb.toStringAsFixed(1)}MB';
  }
}

// ── 2) 云端模型设置 ──────────────────────────────────────────

class _CloudModelBody extends StatelessWidget {
  const _CloudModelBody({required this.config});

  final AgentConfigStore config;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: config,
      builder: (context, _) {
        final models = config.availableCloudModels;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '云端模型仅接收本地转写后的纯文本，用于手动生成总结、日报与未来的自动合并润色；原始录音永不上传。',
              style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('总结与 Agent 推理模型'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < models.length; i++) ...[
                    if (i > 0)
                      Divider(height: 1, thickness: 1, color: c.sep),
                    _modelRow(context, models[i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SubSectionLabel('上下文组织策略'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                children: [
                  _ctxRow(
                    context,
                    keyName: 'ctx-full-day',
                    mode: 'full_day',
                    title: '全天连续单上下文（推荐）',
                    subtitle:
                        '同一天的连续录音共享同一对话线程，增量追加新切片，避免重复发送前文并提升上下文缓存命中率。',
                  ),
                  Divider(height: 1, thickness: 1, color: c.sep),
                  _ctxRow(
                    context,
                    keyName: 'ctx-scoped',
                    mode: 'scoped',
                    title: '仅所选记录独立上下文',
                    subtitle:
                        '每次生成总结仅发送当前勾选的记录文本，不引用同日其它时段的背景上下文。',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SubSectionLabel('输出采样温度（Temperature）'),
            const SizedBox(height: 8),
            Row(
              children: [
                _tempChip(context, 0.2, '0.2 严谨纪要'),
                const SizedBox(width: 8),
                _tempChip(context, 0.5, '0.5 均衡提炼'),
                const SizedBox(width: 8),
                _tempChip(context, 0.8, '0.8 发散洞察'),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _modelRow(BuildContext context, CloudModelOption m) {
    final c = context.rc;
    final selected = config.cloudModel == m.id;
    return InkWell(
      key: Key('model-opt-${m.id}'),
      onTap: () => unawaited(config.setCloudModel(m.id)),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          m.name,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: c.label,
                          ),
                        ),
                      ),
                      if (m.fromGateway) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F5EA),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            '网关可用',
                            style: TextStyle(
                              fontSize: 10,
                              color: RCColors.okInk,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    m.desc,
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 20,
                color: selected ? RCColors.ok : c.ax,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ctxRow(
    BuildContext context, {
    required String keyName,
    required String mode,
    required String title,
    required String subtitle,
  }) {
    final c = context.rc;
    final selected = config.contextMode == mode;
    return InkWell(
      key: Key(keyName),
      onTap: () => unawaited(config.setContextMode(mode)),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 20,
                color: selected ? RCColors.ok : c.ax,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tempChip(BuildContext context, double value, String label) {
    final c = context.rc;
    final active = (config.temperature - value).abs() < 0.05;
    return Expanded(
      child: OutlinedButton(
        key: Key('temp-$value'),
        onPressed: () => unawaited(config.setTemperature(value)),
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? c.label : c.card,
          foregroundColor: active ? Colors.white : c.ink,
          side: BorderSide(color: active ? c.label : c.sep),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

// ── 3) Agent 预设风格与提示词 ─────────────────────────────────

class _AgentPromptsBody extends StatefulWidget {
  const _AgentPromptsBody({required this.config});

  final AgentConfigStore config;

  @override
  State<_AgentPromptsBody> createState() => _AgentPromptsBodyState();
}

class _AgentPromptsBodyState extends State<_AgentPromptsBody> {
  String _tab = 'summary'; // 'summary' | 'polish' | 'dream'
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.config.promptFor(_tab),
  );
  bool _savedToast = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _switchTab(String next) {
    setState(() {
      _tab = next;
      _savedToast = false;
      _ctrl.text = widget.config.promptFor(next);
    });
  }

  Future<void> _pickPreset(String id) async {
    await widget.config.selectPreset(id);
    if (!mounted) return;
    setState(() {
      _savedToast = false;
      _ctrl.text = widget.config.promptFor(_tab);
    });
  }

  Future<void> _saveCurrent() async {
    await widget.config.savePrompt(_tab, _ctrl.text);
    if (!mounted) return;
    setState(() => _savedToast = true);
  }

  Future<void> _resetCurrent() async {
    await widget.config.resetPromptsToActivePreset();
    if (!mounted) return;
    setState(() {
      _savedToast = false;
      _ctrl.text = widget.config.promptFor(_tab);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: widget.config,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择预设风格即可一键切换整理口径；也可以针对「总结生成 / 口语清洗与分段 / 日报与做梦」分别微调提示词。总结生成提示词已实时接入生成链路。',
              style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('预设风格'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in AgentConfigStore.presets)
                  _presetPill(context, p.id, p.label),
                if (widget.config.presetId == 'custom')
                  _presetPill(context, 'custom', '自定义', interactive: false),
              ],
            ),
            const SizedBox(height: 18),
            const _SubSectionLabel('分环节系统提示词（System Prompt）'),
            const SizedBox(height: 8),
            Row(
              children: [
                _stageTab(context, 'summary', '总结生成'),
                const SizedBox(width: 8),
                _stageTab(context, 'polish', '口语清洗与分段'),
                const SizedBox(width: 8),
                _stageTab(context, 'dream', '日报与做梦'),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const Key('prompt-editor'),
                controller: _ctrl,
                minLines: 5,
                maxLines: 9,
                style: TextStyle(fontSize: 13.5, height: 1.55, color: c.label),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '输入该环节的整理提示词…',
                  hintStyle: TextStyle(color: c.ax, fontSize: 13),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _tab == 'summary'
                  ? '注：JSON 结构化字段契约由客户端自动追加在末尾，无需手动编写 JSON 格式说明。'
                  : '注：本环节提示词已持久化保存，将在全天自动合并与日报/做梦管线启用时生效。',
              style: TextStyle(fontSize: 11.5, color: c.sec),
            ),
            if (_savedToast) ...[
              const SizedBox(height: 6),
              const Text(
                '提示词已保存并立即生效',
                key: Key('prompt-saved-hint'),
                style: TextStyle(fontSize: 12, color: RCColors.okInk),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('prompt-reset'),
                    onPressed: _resetCurrent,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.ink,
                      side: BorderSide(color: c.ax),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    child: const Text('恢复预设默认'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('prompt-save'),
                    onPressed: _saveCurrent,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.label,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    child: const Text('保存提示词'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _presetPill(
    BuildContext context,
    String id,
    String label, {
    bool interactive = true,
  }) {
    final c = context.rc;
    final active = widget.config.presetId == id;
    return OutlinedButton(
      key: Key('preset-$id'),
      onPressed: interactive ? () => _pickPreset(id) : null,
      style: OutlinedButton.styleFrom(
        backgroundColor: active ? c.label : c.card,
        foregroundColor: active ? Colors.white : c.ink,
        disabledBackgroundColor: c.label,
        disabledForegroundColor: Colors.white,
        side: BorderSide(color: active ? c.label : c.sep),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Widget _stageTab(BuildContext context, String id, String label) {
    final c = context.rc;
    final active = _tab == id;
    return Expanded(
      child: OutlinedButton(
        key: Key('ptab-$id'),
        onPressed: () => _switchTab(id),
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? const Color(0xFFEAEAE4) : c.card,
          foregroundColor: active ? c.label : c.sec,
          side: BorderSide(color: active ? c.label : c.sep),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

// ── 4) 扩展能力（Skills · Tools · MCP）────────────────────────

class _AgentExtensionsBody extends StatelessWidget {
  const _AgentExtensionsBody({required this.config});

  final AgentConfigStore config;

  Future<void> _showAddMcpDialog(BuildContext context) async {
    final result = await showDialog<({String name, String endpoint})>(
      context: context,
      builder: (_) => const _AddMcpDialog(),
    );
    if (result != null) {
      await config.addCustomMcp(
        name: result.name,
        endpoint: result.endpoint,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: config,
      builder: (context, _) {
        final skills = config.allExtensions
            .where((e) => e.kind == 'skill')
            .toList();
        final tools = config.allExtensions
            .where((e) => e.kind == 'tool')
            .toList();
        final mcps = config.allExtensions
            .where((e) => e.kind == 'mcp')
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '为录音 Agent 按需挂载整理技能（Skills）、本地上下文工具（Tools）与外部协议连接器（MCP）。已启用的 Skills 会自动注入总结生成指令。',
              style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('Skills · 整理技能'),
            const SizedBox(height: 8),
            _extGroupCard(context, skills),
            const SizedBox(height: 18),
            const _SubSectionLabel('Tools · 本地工具能力'),
            const SizedBox(height: 8),
            _extGroupCard(context, tools),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(child: _SubSectionLabel('MCP · 外部上下文服务')),
                TextButton.icon(
                  key: const Key('mcp-add-btn'),
                  onPressed: () => _showAddMcpDialog(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加服务'),
                  style: TextButton.styleFrom(
                    foregroundColor: c.label,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _extGroupCard(context, mcps),
          ],
        );
      },
    );
  }

  Widget _extGroupCard(BuildContext context, List<AgentExtensionItem> items) {
    final c = context.rc;
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.sep),
            _extRow(context, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _extRow(BuildContext context, AgentExtensionItem item) {
    final c = context.rc;
    final on = config.isExtensionOn(item.id);
    return InkWell(
      key: Key('sw-${item.id}'),
      onTap: () => unawaited(config.toggleExtension(item.id)),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    style: TextStyle(fontSize: 12, height: 1.4, color: c.sec),
                  ),
                ],
              ),
            ),
            if (item.custom)
              IconButton(
                key: Key('mcp-del-${item.id}'),
                onPressed: () => unawaited(config.removeCustomMcp(item.id)),
                icon: Icon(Icons.delete_outline, size: 18, color: c.sec),
                visualDensity: VisualDensity.compact,
              ),
            const SizedBox(width: 8),
            RCSwitch(on: on),
          ],
        ),
      ),
    );
  }
}

class _AddMcpDialog extends StatefulWidget {
  const _AddMcpDialog();

  @override
  State<_AddMcpDialog> createState() => _AddMcpDialogState();
}

class _AddMcpDialogState extends State<_AddMcpDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 MCP 服务'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('mcp-name-input'),
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '服务名称',
              hintText: '例如：Notion 团队空间',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('mcp-url-input'),
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Endpoint / URI',
              hintText: 'https://mcp.example.com/sse',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('mcp-confirm-add'),
          onPressed: () => Navigator.of(context).pop((
            name: _nameCtrl.text,
            endpoint: _urlCtrl.text,
          )),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _SubSectionLabel extends StatelessWidget {
  const _SubSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.rc.sec,
      ),
    );
  }
}
