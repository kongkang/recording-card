/// Agent 与云端模型设置状态机 —— 模型选择、上下文策略、温度、预设与提示词、Skills/Tools/MCP 扩展。
///
/// 持久化走 [JsonStore]（键 `agent_v1`），修改即时落盘并通知监听方（Setting 摘要与
/// [SummaryGenerator] 实时读取最新配置）。
library;

import 'package:flutter/foundation.dart';

import '../storage/storage.dart';

/// 硬件物理按键与侧边拨杆可绑定动作（固件事件上行或本地执行，App 侧解释/协同执行）。
enum HardwareButtonAction {
  mark('mark', '打重点（Mark）', '重点'),
  syncNow('sync_now', '立即同步数据', '同步'),
  agentVoice('agent_voice', '语音任务（发给 Agent）', '语音'),
  photoRecognize('photo_recognize', '拍照识别（发给 Agent）', '识图'),
  recordStart('record_start', '开始录音', '开录'),
  recordStop('record_stop', '结束录音', '停录'),
  recordToggle('record_toggle', '开关录音', '录音'),
  none('none', '无动作', '无');

  const HardwareButtonAction(this.code, this.label, this.shortLabel);

  final String code;
  final String label;
  final String shortLabel;

  /// 点一机 V1 按钮可选动作（保持既有选项）。
  static const List<HardwareButtonAction> dyjButtonOptions = [
    mark,
    agentVoice,
    photoRecognize,
    recordToggle,
    none,
  ];

  /// 录音卡 V2 物理按钮可选动作。
  static const List<HardwareButtonAction> cardButtonOptions = [
    mark,
    syncNow,
    agentVoice,
    recordStart,
    recordStop,
    recordToggle,
    none,
  ];

  /// 录音卡 V2 侧边拨杆可选动作。
  static const List<HardwareButtonAction> cardSwitchOptions = [
    recordStart,
    recordStop,
    recordToggle,
    mark,
    syncNow,
    agentVoice,
    none,
  ];

  /// 映射为录音卡 V2 固件 KV 存储值。
  ///
  /// 注意：`syncNow` 写入 `'app_sync'`（而非固件自带的 `'sync_upload'`），
  /// 避免在未配网情况下自动开启 ESP32 Wi-Fi 抢占 SD 卡；改为触发 App 侧实时切片/BLE 同步。
  String toCardFirmwareWire() => switch (this) {
    HardwareButtonAction.mark => 'record_mark',
    HardwareButtonAction.syncNow => 'app_sync',
    HardwareButtonAction.agentVoice => 'agent_voice',
    HardwareButtonAction.recordStart => 'record_start',
    HardwareButtonAction.recordStop => 'record_stop',
    HardwareButtonAction.recordToggle => 'record_toggle',
    HardwareButtonAction.photoRecognize || HardwareButtonAction.none => 'none',
  };

  static HardwareButtonAction fromCardFirmwareWire(String? raw) =>
      switch (raw?.trim()) {
        'record_mark' => HardwareButtonAction.mark,
        'app_sync' || 'sync_now' || 'sync_upload' => HardwareButtonAction.syncNow,
        'agent_voice' => HardwareButtonAction.agentVoice,
        'record_start' => HardwareButtonAction.recordStart,
        'record_stop' => HardwareButtonAction.recordStop,
        'record_toggle' => HardwareButtonAction.recordToggle,
        _ => HardwareButtonAction.none,
      };

  static HardwareButtonAction fromCode(
    String? raw, {
    required HardwareButtonAction fallback,
  }) {
    final trimmed = raw?.trim();
    for (final v in values) {
      if (v.code == trimmed) return v;
    }
    return fallback;
  }
}

/// iPhone 侧边操作按钮默认快捷指令行为。
enum IphoneActionButtonBehavior {
  recordToggle('record_toggle', '切换录音开关'),
  agentVoice('agent_voice', '发语音任务给 Agent');

  const IphoneActionButtonBehavior(this.code, this.label);

  final String code;
  final String label;

  static IphoneActionButtonBehavior fromCode(String? raw) {
    final trimmed = raw?.trim();
    for (final v in values) {
      if (v.code == trimmed) return v;
    }
    return IphoneActionButtonBehavior.recordToggle;
  }
}

class CloudModelOption {
  final String id;
  final String name;
  final String desc;
  final bool fromGateway;

  const CloudModelOption({
    required this.id,
    required this.name,
    required this.desc,
    this.fromGateway = false,
  });
}

class AgentPresetSpec {
  final String id;
  final String label;
  final String desc;
  final String summaryPrompt;
  final String polishPrompt;
  final String dreamPrompt;
  final bool builtin;

  const AgentPresetSpec({
    required this.id,
    required this.label,
    required this.desc,
    required this.summaryPrompt,
    required this.polishPrompt,
    required this.dreamPrompt,
    this.builtin = true,
  });

  AgentPresetSpec copyWith({
    String? label,
    String? desc,
    String? summaryPrompt,
    String? polishPrompt,
    String? dreamPrompt,
  }) => AgentPresetSpec(
    id: id,
    label: label ?? this.label,
    desc: desc ?? this.desc,
    summaryPrompt: summaryPrompt ?? this.summaryPrompt,
    polishPrompt: polishPrompt ?? this.polishPrompt,
    dreamPrompt: dreamPrompt ?? this.dreamPrompt,
    builtin: builtin,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'desc': desc,
    'summary': summaryPrompt,
    'polish': polishPrompt,
    'dream': dreamPrompt,
  };

  factory AgentPresetSpec.fromJson(Map<String, dynamic> j) => AgentPresetSpec(
    id: '${j['id'] ?? ''}',
    label: '${j['label'] ?? '未命名'}',
    desc: '${j['desc'] ?? ''}',
    summaryPrompt: '${j['summary'] ?? ''}',
    polishPrompt: '${j['polish'] ?? ''}',
    dreamPrompt: '${j['dream'] ?? ''}',
    builtin: false,
  );
}

class AgentExtensionItem {
  final String id;
  final String kind; // 'skill' | 'tool' | 'mcp'
  final String title;
  final String subtitle;
  final String? promptRule;
  final bool custom;

  /// `live` 已进入当前清洗或总结；`partial` 只接到旁路；`placeholder` 只是占位。
  final String wiring;
  final String wiringNote;

