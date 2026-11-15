/// Setting 二级配置页 —— 本地语音引擎 / 云端模型设置 / Agent 预设与提示词 / 扩展能力（Skills · Tools · MCP）。
///
/// 窄屏由外层 `AppShell` 顶栏面包屑（`‹ Setting`）返回；宽屏置于右栏；
/// 无 `StoreScope` 的独立挂载场景（如单页测试）自动提供顶部返回栏。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/device_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/auth/oauth_config.dart';
import '../../services/auth_service.dart';
import '../../services/transcribe/asr_models.dart';
import '../../services/transcribe/model_manager_controller.dart';
import '../../services/watch/watch_hardware_service.dart';
import '../../widgets/rc_switch.dart';
import '../../widgets/store_scope.dart';

class SettingSubPage extends StatelessWidget {
  const SettingSubPage({
    super.key,
    required this.subId,
    required this.agentConfig,
    this.device,
    this.modelManager,
    this.authService,
    this.showPaneBack = false,
    this.standalone = false,
  });

  final String subId; // 'login' | 'local' | 'cloud' | 'prompts' | 'voiceprint' | 'ext' | 'island' | 'watch'
  final AgentConfigStore agentConfig;
  final DeviceStore? device;
  final ModelManagerController? modelManager;
  final AuthService? authService;
  final bool showPaneBack;
  final bool standalone;

