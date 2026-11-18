/// 总结生成 —— 把选中的录音转写交给模型网关，产出结构化总结。
///
/// 输出契约（严格 JSON，便于界面稳定渲染）：
/// ```json
/// {
///   "title": "一句话标题",
///   "overview": "一段概览",
///   "structure": [{"name": "分支名", "leaves": ["要点", "要点"]}],
///   "points": [{"title": "信息点", "detail": "细节", "sources": ["记录id"]}],
///   "todos": ["行动项"]
/// }
/// ```
/// 模型偶尔会包 ```json 代码块或多说一句话，这里做容错抽取；抽不出来就抛
/// [SummaryGenerationException]，**不编造内容**——界面呈现失败与重试。
library;

import 'dart:convert';

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import '../../core/store/agent_config_store.dart';
import '../net/model_gateway.dart';

class SummaryGenerationException implements Exception {
  const SummaryGenerationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 生成结果（界面直接映射到 SummaryCard 的字段）。
class SummaryDraft {
  const SummaryDraft({
    required this.title,
    required this.overview,
    required this.structure,
    required this.points,
    required this.todos,
    required this.markdown,
    this.fullText = '',
  });

  final String title;
  final String overview;
  final List<MapBranch> structure;
  final List<InfoPoint> points;
  final List<String> todos;
  final String markdown;
  final String fullText;
}

class SummaryGenerator {
  SummaryGenerator({
    required ModelGateway gateway,
    AgentConfigStore? agentConfig,
  }) : _gateway = gateway,
       _agentConfig = agentConfig;

  final ModelGateway _gateway;
  final AgentConfigStore? _agentConfig;

  /// 是否可以发起生成（配置齐全且已登录）。
  bool get ready => _gateway.ready;

  bool get configured => _gateway.chatAvailable;

  String? _resolveModelOverride() {
    final cfg = _agentConfig;
    if (cfg == null || !cfg.userPickedCloudModel) {
      return null;
    }
    final picked = cfg.cloudModel.trim();
    if (picked.isEmpty) return null;
    final gatewayTextModels = _gateway.discoveredTextModels;
    if (gatewayTextModels.isNotEmpty && !gatewayTextModels.contains(picked)) {
      // 若网关公布了白名单且所选不在白名单内，优先尝试所选或回退网关默认，避免硬编码失败
      return picked;
    }
    return picked;
  }

  String _buildSystemPrompt() {
    final cfg = _agentConfig;
    if (cfg == null) return _instruction;
    final rolePrompt = cfg.promptFor('summary').trim();
    final skillLines = cfg.enabledSkillRules;
    final buffer = StringBuffer()
      ..writeln(rolePrompt.isEmpty ? _defaultRolePrompt : rolePrompt);
    if (skillLines.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('已启用的整理技能约束：');
      for (final rule in skillLines) {
        buffer.writeln('- $rule');
      }
    }
    buffer
      ..writeln()
      ..write(_jsonSchemaContract);
    return buffer.toString();
  }

  /// 生成总结。
  ///
  /// [onProgress] 汇报真实阶段（准备 → 请求模型 → 解析），不做假动画。
  Future<SummaryDraft> generate(
    List<RecordEvent> events, {
    void Function(double progress, String step)? onProgress,
    String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
  }) async {
    if (events.isEmpty) {
      throw const SummaryGenerationException('没有可总结的记录');
    }
    if (!_gateway.isCloudEnabled) {
      throw const SummaryGenerationException('已在设置中关闭云端模型');
    }
    if (!configured) {
      throw const SummaryGenerationException('未配置总结服务，暂时无法生成');
    }
    if (!ready) {
      throw const SummaryGenerationException('登录后才能生成总结');
    }

    onProgress?.call(0.05, '解析来源内容…');
    final ordered = sortEventsChronological(events);
    final transcript = _buildTranscript(
      ordered,
      speakerResolver: speakerResolver,
    );
    if (transcript.trim().isEmpty) {
      throw const SummaryGenerationException('所选记录还没有转写内容');
    }

    onProgress?.call(0.25, '提炼要点与逻辑…');
    final temp = (_agentConfig != null && _agentConfig.developerMode)
        ? _agentConfig.temperature
        : 0.2;
    final raw = await _gateway.chat(
      [
        ChatMessage.system(_buildSystemPrompt()),
        ChatMessage.user(transcript),
      ],
      model: _resolveModelOverride(),
      temperature: temp,
      // 输出含结构化字段与润色全文，随来源条数给足余量但不无上限
      maxTokens: (2400 + ordered.length * 600).clamp(2400, 8192),
      timeout: const Duration(seconds: 120),
    );

    onProgress?.call(0.9, '整理结构、全文与行动项…');
    final draft = _parse(
      raw,
      ordered,
      speakerResolver: speakerResolver,
    );
    onProgress?.call(1, '完成');
    return draft;
  }

  static const String _defaultRolePrompt =
      '你是录音整理助手。用户会给你按时间顺序排列的若干条录音转写文本，每条以「[记录id] 标题（时间）」开头。'
      '请把它们整理成结构化总结与完整润色全文，只依据原文内容，不要编造原文没有的事实。';

  static const String _jsonSchemaContract = '''
只输出一个 JSON 对象，不要任何解释文字、不要 Markdown 代码块，字段如下：
{
  "title": "总结标题，不超过 20 字",
  "overview": "一段话概览，2-3 句",
  "structure": [{"name": "主题分组名", "leaves": ["要点1", "要点2"]}],
  "points": [{"title": "信息点标题", "detail": "细节说明", "sources": ["对应的记录id"]}],
  "todos": ["可执行的行动项"],
  "fullText": "按时间顺序把各段来源记录拼接整理为一篇连续通顺的润色全文：尽量完整保留原意、细节与说话人归属，仅去除口水词并修正同音错别字，不要缩写成摘要"
}
要求：structure 与 points 至少各一条；points 的 sources 只能使用我给你出现过的记录 id；
行动项来自原文的待办或承诺，没有就返回空数组；fullText 为完整润色拼接文本，保留说话人名称。''';

