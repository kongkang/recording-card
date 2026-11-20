/// 总结生成 —— 把选中的录音转写交给模型网关，产出结构化总结。
///
/// 输出契约（严格 JSON，便于界面稳定渲染；全文直接由端侧已润色对话拼接，避免模型重复吐全文导致截断或慢响应）：
/// ```json
/// {
///   "title": "一句话标题",
///   "overview": "概览（简短备忘 1 句，长记录 2-3 句）",
///   "structure": [{"name": "分支名", "leaves": ["要点"]}],
///   "points": [{"title": "信息点", "detail": "细节", "sources": ["记录id"]}],
///   "todos": ["行动项"]
/// }
/// ```
/// 当多条/超长记录总输入超过阈值（默认 16,000 字）时，自动启用按时间顺序切批的
/// Map-Reduce 两阶段保真汇总，完整保留各批数字、金额、日期、说话人承诺与 `[记录id]`。
library;

import 'dart:convert';
import 'dart:math' as math;

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
    int mapReduceTriggerChars = 16000,
    int mapBatchTargetChars = 12000,
  }) : _gateway = gateway,
       _agentConfig = agentConfig,
       _mapReduceTriggerChars = math.max(2000, mapReduceTriggerChars),
       _mapBatchTargetChars = math.max(1500, mapBatchTargetChars);

  final ModelGateway _gateway;
  final AgentConfigStore? _agentConfig;
  final int _mapReduceTriggerChars;
  final int _mapBatchTargetChars;

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
      return picked;
    }
    return picked;
  }

  String _buildSystemPrompt({bool isReduce = false}) {
    final cfg = _agentConfig;
    final customRole = cfg?.promptFor('summary').trim() ?? '';
    final skillLines = cfg?.enabledSkillRules ?? const <String>[];
    final baseRole = customRole.isNotEmpty
        ? customRole
        : (isReduce ? _reduceRolePrompt : _defaultRolePrompt);

    final buffer = StringBuffer()..writeln(baseRole);
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

  String _buildMapPrompt() {
    final skillLines = _agentConfig?.enabledSkillRules ?? const <String>[];
    final buffer = StringBuffer()..writeln(_mapRolePrompt);
    if (skillLines.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('整理技能约束：');
      for (final rule in skillLines) {
        buffer.writeln('- $rule');
      }
    }
    return buffer.toString();
  }

  /// 生成总结。
  ///
  /// [onProgress] 汇报真实阶段（准备 → 分批提炼/请求模型 → 解析），不做假动画。
  Future<SummaryDraft> generate(
    List<RecordEvent> events, {
    void Function(double progress, String step)? onProgress,
    String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
    bool Function()? isCancelled,
  }) async {
    void checkCancelled() {
      if (isCancelled?.call() == true) {
        throw const SummaryGenerationException('已取消总结生成');
      }
    }

    if (events.isEmpty) {
      throw const SummaryGenerationException('没有可总结的记录');
    }
    final orderedAll = sortEventsChronological(events);
    final ordered = orderedAll
        .where((e) => !isSilentPlaceholderEvent(e))
        .toList(growable: false);
    if (ordered.isEmpty) {
      throw const SummaryGenerationException('所选记录均为静音片段，暂无可总结的语音内容');
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

    checkCancelled();
    onProgress?.call(0.05, '解析来源内容…');

    final blocks = _buildEventBlocks(ordered, speakerResolver: speakerResolver);
    final totalChars = blocks.fold<int>(0, (sum, b) => sum + b.formatted.length);
    if (blocks.isEmpty || totalChars == 0) {
      throw const SummaryGenerationException('所选记录还没有转写内容');
    }

    final temp = (_agentConfig != null && _agentConfig.developerMode)
        ? _agentConfig.temperature
        : 0.2;
    final modelOverride = _resolveModelOverride();

    final needsMapReduce =
        totalChars > _mapReduceTriggerChars ||
        blocks.any((b) => b.formatted.length > _mapReduceTriggerChars);

    late final String raw;
    if (!needsMapReduce) {
      onProgress?.call(0.25, '提炼要点与逻辑…');
      final transcript = blocks.map((b) => b.formatted).join('\n');
      raw = await _gateway.chat(
        [
          ChatMessage.system(_buildSystemPrompt()),
          ChatMessage.user(transcript),
        ],
        model: modelOverride,
        temperature: temp,
        maxTokens: (1800 + ordered.length * 250).clamp(1800, 4096),
        timeout: const Duration(seconds: 120),
      );
      checkCancelled();
      onProgress?.call(0.90, '整理结构与行动项…');
    } else {
      raw = await _runMapReduce(
        ordered: ordered,
        blocks: blocks,
        model: modelOverride,
        temperature: temp,
        onProgress: onProgress,
        checkCancelled: checkCancelled,
      );
    }

    final draft = _parse(
      raw,
      ordered,
      speakerResolver: speakerResolver,
    );
    onProgress?.call(1, '完成');
    return draft;
  }

  Future<String> _runMapReduce({
    required List<RecordEvent> ordered,
    required List<_FormattedEventBlock> blocks,
    required String? model,
    required double temperature,
    required void Function(double progress, String step)? onProgress,
    required void Function() checkCancelled,
  }) async {
    final batches = _chunkIntoMapBatches(blocks, targetChars: _mapBatchTargetChars);
    final mapSystem = _buildMapPrompt();
    var digests = <String>[];

    for (var i = 0; i < batches.length; i++) {
      checkCancelled();
      final startProg = 0.10 + (0.60 * i / batches.length);
      onProgress?.call(
        double.parse(startProg.toStringAsFixed(3)),
        '分段提炼第 ${i + 1}/${batches.length} 批记录…',
      );
      final digest = await _gateway.chat(
        [
          ChatMessage.system(mapSystem),
          ChatMessage.user(batches[i]),
        ],
        model: model,
        temperature: temperature,
        maxTokens: 1600,
        timeout: const Duration(seconds: 120),
      );
      checkCancelled();
      final trimmed = digest.trim();
      if (trimmed.isNotEmpty) {
        digests.add('=== 第 ${i + 1}/${batches.length} 批事实纪要 ===\n$trimmed');
      }
      final doneProg = 0.10 + (0.60 * (i + 1) / batches.length);
      onProgress?.call(
        double.parse(doneProg.toStringAsFixed(3)),
        '已完成 ${i + 1}/${batches.length} 批事实提炼…',
      );
    }

    // 若超大规模记录（如整月上百条）汇总后摘要仍超出窗口，再做一层分层压缩
    final combinedLen = digests.fold<int>(0, (s, d) => s + d.length);
    if (combinedLen > _mapReduceTriggerChars * 2 && digests.length > 2) {
      checkCancelled();
      onProgress?.call(0.72, '跨批次归并长周期脉络…');
      final superBatches = _packStrings(digests, targetChars: _mapBatchTargetChars);
      final folded = <String>[];
      for (var i = 0; i < superBatches.length; i++) {
        checkCancelled();
        final compressed = await _gateway.chat(
          [
            ChatMessage.system(mapSystem),
            ChatMessage.user(superBatches[i]),
          ],
          model: model,
          temperature: temperature,
          maxTokens: 1600,
          timeout: const Duration(seconds: 120),
        );
        if (compressed.trim().isNotEmpty) {
          folded.add('=== 阶段汇总 ${i + 1}/${superBatches.length} ===\n${compressed.trim()}');
        }
      }
      if (folded.isNotEmpty) digests = folded;
    }

    checkCancelled();
    onProgress?.call(0.75, '汇总全局逻辑与行动项…');
    final reduceInput = StringBuffer()
      ..writeln('可用来源记录清单（points.sources 只能从中选择真实出现过的 id）：');
    for (final e in ordered) {
      reduceInput.writeln('- [${e.id}] ${e.title}（${e.time} · ${e.dur}）');
    }
    reduceInput
      ..writeln()
      ..writeln(digests.join('\n\n'));

    final raw = await _gateway.chat(
      [
        ChatMessage.system(_buildSystemPrompt(isReduce: true)),
        ChatMessage.user(reduceInput.toString()),
      ],
      model: model,
      temperature: temperature,
      maxTokens: 4096,
      timeout: const Duration(seconds: 120),
    );
    checkCancelled();
    onProgress?.call(0.95, '解析结构化总结…');
    return raw;
  }

  static const String _defaultRolePrompt =
      '你是录音整理助手。用户会给你按时间顺序排列的录音转写文本，每条以「[记录id] 标题（时间）」开头。'
      '请把它们整理成准确、精炼的结构化总结，只依据原文内容，不要编造原文没有的事实。';

  static const String _reduceRolePrompt =
      '你是录音整理助手。用户会给你一份按时间顺序分批提炼的录音事实纪要及可用「[记录id]」清单。'
      '请将各批次信息去重整合为一份全局连贯的结构化总结，完整保留关键数字、金额、日期、责任人承诺与待办，'
      '只依据提供的事实，不要编造内容。';

  static const String _mapRolePrompt = '''
你是高保真录音分段事实提取助手。请按时间顺序提炼本批录音中的核心事实，供后续全局汇总使用。
严格遵守以下要求：
1. 必须保留每条事实对应的 `[记录id]` 标签（如 `[e1]`），绝不丢失或篡改记录 id；
2. 完整保留原文中的精确数字、金额、比例、日期、时间节点、专有名词与人物称呼；
3. 明确记录各说话人的观点、决议、分歧、承诺与可执行待办（todos）；
4. 语言紧凑精炼，不写套话，不编造原文未提及的任何信息。''';

  static const String _jsonSchemaContract = '''
只输出一个 JSON 对象，不要任何解释文字、不要 Markdown 代码块，字段如下：
{
  "title": "总结标题，不超过 20 字",
  "overview": "内容概览（简短单句备忘写精炼 1 句；多条或长对话写 2-3 句）",
  "structure": [{"name": "主题分组名", "leaves": ["核心要点"]}],
  "points": [{"title": "信息点标题", "detail": "具体细节说明", "sources": ["对应的记录id"]}],
  "todos": ["可执行的行动项"]
}
要求：
1. 按输入篇幅自适应详略：若输入只是几秒至几十秒的简短口头备忘或单句话，overview 保持 1 句直达重点，structure 与 points 仅提炼 1 条精炼核心结论，禁止凑数硬拆空泛分支；若输入为长对话或多条记录，按主题完整展开逻辑分支与关键数字细节；
2. structure 与 points 至少各一条；points 的 sources 只能使用出现过的真实记录 id；
3. 行动项仅提取原文明确的待办或承诺，没有就返回空数组 []。''';

  List<_FormattedEventBlock> _buildEventBlocks(
    List<RecordEvent> events, {
    String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
  }) {
    final out = <_FormattedEventBlock>[];
    for (final e in events) {
      final header = '[${e.id}] ${e.title}（${e.time}）';
      final lines = <String>[];
      if (e.mark.trim().isNotEmpty) {
        lines.add('标记：${e.mark.trim()}');
      }

      if (e.dialog.isNotEmpty) {
        final dialogLines = <String>[
          for (final t in e.dialog)
            if (t.text.trim().isNotEmpty)
              '${speakerResolver?.call(e, t.spk) ?? t.spk}：${t.text.trim()}',
        ];
        final dialogText = dialogLines.join('\n');
        final brief = e.brief.trim();
        if (_isDistinctBrief(brief, dialogText)) {
          lines.add('摘要：$brief');
        }
        if (dialogText.isNotEmpty) {
          lines.add('对话：');
          lines.addAll(dialogLines);
        }
      } else if (e.raw.isNotEmpty) {
        final rawLines = <String>[
          for (final t in e.raw)
            if (t.text.trim().isNotEmpty)
              '${speakerResolver?.call(e, t.spk) ?? t.spk}：${t.text.trim()}',
        ];
        final rawText = rawLines.join('\n');
        final brief = e.brief.trim();
        if (_isDistinctBrief(brief, rawText)) {
          lines.add('摘要：$brief');
        }
        if (rawText.isNotEmpty) {
          lines.add('对话：');
          lines.addAll(rawLines);
        }
      } else {
        final body = e.longText.trim().isEmpty
            ? e.brief.trim()
            : e.longText.trim();
        if (body.isNotEmpty) {
          lines.add(body);
        }
      }

      if (lines.isEmpty) continue;
      final formatted = '$header\n${lines.join('\n')}\n';
      out.add(
        _FormattedEventBlock(
          event: e,
          header: header,
          lines: lines,
          formatted: formatted,
        ),
      );
    }
    return out;
  }

  static bool _isDistinctBrief(String brief, String bodyText) {
    if (brief.isEmpty) return false;
    if (brief == '尚无摘要' || brief == '正在整理这段对话…') return false;
    if (bodyText.isEmpty) return true;
    String norm(String s) =>
        s.replaceAll(RegExp(r'[\s，,。！？!?：:；;、（）()\-—]'), '');
    final nb = norm(brief);
    final nd = norm(bodyText);
    if (nb.isEmpty) return false;
    return !nd.contains(nb);
  }

  static List<String> _chunkIntoMapBatches(
    List<_FormattedEventBlock> blocks, {
    required int targetChars,
  }) {
    final batches = <String>[];
    final current = StringBuffer();

    void flushCurrent() {
      final text = current.toString().trim();
      current.clear();
      if (text.isNotEmpty) batches.add(text);
    }

    for (final block in blocks) {
      if (block.formatted.length <= targetChars) {
        if (current.isNotEmpty &&
            current.length + block.formatted.length > targetChars) {
          flushCurrent();
        }
        current.writeln(block.formatted.trimRight());
        current.writeln();
        continue;
      }

      // 单条超长录音（例如 2 小时合并长会）：按行切分为 ~targetChars 子块，且每块重复带 [id] 头部防丢溯源
      flushCurrent();
      final subChunks = <List<String>>[];
      var curLines = <String>[];
      var curLen = block.header.length + 24;
      for (final line in block.lines) {
        if (line.length > targetChars - block.header.length - 32) {
          // 极端超长单行兜底安全切分
          final step = math.max(500, targetChars - block.header.length - 64);
          for (var offset = 0; offset < line.length; offset += step) {
            final slice = line.substring(
              offset,
              math.min(line.length, offset + step),
            );
            if (curLines.isNotEmpty && curLen + slice.length + 1 > targetChars) {
              subChunks.add(curLines);
              curLines = <String>[];
              curLen = block.header.length + 24;
            }
            curLines.add(slice);
            curLen += slice.length + 1;
          }
          continue;
        }
        if (curLines.isNotEmpty && curLen + line.length + 1 > targetChars) {
          subChunks.add(curLines);
          curLines = <String>[];
          curLen = block.header.length + 24;
        }
        curLines.add(line);
        curLen += line.length + 1;
      }
      if (curLines.isNotEmpty) subChunks.add(curLines);

      for (var idx = 0; idx < subChunks.length; idx++) {
        final partHeader = subChunks.length > 1
            ? '[${block.event.id}] ${block.event.title}（${block.event.time} · 片段 ${idx + 1}/${subChunks.length}）'
            : block.header;
        batches.add('$partHeader\n${subChunks[idx].join('\n')}');
      }
    }

    flushCurrent();
    return batches;
  }

  static List<String> _packStrings(
    List<String> items, {
    required int targetChars,
  }) {
    final out = <String>[];
    final buf = StringBuffer();
    for (final item in items) {
      if (buf.isNotEmpty && buf.length + item.length + 2 > targetChars) {
        out.add(buf.toString().trim());
        buf.clear();
      }
      if (buf.isNotEmpty) buf.writeln('\n');
      buf.write(item);
    }
    if (buf.isNotEmpty) out.add(buf.toString().trim());
    return out;
  }

  static String _formatSourceRange(RecordEvent event, {String? explicitRange}) {
    if (explicitRange != null && explicitRange.trim().isNotEmpty) {
      return explicitRange.trim();
    }
    final time = event.time.trim();
    final dur = event.dur.trim();
    if (time.isNotEmpty && dur.isNotEmpty && parseDurationSeconds(dur) != null) {
      return '$time · $dur';
    }
    final mapMatch = RegExp(
      r'\d{1,2}:\d{2}(?::\d{2})?\s*[—–\-~至]\s*\d{1,2}:\d{2}(?::\d{2})?',
    ).firstMatch(event.srcMap);
    if (mapMatch != null) {
      final rangePart = mapMatch.group(0)!.trim();
      return dur.isNotEmpty ? '$rangePart · $dur' : rangePart;
    }
    if (time.isNotEmpty && dur.isNotEmpty) {
      return '$time · $dur';
    }
    return time.isNotEmpty ? time : dur;
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
          if (l != null && '$l'.trim().isNotEmpty) '$l'.trim(),
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
        String id;
        String? explicitRange;
        if (s is Map) {
          id = _str(s['id'] ?? s['eventId']);
          explicitRange = _str(s['range']);
        } else {
          id = '$s'.trim();
          // 容错模型写成 "[e1]" 的情况
          if (id.startsWith('[') && id.endsWith(']') && id.length > 2) {
            id = id.substring(1, id.length - 1).trim();
          }
        }
        final event = byId[id];
        if (event == null) continue; // 模型幻觉出的 id 直接丢弃
        refs.add(
          SourceRef(
            event.id,
            event.title,
            _formatSourceRange(event, explicitRange: explicitRange),
          ),
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

class _FormattedEventBlock {
  const _FormattedEventBlock({
    required this.event,
    required this.header,
    required this.lines,
    required this.formatted,
  });

  final RecordEvent event;
  final String header;
  final List<String> lines;
  final String formatted;
}
