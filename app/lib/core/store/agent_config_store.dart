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

  const AgentExtensionItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.promptRule,
    this.custom = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'subtitle': subtitle,
    if (promptRule != null) 'rule': promptRule,
    if (custom) 'custom': true,
  };

  factory AgentExtensionItem.fromJson(Map<String, dynamic> j) =>
      AgentExtensionItem(
        id: '${j['id'] ?? ''}',
        kind: '${j['kind'] ?? 'mcp'}',
        title: '${j['title'] ?? ''}',
        subtitle: '${j['subtitle'] ?? ''}',
        promptRule: j['rule'] as String?,
        custom: j['custom'] == true,
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
      desc: '中文长文本提炼均衡，适合日常全天录音与通用总结（推荐）',
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
      summaryPrompt:
          '你是录音整理助手。请基于所给录音转写整理结构化纪要：先给 2-3 句概览，再按讨论脉络归纳逻辑结构，提炼关键信息点并严格标注来源记录 ID，最后提取明确的行动项；不编造原文没有的事实。',
      polishPrompt:
          '清理口头禅、重复词与语气助词，合并同一说话人被打断的连续短句，保留专业术语、数字、人名与原始语义，不改写观点倾向。',
      dreamPrompt:
          '日终复盘全天对话脉络，清洗碎片化口语记忆，归档值得长期保留的知识条目，并提炼可复用的个人沟通与决策洞察。',
    ),
    AgentPresetSpec(
      id: 'meeting',
      label: '深度会议',
      desc: '聚焦会议决策、分歧拉齐、责任人与截止时间',
      summaryPrompt:
          '你是高管会议纪要专家。请聚焦会议决策、核心争议与达成共识的条件，按议题拆解逻辑分支，将所有结论与承诺关联到来源记录 ID，并在行动项中明确事项与时间节点。',
      polishPrompt:
          '按会议发言轮次清洗口语冗余，突出方案对比、指标口径与排期表态，完整保留原话中的条件限定词。',
      dreamPrompt:
          '汇总当日多场会议之间的跨议题关联、未闭环阻塞项与次日优先跟进清单。',
    ),
    AgentPresetSpec(
      id: 'interview',
      label: '访谈提炼',
      desc: '保留受访者核心洞察、真实案例与代表性原话',
      summaryPrompt:
          '你是用户研究与深度访谈分析师。请提炼受访者的核心痛点、使用场景、决策动机与反直觉洞察，在信息点中保留最具代表性的细节与来源溯源。',
      polishPrompt:
          '温和去噪，保留受访者的情绪转折、程度副词与具体故事细节，不把鲜活表达压缩成空洞套话。',
      dreamPrompt:
          '将当日访谈所得归档为结构化洞察卡片，关联既有研究假设并标记新发现的反例。',
    ),
    AgentPresetSpec(
      id: 'todo',
      label: '极简待办',
      desc: '压缩背景叙述，优先输出结论与可执行清单',
      summaryPrompt:
          '你是极简行动派助手。概览控制在两句话以内，逻辑结构只列最终结论，信息点只保留硬数字与硬约束，重点输出可直接勾选执行的行动项列表。',
      polishPrompt:
          '精简寒暄与发散闲聊，高密度保留指令、承诺、数字与时间点。',
      dreamPrompt:
          '仅归档今日已完成闭环与明日必做三件事，保持零噪音。',
    ),
  ];

  static const List<AgentExtensionItem> builtinExtensions = [
    AgentExtensionItem(
      id: 'sk-term',
      kind: 'skill',
      title: '术语统一与实体对齐',
      subtitle: '自动对齐同音异写的产品名、技术缩写与项目代号',
      promptRule: '对同音误识的专业术语、缩写与项目代号结合上下文做一致性对齐，不确定时保留原词。',
    ),
    AgentExtensionItem(
      id: 'sk-brief',
      kind: 'skill',
      title: '结论前置与纪要精简',
      subtitle: '每个分支与信息点先给结论，再补充支撑细节',
      promptRule: '概览与每个信息点均采用「结论前置」写法，避免冗长铺垫。',
    ),
    AgentExtensionItem(
      id: 'sk-risk',
      kind: 'skill',
      title: '风险与待决阻塞提炼',
      subtitle: '单独识别对话中提到的风险、依赖阻塞与未决问题',
      promptRule: '专门检查并标注对话中暴露的排期风险、外部依赖阻塞与尚未拍板的待决项。',
    ),
    AgentExtensionItem(
      id: 'tl-photo',
      kind: 'tool',
      title: '关联录音时段照片',
      subtitle: '总结时感知录音窗口内的点一机抓拍与系统相册照片数量',
    ),
    AgentExtensionItem(
      id: 'tl-hist',
      kind: 'tool',
      title: '同日连续上下文感知',
      subtitle: '结合同日早些时候的录音片段理解代词与省略背景',
    ),
    AgentExtensionItem(
      id: 'tl-todo',
      kind: 'tool',
      title: '结构化行动项提取',
      subtitle: '从承诺与排期语句中提取可勾选待办事项',
    ),
    AgentExtensionItem(
      id: 'mcp-kb',
      kind: 'mcp',
      title: '个人知识库 MCP',
      subtitle: 'local://knowledge-vault · 日报与做梦归档接口（规划接入）',
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

  int get enabledExtHardwareCount =>
      (getSeedLinkEnabled ? 1 : 0) + (omiLinkEnabled ? 1 : 0);

  String cloudModel = 'deepseek-v3';
  bool userPickedCloudModel = false;
  String contextMode = 'full_day'; // 'full_day' | 'scoped'
  double temperature = 0.2;

  String get cloudStatusSummary {
    if (!cloudEnabled) return '已关闭';
    if (developerMode) return cloudModel;
    if (customApiBase.trim().isNotEmpty) return '已开启 · 自定义接口';
    return '已开启';
  }

  String presetId = 'general'; // 'general' | 'meeting' | 'interview' | 'todo' | 'custom'
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

  /// 同步网关探测到的真实可用文本模型列表；若用户尚未手动指定，默认对齐到网关首选模型。
  void syncGatewayModels(List<String> models, {String? primaryTextModel}) {
    _gatewayModels = List<String>.unmodifiable(models);
    if (!userPickedCloudModel &&
        primaryTextModel != null &&
        primaryTextModel.trim().isNotEmpty) {
      cloudModel = primaryTextModel.trim();
    }
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

  String promptFor(String kind) =>
      prompts[kind] ?? presets.first.summaryPrompt;

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
    if (data['model'] is String && (data['model'] as String).isNotEmpty) {
      cloudModel = data['model'] as String;
    }
    userPickedCloudModel = data['pickedModel'] == true;
    if (data['ctx'] == 'scoped' || data['ctx'] == 'full_day') {
      contextMode = data['ctx'] as String;
    }
    if (data['temp'] is num) {
      temperature = (data['temp'] as num).toDouble().clamp(0.0, 1.0);
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

  Future<void> setCloudModel(String id) async {
    cloudModel = id.trim();
    userPickedCloudModel = true;
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
      'model': cloudModel,
      'pickedModel': userPickedCloudModel,
      'ctx': contextMode,
      'temp': temperature,
      'preset': presetId,
      'prompts': prompts,
      'ext': extensionStates,
      if (customMcps.isNotEmpty)
        'customMcps': [for (final m in customMcps) m.toJson()],
    });
  }
}