  const AgentExtensionItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.promptRule,
    this.custom = false,
    this.wiring = 'placeholder',
    this.wiringNote = '未接入：当前清洗和总结都不会调用这项。',
  });

  String get wiringLabel => switch (wiring) {
    'live' => '已接入',
    'partial' => '部分接入',
    _ => '未接入',
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'subtitle': subtitle,
    if (promptRule != null) 'rule': promptRule,
    if (custom) 'custom': true,
    'wiring': wiring,
    if (wiringNote.isNotEmpty) 'wiringNote': wiringNote,
  };

  factory AgentExtensionItem.fromJson(Map<String, dynamic> j) =>
      AgentExtensionItem(
        id: '${j['id'] ?? ''}',
        kind: '${j['kind'] ?? 'mcp'}',
        title: '${j['title'] ?? ''}',
        subtitle: '${j['subtitle'] ?? ''}',
        promptRule: j['rule'] as String?,
        custom: j['custom'] == true,
        wiring: j['wiring'] == 'live' || j['wiring'] == 'partial'
            ? j['wiring'] as String
            : 'placeholder',
        wiringNote: '${j['wiringNote'] ?? '未接入：添加后只保存在本机列表，清洗和总结不会调用。'}',
      );
}

class AgentConfigStore extends ChangeNotifier {
  AgentConfigStore({KeyValueStore? store})
    : _json = JsonStore(store: store ?? InMemoryStore());

  final JsonStore _json;
  static const _storageKey = 'agent_v1';

  static const List<CloudModelOption> builtinModels = [
    CloudModelOption(
      id: 'deepseek-v3',
      name: 'deepseek-v3',
      desc: '目录里的候选，不是当前默认。未手动指定时以网关实际返回的模型为准',
    ),
    CloudModelOption(
      id: 'qwen-max',
      name: 'qwen-max',
      desc: '结构化逻辑与行动项抽取稳定，适合多人会议纪要',
    ),
    CloudModelOption(
      id: 'doubao-pro',
      name: 'doubao-pro',
      desc: '中文对话理解与日常摘要梳理自然流畅',
    ),
    CloudModelOption(
      id: 'glm-4-plus',
      name: 'glm-4-plus',
      desc: '中文语境与多轮对话整理稳定可靠',
    ),
    CloudModelOption(
      id: 'gpt-4o',
      name: 'gpt-4o',
      desc: '跨语种与图文对齐理解强，适合中英混杂与白板拍照场景',
    ),
  ];

  static const List<AgentPresetSpec> builtinPresets = [
    AgentPresetSpec(
      id: 'general',
      label: '通用纪要',
      desc: '兼顾概览、逻辑结构、带溯源信息点与可执行待办',
      summaryPrompt: '你是录音整理助手。请基于所给录音转写整理结构化纪要：先给 2-3 句概览，再按讨论脉络归纳逻辑结构，提炼关键信息点并严格标注来源记录 ID，最后提取明确的行动项；不编造原文没有的事实。',
      polishPrompt: '清理口头禅、重复词与语气助词，合并同一说话人被打断的连续短句，保留专业术语、数字、人名与原始语义，不改写观点倾向。',
      dreamPrompt: '日终复盘全天对话脉络，清洗碎片化口语记忆，归档值得长期保留的知识条目，并提炼可复用的个人沟通与决策洞察。',
    ),
    AgentPresetSpec(
      id: 'meeting',
      label: '深度会议',
      desc: '聚焦会议决策、分歧拉齐、责任人与截止时间',
      summaryPrompt: '你是高管会议纪要专家。请聚焦会议决策、核心争议与达成共识的条件，按议题拆解逻辑分支，将所有结论与承诺关联到来源记录 ID，并在行动项中明确事项与时间节点。',
      polishPrompt: '按会议发言轮次清洗口语冗余，突出方案对比、指标口径与排期表态，完整保留原话中的条件限定词。',
      dreamPrompt: '汇总当日多场会议之间的跨议题关联、未闭环阻塞项与次日优先跟进清单。',
    ),
    AgentPresetSpec(
      id: 'interview',
      label: '访谈提炼',
      desc: '保留受访者核心洞察、真实案例与代表性原话',
      summaryPrompt:
          '你是用户研究与深度访谈分析师。请提炼受访者的核心痛点、使用场景、决策动机与反直觉洞察，在信息点中保留最具代表性的细节与来源溯源。',
      polishPrompt: '温和去噪，保留受访者的情绪转折、程度副词与具体故事细节，不把鲜活表达压缩成空洞套话。',
      dreamPrompt: '将当日访谈所得归档为结构化洞察卡片，关联既有研究假设并标记新发现的反例。',
    ),
    AgentPresetSpec(
      id: 'todo',
      label: '极简待办',
      desc: '压缩背景叙述，优先输出结论与可执行清单',
      summaryPrompt:
          '你是极简行动派助手。概览控制在两句话以内，逻辑结构只列最终结论，信息点只保留硬数字与硬约束，重点输出可直接勾选执行的行动项列表。',
      polishPrompt: '精简寒暄与发散闲聊，高密度保留指令、承诺、数字与时间点。',
      dreamPrompt: '仅归档今日已完成闭环与明日必做三件事，保持零噪音。',
    ),
  ];

  /// 兼容旧调用点：仅内置预设（不含用户增改）。
  static List<AgentPresetSpec> get presets => builtinPresets;

  static const List<AgentExtensionItem> builtinExtensions = [
    AgentExtensionItem(
      id: 'sk-term',
      kind: 'skill',
      title: '术语统一与实体对齐',
      subtitle: '自动对齐同音异写的产品名、技术缩写与项目代号',
      promptRule: '对同音误识的专业术语、缩写与项目代号结合上下文做一致性对齐，不确定时保留原词。',
      wiring: 'live',
      wiringNote: '已接入：打开后，这条规则会追加进滚动清洗和总结的提示词。没有单独的技能运行时。',
    ),
    AgentExtensionItem(
      id: 'sk-brief',
      kind: 'skill',
      title: '结论前置与纪要精简',
      subtitle: '每个分支与信息点先给结论，再补充支撑细节',
      promptRule: '概览与每个信息点均采用「结论前置」写法，避免冗长铺垫。',
      wiring: 'live',
      wiringNote: '已接入：打开后，这条规则会追加进滚动清洗和总结的提示词。没有单独的技能运行时。',
    ),
    AgentExtensionItem(
      id: 'sk-risk',
      kind: 'skill',
      title: '风险与待决阻塞提炼',
      subtitle: '单独识别对话中提到的风险、依赖阻塞与未决问题',
      promptRule: '专门检查并标注对话中暴露的排期风险、外部依赖阻塞与尚未拍板的待决项。',
      wiring: 'live',
      wiringNote: '已接入：打开后，这条规则会追加进滚动清洗和总结的提示词。没有单独的技能运行时。',
    ),
    AgentExtensionItem(
      id: 'tl-photo',
      kind: 'tool',
      title: '关联录音时段照片',
      subtitle: '总结时感知录音窗口内的点一机抓拍与系统相册照片数量',
      wiring: 'partial',
      wiringNote: '部分接入：这个开关会同步相册自动对齐。清洗和总结不会把它当成工具去调用。',
    ),
    AgentExtensionItem(
      id: 'tl-hist',
      kind: 'tool',
      title: '同日连续上下文感知',
      subtitle: '结合同日早些时候的录音片段理解代词与省略背景',
      wiring: 'placeholder',
      wiringNote: '未接入：清洗和总结都不会读取这个开关，也不会因此附带同日更早的录音。',
    ),
    AgentExtensionItem(
      id: 'tl-todo',
      kind: 'tool',
      title: '结构化行动项提取',
      subtitle: '从承诺与排期语句中提取可勾选待办事项',
      wiring: 'placeholder',
      wiringNote: '未接入：总结里的行动项来自总结提示词，不看这个开关。',
    ),
    AgentExtensionItem(
      id: 'mcp-kb',
      kind: 'mcp',
      title: '个人知识库 MCP',
      subtitle: 'local://knowledge-vault · 日报与做梦归档接口（规划接入）',
      wiring: 'placeholder',
      wiringNote: '未接入：没有 MCP 客户端。打开后也不会连接外部服务。',
    ),
  ];