  static const String _instruction = '$_defaultRolePrompt\n\n$_jsonSchemaContract';

  String _buildTranscript(
    List<RecordEvent> events, {
    String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
  }) {
    final buffer = StringBuffer();
    for (final e in events) {
      buffer.writeln('[${e.id}] ${e.title}（${e.time}）');
      final body = e.longText.trim().isEmpty ? e.brief : e.longText;
      buffer.writeln(body.isEmpty ? '（无转写内容）' : body);
      // 润色后的对话是总结与全文的最可靠依据；原文过长时只带摘要，避免超上下文
      if (e.dialog.isNotEmpty) {
        final dialog = [
          for (final t in e.dialog)
            '${speakerResolver?.call(e, t.spk) ?? t.spk}：${t.text}',
        ].join('\n');
        if (dialog.length <= 6000) {
          buffer.writeln('对话：');
          buffer.writeln(dialog);
        }
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  SummaryDraft _parse(
    String raw,
    List<RecordEvent> events, {
    String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
  }) {
    final jsonText = _extractJson(raw);
    if (jsonText == null) {
      throw const SummaryGenerationException('总结结果格式异常，请重试');
    }
    late final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw const SummaryGenerationException('总结结果格式异常，请重试');
      }
      json = decoded;
    } on FormatException {
      throw const SummaryGenerationException('总结结果解析失败，请重试');
    }

    final title = _str(json['title'], fallback: '要点小结');
    final overview = _str(json['overview']);

    final structure = <MapBranch>[];
    for (final b in _list(json['structure'])) {
      if (b is! Map) continue;
      final name = _str(b['name']);
      final leaves = [
        for (final l in _list(b['leaves']))
          if (l != null) '$l',
      ];
      if (name.isEmpty && leaves.isEmpty) continue;
      structure.add(MapBranch(name.isEmpty ? '要点' : name, leaves));
    }

    final byId = {for (final e in events) e.id: e};
    final points = <InfoPoint>[];
    for (final p in _list(json['points'])) {
      if (p is! Map) continue;
      final pointTitle = _str(p['title']);
      if (pointTitle.isEmpty) continue;
      final refs = <SourceRef>[];
      for (final s in _list(p['sources'])) {
        final id = '$s';
        final event = byId[id];
        if (event == null) continue; // 模型幻觉出的 id 直接丢弃
        refs.add(
          SourceRef(event.id, event.title, '${event.time} · ${event.dur}'),
        );
      }
      points.add(InfoPoint(pointTitle, _str(p['detail']), refs));
    }

    final todos = [
      for (final t in _list(json['todos']))
        if ('$t'.trim().isNotEmpty) '$t'.trim(),
    ];

    final parsedFullText = _str(json['fullText']).trim();
    final fullText = parsedFullText.isNotEmpty
        ? parsedFullText
        : stitchPolishedFullText(events, speakerResolver: speakerResolver);

    return SummaryDraft(
      title: title,
      overview: overview,
      structure: structure,
      points: points,
      todos: todos,
      fullText: fullText,
      markdown: _markdown(
        title,
        overview,
        structure,
        points,
        todos,
        fullText,
        events,
      ),
    );
  }

  /// 从模型输出里抽出第一个完整 JSON 对象（容错：代码块包裹、前后有废话）。
  static String? _extractJson(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    // 去 ```json ... ``` 围栏
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    final candidate = fence?.group(1)?.trim() ?? text;
    final start = candidate.indexOf('{');
    if (start < 0) return null;
    // 括号配对，避免把后面的说明文字也切进来
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < candidate.length; i++) {
      final ch = candidate[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return candidate.substring(start, i + 1);
      }
    }
    return null;
  }

  static String _str(Object? value, {String fallback = ''}) {
    if (value is String) return value.trim();
    if (value == null) return fallback;
    return '$value'.trim();
  }

  static List<Object?> _list(Object? value) =>
      value is List ? value : const <Object?>[];

  static String _markdown(
    String title,
    String overview,
    List<MapBranch> structure,
    List<InfoPoint> points,
    List<String> todos,
    String fullText,
    List<RecordEvent> events,
  ) {
    final b = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('## 概览')
      ..writeln(overview)
      ..writeln()
      ..writeln('## 逻辑结构');
    for (final branch in structure) {
      b.writeln('- ${branch.name}');
      for (final leaf in branch.leaves) {
        b.writeln('  - $leaf');
      }
    }
    b
      ..writeln()
      ..writeln('## 信息点');
    for (final p in points) {
      b.writeln('- **${p.title}**：${p.detail}');
      for (final s in p.sources) {
        b.writeln('  - 来源：${s.label} · ${s.range}');
      }
    }
    b
      ..writeln()
      ..writeln('## 行动项');
    if (todos.isEmpty) {
      b.writeln('- （无）');
    } else {
      for (final t in todos) {
        b.writeln('- [ ] $t');
      }
    }
    if (fullText.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('## 全文（AI 智能优化版）')
        ..writeln(fullText.trim());
    }
    b
      ..writeln()
      ..writeln('## 来源记录');
    for (final e in events) {
      b.writeln('- ${e.title} · ${e.time}（${e.dur}）');
    }
    return b.toString();
  }
}
