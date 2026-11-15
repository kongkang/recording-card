/// Setting 二级配置页 —— 本地语音引擎 / 云端模型设置 / Agent 预设与提示词 / 扩展能力（Skills · Tools · MCP）。
///
/// 窄屏由外层 `AppShell` 顶栏面包屑（`‹ Setting`）返回；宽屏置于右栏；
/// 无 `StoreScope` 的独立挂载场景（如单页测试）自动提供顶部返回栏。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/device_store.dart';
import '../../core/store/voiceprint_library_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/audio/voice_sample_capture.dart';
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

// ── 5) 声纹识别说明与 5 常用槽位 / 人物库管理 ─────────────────

class _VoiceprintBody extends StatefulWidget {
  const _VoiceprintBody({required this.controller});

  final ModelManagerController? controller;

  @override
  State<_VoiceprintBody> createState() => _VoiceprintBodyState();
}

class _VoiceprintBodyState extends State<_VoiceprintBody> {
  VoiceprintLibraryStore? _fallbackStore;
  String? _recordingTargetKey;
  String? _vpHint;
  bool _vpError = false;

  @override
  void initState() {
    super.initState();
    final ctrl = widget.controller;
    if (ctrl != null && !ctrl.hasStatuses) {
      unawaited(ctrl.refresh());
    }
  }

  @override
  void dispose() {
    _fallbackStore?.dispose();
    super.dispose();
  }

  VoiceprintLibraryStore _resolveStore(BuildContext context) {
    final scoped = StoreScope.maybeOf(context)?.voiceprintStore;
    if (scoped != null) return scoped;
    return _fallbackStore ??= VoiceprintLibraryStore();
  }

  Future<void> _recordVoiceSample(
    VoiceprintLibraryStore vpStore, {
    required String targetKey,
    required String targetName,
    required bool isSelf,
    int? slot,
  }) async {
    if (_recordingTargetKey != null) return;
    setState(() {
      _recordingTargetKey = targetKey;
      _vpHint = null;
      _vpError = false;
    });
    try {
      final driver = VoiceSampleCaptureDriver(
        installer: widget.controller?.installer,
      );
      final res = await driver.captureAndEmbed(
        targetName: targetName,
        deviceLabel: '本机麦克风',
        sceneLabel: isSelf ? '单独录音' : '补充录音',
      );
      if (!mounted) return;
      if (!res.ok || res.embedding.isEmpty) {
        setState(() {
          _vpError = true;
          _vpHint = res.error ?? '采集声纹样本失败，请确认麦克风权限与声纹模型状态';
        });
        return;
      }
      if (isSelf) {
        vpStore.recordSelfSample(
          embedding: res.embedding,
          deviceLabel: '本机麦克风',
          sceneLabel: '单独录音',
        );
      } else {
        vpStore.upsertPersonAndSample(
          name: targetName,
          embedding: res.embedding,
          deviceLabel: '本机麦克风',
          sceneLabel: '补充录音',
          explicitSlot: slot,
        );
      }
      setState(() {
        _vpError = false;
        _vpHint = '已为「$targetName」录入 1 组声纹样本（${res.embedding.length} 维）';
      });
    } finally {
      if (mounted) {
        setState(() => _recordingTargetKey = null);
      }
    }
  }