  static const Map<String, bool> _defaultExtensionStates = {
    'sk-term': true,
    'sk-brief': true,
    'sk-risk': false,
    'tl-photo': true,
    'tl-hist': true,
    'tl-todo': true,
    'mcp-kb': false,
  };

  static const String defaultAgentPrompt =
      '你是 OS1，用户的随身录音记忆与生活搭档。说话像真人朋友一样自然简练、有温度，'
      '有把握的事实直接引用记录或总结里的具体时间、人物和要点，没有把握或未采集的绝不编造。'
      '严禁在回复中输出“思考过程”“调用工具”等内部步骤字样。';

  bool cloudEnabled = true;
  String customApiBase = '';
  bool developerMode = false;
  bool photoLinkEnabled = true;
  bool islandEnabled = true;
  bool watchLinkEnabled = false;
  bool getSeedLinkEnabled = false;
  bool omiLinkEnabled = false;
  bool feishuLinkEnabled = false;

  /// 行为与健康信号总开关。默认关闭；打开后才申请系统权限并在本机采集。
  bool healthSignalEnabled = false;

  /// 用户手动选中的端侧语音转写引擎（null=跟随平台默认，'system'=系统内置，'sensevoice'=增强模型）。
  String? preferredAsrEngine;

  /// OS1 对话 Agent 默认挂载的基础能力权限（保持开放可扩展，均可在设置或由 Agent 自身调整）。
  bool agentWebSearchEnabled = true;
  bool agentRecordSearchEnabled = true;
  bool agentHealthAccessEnabled = true;
  String customSearchApiUrl = '';
  String customSearchApiKey = '';
  String agentPrompt = defaultAgentPrompt;

  /// 点一机 V1 物理按键默认行为：单击=重点、长按=语音任务、双击=拍照识别。
  HardwareButtonAction dyjClickAction = HardwareButtonAction.mark;
  HardwareButtonAction dyjLongPressAction = HardwareButtonAction.agentVoice;
  HardwareButtonAction dyjDoubleClickAction =
      HardwareButtonAction.photoRecognize;

  /// 录音卡 V2（CardV2）物理按钮与侧边拨杆默认行为：
  /// 单击=重点、双击=立即同步数据、长按=调用 Agent、拨杆开=开始录音、拨杆关=结束录音。
  HardwareButtonAction cardClickAction = HardwareButtonAction.mark;
  HardwareButtonAction cardDoubleClickAction = HardwareButtonAction.syncNow;
  HardwareButtonAction cardLongPressAction = HardwareButtonAction.agentVoice;
  HardwareButtonAction cardSwitchOnAction = HardwareButtonAction.recordStart;
  HardwareButtonAction cardSwitchOffAction = HardwareButtonAction.recordStop;
  bool cardControlsUserConfigured = false;

  /// iPhone 侧边操作按钮「切换录音」快捷动作模式（专用「向 Agent 发送语音任务」始终直接发给 Agent）。
  IphoneActionButtonBehavior iphoneActionButtonBehavior =
      IphoneActionButtonBehavior.recordToggle;

  HardwareButtonAction dyjActionForGesture(String gesture) => switch (gesture) {
    'click' => dyjClickAction,
    'long_press' || 'long_press_start' || 'long_press_end' => dyjLongPressAction,
    'double_click' => dyjDoubleClickAction,
    _ => HardwareButtonAction.none,
  };

  HardwareButtonAction cardActionForGesture(String gesture) => switch (gesture) {
    'click' => cardClickAction,
    'double_click' => cardDoubleClickAction,
    'long_press' || 'long_press_start' || 'long_press_end' => cardLongPressAction,
    'switch_on' => cardSwitchOnAction,
    'switch_off' => cardSwitchOffAction,
    _ => HardwareButtonAction.none,
  };

  bool get hasAnyCardControlAction =>
      cardClickAction != HardwareButtonAction.none ||
      cardDoubleClickAction != HardwareButtonAction.none ||
      cardLongPressAction != HardwareButtonAction.none ||
      cardSwitchOnAction != HardwareButtonAction.none ||
      cardSwitchOffAction != HardwareButtonAction.none;

  Map<String, String> cardFirmwareBindingsPayload() => {
    'btnSingle': cardClickAction.toCardFirmwareWire(),
    'btnDouble': cardDoubleClickAction.toCardFirmwareWire(),
    'btnLongPress': cardLongPressAction.toCardFirmwareWire(),
    'btnLongRelease': 'none',
    'switchOn': cardSwitchOnAction.toCardFirmwareWire(),
    'switchOff': cardSwitchOffAction.toCardFirmwareWire(),
  };

  Map<String, String> cardFirmwareSinglePayload(
    String input,
    HardwareButtonAction action,
  ) {
    final wire = action.toCardFirmwareWire();
    return switch (input) {
      'click' => {'btnSingle': wire},
      'double_click' => {'btnDouble': wire},
      'long_press' => {'btnLongPress': wire, 'btnLongRelease': 'none'},
      'switch_on' => {'switchOn': wire},
      'switch_off' => {'switchOff': wire},
      _ => const {},
    };
  }

  String get dyjButtonSummary =>
      '单击${dyjClickAction.shortLabel} · 长按${dyjLongPressAction.shortLabel} · 双击${dyjDoubleClickAction.shortLabel}';

