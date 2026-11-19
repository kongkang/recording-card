/// Setting 二级配置页 —— 本地语音引擎 / 云端模型设置 / Agent 预设与提示词 / 扩展能力（Skills · Tools · MCP）。
///
/// 窄屏由外层 `AppShell` 顶栏面包屑（`‹ Setting`）返回；宽屏置于右栏；
/// 无 `StoreScope` 的独立挂载场景（如单页测试）自动提供顶部返回栏。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/device_store.dart';
import '../../core/store/voiceprint_library_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/audio/voice_sample_capture.dart';
import '../../services/auth/oauth_config.dart';
import '../../services/auth_service.dart';
import '../../services/health/health_signal_controller.dart';
import '../../services/transcribe/asr_models.dart';
import '../../services/transcribe/model_manager_controller.dart';
import '../../services/transcribe/system_speech_client.dart';
import '../../services/watch/watch_hardware_service.dart';
import '../../widgets/rc_switch.dart';
import '../../widgets/store_scope.dart';
import 'developer_schedule_section.dart';
import 'health_signal_body.dart';

class SettingSubPage extends StatelessWidget {
  const SettingSubPage({
    super.key,
    required this.subId,
    required this.agentConfig,
    this.device,
    this.modelManager,
    this.authService,
    this.healthSignals,
    this.showPaneBack = false,
    this.standalone = false,
  });

  final String subId; // 'login' | 'local' | 'cloud' | 'prompts' | 'voiceprint' | 'ext' | 'island' | 'watch' | 'exthw' | 'dev'
  final AgentConfigStore agentConfig;
  final DeviceStore? device;
  final ModelManagerController? modelManager;
  final AuthService? authService;
  final HealthSignalController? healthSignals;
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
    'exthw' => '第三方硬件联动',
    'health' => '行为与健康信号',
    'dev' => '开发者设置',
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
                    'local' => _LocalEngineBody(
                      controller: modelManager,
                      config: agentConfig,
                    ),
                    'cloud' => _CloudModelBody(config: agentConfig),
                    'prompts' => _AgentPromptsBody(config: agentConfig),
                    'voiceprint' => _VoiceprintBody(controller: modelManager),
                    'ext' => _AgentExtensionsBody(config: agentConfig),
                    'island' => _DynamicIslandBody(config: agentConfig),
                    'watch' => _AppleWatchLinkBody(
                      config: agentConfig,
                      device: device,
                    ),
                    'exthw' => _ExtHardwareLinkBody(
                      config: agentConfig,
                      device: device,
                    ),
                    'health' => healthSignals == null
                        ? const Text('采集服务未装载')
                        : HealthSignalSettingsBody(controller: healthSignals!),
                    'dev' => _DeveloperCleanBody(config: agentConfig),
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
  const _LocalEngineBody({required this.controller, this.config});

  final ModelManagerController? controller;
  final AgentConfigStore? config;

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

  void _showHint(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  ({String title, String content}) _deleteDialogCopy(
    ModelManagerController ctrl,
    ModelSpec spec,
  ) {
    if (spec.id == senseVoiceSpec.id) {
      if (ctrl.supportsSystemAsr) {
        final fallbackName = ctrl.systemCapabilities.effectiveEngineTitle;
        return (
          title: '确认删除 SenseVoice 增强模型？',
          content:
              '删除后将释放约 228 MB 本机存储空间，并自动回退为「$fallbackName」继续免费离线转写，隐私同样全程留在本机。后续需要方言或中英混杂增强效果时可随时重新下载。',
        );
      }
      return (
        title: '确认删除本地语音模型？',
        content:
            '删除后将无法自动离线语音转文字，仅能切换到付费云端模式；原享有的终身本地转写服务也会失效，且语音上行云端存在隐私泄露风险。',
      );
    }
    if (spec.id == campplusEmbeddingSpec.id) {
      return (
        title: '确认删除 CAM++ 声纹模型？',
        content:
            '删除后可释放约 27 MB 空间，语音转写不受影响；之后的新录音说话人将暂标为「未区分」，可在本地语音引擎页随时重新下载恢复。',
      );
    }
    return (
      title: '确认删除${spec.displayName}？',
      content: '删除后可释放本机存储空间，后续可随时在本页重新下载。',
    );
  }

  Future<void> _confirmDeleteModel(
    BuildContext context,
    ModelManagerController ctrl,
    ModelSpec spec,
  ) async {
    final copy = _deleteDialogCopy(ctrl, spec);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('model-delete-confirm-dialog'),
        title: Text(copy.title),
        content: Text(copy.content),
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
    final ctrl = widget.controller;
    final config = widget.config;
    final listenables = <Listenable>[?ctrl, ?config];
    if (listenables.isEmpty) {
      return _buildContent(context);
    }
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (ctx, _) => _buildContent(ctx),
    );
  }