  Future<void> _showAddPersonDialog(
    BuildContext context,
    VoiceprintLibraryStore vpStore,
  ) async {
    final textCtrl = TextEditingController();
    final created = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增人物档案'),
        content: TextField(
          key: const Key('vp-add-person-input'),
          controller: textCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入姓名或常用称呼（例如：张总）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('vp-add-person-confirm-btn'),
            onPressed: () => Navigator.of(ctx).pop(textCtrl.text.trim()),
            child: const Text('添加到人物库'),
          ),
        ],
      ),
    );
    textCtrl.dispose();
    if (!mounted || created == null || created.isEmpty) return;
    vpStore.upsertPersonAndSample(name: created, preferFrequentSlot: false);
    setState(() {
      _vpError = false;
      _vpHint = '已将「$created」加入人物库（默认仅手动选用，不占用常用识别槽位）';
    });
  }

  Widget _buildSampleChips(
    RCColorScheme c,
    List<VoiceSampleRecord> samples, {
    String emptyLabel = '暂无音频样本，仅名称记录',
  }) {
    if (samples.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.sep),
        ),
        child: Text(emptyLabel, style: TextStyle(fontSize: 11, color: c.sec)),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in samples)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.sep),
            ),
            child: Text(
              '${s.deviceLabel} · ${s.sceneLabel}',
              style: TextStyle(fontSize: 11, color: c.sec),
            ),
          ),
      ],
    );
  }

  Widget _buildFrequentSlotCard(
    RCColorScheme c,
    VoiceprintLibraryStore vpStore,
    int slot,
  ) {
    final isSelfSlot = slot == 1;
    final p = isSelfSlot
        ? (vpStore.profileAtSlot(1) ?? vpStore.selfProfile)
        : vpStore.profileAtSlot(slot);

    if (p == null) {
      return Container(
        key: Key('vp-slot-$slot'),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.sep),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '槽位 $slot · 空槽位（可从下方人物库设入）',
                style: TextStyle(fontSize: 12.5, color: c.sec),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: c.sep),
              ),
              child: Text('未占用', style: TextStyle(fontSize: 11, color: c.sec)),
            ),
          ],
        ),
      );
    }

    final targetKey = isSelfSlot ? 'self' : 'slot-$slot';
    final capturingThis = _recordingTargetKey == targetKey;
    final badgeText = isSelfSlot
        ? '本人声纹（${p.samples.length} 组样本）'
        : '自动识别 · 含 ${p.samples.length} 组样本';

    return Container(
      key: Key('vp-slot-$slot'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSelfSlot ? c.okInk.withValues(alpha: 0.08) : c.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelfSlot ? c.okInk.withValues(alpha: 0.35) : c.sep,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isSelfSlot ? '槽位 1 · 本人' : '槽位 $slot',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: isSelfSlot ? RCColors.okInk : c.sec,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: c.sep),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 11,
                    color: isSelfSlot ? RCColors.okInk : c.sec,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildSampleChips(
            c,
            p.samples,
            emptyLabel: isSelfSlot ? '尚未单独录制我的声音样本，建议点击下方按钮录入' : '暂无音频样本',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: Key(
                  isSelfSlot ? 'vp-record-self-btn' : 'vp-record-slot-$slot',
                ),
                onPressed: _recordingTargetKey != null
                    ? null
                    : () => unawaited(
                        _recordVoiceSample(
                          vpStore,
                          targetKey: targetKey,
                          targetName: p.name,
                          isSelf: isSelfSlot,
                          slot: slot,
                        ),
                      ),
                child: Text(
                  capturingThis
                      ? '采集声纹中…'
                      : (isSelfSlot ? '单独录音增加' : '+ 补充录音样本'),
                ),
              ),
              if (!isSelfSlot)
                OutlinedButton(
                  key: Key('vp-remove-slot-$slot'),
                  onPressed: () {
                    vpStore.demoteFromFrequentSlot(p.id);
                    setState(() {
                      _vpError = false;
                      _vpHint = '已将「${p.name}」移出常用自动识别槽位';
                    });
                  },
                  child: const Text('移出常用'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryPersonCard(
    RCColorScheme c,
    VoiceprintLibraryStore vpStore,
    PersonVoiceProfile p,
    int index,
  ) {
    final targetKey = 'lib-${p.id}';
    final capturingThis = _recordingTargetKey == targetKey;
    final inFrequent = p.isInFrequentSlot;
    return Container(
      key: Key('vp-lib-person-$index'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: inFrequent ? c.okInk.withValues(alpha: 0.08) : c.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: inFrequent
                        ? c.okInk.withValues(alpha: 0.35)
                        : c.sep,
                  ),
                ),
                child: Text(
                  inFrequent ? '常用自动识别' : '仅手动标记 · 省算力',
                  style: TextStyle(
                    fontSize: 11,
                    color: inFrequent ? RCColors.okInk : c.sec,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildSampleChips(c, p.samples),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: Key('vp-lib-sample-$index'),
                onPressed: _recordingTargetKey != null
                    ? null
                    : () => unawaited(
                        _recordVoiceSample(
                          vpStore,
                          targetKey: targetKey,
                          targetName: p.name,
                          isSelf: false,
                          slot: p.frequentSlot,
                        ),
                      ),
                child: Text(capturingThis ? '采集声纹中…' : '+ 补充设备/场景样本'),
              ),
              OutlinedButton(
                key: Key('vp-lib-toggle-$index'),
                onPressed: () {
                  if (inFrequent) {
                    vpStore.demoteFromFrequentSlot(p.id);
                    setState(() {
                      _vpError = false;
                      _vpHint = '已将「${p.name}」移出常用自动识别槽位';
                    });
                  } else {
                    final ok = vpStore.promoteToFrequentSlot(p.id);
                    setState(() {
                      _vpError = !ok;
                      _vpHint = ok
                          ? '已将「${p.name}」设为常用自动识别（槽位 ${vpStore.findByName(p.name)?.frequentSlot ?? ''}）'
                          : '常用槽位已满（上限 5 个），请先移出其他常用人物';
                    });
                  }
                },
                child: Text(
                  inFrequent ? '常用槽位 ${p.frequentSlot}（点击移出）' : '设为常用',
                ),
              ),
              OutlinedButton(
                key: Key('vp-lib-del-$index'),
                style: OutlinedButton.styleFrom(foregroundColor: c.danger),
                onPressed: () {
                  vpStore.deletePerson(p.id);
                  setState(() {
                    _vpError = false;
                    _vpHint = '已从人物库移除「${p.name}」';
                  });
                },
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final ctrl = widget.controller;
    final vpStore = _resolveStore(context);
    final listenable = ctrl == null
        ? vpStore
        : Listenable.merge([ctrl, vpStore]);

    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final installed =
            ctrl?.statusFor(campplusEmbeddingSpec)?.installed ?? false;
        final libPersons = vpStore.allPersons.where((p) => !p.isSelf).toList();
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
            if (_vpHint != null) ...[
              const SizedBox(height: 10),
              Text(
                _vpHint!,
                key: const Key('vp-hint-text'),
                style: TextStyle(
                  fontSize: 12,
                  color: _vpError ? c.danger : RCColors.okInk,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              key: const Key('vp-frequent-section'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '常用声纹（自动识别 · 上限 5 个）',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: c.label,
                          ),
                        ),
                      ),
                      Text(
                        '槽位 1 固定为本人',
                        style: TextStyle(fontSize: 11.5, color: c.sec),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '为平衡本机算力消耗，仅这 5 个常用档案参与自动识别与模糊匹配（「几乎准确」直接标为他，「无法确定」提示可能为他）。',
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                  for (
                    var slot = 1;
                    slot <= VoiceprintLibraryStore.maxFrequentSlots;
                    slot++
                  )
                    _buildFrequentSlotCard(c, vpStore, slot),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              key: const Key('vp-library-section'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已记录声纹与最近使用人物库（不限数量）',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: c.label,
                          ),
                        ),
                      ),
                      Text(
                        '共 ${libPersons.length} 人',
                        style: TextStyle(fontSize: 11.5, color: c.sec),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        key: const Key('vp-add-person-btn'),
                        onPressed: () =>
                            unawaited(_showAddPersonDialog(context, vpStore)),
                        child: const Text('+ 新增人物'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '标记过即入库，人数无上限；同一个人名下归并不同设备与场景声纹，默认仅手动选用，不消耗自动比对算力。',
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                  if (libPersons.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '尚无他人声纹档案：可在对话详情或总结全文中点击说话人命名，或点击「+ 新增人物」预先录入。',
                        style: TextStyle(fontSize: 12, color: c.sec),
                      ),
                    )
                  else
                    for (var i = 0; i < libPersons.length; i++)
                      _buildLibraryPersonCard(c, vpStore, libPersons[i], i),
                ],
              ),
            ),
          ],
        );
      },
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
  AudioPlayer? _player;
  StreamSubscription<void>? _playerCompleteSub;
  String? _playingSliceId;

  @override
  void initState() {
    super.initState();
    final wh = widget.device?.watchHardware;
    if (wh != null) {
      unawaited(wh.refreshStatus());
    }
  }

  @override
  void dispose() {
    unawaited(_playerCompleteSub?.cancel());
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(player.dispose().catchError((_) {}));
    }
    super.dispose();
  }

  static String _batteryTierText(WatchBridgeStatus s) {
    if (s.isCharging) return '充电中';
    if (s.batteryLevel <= 0) return '未知';
    if (s.batteryLevel < 20) return '电量低';
    if (s.batteryLevel < 40) return '电量中';
    return '电量高';
  }

  static String _formatClockFromSec(int sec) {
    final s = sec < 0 ? 0 : sec;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = s % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  static String _formatTimeOfDay(int startAtMs) {
    if (startAtMs <= 0) return '刚刚';
    final dt = DateTime.fromMillisecondsSinceEpoch(startAtMs).toLocal();
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  static String _formatDurMs(int durationMs) {
    final sec = (durationMs / 1000).round();
    if (sec < 60) return '${sec}s';
    final m = sec ~/ 60;
    final r = sec % 60;
    return r == 0 ? '$m 分钟' : '$m 分 $r 秒';
  }

  static String _formatSizeBytes(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
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

  Future<bool> _ensureWatchConnected(DeviceStore dev) async {
    final alreadyWatch =
        dev.isConnected && dev.activeKind == DeviceKind.appleWatch;
    if (alreadyWatch) return true;
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
      return false;
    }
    await dev.connectTo(cardDev);
    final ok = dev.isConnected && dev.activeKind == DeviceKind.appleWatch;
    if (!ok && mounted) {
      setState(() {
        _hint = dev.linkError ?? 'Apple Watch 连接未完成，请确认手表端已安装「录音卡」';
      });
    }
    return ok;
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
      final ok = await _ensureWatchConnected(dev);
      if (ok && mounted) {
        setState(() => _hint = '已将 Apple Watch 设为当前采集硬件');
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

  Future<void> _toggleRemoteRec() async {
    final dev = widget.device;
    if (dev == null) return;
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      final connected = await _ensureWatchConnected(dev);
      if (!connected) return;
      final wasRecording = dev.isRecording;
      final err = await dev.toggleRecording();
      if (!mounted) return;
      if (err != null) {
        setState(() => _hint = err);
        return;
      }
      setState(() {
        _hint = !wasRecording && dev.isRecording
            ? '已远程开启手表录音（灵动岛与本机待命保底已同步激活）'
            : (wasRecording && !dev.isRecording
                  ? '已停止手表录音，切片将自动同步并转为 16kHz WAV 入库'
                  : (dev.recordingError ?? '手表录音状态已更新'));
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendRemoteMark() async {
    final dev = widget.device;
    if (dev == null) return;
    final isWatchRecording =
        dev.isConnected &&
        dev.activeKind == DeviceKind.appleWatch &&
        dev.isRecording;
    if (!isWatchRecording) {
      setState(() => _hint = '请先开启手表录音后再打重点');
      return;
    }
    setState(() => _busy = true);
    try {
      final sec = dev.recSeconds > 0
          ? dev.recSeconds
          : dev.watchHardware.currentStatus.elapsedSec;
      await dev.watchHardware.addMark(atMs: sec * 1000);
      if (mounted) {
        setState(() => _hint = '已在腕上录音 ${sec}s 处打重点标记');
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _hint = '重点标记发送失败：$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshWatchStatus() async {
    final dev = widget.device;
    if (dev == null) return;
    setState(() => _busy = true);
    try {
      await dev.watchHardware.refreshStatus();
      if (mounted) {
        setState(() => _hint = '已刷新手表连接与待传队列状态');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleSlicePlay(WatchReceivedSliceRecord sl) async {
    if (_playingSliceId == sl.sliceId) {
      setState(() => _playingSliceId = null);
      final player = _player;
      if (player != null) {
        unawaited(player.stop().catchError((_) {}));
      }
      return;
    }
    final trimmed = sl.wavPath.trim();
    if (trimmed.isEmpty || !File(trimmed).existsSync()) {
      setState(() => _hint = '本地音频文件不存在或尚未同步：${sl.fileName}');
      return;
    }
    setState(() {
      _playingSliceId = sl.sliceId;
      _hint = '正在试听本地 16kHz WAV：${sl.fileName}';
    });
    try {
      var player = _player;
      if (player == null) {
        player = AudioPlayer();
        _player = player;
        _playerCompleteSub = player.onPlayerComplete.listen((_) {
          if (!mounted) return;
          setState(() => _playingSliceId = null);
        });
      }
      await player.play(DeviceFileSource(trimmed));
    } on MissingPluginException {
      // 单元测试环境未挂载原生音频插件时保留试听切换反馈
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _playingSliceId = null;
        _hint = '试听失败：${e.message ?? e.code}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _playingSliceId = null;
        _hint = '试听失败：$e';
      });
    }
  }

  Future<void> _exportSlice(WatchReceivedSliceRecord sl) async {
    final trimmed = sl.wavPath.trim();
    final f = File(trimmed);
    if (trimmed.isEmpty || !f.existsSync()) {
      setState(() => _hint = '未找到可导出的本地 WAV 文件：${sl.fileName}');
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(trimmed, mimeType: 'audio/wav', length: f.lengthSync()),
          ],
          title: sl.fileName,
          subject: sl.fileName,
        ),
      );
      if (mounted) {
        setState(() => _hint = '已调起系统分享：${sl.fileName}');
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() => _hint = '已准备导出本地文件：${sl.fileName}');
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _hint = '导出失败：$e');
      }
    }
  }

  Future<void> _deleteSlice(
    DeviceStore dev,
    WatchReceivedSliceRecord sl,
  ) async {
    if (_playingSliceId == sl.sliceId) {
      _playingSliceId = null;
      final player = _player;
      if (player != null) {
        unawaited(player.stop().catchError((_) {}));
      }
    }
    await dev.watchHardware.deleteReceivedSlice(sl.sliceId);
    if (!mounted) return;
    setState(() => _hint = '已删除本地切片：${sl.fileName}');
  }

  Widget _buildTagChip(
    String text, {
    required Color bg,
    required Color fg,
    required Color border,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: border),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
    ),
  );

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
        final isWatchRecording = isWatchConnected && (dev?.isRecording ?? false);
        final clockText = dev != null && dev.recSeconds > 0
            ? dev.recClockText
            : _formatClockFromSec(status?.elapsedSec ?? 0);
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
        final slices =
            dev?.watchHardware.receivedSlices ??
            const <WatchReceivedSliceRecord>[];

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
                  _WatchKvRow(
                    label: '腕上录音',
                    value: isWatchRecording ? '录音中 · $clockText' : '未录音',
                  ),
                  if (isWatchRecording)
                    const _WatchKvRow(
                      label: '息屏保活通道',
                      value: 'HKWorkoutSession 运动保活',
                    ),
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
            const _SubSectionLabel('远程控制（纯本地直连）'),
            const SizedBox(height: 8),
            Container(
              key: const Key('watch-remote-card'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '直连 WatchConnectivity 控制',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: c.label,
                          ),
                        ),
                      ),
                      Text(
                        '不经服务器',
                        style: TextStyle(fontSize: 11.5, color: c.sec),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    key: const Key('watch-remote-rec-btn'),
                    style: isWatchRecording
                        ? FilledButton.styleFrom(
                            backgroundColor: c.danger,
                            foregroundColor: Colors.white,
                          )
                        : null,
                    onPressed: (_busy || dev == null)
                        ? null
                        : _toggleRemoteRec,
                    child: Text(
                      isWatchRecording ? '停止手表录音（腕上采集中）' : '开启手表录音',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        key: const Key('watch-remote-mark-btn'),
                        onPressed: (_busy || dev == null)
                            ? null
                            : _sendRemoteMark,
                        child: const Text('打重点（Mark）'),
                      ),
                      OutlinedButton(
                        key: const Key('watch-refresh-btn'),
                        onPressed: (_busy || dev == null)
                            ? null
                            : _refreshWatchStatus,
                        child: const Text('刷新手表状态'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: _SubSectionLabel('已接收切片（本地 16kHz WAV）'),
                ),
                Text(
                  '共 ${slices.length} 片',
                  style: TextStyle(fontSize: 11.5, color: c.sec),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              key: const Key('watch-slices-card'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '表端以 32kbps .m4a 低功耗录制并离线暂存，回传 iPhone 后本机自动转码为 16kHz / 16-bit 单声道 PCM WAV 送入 SenseVoice 转写，原始音频不上传云端。',
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                  if (slices.isEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '暂无已接收的手表切片。开启手表录音或拉取待传切片后，切片将自动本地落盘到这里。',
                      key: const Key('watch-slices-empty'),
                      style: TextStyle(fontSize: 12.5, color: c.sec),
                    ),
                  ] else
                    for (var i = 0; i < slices.length; i++) ...[
                      const SizedBox(height: 10),
                      Builder(
                        builder: (context) {
                          final sl = slices[i];
                          final playing = _playingSliceId == sl.sliceId;
                          final sizeText = _formatSizeBytes(sl.fileSizeBytes);
                          final meta = [
                            _formatTimeOfDay(sl.startAtMs),
                            '时长 ${_formatDurMs(sl.durationMs)}',
                            if (sizeText.isNotEmpty) sizeText,
                          ].join(' · ');
                          return Container(
                            key: Key('watch-slice-item-$i'),
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: c.bg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: c.sep),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      '第 ${sl.sliceIndex + 1} 片 · ${sl.fileName}',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: c.label,
                                      ),
                                    ),
                                    if (sl.offlineRecorded)
                                      _buildTagChip(
                                        '离线补传',
                                        bg: RCColors.warn.withValues(
                                          alpha: 0.12,
                                        ),
                                        fg: const Color(0xFF8A4300),
                                        border: RCColors.warn.withValues(
                                          alpha: 0.35,
                                        ),
                                      ),
                                    _buildTagChip(
                                      '已入 Timeline 转写',
                                      bg: c.okInk.withValues(alpha: 0.08),
                                      fg: c.okInk,
                                      border: c.okInk.withValues(alpha: 0.32),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  playing ? '$meta · 正在回放' : meta,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: playing ? c.okInk : c.sec,
                                  ),
                                ),
                                if (sl.marksMs.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    '重点标记（相对起点）：${sl.marksMs.map((m) => '${(m / 1000).round()}s').join('、')}',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Color(0xFF0F4C81),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    OutlinedButton(
                                      key: Key('watch-slice-play-$i'),
                                      onPressed: () =>
                                          unawaited(_toggleSlicePlay(sl)),
                                      child: Text(
                                        playing ? '停止试听' : '试听 WAV',
                                      ),
                                    ),
                                    OutlinedButton(
                                      key: Key('watch-slice-export-$i'),
                                      onPressed: () =>
                                          unawaited(_exportSlice(sl)),
                                      child: const Text('导出'),
                                    ),
                                    OutlinedButton(
                                      key: Key('watch-slice-del-$i'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: c.danger,
                                      ),
                                      onPressed: dev == null
                                          ? null
                                          : () => unawaited(
                                              _deleteSlice(dev, sl),
                                            ),
                                      child: const Text('删除'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
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