  String get _title => switch (subId) {
    'login' => '云端账号授权',
    'local' => '本地语音引擎',
    'cloud' => '云端模型设置',
    'prompts' => '预设风格与提示词',
    'voiceprint' => '声纹识别',
    'ext' => '扩展能力（Skills · Tools · MCP）',
    'island' => '灵动岛与操作按钮',
    'watch' => 'Apple Watch 联动',
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
                padding: EdgeInsets.fromLTRB(
                  22,
                  14,
                  22,
                  RCDims.pageBottomPad +
                      (standalone ? MediaQuery.paddingOf(context).bottom : 0),
                ),
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
                    'login' => _LoginAuthBody(
                      authService: authService,
                      device: device,
                    ),
                    'local' => _LocalEngineBody(controller: modelManager),
                    'cloud' => _CloudModelBody(config: agentConfig),
                    'prompts' => _AgentPromptsBody(config: agentConfig),
                    'voiceprint' => _VoiceprintBody(controller: modelManager),
                    'ext' => _AgentExtensionsBody(config: agentConfig),
                    'island' => _DynamicIslandBody(config: agentConfig),
                    'watch' => _AppleWatchLinkBody(
                      config: agentConfig,
                      device: device,
                    ),
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
  @override
  void initState() {
    super.initState();
    final ctrl = widget.controller;
    if (ctrl != null && !ctrl.hasStatuses) {
      unawaited(ctrl.refresh());
    }
  }

  Future<void> _confirmDeleteModel(
    BuildContext context,
    ModelManagerController ctrl,
    ModelSpec spec,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('model-delete-confirm-dialog'),
        title: const Text('确认删除本地语音模型？'),
        content: const Text(
          '删除后将无法自动离线语音转文字，仅能切换到付费云端模式；原享有的终身本地转写服务也会失效，且语音上行云端存在隐私泄露风险。',
        ),
        actions: [
          TextButton(
            key: const Key('model-delete-cancel-btn'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('model-delete-confirm-btn'),
            style: FilledButton.styleFrom(
              backgroundColor: context.rc.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ctrl.delete(spec);
    }
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
      final showDownloadBtn =
          ctrl != null && (!allReady || ctrl.hasRemoteUpdates);
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
            child: Row(
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
                    allReady
                        ? '本地语音引擎已就绪，切片与转写全程留在本机。'
                        : '本地语音引擎待补齐，音频与声纹均不上传云端。',
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: c.sec),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SubSectionLabel('本地语音三引擎（共 ${specs.length} 项）'),
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
                                    ? '本地模型待下载补齐'
                                    : '模型下载服务未配置'),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: c.sec,
                          ),
                        ),
                      ),
                      if (showDownloadBtn)
                        OutlinedButton(
                          key: const Key('model-install-all'),
                          onPressed: ctrl.busy || !ctrl.configured
                              ? null
                              : () => unawaited(ctrl.installAll()),
                          child: Text(ctrl.hasRemoteUpdates ? '更新' : '下载'),
                        ),
                    ],
                  ),
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
                    fontSize: 14.5,
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
              if (ctrl != null && !installed && !spec.bundled) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: Key('model-install-${spec.id}'),
                  tooltip: '下载模型',
                  onPressed: ctrl.busy || !ctrl.configured
                      ? null
                      : () => unawaited(ctrl.installSpec(spec)),
                  icon: Icon(Icons.download_outlined, size: 17, color: c.sec),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
              if (ctrl != null && installed && !spec.bundled) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: Key('model-delete-${spec.id}'),
                  tooltip: '删除模型',
                  onPressed: ctrl.busy
                      ? null
                      : () => unawaited(_confirmDeleteModel(context, ctrl, spec)),
                  icon: Icon(Icons.delete_outline, size: 17, color: c.sec),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${meta.stageTag} · $sizeText',
            style: TextStyle(fontSize: 12, color: c.sec),
          ),
          const SizedBox(height: 6),
          Text(
            meta.explanation,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: c.ink),
          ),
        ],
      ),
    );
  }

  static ({String title, String stageTag, String expectedSize, String explanation})
  _roleMeta(ModelSpec spec) {
    if (spec.id == senseVoiceSpec.id) {
      return (
        title: 'SenseVoice 离线转写',
        stageTag: '离线语音转文字',
        expectedSize: '约 230MB',
        explanation: '在本机将切片语音转写为中英文文本。',
      );
    }
    if (spec.id == sileroVadSpec.id) {
      return (
        title: 'Silero VAD 人声检测',
        stageTag: '人声静音切分',
        expectedSize: '约 1.8MB',
        explanation: '过滤长静音片段并精准切分单句边界。',
      );
    }
    if (spec.id == campplusEmbeddingSpec.id) {
      return (
        title: 'CAM++ 声纹识别',
        stageTag: '说话人聚类推测',
        expectedSize: '约 27MB',
        explanation: '提取说话人声纹特征进行聚类推测。',
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

class _CloudModelBody extends StatefulWidget {
  const _CloudModelBody({required this.config});

  final AgentConfigStore config;

  @override
  State<_CloudModelBody> createState() => _CloudModelBodyState();
}

class _CloudModelBodyState extends State<_CloudModelBody> {
  late final TextEditingController _apiCtrl = TextEditingController(
    text: widget.config.customApiBase,
  );
  bool _savedHint = false;

  AgentConfigStore get config => widget.config;

  @override
  void dispose() {
    _apiCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveApi() async {
    await config.setCustomApiBase(_apiCtrl.text);
    if (!mounted) return;
    setState(() => _savedHint = true);
  }

  Future<void> _resetApi() async {
    _apiCtrl.clear();
    await config.setCustomApiBase('');
    if (!mounted) return;
    setState(() => _savedHint = false);
  }

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
              '仅上行本地转写纯文本用于总结与整理；原始音频不上传云端。',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: c.sec),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: InkWell(
                key: const Key('cloud-enable-switch'),
                borderRadius: BorderRadius.circular(12),
                onTap: () =>
                    unawaited(config.setCloudEnabled(!config.cloudEnabled)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '开启云端模型',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: c.label,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              config.cloudEnabled
                                  ? '已开启，支持云端总结生成'
                                  : '已关闭，仅使用本地能力',
                              style: TextStyle(fontSize: 12, color: c.sec),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      RCSwitch(on: config.cloudEnabled),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('自定义 API 地址'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('cloud-custom-api-input'),
                    controller: _apiCtrl,
                    style: TextStyle(fontSize: 13.5, color: c.label),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'https://api.example.com（留空走默认网关）',
                      hintStyle: TextStyle(fontSize: 13, color: c.ax),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                        borderSide: BorderSide(color: c.sep),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                        borderSide: BorderSide(color: c.sep),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (_savedHint)
                        const Expanded(
                          child: Text(
                            '已保存接口地址',
                            key: Key('cloud-custom-api-saved'),
                            style: TextStyle(
                              fontSize: 12,
                              color: RCColors.okInk,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      if (config.customApiBase.isNotEmpty ||
                          _apiCtrl.text.trim().isNotEmpty) ...[
                        TextButton(
                          key: const Key('cloud-custom-api-reset'),
                          onPressed: _resetApi,
                          child: const Text('恢复默认'),
                        ),
                        const SizedBox(width: 6),
                      ],
                      FilledButton(
                        key: const Key('cloud-custom-api-save'),
                        onPressed: _saveApi,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.label,
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('保存', style: TextStyle(fontSize: 12.5)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (config.developerMode) ...[
              const SizedBox(height: 20),
              const _SubSectionLabel('开发者模式 · 总结与 Agent 推理模型'),
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
                      subtitle: '同一天录音共享上下文线程，增量追加新切片。',
                    ),
                    Divider(height: 1, thickness: 1, color: c.sep),
                    _ctxRow(
                      context,
                      keyName: 'ctx-scoped',
                      mode: 'scoped',
                      title: '仅所选记录独立上下文',
                      subtitle: '每次仅发送当前勾选记录文本。',
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

// ── 0) 云端账号授权与第三方绑定 ──────────────────────────────

class _LoginAuthBody extends StatefulWidget {
  const _LoginAuthBody({required this.authService, this.device});

  final AuthService? authService;
  final DeviceStore? device;

  @override
  State<_LoginAuthBody> createState() => _LoginAuthBodyState();
}

class _LoginAuthBodyState extends State<_LoginAuthBody> {
  String? _statusMsg;
  bool _signingOut = false;

  Future<void> _handleSignOut(BuildContext context) async {
    final auth = widget.authService;
    if (auth == null || _signingOut) return;

    final device = widget.device;
    final appStore = StoreScope.maybeOf(context);
    final phoneRec = device?.isPhoneRecording ?? false;
    final hwRec = (device?.isConnected ?? false) && (device?.isRecording ?? false);

    if (!phoneRec && !hwRec) {
      auth.signOut();
      return;
    }

    final c = context.rc;
    final recDesc = phoneRec && hwRec
        ? '当前正在进行本机与硬件录音，退出登录将自动关闭录音并保存当前片段，避免不同账号间的数据归属混淆。'
        : phoneRec
            ? '当前正在进行本机录音，退出登录将自动关闭录音并保存当前片段，避免不同账号间的数据归属混淆。'
            : '当前录音卡正在录音，退出登录将自动关闭录音并保存当前片段，避免不同账号间的数据归属混淆。';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('signout-recording-confirm-dialog'),
        title: const Text('退出登录并关闭录音？'),
        content: Text(recDesc),
        actions: <Widget>[
          TextButton(
            key: const Key('signout-recording-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('signout-recording-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: c.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('关闭录音并退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _signingOut = true);
    try {
      await device?.stopAllRecordingsForSignOut();
      // 让 PhoneMicRecorder 广播流在同一登录态微任务中把尾片投递给 AppShell._phoneSliceSub
      await Future<void>.value();
      await Future<void>.value();
      if (appStore != null) {
        await appStore
            .finishLiveRecording()
            .timeout(const Duration(seconds: 5), onTimeout: () => 0);
      }
      auth.signOut();
    } finally {
      if (mounted) {
        setState(() => _signingOut = false);
      }
    }
  }

  Future<void> _triggerOAuth({String? provider}) async {
    final auth = widget.authService;
    if (auth == null) {
      setState(() => _statusMsg = '当前页面未连接鉴权服务');
      return;
    }
    final validLoginType =
        (provider != null && OAuthConfig.supportedLoginTypes.contains(provider))
            ? provider
            : null;
    final err = (provider == 'wechat' && auth.shouldShowWechatSignIn)
        ? await auth.signInWithWechat()
        : await auth.signInWithOAuth(loginType: validLoginType);
    if (!mounted) return;
    setState(() {
      _statusMsg = err ?? (auth.isSignedIn ? '外脑账号已授权' : '已取消授权');
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final auth = widget.authService;

    Widget buildBody() {
      final signedIn = auth?.isSignedIn ?? false;
      final session = auth?.session;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '统一由外脑（Wainao）账号鉴权；微信、Google、GitHub 与 Facebook 绑定均基于外脑账号体系完成授权。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: c.sec),
          ),
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
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: signedIn ? RCColors.ok : c.ax,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        signedIn
                            ? (session?.account ?? '外脑账号已授权')
                            : '未授权外脑账号',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: c.label,
                        ),
                      ),
                    ),
                    if (signedIn)
                      TextButton(
                        key: const Key('auth-signout-btn'),
                        onPressed: _signingOut
                            ? null
                            : () => unawaited(_handleSignOut(context)),
                        style: TextButton.styleFrom(
                          foregroundColor: c.danger,
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        child: Text(_signingOut ? '正在关闭录音…' : '退出登录'),
                      )
                    else
                      FilledButton(
                        key: const Key('auth-wainao-login-btn'),
                        onPressed: auth?.isBusy == true
                            ? null
                            : () => unawaited(_triggerOAuth()),
                        style: FilledButton.styleFrom(
                          backgroundColor: c.label,
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          auth?.isBusy == true ? '授权中…' : '外脑授权登录',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                  ],
                ),
                if (session?.email != null && session!.email!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    session.email!,
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                ],
                if (_statusMsg != null || auth?.lastError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    auth?.lastError ?? _statusMsg ?? '',
                    key: const Key('auth-status-msg'),
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          const _SubSectionLabel('第三方账号绑定'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Column(
              children: [
                _providerRow(
                  context,
                  keyName: 'auth-bind-wechat',
                  title: '微信绑定',
                  subtitle: '中国地区推荐，通过外脑鉴权关联微信身份',
                  onTap: () => unawaited(_triggerOAuth(provider: 'wechat')),
                ),
                Divider(height: 1, thickness: 1, color: c.sep),
                _providerRow(
                  context,
                  keyName: 'auth-bind-google',
                  title: 'Google 绑定',
                  subtitle: '关联 Google 账号用于跨端会话',
                  onTap: () => unawaited(_triggerOAuth(provider: 'google')),
                ),
                Divider(height: 1, thickness: 1, color: c.sep),
                _providerRow(
                  context,
                  keyName: 'auth-bind-github',
                  title: 'GitHub 绑定',
                  subtitle: '开发者身份登录与授权',
                  onTap: () => unawaited(_triggerOAuth(provider: 'github')),
                ),
                Divider(height: 1, thickness: 1, color: c.sep),
                _providerRow(
                  context,
                  keyName: 'auth-bind-facebook',
                  title: 'Facebook 登录',
                  subtitle: '通过外脑认证关联 Facebook',
                  onTap: () => unawaited(_triggerOAuth(provider: 'facebook')),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (auth == null) return buildBody();
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) => buildBody(),
    );
  }

  Widget _providerRow(
    BuildContext context, {
    required String keyName,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final c = context.rc;
    return InkWell(
      key: Key(keyName),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
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
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.ax),
          ],
        ),
      ),
    );
  }
}

// ── 5) 声纹识别说明 ───────────────────────────────────────────

class _VoiceprintBody extends StatefulWidget {
  const _VoiceprintBody({required this.controller});

  final ModelManagerController? controller;

  @override
  State<_VoiceprintBody> createState() => _VoiceprintBodyState();
}

class _VoiceprintBodyState extends State<_VoiceprintBody> {
  @override
  void initState() {
    super.initState();
    final ctrl = widget.controller;
    if (ctrl != null && !ctrl.hasStatuses) {
      unawaited(ctrl.refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final ctrl = widget.controller;
    Widget content() {
      final installed =
          ctrl?.statusFor(campplusEmbeddingSpec)?.installed ?? false;
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
                    Expanded(
                      child: Text(
                        '说话人聚类（推测）',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: c.label,
                        ),
                      ),
                    ),
                    Text(
                      installed ? '已就绪' : '待下载',
                      style: TextStyle(
                        fontSize: 12,
                        color: installed ? RCColors.okInk : c.sec,
                      ),
                    ),
                    if (ctrl != null && !installed) ...[
                      const SizedBox(width: 10),
                      OutlinedButton(
                        key: const Key('voiceprint-install-btn'),
                        onPressed: ctrl.busy || !ctrl.configured
                            ? null
                            : () => unawaited(
                                  ctrl.installSpec(campplusEmbeddingSpec),
                                ),
                        child: Text(
                          ctrl.busy
                              ? '下载中…'
                              : (ctrl.error != null ? '重试' : '下载'),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '基于本机声纹特征将对话归类为「说话人 1 / 2（推测）」，原始声纹特征仅留存在本机，不断言真实身份。',
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: c.sec),
                ),
                if (ctrl != null && ctrl.busy) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: ctrl.progress > 0 ? ctrl.progress : null,
                    minHeight: 4,
                    backgroundColor: c.sep,
                  ),
                  if (ctrl.text.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      ctrl.text,
                      key: const Key('voiceprint-progress-text'),
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                  ],
                ],
                if (ctrl != null && !installed && ctrl.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    ctrl.error!,
                    key: const Key('voiceprint-error'),
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
      );
    }

    if (ctrl == null) return content();
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => content(),
    );
  }
}

// ── 6) 灵动岛与操作按钮 ───────────────────────────────────────

class _DynamicIslandBody extends StatelessWidget {
  const _DynamicIslandBody({required this.config});

  final AgentConfigStore config;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: config,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: InkWell(
              key: const Key('island-enable-switch'),
              borderRadius: BorderRadius.circular(12),
              onTap: () =>
                  unawaited(config.setIslandEnabled(!config.islandEnabled)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '开启录音灵动岛与锁屏实况',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: c.label,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '蓝牙硬件录音、断连自动保底录音及本机录音开启期间，在灵动岛和锁屏实时展示运行状态与计时。',
                            style: TextStyle(fontSize: 12, color: c.sec),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    RCSwitch(on: config.islandEnabled),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _SubSectionLabel('iPhone 操作按钮快捷方式'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Text(
              '前往系统「设置 → 操作按钮 → 快捷指令」，选择「录音卡 · 切换录音」即可一键开启或关闭录音（已连硬件时控制硬件录音并开启本机待命保底，未连硬件时控制本机录音）。',
              style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 7) Apple Watch 联动（独立采集硬件接入）──────────────────

class _AppleWatchLinkBody extends StatefulWidget {
  const _AppleWatchLinkBody({required this.config, required this.device});

  final AgentConfigStore config;
  final DeviceStore? device;

  @override
  State<_AppleWatchLinkBody> createState() => _AppleWatchLinkBodyState();
}

class _AppleWatchLinkBodyState extends State<_AppleWatchLinkBody> {
  String? _hint;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final wh = widget.device?.watchHardware;
    if (wh != null) {
      unawaited(wh.refreshStatus());
    }
  }

  static String _batteryTierText(WatchBridgeStatus s) {
    if (s.isCharging) return '充电中';
    if (s.batteryLevel <= 0) return '未知';
    if (s.batteryLevel < 20) return '电量低';
    if (s.batteryLevel < 40) return '电量中';
    return '电量高';
  }

  Future<void> _toggleLink(bool next) async {
    await widget.config.setWatchLinkEnabled(next);
    final dev = widget.device;
    if (dev != null) {
      await dev.setWatchLinkEnabled(next);
    }
    if (!mounted) return;
    setState(() {
      _hint = next ? '已开启 Apple Watch 联动，可在右上角胶囊扫描连接' : '已关闭 Apple Watch 联动';
    });
  }

  Future<void> _connectOrDisconnect() async {
    final dev = widget.device;
    if (dev == null) return;
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      final isWatchConnected =
          dev.isConnected && dev.activeKind == DeviceKind.appleWatch;
      if (isWatchConnected) {
        await dev.disconnectSafely();
        if (mounted) {
          setState(() => _hint = '已断开 Apple Watch 连接');
        }
        return;
      }
      if (!widget.config.watchLinkEnabled) {
        await widget.config.setWatchLinkEnabled(true);
        await dev.setWatchLinkEnabled(true);
      } else {
        await dev.watchHardware.refreshStatus();
      }
      final cardDev = dev.watchHardware.asCardDevice;
      if (cardDev == null) {
        if (mounted) {
          setState(() => _hint = '未检测到已配对的 Apple Watch');
        }
        return;
      }
      await dev.connectTo(cardDev);
      if (mounted) {
        setState(() {
          _hint = dev.isConnected && dev.activeKind == DeviceKind.appleWatch
              ? '已将 Apple Watch 设为当前采集硬件'
              : (dev.linkError ?? 'Apple Watch 连接未完成，请确认手表端已安装「录音卡」');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _flushPending() async {
    final dev = widget.device;
    if (dev == null) return;
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      final count = await dev.watchHardware.flushAndDrain();
      if (mounted) {
        setState(
          () => _hint = count > 0
              ? '已拉取 $count 段手表本地切片进入转写队列'
              : '手表暂无待传切片',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final dev = widget.device;
    final listenable = dev == null
        ? widget.config
        : Listenable.merge([widget.config, dev, dev.watchHardware]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final on = widget.config.watchLinkEnabled;
        final status = dev?.watchHardware.currentStatus;
        final isWatchConnected =
            dev?.isConnected == true &&
            dev?.activeKind == DeviceKind.appleWatch;
        final pairedText = status == null
            ? '待检测'
            : (!status.supported
                  ? '当前平台不支持'
                  : (status.paired ? '已配对' : '未配对'));
        final installedText = status == null
            ? '—'
            : (status.watchAppInstalled ? '已安装' : '未安装');
        final linkText = isWatchConnected
            ? '已作为当前硬件接入'
            : (status?.reachable == true ? '表端在线可达' : '离线待命（支持表端先存后传）');
        final battText = status == null ? '未知' : _batteryTierText(status);
        final pendingText = '${status?.pendingCount ?? 0} 段';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: InkWell(
                key: const Key('watch-link-toggle-row'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => unawaited(_toggleLink(!on)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '将 Apple Watch 作为录音硬件接入',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: c.label,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '开启后手表与录音卡 V2 / 点一机 V1 / 语音 AI 键盘并列出现在右上角设备选单，表端仅负责轻量采集与本地缓存，切片全部在本机离线转码入库。',
                              style: TextStyle(fontSize: 12, color: c.sec),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      KeyedSubtree(
                        key: const Key('watch-link-switch'),
                        child: RCSwitch(on: on),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('配对与协同状态'),
            const SizedBox(height: 8),
            Container(
              key: const Key('watch-link-status-card'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _WatchKvRow(label: '配对状态', value: pairedText),
                  _WatchKvRow(label: '手表端应用', value: installedText),
                  _WatchKvRow(label: '协同链路', value: linkText),
                  _WatchKvRow(label: '手表电量', value: battText),
                  _WatchKvRow(label: '本地待传队列', value: pendingText, last: true),
                  if (status != null &&
                      status.paired &&
                      !status.watchAppInstalled) ...[
                    const SizedBox(height: 10),
                    Container(
                      key: const Key('watch-install-guide-banner'),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: c.bg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.sep),
                      ),
                      child: Text(
                        '检测到已配对 Apple Watch，但表端尚未完成安装：\n'
                        '① 开发测试版请先在手表端开启「设置 → 隐私与安全性 → 开发者模式」并按提示重启确认；\n'
                        '② 打开 iPhone 系统「Watch」App →「我的手表」滑到底部「可用 App」→ 找到「录音卡手表」点击「安装」。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: c.sec,
                        ),
                      ),
                    ),
                  ],
                  if (_hint != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _hint!,
                      key: const Key('watch-link-hint'),
                      style: TextStyle(fontSize: 12, color: c.okInk),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        key: const Key('watch-connect-btn'),
                        onPressed: (_busy || dev == null)
                            ? null
                            : _connectOrDisconnect,
                        child: Text(
                          isWatchConnected ? '断开手表连接' : '设为当前录音硬件',
                        ),
                      ),
                      OutlinedButton(
                        key: const Key('watch-flush-btn'),
                        onPressed: (_busy || dev == null || !on)
                            ? null
                            : _flushPending,
                        child: const Text('立即拉取待传录音'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('表盘常驻采集配置（三步）'),
            const SizedBox(height: 8),
            Container(
              key: const Key('watch-complication-guide'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '1. 长按 Apple Watch 表盘 →「编辑」→ 选定角落、圆形、矩形或内嵌槽位，添加「录音卡」表盘组件；',
                    style: TextStyle(fontSize: 12.5, height: 1.55, color: c.label),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '2. 抬腕轻点组件即可直接拉起手表端持续录音（HKWorkoutSession + 扩展后台保活，支持抬腕打重点 Mark）；',
                    style: TextStyle(fontSize: 12.5, height: 1.55, color: c.label),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '3. 表端先存 .m4a 切片（无网络/断连也不断录），靠近手机自动 via WCSession 回传，并在 iPhone 本机转为 16kHz Mono PCM WAV 送入 SenseVoice 转写，原始音频不直传云端。',
                    style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WatchKvRow extends StatelessWidget {
  const _WatchKvRow({
    required this.label,
    required this.value,
    this.last = false,
  });

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 8),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: c.sec)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.label,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