  Widget _buildContent(BuildContext context) {
    final ctrl = widget.controller;
    final specs =
        ctrl?.specs ??
        const [senseVoiceSpec, sileroVadSpec, campplusEmbeddingSpec];
    final effectiveMode = ctrl?.effectiveAsrMode ?? 'pending';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStatusCard(context, ctrl, effectiveMode),
        const SizedBox(height: 18),
        const _SubSectionLabel('语音转写模型'),
        const SizedBox(height: 8),
        _buildEngineSelectorCard(context, ctrl, effectiveMode),
        const SizedBox(height: 18),
        _SubSectionLabel('本地模型文件与存储（共 ${specs.length} 项）'),
        for (final spec in specs) ...[
          const SizedBox(height: 10),
          _buildSpecCard(context, spec, ctrl),
        ],
      ],
    );
  }

  Widget _buildStatusCard(
    BuildContext context,
    ModelManagerController? ctrl,
    String effectiveMode,
  ) {
    final c = context.rc;
    final sysCaps =
        ctrl?.systemCapabilities ?? SystemSpeechCapabilities.unsupported;
    final speakerReady = ctrl?.speakerReady ?? false;
    final configured = ctrl?.configured ?? false;

    final String title;
    final String pillText;
    final Color pillBg;
    final Color pillFg;
    final String desc;
    final bool isReady =
        effectiveMode == 'system' || effectiveMode == 'sensevoice';

    if (effectiveMode == 'system') {
      title = '本地转写已就绪';
      pillText = '系统内置生效中';
      pillBg = const Color(0xFFEDF7F0);
      pillFg = const Color(0xFF1F7A34);
      final engineTitle = sysCaps.effectiveEngineTitle;
      final devLabel = sysCaps.effectiveDeviceLabel;
      if (sysCaps.isAndroid) {
        if (!sysCaps.offlinePackInstalled) {
          desc =
              '已识别本机为 $devLabel，默认启用「$engineTitle」；当前系统中文离线语音包未就绪，可先一键拉起系统下载或改用 SenseVoice。';
        } else {
          desc = speakerReady
              ? '已识别本机为 $devLabel，默认启用「$engineTitle」，免下载 228 MB 语音包即可立即离线转写；27 MB 声纹模型已在后台自动就绪。'
              : '已识别本机为 $devLabel，默认启用「$engineTitle」离线转写；27 MB 声纹模型未安装，新录音说话人暂标为「未区分」。';
        }
      } else {
        desc = speakerReady
            ? '已识别本机为 $devLabel，默认使用原生端侧引擎（SpeechAnalyzer），免下载 228 MB 语音包即可立即离线转写；27 MB 声纹模型已在后台自动就绪。'
            : '已识别本机为 $devLabel，默认使用原生端侧引擎（SpeechAnalyzer）离线转写；27 MB 声纹模型未安装，新录音说话人暂标为「未区分」。';
      }
    } else if (effectiveMode == 'sensevoice') {
      title = '本地转写已就绪';
      pillText = 'SenseVoice 生效中';
      pillBg = const Color(0xFFEDF7F0);
      pillFg = const Color(0xFF1F7A34);
      final devPrefix = sysCaps.deviceSummary.trim().isNotEmpty
          ? '当前设备为 ${sysCaps.effectiveDeviceLabel}，'
          : '';
      desc = speakerReady
          ? '$devPrefix当前使用 SenseVoice 增强离线模型，针对中英混杂、粤语方言与多人对话深度优化，全程在本机离线处理。'
          : '$devPrefix当前使用 SenseVoice 增强离线模型转写；27 MB 声纹模型未安装，新录音说话人暂标为「未区分」。';
    } else {
      title = (ctrl != null && !configured) ? '模型下载服务未配置' : '待启用本地转写';
      pillText = (ctrl != null && !configured) ? '未配置' : '待手动下载';
      pillBg = const Color(0xFFFFF4E0);
      pillFg = const Color(0xFF8A4300);
      if (ctrl != null && !configured) {
        desc = '未配置模型下载地址（RC_MODEL_BASE）；音频与声纹均不上传云端，配置后可下载 SenseVoice 增强模型。';
      } else {
        desc = sysCaps.effectiveUnsupportedReason;
      }
    }

    final showActionBtn =
        ctrl != null &&
        (effectiveMode == 'pending' || !speakerReady || ctrl.hasRemoteUpdates);
    final showSysPackDownload =
        ctrl != null &&
        effectiveMode == 'system' &&
        sysCaps.isAndroid &&
        !sysCaps.offlinePackInstalled &&
        sysCaps.canDownloadOfflinePack;
    final String btnLabel;
    if (ctrl != null && ctrl.busy) {
      btnLabel = '下载中…';
    } else if (ctrl != null && ctrl.hasRemoteUpdates && speakerReady && isReady) {
      btnLabel = '更新至新版模型';
    } else if (isReady && !speakerReady) {
      btnLabel = '恢复声纹模型（~27 MB）';
    } else {
      btnLabel = '下载增强模型（~228 MB）';
    }

    return Container(
      key: const Key('local-status-card'),
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
                  color: isReady ? RCColors.ok : RCColors.warn,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
              ),
              _tagPill(pillText, bg: pillBg, fg: pillFg),
            ],
          ),
          if (sysCaps.deviceSummary.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '当前设备：${sysCaps.effectiveDeviceLabel}',
              key: const Key('local-device-summary'),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: c.ink,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(desc, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.sec)),
          if (showActionBtn || showSysPackDownload) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (showSysPackDownload)
                  OutlinedButton(
                    key: const Key('model-dl-sys-pack'),
                    onPressed: ctrl.busy
                        ? null
                        : () => unawaited(ctrl.requestSystemLanguagePack()),
                    child: const Text('下载系统中文离线语音包'),
                  ),
                if (showActionBtn)
                  OutlinedButton(
                    key: const Key('model-install-all'),
                    onPressed: ctrl.busy || !configured
                        ? null
                        : () => unawaited(
                            effectiveMode == 'pending' || ctrl.hasRemoteUpdates
                                ? ctrl.installAll()
                                : ctrl.installSpec(campplusEmbeddingSpec),
                          ),
                    child: Text(btnLabel),
                  ),
              ],
            ),
          ],
          if (ctrl != null && ctrl.busy) ...[
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
          if (ctrl != null && ctrl.error != null) ...[
            const SizedBox(height: 8),
            Text(
              ctrl.error!,
              key: const Key('model-error'),
              style: TextStyle(fontSize: 12, height: 1.4, color: c.danger),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEngineSelectorCard(
    BuildContext context,
    ModelManagerController? ctrl,
    String effectiveMode,
  ) {
    final c = context.rc;
    final sysCaps =
        ctrl?.systemCapabilities ?? SystemSpeechCapabilities.unsupported;
    final sysOk = ctrl?.supportsSystemAsr ?? false;
    final senseInstalled =
        ctrl?.statusFor(senseVoiceSpec)?.installed ?? false;
    final configured = ctrl?.configured ?? false;

    final sysDesc = sysCaps.isAndroid
        ? '调用「${sysCaps.effectiveEngineTitle}」纯端侧离线识别，音频仅留在本机；${sysCaps.offlinePackInstalled ? '安装即用，免下 228 MB 增强模型。' : '中文离线语音包未就绪时可一键拉起系统下载。'}'
        : '调用原生 SpeechAnalyzer 纯端侧引擎（未预置长音频资产时自动以系统听写包垫底），刚装好软件即可立即离线使用，音频不出本机。';

    final senseStateLabel = senseInstalled
        ? '~228 MB · 已下载'
        : (ctrl?.busy == true &&
                  ctrl?.selectedEngine != LocalAsrEngineMode.system
              ? '~228 MB · 下载中…'
              : '~228 MB · 按需下载');
    final senseDesc =
        '外脑调优多语种离线模型，在中英混杂、粤语/口音与情绪识别场景下效果更佳。'
        '${senseInstalled ? '' : '默认不随安装自动下载，点此即可下载并启用。'}';

    return Container(
      key: const Key('asr-engine-group'),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        children: [
          if (sysOk) ...[
            _buildEngineOptionRow(
              context,
              key: const Key('asr-opt-system'),
              title: sysCaps.effectiveEngineTitle,
              tags: [
                _tagPill('免下载 · 0 MB', bg: const Color(0xFFF0F0EC), fg: c.sec),
                _tagPill(
                  '默认推荐',
                  bg: const Color(0xFFEDF7F0),
                  fg: const Color(0xFF1F7A34),
                ),
              ],
              subtitle: sysDesc,
              selected: effectiveMode == 'system',
              onTap: ctrl == null || ctrl.busy
                  ? null
                  : () => unawaited(
                      ctrl.selectAsrEngine(LocalAsrEngineMode.system),
                    ),
            ),
            Divider(height: 1, thickness: 1, color: c.sep),
          ],
          _buildEngineOptionRow(
            context,
            key: const Key('asr-opt-sensevoice'),
            title: 'SenseVoice 增强模型',
            tags: [
              _tagPill(senseStateLabel, bg: const Color(0xFFF0F0EC), fg: c.sec),
              if (!sysOk)
                _tagPill(
                  '本机推荐方案',
                  bg: const Color(0xFFEEF5FF),
                  fg: const Color(0xFF0F4C81),
                ),
            ],
            subtitle: senseDesc,
            selected: effectiveMode == 'sensevoice',
            onTap: ctrl == null || ctrl.busy
                ? null
                : () {
                    if (!senseInstalled && !configured) {
                      _showHint(context, '未配置模型下载地址（RC_MODEL_BASE）');
                      return;
                    }
                    unawaited(
                      ctrl.selectAsrEngine(LocalAsrEngineMode.sensevoice),
                    );
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildEngineOptionRow(
    BuildContext context, {
    required Key key,
    required String title,
    required List<Widget> tags,
    required String subtitle,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final c = context.rc;
    return InkWell(
      key: key,
      onTap: onTap,
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
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.label,
                        ),
                      ),
                      ...tags,
                    ],
                  ),
                  const SizedBox(height: 4),
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

  Widget _tagPill(
    String label, {
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: fg)),
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
    final pillLabel = installed
        ? '已就绪'
        : (spec.bundled
              ? '随包内置'
              : (spec.id == senseVoiceSpec.id ? '未下载（按需）' : '未安装'));
    final dlBtnKey = Key(
      spec.id == senseVoiceSpec.id ? 'model-dl-asr' : 'model-dl-spk',
    );
    final dlBtnLabel = spec.id == senseVoiceSpec.id
        ? '下载并启用（~228 MB）'
        : '下载模型（~27 MB）';

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
              _tagPill(
                pillLabel,
                bg: installed
                    ? const Color(0xFFE8F5EA)
                    : const Color(0xFFF0F0EC),
                fg: installed ? RCColors.okInk : c.sec,
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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: c.ink),
          ),
          if (ctrl != null && !installed && !spec.bundled) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              key: dlBtnKey,
              onPressed: ctrl.busy || !ctrl.configured
                  ? null
                  : () => unawaited(ctrl.installSpec(spec)),
              child: Text(ctrl.busy ? '下载中…' : dlBtnLabel),
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
        title: 'SenseVoice 离线转写',
        stageTag: '离线语音转文字',
        expectedSize: '约 228MB',
        explanation: '离线增强模型，按需下载，随时可删并释放空间。',
      );
    }
    if (spec.id == sileroVadSpec.id) {
      return (
        title: 'Silero VAD 人声检测',
        stageTag: '人声静音切分',
        expectedSize: '约 644KB',
        explanation: '随包内置免下载，识别人声起止并跳过空白静音。',
      );
    }
    if (spec.id == campplusEmbeddingSpec.id) {
      return (
        title: 'CAM++ 声纹识别',
        stageTag: '说话人聚类推测',
        expectedSize: '约 27MB',
        explanation: '体积小默认后台自动就绪，配合系统内置或增强转写均可区分说话人。',
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
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)}KB';
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
              const SizedBox(height: 6),
              Text(
                '当前生效：${config.effectiveModelLabel}（${config.modelSourceLabel}）。未手动点选时不会把 deepseek-v3 当作已选。清洗模型也可以在「开发者设置」里改，不必先连点版本号。',
                key: const Key('cloud-effective-model'),
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
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
                      subtitle: '每次仅发送当前勾选记录文本。这项偏好目前只保存，清洗和总结还没有读取。',
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
    final selected = config.userPickedCloudModel && config.cloudModel == m.id;
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
  late final TextEditingController _agentPromptCtrl = TextEditingController(
    text: widget.config.agentPrompt,
  );
  bool _savedToast = false;
  bool _agentSavedToast = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _agentPromptCtrl.dispose();
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

  Future<String?> _askPresetName({
    required String title,
    String initial = '',
    String confirmLabel = '确定',
  }) async {
    final textCtrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('preset-name-input'),
          controller: textCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：产品评审 / 客户回访',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('preset-name-confirm'),
            onPressed: () => Navigator.of(ctx).pop(textCtrl.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    textCtrl.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }

  Future<void> _addPreset() async {
    // 先把当前编辑框内容写入内存，再另存
    await widget.config.savePrompt(_tab, _ctrl.text);
    final name = await _askPresetName(
      title: '新增预设风格',
      confirmLabel: '新增',
    );
    if (name == null || !mounted) return;
    await widget.config.addUserPreset(label: name);
    if (!mounted) return;
    setState(() {
      _savedToast = true;
      _ctrl.text = widget.config.promptFor(_tab);
    });
  }

  Future<void> _renameSelectedPreset() async {
    final id = widget.config.presetId;
    final cur = widget.config.presetById(id);
    if (cur == null || cur.builtin) return;
    final name = await _askPresetName(
      title: '修改预设名称',
      initial: cur.label,
      confirmLabel: '保存',
    );
    if (name == null || !mounted) return;
    await widget.config.renameUserPreset(id, name);
    if (!mounted) return;
    setState(() => _savedToast = true);
  }

  Future<void> _deleteSelectedPreset() async {
    final id = widget.config.presetId;
    final cur = widget.config.presetById(id);
    if (cur == null || cur.builtin) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该预设？'),
        content: Text('将删除「${cur.label}」，提示词不会再出现在预设列表中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('preset-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.config.deleteUserPreset(id);
    if (!mounted) return;
    setState(() {
      _savedToast = false;
      _ctrl.text = widget.config.promptFor(_tab);
    });
  }

  Future<void> _saveAsNamedPreset() async {
    await widget.config.savePrompt(_tab, _ctrl.text);
    final active = widget.config.presetById(widget.config.presetId);
    if (active != null && !active.builtin) {
      await widget.config.saveCurrentAsPreset();
      if (!mounted) return;
      setState(() => _savedToast = true);
      return;
    }
    final name = await _askPresetName(
      title: '另存为新预设',
      initial: active == null ? '自定义风格' : '${active.label} 改',
      confirmLabel: '另存',
    );
    if (name == null || !mounted) return;
    await widget.config.saveCurrentAsPreset(newLabel: name);
    if (!mounted) return;
    setState(() {
      _savedToast = true;
      _ctrl.text = widget.config.promptFor(_tab);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: widget.config,
      builder: (context, _) {
        final selected = widget.config.presetById(widget.config.presetId);
        final isUser = selected != null && !selected.builtin;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '预设风格可新增与修改：选中后编辑下方提示词并保存；内置风格改动可另存为你的命名预设。总结生成提示词已实时接入生成链路。',
              style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('预设风格'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in widget.config.allPresets)
                  _presetPill(context, p.id, p.label),
                if (widget.config.presetId == 'custom')
                  _presetPill(context, 'custom', '自定义', interactive: false),
                OutlinedButton(
                  key: const Key('preset-add-btn'),
                  onPressed: _addPreset,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.label,
                    side: BorderSide(color: c.sep),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('+ 新增'),
                ),
              ],
            ),
            if (isUser) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    key: const Key('preset-rename-btn'),
                    onPressed: _renameSelectedPreset,
                    style: _rcMiniChipBtnStyle(c),
                    child: const Text('修改名称'),
                  ),
                  OutlinedButton(
                    key: const Key('preset-delete-btn'),
                    onPressed: _deleteSelectedPreset,
                    style: _rcMiniChipBtnStyle(c, foreground: c.danger),
                    child: const Text('删除预设'),
                  ),
                ],
              ),
            ],
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
            const SizedBox(height: 10),
            OutlinedButton(
              key: const Key('preset-save-as-btn'),
              onPressed: _saveAsNamedPreset,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.label,
                side: BorderSide(color: c.sep),
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: Text(isUser ? '写回当前预设' : '另存为新预设'),
            ),
            const SizedBox(height: 22),
            const _SubSectionLabel('OS1 对话助手提示词'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const Key('agent-prompt-editor'),
                controller: _agentPromptCtrl,
                minLines: 4,
                maxLines: 7,
                style: TextStyle(fontSize: 13.5, height: 1.55, color: c.label),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '输入 OS1 语音与轻聊对话的性格、语气和约束…',
                  hintStyle: TextStyle(color: c.ax, fontSize: 13),
                ),
              ),
            ),
            if (_agentSavedToast) ...[
              const SizedBox(height: 6),
              const Text(
                'OS1 助手提示词已保存并生效',
                key: Key('agent-prompt-saved-hint'),
                style: TextStyle(fontSize: 12, color: RCColors.okInk),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('agent-prompt-reset'),
                    onPressed: () async {
                      await widget.config.resetAgentPrompt();
                      if (!mounted) return;
                      setState(() {
                        _agentPromptCtrl.text = widget.config.agentPrompt;
                        _agentSavedToast = false;
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.ink,
                      side: BorderSide(color: c.ax),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: const Text('恢复助手默认'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('agent-prompt-save'),
                    onPressed: () async {
                      await widget.config.setAgentPrompt(_agentPromptCtrl.text);
                      if (!mounted) return;
                      setState(() {
                        _agentPromptCtrl.text = widget.config.agentPrompt;
                        _agentSavedToast = true;
                      });
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.label,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: const Text('保存助手提示词'),
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

class _AgentExtensionsBody extends StatefulWidget {
  const _AgentExtensionsBody({required this.config});

  final AgentConfigStore config;

  @override
  State<_AgentExtensionsBody> createState() => _AgentExtensionsBodyState();
}

class _AgentExtensionsBodyState extends State<_AgentExtensionsBody> {
  late final TextEditingController _searchUrlCtrl = TextEditingController(
    text: widget.config.customSearchApiUrl,
  );
  late final TextEditingController _searchKeyCtrl = TextEditingController(
    text: widget.config.customSearchApiKey,
  );
  bool _searchSaved = false;

  AgentConfigStore get config => widget.config;

  @override
  void dispose() {
    _searchUrlCtrl.dispose();
    _searchKeyCtrl.dispose();
    super.dispose();
  }

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
              'Skills、Tools、MCP 要分开看。标成「已接入」的才会进入当前清洗或总结；标成「未接入」的只是占位，打开开关也不会调用。',
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
            const SizedBox(height: 18),
            const _SubSectionLabel('OS1 对话工具权限'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                children: [
                  _permRow(
                    context,
                    keyName: 'sw-agent-web',
                    title: '联网搜索与网页抓取',
                    subtitle: '默认内置免 Key 双路搜索，可选配自定义搜索 API',
                    value: config.agentWebSearchEnabled,
                    onTap: () => unawaited(
                      config.setAgentWebSearchEnabled(
                        !config.agentWebSearchEnabled,
                      ),
                    ),
                  ),
                  Divider(height: 1, thickness: 1, color: c.sep),
                  _permRow(
                    context,
                    keyName: 'sw-agent-records',
                    title: '历史录音与总结检索',
                    subtitle: '允许在后台索引并查阅历史转写、说话人与总结卡',
                    value: config.agentRecordSearchEnabled,
                    onTap: () => unawaited(
                      config.setAgentRecordSearchEnabled(
                        !config.agentRecordSearchEnabled,
                      ),
                    ),
                  ),
                  Divider(height: 1, thickness: 1, color: c.sep),
                  _permRow(
                    context,
                    keyName: 'sw-agent-health',
                    title: '本机健康与位置查询',
                    subtitle: '仅读取本机已采集样本（受总开关门控，不上传无关数据）',
                    value: config.agentHealthAccessEnabled,
                    onTap: () => unawaited(
                      config.setAgentHealthAccessEnabled(
                        !config.agentHealthAccessEnabled,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
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
                  Text(
                    '自定义联网搜索接口（可选）',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '留空默认使用内置免 Key 搜索；填 HTTPS 地址后将 POST {query, limit}。',
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('agent-search-url-input'),
                    controller: _searchUrlCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'https://api.tavily.com/search（留空走内置）',
                    ),
                    style: TextStyle(fontSize: 13, color: c.label),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('agent-search-key-input'),
                    controller: _searchKeyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Bearer API Key（可选）',
                    ),
                    style: TextStyle(fontSize: 13, color: c.label),
                  ),
                  if (_searchSaved) ...[
                    const SizedBox(height: 6),
                    const Text(
                      '搜索接口配置已保存',
                      key: Key('agent-search-saved-hint'),
                      style: TextStyle(fontSize: 12, color: RCColors.okInk),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            _searchUrlCtrl.clear();
                            _searchKeyCtrl.clear();
                            await config.setCustomSearchApi(url: '', apiKey: '');
                            if (!mounted) return;
                            setState(() => _searchSaved = false);
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: c.ink,
                            side: BorderSide(color: c.ax),
                            shape: const StadiumBorder(),
                          ),
                          child: const Text('恢复内置'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          key: const Key('agent-search-save'),
                          onPressed: () async {
                            await config.setCustomSearchApi(
                              url: _searchUrlCtrl.text,
                              apiKey: _searchKeyCtrl.text,
                            );
                            if (!mounted) return;
                            setState(() => _searchSaved = true);
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: c.label,
                            foregroundColor: Colors.white,
                            shape: const StadiumBorder(),
                          ),
                          child: const Text('保存搜索配置'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _permRow(
    BuildContext context, {
    required String keyName,
    required String title,
    required String subtitle,
    required bool value,
    required VoidCallback onTap,
  }) {
    final c = context.rc;
    return InkWell(
      key: Key(keyName),
      onTap: onTap,
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
                    style: TextStyle(fontSize: 12, height: 1.4, color: c.sec),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            RCSwitch(on: value),
          ],
        ),
      ),
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
                  const SizedBox(height: 4),
                  Text(
                    '${item.wiringLabel} · ${item.wiringNote}',
                    key: Key('ext-wiring-${item.id}'),
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: c.sec),
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
  String? _playingSampleId;
  AudioPlayer? _samplePlayer;

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
    unawaited(_samplePlayer?.dispose() ?? Future<void>.value());
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

    final countdown = ValueNotifier<int>(3);
    final dialogOpen = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const Key('vp-record-countdown-dialog'),
          content: ValueListenableBuilder<int>(
            valueListenable: countdown,
            builder: (_, remain, _) {
              final label = remain > 0 ? '$remain' : '处理中…';
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    remain > 0 ? '正在录音' : '正在提取声纹',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请对着麦克风清晰朗读一句话',
                    style: TextStyle(fontSize: 12.5, color: context.rc.sec),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    key: const Key('vp-record-countdown-num'),
                    label,
                    style: TextStyle(
                      fontSize: remain > 0 ? 48 : 22,
                      fontWeight: FontWeight.w800,
                      color: context.rc.label,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    try {
      final driver = VoiceSampleCaptureDriver(
        installer: widget.controller?.installer,
        onTick: (remain) {
          countdown.value = remain;
        },
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
          audioPath: res.audioPath,
        );
      } else {
        vpStore.upsertPersonAndSample(
          name: targetName,
          embedding: res.embedding,
          deviceLabel: '本机麦克风',
          sceneLabel: '补充录音',
          audioPath: res.audioPath,
          explicitSlot: slot,
        );
      }
      setState(() {
        _vpError = false;
        _vpHint = '已为「$targetName」录入 1 组声纹样本';
      });
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await dialogOpen;
      countdown.dispose();
      if (mounted) {
        setState(() => _recordingTargetKey = null);
      }
    }
  }

  Future<void> _playSample(VoiceSampleRecord sample) async {
    final path = sample.audioPath;
    if (path == null || path.isEmpty) {
      setState(() {
        _vpError = true;
        _vpHint = '该样本没有可回放的录音文件（可能是旧版本录入）';
      });
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      setState(() {
        _vpError = true;
        _vpHint = '录音文件已丢失，请重新录制样本';
      });
      return;
    }
    try {
      final player = _samplePlayer ??= AudioPlayer();
      if (_playingSampleId == sample.id) {
        await player.stop();
        setState(() => _playingSampleId = null);
        return;
      }
      await player.stop();
      await player.play(DeviceFileSource(path));
      setState(() => _playingSampleId = sample.id);
      player.onPlayerComplete.first.then((_) {
        if (mounted && _playingSampleId == sample.id) {
          setState(() => _playingSampleId = null);
        }
      });
    } on Object catch (e) {
      setState(() {
        _vpError = true;
        _vpHint = '播放失败：$e';
      });
    }
  }

  Future<void> _confirmDeleteSample(
    VoiceprintLibraryStore vpStore, {
    required String personId,
    required VoiceSampleRecord sample,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('vp-sample-delete-confirm'),
        title: const Text('删除声纹样本？'),
        content: Text(
          '将删除「${sample.deviceLabel} · ${sample.sceneLabel}」这条录音与声纹特征，此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('vp-sample-delete-confirm-btn'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_playingSampleId == sample.id) {
      await _samplePlayer?.stop();
      _playingSampleId = null;
    }
    final removed = vpStore.removeSample(
      personId: personId,
      sampleId: sample.id,
    );
    final path = removed?.audioPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      } on Object {
        // 文件清理失败不影响库状态
      }
    }
    setState(() {
      _vpError = false;
      _vpHint = '已删除 1 组声纹样本';
    });
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
    VoiceprintLibraryStore vpStore,
    String personId,
    List<VoiceSampleRecord> samples, {
    String emptyLabel = '暂无音频样本，仅名称记录',
  }) {
    if (samples.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.sep),
        ),
        child: Text(emptyLabel, style: TextStyle(fontSize: 11, color: c.sec)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in samples) ...[
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('vp-sample-${s.id}'),
              borderRadius: BorderRadius.circular(999),
              onTap: () => unawaited(_playSample(s)),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: c.sep),
                ),
                child: Row(
                  children: [
                    Icon(
                      _playingSampleId == s.id
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      size: 22,
                      color: s.audioPath == null || s.audioPath!.isEmpty
                          ? c.ax
                          : c.label,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${s.deviceLabel} · ${s.sceneLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      key: Key('vp-sample-del-${s.id}'),
                      tooltip: '删除样本',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: () => unawaited(
                        _confirmDeleteSample(
                          vpStore,
                          personId: personId,
                          sample: s,
                        ),
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: c.sec,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
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
            vpStore,
            p.id,
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
                style: _rcMiniChipBtnStyle(c),
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
                      ? '录音中…'
                      : (isSelfSlot ? '单独录音增加' : '+ 补充录音样本'),
                ),
              ),
              if (!isSelfSlot)
                OutlinedButton(
                  key: Key('vp-remove-slot-$slot'),
                  style: _rcMiniChipBtnStyle(c),
                  onPressed: () {
                    vpStore.demoteFromFrequentSlot(p.id);
                    setState(() {
                      _vpError = false;
                      _vpHint = '已将「${p.name}」移出常用';
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
                  inFrequent ? '常用自动识别' : '手动选用',
                  style: TextStyle(
                    fontSize: 11,
                    color: inFrequent ? RCColors.okInk : c.sec,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildSampleChips(c, vpStore, p.id, p.samples),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: Key('vp-lib-sample-$index'),
                style: _rcMiniChipBtnStyle(c),
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
                child: Text(capturingThis ? '录音中…' : '+ 补充录音样本'),
              ),
              OutlinedButton(
                key: Key('vp-lib-toggle-$index'),
                style: _rcMiniChipBtnStyle(c),
                onPressed: () {
                  if (inFrequent) {
                    vpStore.demoteFromFrequentSlot(p.id);
                    setState(() {
                      _vpError = false;
                      _vpHint = '已将「${p.name}」移出常用';
                    });
                  } else {
                    final ok = vpStore.promoteToFrequentSlot(p.id);
                    setState(() {
                      _vpError = !ok;
                      _vpHint = ok
                          ? '已将「${p.name}」设为常用（槽位 ${vpStore.findByName(p.name)?.frequentSlot ?? ''}）'
                          : '常用槽位已满（上限 5 个），请先移出其他人物';
                    });
                  }
                },
                child: Text(
                  inFrequent ? '常用槽位 ${p.frequentSlot}（点击移出）' : '设为常用',
                ),
              ),
              OutlinedButton(
                key: Key('vp-lib-del-$index'),
                style: _rcMiniChipBtnStyle(c, foreground: c.danger),
                onPressed: () {
                  vpStore.deletePerson(p.id);
                  setState(() {
                    _vpError = false;
                    _vpHint = '已移除「${p.name}」';
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
                          style: _rcMiniChipBtnStyle(c),
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
                    '本机离线区分不同说话人，声纹仅保存在本机。',
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
                          '常用声纹（上限 5 个）',
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
                    '最多设置 5 个常用声纹参与自动识别。',
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
                          '全部人物库',
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
                        style: _rcMiniChipBtnStyle(c),
                        onPressed: () =>
                            unawaited(_showAddPersonDialog(context, vpStore)),
                        child: const Text('+ 新增人物'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '命名过的说话人保存在此，方便手动选用。',
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                  if (libPersons.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '暂无其他人物，可在对话详情点击说话人命名，或点击「+ 新增人物」。',
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
                            '录音期间在灵动岛和锁屏显示录音状态与时长。',
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
          const _SubSectionLabel('iPhone 操作按钮'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Column(
              children: [
                InkWell(
                  key: const Key('action-btn-mode-record'),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  onTap: () => unawaited(
                    config.setIphoneActionButtonBehavior(
                      IphoneActionButtonBehavior.recordToggle,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '切换录音',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.label,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '按一次开始或停止硬件 / 本机持续录音',
                                style: TextStyle(fontSize: 12, color: c.sec),
                              ),
                            ],
                          ),
                        ),
                        if (config.iphoneActionButtonBehavior ==
                            IphoneActionButtonBehavior.recordToggle)
                          Icon(Icons.check_rounded, size: 18, color: c.label),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, thickness: 0.6, color: c.sep),
                InkWell(
                  key: const Key('action-btn-mode-agent'),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(12),
                  ),
                  onTap: () => unawaited(
                    config.setIphoneActionButtonBehavior(
                      IphoneActionButtonBehavior.agentVoice,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '语音任务（发给 Agent）',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.label,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '抓取按压期间的语音转写后发给 Agent 并播报回复（未录音自动开启临时录音）',
                                style: TextStyle(fontSize: 12, color: c.sec),
                              ),
                            ],
                          ),
                        ),
                        if (config.iphoneActionButtonBehavior ==
                            IphoneActionButtonBehavior.agentVoice)
                          Icon(Icons.check_rounded, size: 18, color: c.label),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Text(
              '前往系统「设置 → 操作按钮 → 快捷指令」，选择「录音卡 · 切换录音」（可在上方切换触发录音或发语音任务给 Agent），或直接绑定专用快捷指令「录音卡 · 向 Agent 发送语音任务」。',
              style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 设计规范统一按钮样式（对齐原型 .btn / .btn.ghost / .mini-chip）──

ButtonStyle _rcPrimaryBtnStyle(RCColorScheme c) => FilledButton.styleFrom(
  backgroundColor: c.label,
  foregroundColor: Colors.white,
  disabledBackgroundColor: c.label.withValues(alpha: 0.35),
  disabledForegroundColor: Colors.white,
  elevation: 0,
  minimumSize: const Size(0, 38),
  maximumSize: const Size(double.infinity, 38),
  padding: const EdgeInsets.symmetric(horizontal: 12),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
);

ButtonStyle _rcGhostBtnStyle(RCColorScheme c) => ButtonStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  foregroundColor: WidgetStateProperty.resolveWith(
    (s) => s.contains(WidgetState.disabled)
        ? c.label.withValues(alpha: 0.35)
        : c.label,
  ),
  overlayColor: WidgetStatePropertyAll(c.label.withValues(alpha: 0.05)),
  elevation: const WidgetStatePropertyAll(0),
  minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
  maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 38)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
  ),
  side: WidgetStateBorderSide.resolveWith(
    (s) => BorderSide(
      color: s.contains(WidgetState.disabled)
          ? c.sep.withValues(alpha: 0.5)
          : c.sep,
    ),
  ),
  textStyle: const WidgetStatePropertyAll(
    TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
  ),
);

ButtonStyle _rcMiniChipBtnStyle(RCColorScheme c, {Color? foreground}) {
  final fg = foreground ?? c.ink;
  return ButtonStyle(
    backgroundColor: WidgetStatePropertyAll(c.card),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? fg.withValues(alpha: 0.35) : fg,
    ),
    overlayColor: WidgetStatePropertyAll(fg.withValues(alpha: 0.06)),
    elevation: const WidgetStatePropertyAll(0),
    minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    side: WidgetStatePropertyAll(BorderSide(color: c.sep)),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
    ),
  );
}

// ── 7) Apple Watch 联动 ──────────────────────────────────────

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
      _hint = next ? '已开启手表联动' : '已关闭手表联动';
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
          setState(() => _hint = '已断开手表连接');
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
              ? '已连接 Apple Watch'
              : (dev.linkError ?? '请先确认手表已安装「录音卡」');
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
          () => _hint = count > 0 ? '已同步 $count 段手表录音' : '暂无待传录音',
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
            : (!status.supported ? '不支持' : (status.paired ? '已配对' : '未配对'));
        final installedText = status == null
            ? '—'
            : (status.watchAppInstalled ? '已安装' : '未安装');
        final linkText = isWatchConnected
            ? '已连接'
            : (status?.reachable == true
                ? '在线'
                : (status?.paired == true && status?.watchAppInstalled == true
                    ? '待机就绪'
                    : '离线'));
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
                    horizontal: 16,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '启用 Apple Watch 录音',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: c.label,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '开启后可在右上角设备列表中选择手表录音',
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
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _WatchKvRow(label: '配对状态', value: pairedText),
                  _WatchKvRow(label: '手表应用', value: installedText),
                  _WatchKvRow(label: '连接状态', value: linkText),
                  _WatchKvRow(label: '手表电量', value: battText),
                  _WatchKvRow(label: '待传录音', value: pendingText, last: true),
                  if (status != null &&
                      status.paired &&
                      !status.watchAppInstalled) ...[
                    const SizedBox(height: 8),
                    Container(
                      key: const Key('watch-install-guide-banner'),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: c.bg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.sep),
                      ),
                      child: Text(
                        '未安装手表应用：请在 iPhone「Watch」App 底部「可用 App」中点击安装（测试版需先在手表「设置 → 隐私与安全性」开启开发者模式）。',
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
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          key: const Key('watch-connect-btn'),
                          style: _rcPrimaryBtnStyle(c),
                          onPressed: (_busy || dev == null)
                              ? null
                              : _connectOrDisconnect,
                          child: Text(
                            isWatchConnected ? '断开连接' : '连接手表',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('watch-flush-btn'),
                          style: _rcGhostBtnStyle(c),
                          onPressed: (_busy || dev == null || !on)
                              ? null
                              : _flushPending,
                          child: const Text(
                            '同步待传录音',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SubSectionLabel('表盘快捷录音'),
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
                    '1. 长按表盘点击「编辑」，添加「录音卡」组件；',
                    style: TextStyle(fontSize: 13, height: 1.5, color: c.label),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '2. 抬腕轻点组件即可开始录音；',
                    style: TextStyle(fontSize: 13, height: 1.5, color: c.label),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '3. 脱离手机也可独立录音，靠近手机自动同步。',
                    style: TextStyle(fontSize: 13, height: 1.5, color: c.sec),
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
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.sep)),
      ),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13.5, color: c.label)),
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

// ── 8) 第三方硬件联动（ReAI 独立 SDK 包裹层） ───────────────────────

class _ExtHardwareLinkBody extends StatefulWidget {
  const _ExtHardwareLinkBody({required this.config, required this.device});

  final AgentConfigStore config;
  final DeviceStore? device;

  @override
  State<_ExtHardwareLinkBody> createState() => _ExtHardwareLinkBodyState();
}

class _ExtHardwareLinkBodyState extends State<_ExtHardwareLinkBody> {
  String? _hint;

  Future<void> _toggleGetSeed(bool next) async {
    await widget.config.setGetSeedLinkEnabled(next);
    await widget.device?.setExtHardwareEnabled(getSeed: next);
    if (!mounted) return;
    setState(() {
      _hint = next ? '已开启 Get 笔记录音卡扫描联动' : '已关闭 Get 笔记录音卡联动';
    });
  }

  Future<void> _toggleOmi(bool next) async {
    await widget.config.setOmiLinkEnabled(next);
    await widget.device?.setExtHardwareEnabled(omi: next);
    if (!mounted) return;
    setState(() {
      _hint = next ? '已开启 Omi 量产版录音器扫描联动' : '已关闭 Omi 量产版录音器联动';
    });
  }

  Future<void> _toggleFeishu(bool next) async {
    await widget.config.setFeishuLinkEnabled(next);
    await widget.device?.setExtHardwareEnabled(feishu: next);
    if (!mounted) return;
    setState(() {
      _hint = next ? '已开启飞书录音豆扫描联动' : '已关闭飞书录音豆联动';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final dev = widget.device;
    final listenable = dev == null
        ? widget.config
        : Listenable.merge([widget.config, dev]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final getSeedOn = widget.config.getSeedLinkEnabled;
        final omiOn = widget.config.omiLinkEnabled;
        final feishuOn = widget.config.feishuLinkEnabled;
        final gsConn =
            dev?.isConnected == true &&
            dev?.activeKind == DeviceKind.getSeedGsc10;
        final omiConn =
            dev?.isConnected == true && dev?.activeKind == DeviceKind.omiCv1;
        final feishuConn =
            dev?.isConnected == true &&
            dev?.activeKind == DeviceKind.feishuD3200;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                children: [
                  _extHardwareRow(
                    context,
                    cardKey: const Key('ext-getseed-card'),
                    switchKey: const Key('ext-getseed-switch'),
                    title: '得到 Get 笔记录音卡',
                    modelTag: 'GSC10',
                    subtitle: '机身物理按键控录与打点，离线录音靠近手机自动同步',
                    enabled: getSeedOn,
                    connected: gsConn,
                    topRadius: 12,
                    onChanged: () => unawaited(_toggleGetSeed(!getSeedOn)),
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    endIndent: 16,
                    color: c.sep,
                  ),
                  _extHardwareRow(
                    context,
                    cardKey: const Key('ext-omi-card'),
                    switchKey: const Key('ext-omi-switch'),
                    title: 'Omi 随身录音器',
                    modelTag: 'Friend',
                    subtitle: '蓝牙随身拾音，支持按键打点与板载存储同步',
                    enabled: omiOn,
                    connected: omiConn,
                    onChanged: () => unawaited(_toggleOmi(!omiOn)),
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    endIndent: 16,
                    color: c.sep,
                  ),
                  _extHardwareRow(
                    context,
                    cardKey: const Key('ext-feishu-card'),
                    switchKey: const Key('ext-feishu-switch'),
                    title: '飞书录音豆',
                    modelTag: 'D3200',
                    statusTag: 'Beta',
                    statusKey: const Key('ext-feishu-beta'),
                    subtitle: 'BLE 同步板载录音，支持远程启停；尚未真机验证，固件走官方 App',
                    enabled: feishuOn,
                    connected: feishuConn,
                    bottomRadius: 12,
                    onChanged: () => unawaited(_toggleFeishu(!feishuOn)),
                  ),
                ],
              ),
            ),
            if (_hint != null) ...[
              const SizedBox(height: 10),
              Text(
                _hint!,
                key: const Key('ext-hw-hint'),
                style: TextStyle(fontSize: 12, color: c.sec),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _extHardwareRow(
    BuildContext context, {
    required Key cardKey,
    required Key switchKey,
    required String title,
    required String modelTag,
    String? statusTag,
    Key? statusKey,
    required String subtitle,
    required bool enabled,
    required bool connected,
    double topRadius = 0,
    double bottomRadius = 0,
    required VoidCallback onChanged,
  }) {
    final c = context.rc;
    final radius = BorderRadius.vertical(
      top: Radius.circular(topRadius),
      bottom: Radius.circular(bottomRadius),
    );
    return Container(
      key: cardKey,
      child: InkWell(
        key: switchKey,
        borderRadius: radius,
        onTap: onChanged,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: c.label,
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
                            modelTag,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: c.sec,
                            ),
                          ),
                        ),
                        if (statusTag != null)
                          Container(
                            key: statusKey,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF7E6),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              statusTag,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFAD6800),
                              ),
                            ),
                          ),
                        if (connected)
                          Text(
                            '· 已连接',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: c.okInk,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: c.sec,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              RCSwitch(on: enabled),
            ],
          ),
        ),
      ),
    );
  }
}

/// 开发者设置 —— 语义清洗周期、上轮重叠上下文窗口、静音停顿触发与全量重洗。
class _DeveloperCleanBody extends StatelessWidget {
  const _DeveloperCleanBody({required this.config});

  final AgentConfigStore config;

  static const _cyclePresets = [2, 5, 10, 15, 30, 60, 120];
  static const _paraPresets = [0, 1, 3, 5, 8];
  static const _minutePresets = [1, 2, 3, 5, 10, 15];

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final primary = Theme.of(context).colorScheme.primary;
    final store = StoreScope.maybeOf(context);
    return ListenableBuilder(
      listenable: config,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        DeveloperModelSection(config: config),
        const SizedBox(height: 16),
        _SubSectionLabel('增量清洗与逻辑分段周期'),
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '清洗整理周期',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.label,
                      ),
                    ),
                  ),
                  Text(
                    AgentConfigStore.formatCleanCycle(config.cleanCycleMinutes),
                    key: const Key('dev-cycle-value'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '持续录音达到该时长阈值后，自动结合声纹与语义对整段语音去口水词、合并同说话人段落并生成阶段标题与概述。',
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in _cyclePresets)
                    ChoiceChip(
                      key: Key('dev-cycle-preset-$m'),
                      label: Text(AgentConfigStore.formatCleanCycle(m)),
                      selected: config.cleanCycleMinutes == m,
                      onSelected: (_) =>
                          unawaited(config.setCleanCycleMinutes(m)),
                    ),
                ],
              ),
              Slider(
                key: const Key('dev-cycle-slider'),
                min: 1,
                max: 180,
                divisions: 179,
                value: config.cleanCycleMinutes.toDouble().clamp(1, 180),
                label: AgentConfigStore.formatCleanCycle(config.cleanCycleMinutes),
                onChanged: (v) =>
                    unawaited(config.setCleanCycleMinutes(v.round())),
              ),
              Divider(height: 18, color: c.sep),
              InkWell(
                key: const Key('dev-silence-trigger'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => unawaited(
                  config.setCleanOnSilenceGap(!config.cleanOnSilenceGap),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '停顿 ≥ 1 分钟自动触发清洗',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: c.label,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '未满周期但检测到明显沉默空白或停止录音时提前整理',
                              style: TextStyle(fontSize: 11.5, color: c.sec),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      RCSwitch(on: config.cleanOnSilenceGap),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SubSectionLabel('层叠连续上下文（Overlap）'),
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
                '重叠依据',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('dev-overlap-mode-paragraphs'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: config.cleanOverlapMode == 'paragraphs'
                            ? primary.withValues(alpha: 0.12)
                            : null,
                        side: BorderSide(
                          color: config.cleanOverlapMode == 'paragraphs'
                              ? primary
                              : c.sep,
                        ),
                      ),
                      onPressed: () =>
                          unawaited(config.setCleanOverlapMode('paragraphs')),
                      child: const Text('按上一轮已整理段落'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('dev-overlap-mode-minutes'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: config.cleanOverlapMode == 'minutes'
                            ? primary.withValues(alpha: 0.12)
                            : null,
                        side: BorderSide(
                          color: config.cleanOverlapMode == 'minutes'
                              ? primary
                              : c.sep,
                        ),
                      ),
                      onPressed: () =>
                          unawaited(config.setCleanOverlapMode('minutes')),
                      child: const Text('按上一轮尾部时长'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (config.cleanOverlapMode == 'paragraphs') ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '携带上一轮末尾已整理段落数',
                        style: TextStyle(fontSize: 13, color: c.label),
                      ),
                    ),
                    Text(
                      '${config.cleanOverlapParagraphs} 段',
                      key: const Key('dev-overlap-value'),
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
                    for (final n in _paraPresets)
                      ChoiceChip(
                        key: Key('dev-overlap-para-$n'),
                        label: Text('$n 段'),
                        selected: config.cleanOverlapParagraphs == n,
                        onSelected: (_) =>
                            unawaited(config.setCleanOverlapParagraphs(n)),
                      ),
                  ],
                ),
                Slider(
                  key: const Key('dev-overlap-para-slider'),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  value: config.cleanOverlapParagraphs.toDouble().clamp(0, 10),
                  label: '${config.cleanOverlapParagraphs} 段',
                  onChanged: (v) =>
                      unawaited(config.setCleanOverlapParagraphs(v.round())),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '携带上一轮尾部时间窗',
                        style: TextStyle(fontSize: 13, color: c.label),
                      ),
                    ),
                    Text(
                      '${config.cleanOverlapMinutes} 分钟',
                      key: const Key('dev-overlap-value'),
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
                    for (final m in _minutePresets)
                      ChoiceChip(
                        key: Key('dev-overlap-min-$m'),
                        label: Text('$m 分钟'),
                        selected: config.cleanOverlapMinutes == m,
                        onSelected: (_) =>
                            unawaited(config.setCleanOverlapMinutes(m)),
                      ),
                  ],
                ),
                Slider(
                  key: const Key('dev-overlap-min-slider'),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  value: config.cleanOverlapMinutes.toDouble().clamp(1, 30),
                  label: '${config.cleanOverlapMinutes} 分钟',
                  onChanged: (v) =>
                      unawaited(config.setCleanOverlapMinutes(v.round())),
                ),
              ],
              Text(
                '下一轮整理会自动承接上文标题、概述及末尾重叠段，确保跨周期讨论被平滑接续、不断章取义。',
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const DeveloperTaskSection(),
        const SizedBox(height: 16),
        const DeveloperReplaySection(),
        const SizedBox(height: 16),
        _SubSectionLabel('存量清洗与验证'),
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
                '清理历史仅含句号/孤立标点的误判切片，并按上方周期与层叠参数重新梳理所有已保存录音的阶段标题、概述与合并段落。',
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
              const SizedBox(height: 12),
              if (store == null)
                const Text(
                  '当前为独立预览环境，无法操作本地录音库。',
                  style: TextStyle(fontSize: 12, color: RCColors.sec),
                )
              else
                ListenableBuilder(
                  listenable: store,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        key: const Key('dev-reclean-btn'),
                        onPressed: store.isRecleaning
                            ? null
                            : () => unawaited(store.recleanAllRecordings()),
                        icon: store.isRecleaning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_fix_high_outlined, size: 18),
                        label: Text(
                          store.isRecleaning
                              ? '正在清洗整理…'
                              : '立即重新清洗整理本地记录',
                        ),
                      ),
                      if (store.recleanStatus.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          store.recleanStatus,
                          key: const Key('dev-reclean-status'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (config.developerMode) ...[
          const SizedBox(height: 16),
          HealthSamplingDevSection(config: config),
        ],
      ],
      ),
    );
  }
}