  String get cardButtonSummary =>
      '单击${cardClickAction.shortLabel} · 双击${cardDoubleClickAction.shortLabel} · 长按${cardLongPressAction.shortLabel} · 拨杆${cardSwitchOnAction.shortLabel}/${cardSwitchOffAction.shortLabel}';

  int get enabledExtHardwareCount =>
      (getSeedLinkEnabled ? 1 : 0) +
      (omiLinkEnabled ? 1 : 0) +
      (feishuLinkEnabled ? 1 : 0);

  /// 用户手动指定的模型。空字符串表示没有指定，不能把目录里的 deepseek-v3 当成已选。
  String cloudModel = '';
  bool userPickedCloudModel = false;

  /// 网关最近一次探测到的文本模型。只用于展示和未指定时的实际调用，不是用户选择。
  String gatewayModel = '';
  String contextMode = 'full_day'; // 'full_day' | 'scoped'
  double temperature = 0.2;

  // ── 开发者设置：连续录音清洗周期与层叠重叠策略 ─────────────
  /// 阶段清洗触发周期（分钟，支持 1..180 分钟，从分钟到小时可调）。
  int cleanCycleMinutes = 10;

  /// 遇到 >=1 分钟静音空白或停止录音时自动提前收敛清洗。
  bool cleanOnSilenceGap = true;

  /// 层叠上下文重叠模式：'paragraphs'（上一轮已整理段落）| 'minutes'（上一轮时间窗口）。
  String cleanOverlapMode = 'paragraphs';

  /// 按已整理段落重叠时，附带上一轮末尾段落条数（0..10）。
  int cleanOverlapParagraphs = 3;

  /// 按时间重叠时，回溯包含上一轮末尾的分钟数（1..30）。
  int cleanOverlapMinutes = 3;

  /// 录音切片长度（秒）。只保存配置，不改变现有实时切片、合并或分段。
  /// 当前流水线仍按代码里的 1 分钟窗口运行。
  int recordingSliceSeconds = 60;

  /// 健康与位置采样间隔（秒）。默认 60，可在开发者设置调到 300（5 分钟）。
  int healthSampleIntervalSeconds = 60;

  /// 采样窗口内的相位（秒）。默认 30，让取样落在每分钟后半段。
  int healthSamplePhaseSeconds = 30;

  int get healthSampleIntervalMs => healthSampleIntervalSeconds * 1000;

  int get healthSamplePhaseMs => healthSamplePhaseSeconds * 1000;

  static String formatSampleWindow(int seconds) {
    if (seconds > 0 && seconds % 60 == 0) return '${seconds ~/ 60} 分钟';
    return '$seconds 秒';
  }

  static String formatCleanCycle(int minutes) {
    final clamped = minutes < 1 ? 1 : minutes;
    if (clamped < 60) return '$clamped 分钟';
    final h = clamped ~/ 60;
    final m = clamped % 60;
    if (h < 24) return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
    final days = h ~/ 24;
    final rh = h % 24;
    if (rh == 0 && m == 0) return '$days 天';
    return m == 0 ? '$days 天 $rh 小时' : '$days 天 $rh 小时 $m 分钟';
  }

  String get developerCleanSummary {
    final cycleText = formatCleanCycle(cleanCycleMinutes);
    final overlapText = cleanOverlapMode == 'minutes'
        ? '重叠 $cleanOverlapMinutes 分钟'
        : (cleanOverlapParagraphs == 0
              ? '无重叠'
              : '重叠 $cleanOverlapParagraphs 段');
    return '每 $cycleText · $overlapText';
  }

  String get effectiveModelId {
    if (userPickedCloudModel && cloudModel.trim().isNotEmpty) {
      return cloudModel.trim();
    }
    return gatewayModel.trim();
  }

  String get modelSourceLabel {
    if (userPickedCloudModel && cloudModel.trim().isNotEmpty) return '用户指定';
    if (gatewayModel.trim().isNotEmpty) return '网关默认';
    return '未指定';
  }

  String get effectiveModelLabel {
    final id = effectiveModelId;
    return id.isEmpty ? '等待网关模型' : id;
  }

  String get cloudStatusSummary {
    if (!cloudEnabled) return '已关闭';
    final custom = customApiBase.trim().isNotEmpty;
    final model = effectiveModelId;
    if (model.isEmpty) {
      return custom ? '已开启 · 自定义接口 · 等待网关模型' : '已开启 · 等待网关模型';
    }
    final source = modelSourceLabel;
    return custom ? '$model · $source · 自定义接口' : '$model · $source';
  }

  String presetId = 'general'; // builtin id | user-* | 'custom'
  late Map<String, String> prompts = _promptsFromPreset(builtinPresets.first);

  Map<String, bool> extensionStates = Map<String, bool>.of(
    _defaultExtensionStates,
  );
  List<AgentExtensionItem> customMcps = const [];
  List<AgentPresetSpec> userPresets = const [];

  List<String> _gatewayModels = const [];

  static Map<String, String> _promptsFromPreset(AgentPresetSpec p) => {
    'summary': p.summaryPrompt,
    'polish': p.polishPrompt,
    'dream': p.dreamPrompt,
  };

  List<AgentPresetSpec> get allPresets => [
    ...builtinPresets,
    ...userPresets,
  ];

