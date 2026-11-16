/// Agent 与云端模型设置状态机 —— 模型选择、上下文策略、温度、预设与提示词、Skills/Tools/MCP 扩展。
///
/// 持久化走 [JsonStore]（键 `agent_v1`），修改即时落盘并通知监听方（Setting 摘要与
/// [SummaryGenerator] 实时读取最新配置）。
library;

import 'package:flutter/foundation.dart';

import '../storage/storage.dart';

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

  const AgentPresetSpec({
    required this.id,
    required this.label,
    required this.desc,
    required this.summaryPrompt,
    required this.polishPrompt,
    required this.dreamPrompt,
  });
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

  static const List<AgentPresetSpec> presets = [
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

  bool cloudEnabled = true;
  String customApiBase = '';
  bool developerMode = false;
  bool photoLinkEnabled = true;
  bool islandEnabled = true;
  bool watchLinkEnabled = false;
  bool getSeedLinkEnabled = false;
  bool omiLinkEnabled = false;

  /// 行为与健康信号总开关。默认关闭；打开后才申请系统权限并在本机采集。
  bool healthSignalEnabled = false;

  int get enabledExtHardwareCount =>
      (getSeedLinkEnabled ? 1 : 0) + (omiLinkEnabled ? 1 : 0);

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

  String presetId =
      'general'; // 'general' | 'meeting' | 'interview' | 'todo' | 'custom'
  late Map<String, String> prompts = _promptsFromPreset(presets.first);

  Map<String, bool> extensionStates = Map<String, bool>.of(
    _defaultExtensionStates,
  );
  List<AgentExtensionItem> customMcps = const [];

  List<String> _gatewayModels = const [];

  static Map<String, String> _promptsFromPreset(AgentPresetSpec p) => {
    'summary': p.summaryPrompt,
    'polish': p.polishPrompt,
    'dream': p.dreamPrompt,
  };

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
    return presets.where((p) => p.id == presetId).firstOrNull?.label ?? '通用纪要';
  }

  String promptFor(String kind) => prompts[kind] ?? presets.first.summaryPrompt;

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
    if (data['healthSignalEnabled'] is bool) {
      healthSignalEnabled = data['healthSignalEnabled'] as bool;
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

  Future<void> setHealthSignalEnabled(bool value) async {
    healthSignalEnabled = value;
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
    final spec = presets.where((p) => p.id == id).firstOrNull;
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
    final activeSpec = presets.where((p) => p.id == presetId).firstOrNull;
    if (activeSpec != null) {
      final expected = _promptsFromPreset(activeSpec)[kind];
      if (expected != trimmed) {
        presetId = 'custom';
      }
    }
    notifyListeners();
    await _save();
  }

  Future<void> resetPromptsToActivePreset() async {
    final spec =
        presets.where((p) => p.id == presetId).firstOrNull ?? presets.first;
    presetId = spec.id;
    prompts = _promptsFromPreset(spec);
    notifyListeners();
    await _save();
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
      'healthSignalEnabled': healthSignalEnabled,
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
      'ext': extensionStates,
      if (customMcps.isNotEmpty)
        'customMcps': [for (final m in customMcps) m.toJson()],
    });
  }
}