  AgentPresetSpec? presetById(String id) {
    for (final p in allPresets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 同步网关探测到的真实可用文本模型。未手动指定时不把网关模型写进用户选择。
  void syncGatewayModels(List<String> models, {String? primaryTextModel}) {
    _gatewayModels = List<String>.unmodifiable(models);
    final primary = primaryTextModel?.trim() ?? '';
    if (primary.isNotEmpty) gatewayModel = primary;
    notifyListeners();
  }

  List<CloudModelOption> get availableCloudModels {
    final result = <CloudModelOption>[];
    final seen = <String>{};
    for (final id in _gatewayModels) {
      if (id.trim().isEmpty || !seen.add(id)) continue;
      final builtin = builtinModels.where((b) => b.id == id).firstOrNull;
      result.add(
        CloudModelOption(
          id: id,
          name: builtin?.name ?? id,
          desc: builtin?.desc ?? '模型网关当前已开通的云端文本模型',
          fromGateway: true,
        ),
      );
    }
    for (final b in builtinModels) {
      if (seen.add(b.id)) {
        result.add(b);
      }
    }
    // 普通及开发者视图最多仅展示 5 个候选模型，避免冗长干扰选择
    return result.take(5).toList(growable: false);
  }

  String get presetLabel {
    if (presetId == 'custom') return '自定义';
    return presetById(presetId)?.label ?? '通用纪要';
  }

  bool get isUserPresetSelected =>
      presetById(presetId)?.builtin == false;

  String promptFor(String kind) =>
      prompts[kind] ?? builtinPresets.first.summaryPrompt;

  List<AgentExtensionItem> get allExtensions => [
    ...builtinExtensions,
    ...customMcps,
  ];

  bool isExtensionOn(String id) => extensionStates[id] ?? false;

  int get enabledExtensionCount =>
      allExtensions.where((item) => isExtensionOn(item.id)).length;

  List<String> get enabledSkillRules => [
    for (final item in builtinExtensions)
      if (item.kind == 'skill' &&
          isExtensionOn(item.id) &&
          item.promptRule != null)
        item.promptRule!,
  ];

  Future<void> load() async {
    final data = await _json.read(_storageKey);
    if (data == null) return;
    if (data['cloudEnabled'] is bool) {
      cloudEnabled = data['cloudEnabled'] as bool;
    }
    if (data['customApiBase'] is String) {
      customApiBase = data['customApiBase'] as String;
    }
    if (data['devMode'] is bool) {
      developerMode = data['devMode'] as bool;
    }
    if (data['photoLinkEnabled'] is bool) {
      photoLinkEnabled = data['photoLinkEnabled'] as bool;
    }
    if (data['islandEnabled'] is bool) {
      islandEnabled = data['islandEnabled'] as bool;
    }
    if (data['watchLinkEnabled'] is bool) {
      watchLinkEnabled = data['watchLinkEnabled'] as bool;
    }
    if (data['getSeedLinkEnabled'] is bool) {
      getSeedLinkEnabled = data['getSeedLinkEnabled'] as bool;
    }
    if (data['omiLinkEnabled'] is bool) {
      omiLinkEnabled = data['omiLinkEnabled'] as bool;
    }
    if (data['feishuLinkEnabled'] is bool) {
      feishuLinkEnabled = data['feishuLinkEnabled'] as bool;
    }
    if (data['healthSignalEnabled'] is bool) {
      healthSignalEnabled = data['healthSignalEnabled'] as bool;
    }
    if (data['asrEngine'] == 'system' || data['asrEngine'] == 'sensevoice') {
      preferredAsrEngine = data['asrEngine'] as String;
    }
    if (data['agentWebSearchEnabled'] is bool) {
      agentWebSearchEnabled = data['agentWebSearchEnabled'] as bool;
    }
    if (data['agentRecordSearchEnabled'] is bool) {
      agentRecordSearchEnabled = data['agentRecordSearchEnabled'] as bool;
    }
    if (data['agentHealthAccessEnabled'] is bool) {
      agentHealthAccessEnabled = data['agentHealthAccessEnabled'] as bool;
    }
    if (data['customSearchApiUrl'] is String) {
      customSearchApiUrl = data['customSearchApiUrl'] as String;
    }
    if (data['customSearchApiKey'] is String) {
      customSearchApiKey = data['customSearchApiKey'] as String;
    }
    if (data['agentPrompt'] is String &&
        (data['agentPrompt'] as String).trim().isNotEmpty) {
      agentPrompt = (data['agentPrompt'] as String).trim();
    }
    if (data['dyjBtnClick'] is String) {
      dyjClickAction = HardwareButtonAction.fromCode(
        data['dyjBtnClick'] as String,
        fallback: HardwareButtonAction.mark,
      );
    }
    if (data['dyjBtnLong'] is String) {
      dyjLongPressAction = HardwareButtonAction.fromCode(
        data['dyjBtnLong'] as String,
        fallback: HardwareButtonAction.agentVoice,
      );
    }
    if (data['dyjBtnDouble'] is String) {
      dyjDoubleClickAction = HardwareButtonAction.fromCode(
        data['dyjBtnDouble'] as String,
        fallback: HardwareButtonAction.photoRecognize,
      );
    }
    if (data['cardBtnClick'] is String) {
      cardClickAction = HardwareButtonAction.fromCode(
        data['cardBtnClick'] as String,
        fallback: HardwareButtonAction.mark,
      );
    }
    if (data['cardBtnDouble'] is String) {
      cardDoubleClickAction = HardwareButtonAction.fromCode(
        data['cardBtnDouble'] as String,
        fallback: HardwareButtonAction.syncNow,
      );
    }
    if (data['cardBtnLong'] is String) {
      cardLongPressAction = HardwareButtonAction.fromCode(
        data['cardBtnLong'] as String,
        fallback: HardwareButtonAction.agentVoice,
      );
    }
    if (data['cardSwitchOn'] is String) {
      cardSwitchOnAction = HardwareButtonAction.fromCode(
        data['cardSwitchOn'] as String,
        fallback: HardwareButtonAction.recordStart,
      );
    }
    if (data['cardSwitchOff'] is String) {
      cardSwitchOffAction = HardwareButtonAction.fromCode(
        data['cardSwitchOff'] as String,
        fallback: HardwareButtonAction.recordStop,
      );
    }
    if (data['cardBtnUserConfigured'] is bool) {
      cardControlsUserConfigured = data['cardBtnUserConfigured'] as bool;
    }
    if (data['iphoneActionBehavior'] is String) {
      iphoneActionButtonBehavior = IphoneActionButtonBehavior.fromCode(
        data['iphoneActionBehavior'] as String,
      );
    }
    final storedModel = data['model'] is String
        ? (data['model'] as String).trim()
        : '';
    final pickedFlag = data['pickedModel'];
    final legacyExplicitPick =
        pickedFlag == null &&
        storedModel.isNotEmpty &&
        storedModel != 'deepseek-v3';
    if ((pickedFlag == true || legacyExplicitPick) && storedModel.isNotEmpty) {
      cloudModel = storedModel;
      userPickedCloudModel = true;
    } else {
      cloudModel = '';
      userPickedCloudModel = false;
    }
    if (data['gatewayModel'] is String) {
      gatewayModel = (data['gatewayModel'] as String).trim();
    }
    if (data['ctx'] == 'scoped' || data['ctx'] == 'full_day') {
      contextMode = data['ctx'] as String;
    }
    if (data['temp'] is num) {
      temperature = (data['temp'] as num).toDouble().clamp(0.0, 1.0);
    }
    if (data['cleanCycleMinutes'] is num) {
      cleanCycleMinutes = (data['cleanCycleMinutes'] as num).toInt().clamp(
        1,
        10080,
      );
    }
    if (data['cleanOnSilenceGap'] is bool) {
      cleanOnSilenceGap = data['cleanOnSilenceGap'] as bool;
    }
    if (data['cleanOverlapMode'] == 'paragraphs' ||
        data['cleanOverlapMode'] == 'minutes') {
      cleanOverlapMode = data['cleanOverlapMode'] as String;
    }
    if (data['cleanOverlapParagraphs'] is num) {
      cleanOverlapParagraphs = (data['cleanOverlapParagraphs'] as num)
          .toInt()
          .clamp(0, 10);
    }
    if (data['cleanOverlapMinutes'] is num) {
      cleanOverlapMinutes = (data['cleanOverlapMinutes'] as num).toInt().clamp(
        1,
        30,
      );
    }
    if (data['recordingSliceSeconds'] is num) {
      recordingSliceSeconds = (data['recordingSliceSeconds'] as num)
          .toInt()
          .clamp(60, 600);
    }
    if (data['healthSampleIntervalSeconds'] is num) {
      healthSampleIntervalSeconds = (data['healthSampleIntervalSeconds'] as num)
          .toInt()
          .clamp(60, 600);
    }
    if (data['healthSamplePhaseSeconds'] is num) {
      healthSamplePhaseSeconds = (data['healthSamplePhaseSeconds'] as num)
          .toInt()
          .clamp(0, healthSampleIntervalSeconds - 1);
    }
    if (data['preset'] is String && (data['preset'] as String).isNotEmpty) {
      presetId = data['preset'] as String;
    }
    final rawUserPresets = data['userPresets'];
    if (rawUserPresets is List) {
      userPresets = [
        for (final item in rawUserPresets)
          if (item is Map<String, dynamic>) AgentPresetSpec.fromJson(item),
      ].where((p) => p.id.isNotEmpty && p.label.trim().isNotEmpty).toList();
    }
    final rawPrompts = data['prompts'];
    if (rawPrompts is Map) {
      prompts = {
        ...prompts,
        for (final e in rawPrompts.entries)
          if (e.value is String) '${e.key}': e.value as String,
      };
    }
    final rawExt = data['ext'];
    if (rawExt is Map) {
      extensionStates = {
        ..._defaultExtensionStates,
        for (final e in rawExt.entries)
          if (e.value is bool) '${e.key}': e.value as bool,
      };
      if (data['photoLinkEnabled'] is! bool && rawExt['tl-photo'] is bool) {
        photoLinkEnabled = rawExt['tl-photo'] as bool;
      }
    }
    final rawCustom = data['customMcps'];
    if (rawCustom is List) {
      customMcps = [
        for (final item in rawCustom)
          if (item is Map<String, dynamic>) AgentExtensionItem.fromJson(item),
      ];
    }
    notifyListeners();
  }

  Future<void> setCloudEnabled(bool value) async {
    cloudEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setCustomApiBase(String url) async {
    customApiBase = url.trim().replaceFirst(RegExp(r'/+$'), '');
    notifyListeners();
    await _save();
  }

  Future<void> setDeveloperMode(bool value) async {
    developerMode = value;
    notifyListeners();
    await _save();
  }

  Future<void> setPhotoLinkEnabled(bool value) async {
    photoLinkEnabled = value;
    extensionStates = {...extensionStates, 'tl-photo': value};
    notifyListeners();
    await _save();
  }

  Future<void> setIslandEnabled(bool value) async {
    islandEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setWatchLinkEnabled(bool value) async {
    watchLinkEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setGetSeedLinkEnabled(bool value) async {
    getSeedLinkEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setOmiLinkEnabled(bool value) async {
    omiLinkEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setFeishuLinkEnabled(bool value) async {
    feishuLinkEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setHealthSignalEnabled(bool value) async {
    healthSignalEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setAgentWebSearchEnabled(bool value) async {
    agentWebSearchEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setAgentRecordSearchEnabled(bool value) async {
    agentRecordSearchEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setAgentHealthAccessEnabled(bool value) async {
    agentHealthAccessEnabled = value;
    notifyListeners();
    await _save();
  }

  Future<void> setCustomSearchApi({String? url, String? apiKey}) async {
    if (url != null) {
      customSearchApiUrl = url.trim().replaceFirst(RegExp(r'/+$'), '');
    }
    if (apiKey != null) {
      customSearchApiKey = apiKey.trim();
    }
    notifyListeners();
    await _save();
  }

  Future<void> setAgentPrompt(String text) async {
    final trimmed = text.trim();
    agentPrompt = trimmed.isEmpty ? defaultAgentPrompt : trimmed;
    notifyListeners();
    await _save();
  }

  Future<void> resetAgentPrompt() async {
    agentPrompt = defaultAgentPrompt;
    notifyListeners();
    await _save();
  }

  Future<void> setRecordingSliceSeconds(int seconds) async {
    recordingSliceSeconds = seconds.clamp(60, 600);
    notifyListeners();
    await _save();
  }

  Future<void> setHealthSampleIntervalSeconds(int seconds) async {
    healthSampleIntervalSeconds = seconds.clamp(60, 600);
    if (healthSamplePhaseSeconds >= healthSampleIntervalSeconds) {
      healthSamplePhaseSeconds = healthSampleIntervalSeconds - 1;
    }
    notifyListeners();
    await _save();
  }

  Future<void> setHealthSamplePhaseSeconds(int seconds) async {
    final maxPhase = healthSampleIntervalSeconds - 1;
    healthSamplePhaseSeconds = seconds.clamp(0, maxPhase);
    notifyListeners();
    await _save();
  }

  Future<void> setCloudModel(String id) async {
    final next = id.trim();
    if (next.isEmpty) {
      await clearCloudModelPick();
      return;
    }
    cloudModel = next;
    userPickedCloudModel = true;
    notifyListeners();
    await _save();
  }

  Future<void> clearCloudModelPick() async {
    cloudModel = '';
    userPickedCloudModel = false;
    notifyListeners();
    await _save();
  }

  Future<void> setContextMode(String mode) async {
    if (mode != 'full_day' && mode != 'scoped') return;
    contextMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> setTemperature(double value) async {
    temperature = value.clamp(0.0, 1.0);
    notifyListeners();
    await _save();
  }

  Future<void> setCleanCycleMinutes(int minutes) async {
    final next = minutes.clamp(1, 10080);
    if (next == cleanCycleMinutes) return;
    cleanCycleMinutes = next;
    notifyListeners();
    await _save();
  }

  Future<void> setCleanOnSilenceGap(bool value) async {
    cleanOnSilenceGap = value;
    notifyListeners();
    await _save();
  }

  Future<void> setCleanOverlapMode(String mode) async {
    if (mode != 'paragraphs' && mode != 'minutes') return;
    cleanOverlapMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> setCleanOverlapParagraphs(int count) async {
    cleanOverlapParagraphs = count.clamp(0, 10);
    notifyListeners();
    await _save();
  }

  Future<void> setCleanOverlapMinutes(int minutes) async {
    cleanOverlapMinutes = minutes.clamp(1, 30);
    notifyListeners();
    await _save();
  }

  Future<void> selectPreset(String id) async {
    final spec = presetById(id);
    if (spec == null) return;
    presetId = spec.id;
    prompts = _promptsFromPreset(spec);
    notifyListeners();
    await _save();
  }

  Future<void> savePrompt(String kind, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    prompts = {...prompts, kind: trimmed};
    final activeSpec = presetById(presetId);
    if (activeSpec != null && !activeSpec.builtin) {
      // 用户自定义预设：就地回写，支持「改」
      final idx = userPresets.indexWhere((p) => p.id == activeSpec.id);
      if (idx >= 0) {
        final cur = userPresets[idx];
        userPresets = [
          for (var i = 0; i < userPresets.length; i++)
            if (i == idx)
              cur.copyWith(
                summaryPrompt: kind == 'summary' ? trimmed : cur.summaryPrompt,
                polishPrompt: kind == 'polish' ? trimmed : cur.polishPrompt,
                dreamPrompt: kind == 'dream' ? trimmed : cur.dreamPrompt,
              )
            else
              userPresets[i],
        ];
      }
    } else if (activeSpec != null) {
      final expected = _promptsFromPreset(activeSpec)[kind];
      if (expected != trimmed) {
        presetId = 'custom';
      }
    } else {
      presetId = 'custom';
    }
    notifyListeners();
    await _save();
  }

  Future<void> resetPromptsToActivePreset() async {
    final spec = presetById(presetId) ?? builtinPresets.first;
    presetId = spec.id;
    prompts = _promptsFromPreset(spec);
    notifyListeners();
    await _save();
  }

  /// 新增用户预设（可基于当前提示词，也可空白拷贝通用纪要）。
  Future<AgentPresetSpec?> addUserPreset({
    required String label,
    String? summaryPrompt,
    String? polishPrompt,
    String? dreamPrompt,
  }) async {
    final clean = label.trim();
    if (clean.isEmpty) return null;
    final id = 'user-${DateTime.now().millisecondsSinceEpoch}';
    final base = builtinPresets.first;
    final created = AgentPresetSpec(
      id: id,
      label: clean,
      desc: '用户自定义风格',
      summaryPrompt: (summaryPrompt ?? prompts['summary'] ?? base.summaryPrompt)
          .trim(),
      polishPrompt: (polishPrompt ?? prompts['polish'] ?? base.polishPrompt)
          .trim(),
      dreamPrompt: (dreamPrompt ?? prompts['dream'] ?? base.dreamPrompt).trim(),
      builtin: false,
    );
    userPresets = [...userPresets, created];
    presetId = created.id;
    prompts = _promptsFromPreset(created);
    notifyListeners();
    await _save();
    return created;
  }

  Future<bool> renameUserPreset(String id, String label) async {
    final clean = label.trim();
    if (clean.isEmpty) return false;
    final idx = userPresets.indexWhere((p) => p.id == id);
    if (idx < 0) return false;
    userPresets = [
      for (var i = 0; i < userPresets.length; i++)
        if (i == idx) userPresets[i].copyWith(label: clean) else userPresets[i],
    ];
    notifyListeners();
    await _save();
    return true;
  }

  Future<bool> deleteUserPreset(String id) async {
    final before = userPresets.length;
    userPresets = userPresets.where((p) => p.id != id).toList();
    if (userPresets.length == before) return false;
    if (presetId == id) {
      final fallback = builtinPresets.first;
      presetId = fallback.id;
      prompts = _promptsFromPreset(fallback);
    }
    notifyListeners();
    await _save();
    return true;
  }

  /// 将当前提示词写回已选用户预设；若当前是内置/匿名自定义，则另存为新预设。
  Future<AgentPresetSpec?> saveCurrentAsPreset({String? newLabel}) async {
    final active = presetById(presetId);
    if (active != null && !active.builtin) {
      final idx = userPresets.indexWhere((p) => p.id == active.id);
      if (idx >= 0) {
        final cur = userPresets[idx];
        userPresets = [
          for (var i = 0; i < userPresets.length; i++)
            if (i == idx)
              cur.copyWith(
                summaryPrompt: prompts['summary'] ?? cur.summaryPrompt,
                polishPrompt: prompts['polish'] ?? cur.polishPrompt,
                dreamPrompt: prompts['dream'] ?? cur.dreamPrompt,
              )
            else
              userPresets[i],
        ];
        notifyListeners();
        await _save();
        return userPresets[idx];
      }
    }
    final label =
        (newLabel ?? (active == null ? '自定义风格' : '${active.label} 改')).trim();
    return addUserPreset(label: label.isEmpty ? '自定义风格' : label);
  }

  Future<void> toggleExtension(String id) async {
    final next = !isExtensionOn(id);
    extensionStates = {...extensionStates, id: next};
    if (id == 'tl-photo') {
      photoLinkEnabled = next;
    }
    notifyListeners();
    await _save();
  }

  Future<void> addCustomMcp({
    required String name,
    required String endpoint,
  }) async {
    final cleanName = name.trim();
    final cleanEndpoint = endpoint.trim();
    if (cleanName.isEmpty || cleanEndpoint.isEmpty) return;
    final id = 'mcp-custom-${DateTime.now().millisecondsSinceEpoch}';
    final item = AgentExtensionItem(
      id: id,
      kind: 'mcp',
      title: cleanName,
      subtitle: cleanEndpoint,
      custom: true,
      wiring: 'placeholder',
      wiringNote: '未接入：只保存在本机列表，当前清洗和总结不会调用这个服务。',
    );
    customMcps = [...customMcps, item];
    extensionStates = {...extensionStates, id: true};
    notifyListeners();
    await _save();
  }

  Future<void> removeCustomMcp(String id) async {
    customMcps = customMcps.where((m) => m.id != id).toList();
    final nextStates = Map<String, bool>.of(extensionStates)..remove(id);
    extensionStates = nextStates;
    notifyListeners();
    await _save();
  }

  Future<void> setPreferredAsrEngine(String? mode) async {
    final normalized = (mode == 'system' || mode == 'sensevoice') ? mode : null;
    if (preferredAsrEngine == normalized) return;
    preferredAsrEngine = normalized;
    notifyListeners();
    await _save();
  }

  Future<void> setDyjButtonAction(
    String gesture,
    HardwareButtonAction action,
  ) async {
    var changed = false;
    switch (gesture) {
      case 'click':
        if (dyjClickAction != action) {
          dyjClickAction = action;
          changed = true;
        }
      case 'long_press':
        if (dyjLongPressAction != action) {
          dyjLongPressAction = action;
          changed = true;
        }
      case 'double_click':
        if (dyjDoubleClickAction != action) {
          dyjDoubleClickAction = action;
          changed = true;
        }
    }
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  Future<void> setCardControlAction(
    String input,
    HardwareButtonAction action,
  ) async {
    var changed = !cardControlsUserConfigured;
    cardControlsUserConfigured = true;
    switch (input) {
      case 'click':
        if (cardClickAction != action) {
          cardClickAction = action;
          changed = true;
        }
      case 'double_click':
        if (cardDoubleClickAction != action) {
          cardDoubleClickAction = action;
          changed = true;
        }
      case 'long_press':
        if (cardLongPressAction != action) {
          cardLongPressAction = action;
          changed = true;
        }
      case 'switch_on':
        if (cardSwitchOnAction != action) {
          cardSwitchOnAction = action;
          changed = true;
        }
      case 'switch_off':
        if (cardSwitchOffAction != action) {
          cardSwitchOffAction = action;
          changed = true;
        }
    }
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  Future<void> resetCardControlDefaults() async {
    final changed =
        cardClickAction != HardwareButtonAction.mark ||
        cardDoubleClickAction != HardwareButtonAction.syncNow ||
        cardLongPressAction != HardwareButtonAction.agentVoice ||
        cardSwitchOnAction != HardwareButtonAction.recordStart ||
        cardSwitchOffAction != HardwareButtonAction.recordStop ||
        cardControlsUserConfigured;
    cardClickAction = HardwareButtonAction.mark;
    cardDoubleClickAction = HardwareButtonAction.syncNow;
    cardLongPressAction = HardwareButtonAction.agentVoice;
    cardSwitchOnAction = HardwareButtonAction.recordStart;
    cardSwitchOffAction = HardwareButtonAction.recordStop;
    cardControlsUserConfigured = false;
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  /// 从已连接录音卡回读既有绑定到 UI，保持 App 展示与设备真实 KV 一致。
  Future<void> syncCardBindingsFromDevice(Map<String, dynamic> raw) async {
    final nextClick = HardwareButtonAction.fromCardFirmwareWire(
      raw['btnSingle'] as String?,
    );
    final nextDouble = HardwareButtonAction.fromCardFirmwareWire(
      raw['btnDouble'] as String?,
    );
    final nextLong = HardwareButtonAction.fromCardFirmwareWire(
      raw['btnLongPress'] as String?,
    );
    final nextSwitchOn = HardwareButtonAction.fromCardFirmwareWire(
      raw['switchOn'] as String?,
    );
    final nextSwitchOff = HardwareButtonAction.fromCardFirmwareWire(
      raw['switchOff'] as String?,
    );
    final changed =
        cardClickAction != nextClick ||
        cardDoubleClickAction != nextDouble ||
        cardLongPressAction != nextLong ||
        cardSwitchOnAction != nextSwitchOn ||
        cardSwitchOffAction != nextSwitchOff ||
        !cardControlsUserConfigured;
    cardClickAction = nextClick;
    cardDoubleClickAction = nextDouble;
    cardLongPressAction = nextLong;
    cardSwitchOnAction = nextSwitchOn;
    cardSwitchOffAction = nextSwitchOff;
    cardControlsUserConfigured = true;
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  Future<void> setIphoneActionButtonBehavior(
    IphoneActionButtonBehavior next,
  ) async {
    if (iphoneActionButtonBehavior == next) return;
    iphoneActionButtonBehavior = next;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    await _json.write(_storageKey, {
      'cloudEnabled': cloudEnabled,
      if (customApiBase.isNotEmpty) 'customApiBase': customApiBase,
      if (developerMode) 'devMode': developerMode,
      'photoLinkEnabled': photoLinkEnabled,
      'islandEnabled': islandEnabled,
      'watchLinkEnabled': watchLinkEnabled,
      'getSeedLinkEnabled': getSeedLinkEnabled,
      'omiLinkEnabled': omiLinkEnabled,
      'feishuLinkEnabled': feishuLinkEnabled,
      'healthSignalEnabled': healthSignalEnabled,
      if (preferredAsrEngine != null) 'asrEngine': preferredAsrEngine,
      'agentWebSearchEnabled': agentWebSearchEnabled,
      'agentRecordSearchEnabled': agentRecordSearchEnabled,
      'agentHealthAccessEnabled': agentHealthAccessEnabled,
      if (customSearchApiUrl.isNotEmpty)
        'customSearchApiUrl': customSearchApiUrl,
      if (customSearchApiKey.isNotEmpty)
        'customSearchApiKey': customSearchApiKey,
      if (agentPrompt != defaultAgentPrompt) 'agentPrompt': agentPrompt,
      'dyjBtnClick': dyjClickAction.code,
      'dyjBtnLong': dyjLongPressAction.code,
      'dyjBtnDouble': dyjDoubleClickAction.code,
      'cardBtnClick': cardClickAction.code,
      'cardBtnDouble': cardDoubleClickAction.code,
      'cardBtnLong': cardLongPressAction.code,
      'cardSwitchOn': cardSwitchOnAction.code,
      'cardSwitchOff': cardSwitchOffAction.code,
      if (cardControlsUserConfigured) 'cardBtnUserConfigured': true,
      'iphoneActionBehavior': iphoneActionButtonBehavior.code,
      'recordingSliceSeconds': recordingSliceSeconds,
      'healthSampleIntervalSeconds': healthSampleIntervalSeconds,
      'healthSamplePhaseSeconds': healthSamplePhaseSeconds,
      if (userPickedCloudModel && cloudModel.trim().isNotEmpty)
        'model': cloudModel,
      'pickedModel': userPickedCloudModel,
      if (gatewayModel.trim().isNotEmpty) 'gatewayModel': gatewayModel,
      'ctx': contextMode,
      'temp': temperature,
      'cleanCycleMinutes': cleanCycleMinutes,
      'cleanOnSilenceGap': cleanOnSilenceGap,
      'cleanOverlapMode': cleanOverlapMode,
      'cleanOverlapParagraphs': cleanOverlapParagraphs,
      'cleanOverlapMinutes': cleanOverlapMinutes,
      'preset': presetId,
      'prompts': prompts,
      if (userPresets.isNotEmpty)
        'userPresets': [for (final p in userPresets) p.toJson()],
      'ext': extensionStates,
      if (customMcps.isNotEmpty)
        'customMcps': [for (final m in customMcps) m.toJson()],
    });
  }
}
