/// 中轮 / 长轮的保守实现：只吃上一轮已经整理好的段落，再合并成更少的阶段。
///
/// 不把两小时原始逐句塞进提示词，也不替换短轮的滚动清洗算法。
/// 模型没返回可解析结果时保持上一轮原文，不编造段落。
library;

import 'dart:convert';
import 'dart:math' as math;

import '../analysis/chat_completion.dart';
import '../recordings/cleaned_dialogue.dart';
import '../segment/fast_topic_segment_agent.dart';
import '../segment/section_copy.dart';

class OrganizedParagraph {
  const OrganizedParagraph({
    required this.speaker,
    required this.text,
    required this.startAtMs,
    required this.endAtMs,
    this.srcUtteranceIds = const [],
  });

  final String speaker;
  final String text;
  final int startAtMs;
  final int endAtMs;
  final List<String> srcUtteranceIds;

  Map<String, dynamic> toJson() => {
    'speaker': speaker,
    'text': text,
    'startAtMs': startAtMs,
    'endAtMs': endAtMs,
    if (srcUtteranceIds.isNotEmpty) 'srcUtteranceIds': srcUtteranceIds,
  };

  factory OrganizedParagraph.fromJson(Map<String, dynamic> json) =>
      OrganizedParagraph(
        speaker: '${json['speaker'] ?? ''}',
        text: '${json['text'] ?? ''}',
        startAtMs: (json['startAtMs'] as num?)?.toInt() ?? 0,
        endAtMs: (json['endAtMs'] as num?)?.toInt() ?? 0,
        srcUtteranceIds: [
          for (final id in (json['srcUtteranceIds'] as List? ?? const []))
            '$id',
        ],
      );

  TopicParagraph toTopicParagraph() => TopicParagraph(
    speaker: speaker,
    text: text,
    startAtMs: startAtMs,
    endAtMs: endAtMs,
    srcUtteranceIds: srcUtteranceIds,
  );
}

class OrganizedSection {
  const OrganizedSection({
    required this.anchorId,
    required this.title,
    required this.brief,
    required this.overview,
    required this.startAtMs,
    required this.endAtMs,
    this.tags = const [],
    this.paragraphs = const [],
    this.summary = '',
    this.evidenceSliceIds = const [],
  });

  final String anchorId;
  final String title;
  final String brief;
  final String overview;
  final int startAtMs;
  final int endAtMs;
  final List<String> tags;
  final List<OrganizedParagraph> paragraphs;
  final String summary;
  final List<String> evidenceSliceIds;

  Map<String, dynamic> toJson() => {
    'anchorId': anchorId,
    'title': title,
    'brief': brief,
    'overview': overview,
    'startAtMs': startAtMs,
    'endAtMs': endAtMs,
    if (tags.isNotEmpty) 'tags': tags,
    'paragraphs': [for (final p in paragraphs) p.toJson()],
    if (summary.isNotEmpty) 'summary': summary,
    if (evidenceSliceIds.isNotEmpty) 'evidenceSliceIds': evidenceSliceIds,
  };

  factory OrganizedSection.fromJson(Map<String, dynamic> json) {
    final copy = SectionCopy.fromModel(json);
    return OrganizedSection(
      anchorId: '${json['anchorId'] ?? ''}',
      title: copy.title.isNotEmpty ? copy.title : '${json['title'] ?? ''}',
      brief: copy.brief,
      overview: copy.overview,
      startAtMs: (json['startAtMs'] as num?)?.toInt() ?? 0,
      endAtMs: (json['endAtMs'] as num?)?.toInt() ?? 0,
      tags: [for (final tag in (json['tags'] as List? ?? const [])) '$tag'],
      paragraphs: [
        for (final item in (json['paragraphs'] as List? ?? const []))
          if (item is Map<String, dynamic>)
            OrganizedParagraph.fromJson(item)
          else if (item is Map)
            OrganizedParagraph.fromJson(Map<String, dynamic>.from(item)),
      ],
      summary: copy.summary,
      evidenceSliceIds: SectionCopy.evidenceSliceIds(json),
    );
  }

  TopicSectionOverride toTopicSection() => TopicSectionOverride(
    title: title,
    brief: brief,
    overview: overview,
    summary: summary.isNotEmpty ? summary : brief,
    tags: tags,
    startTurnIndex: 0,
    endTurnIndex: paragraphs.isEmpty ? 0 : paragraphs.length - 1,
    paragraphs: [for (final p in paragraphs) p.toTopicParagraph()],
    cleanedByCloud: true,
    startAtMs: startAtMs,
    endAtMs: endAtMs,
    evidenceSliceIds: evidenceSliceIds,
  );
}

class OrganizedPayload {
  const OrganizedPayload({required this.stage, required this.sections});

  final String stage;
  final List<OrganizedSection> sections;

  bool get isEmpty => sections.isEmpty;

  Map<String, dynamic> toJson() => {
    'stage': stage,
    'sections': [for (final section in sections) section.toJson()],
  };

  static OrganizedPayload parse(
    Map<String, dynamic>? payload, {
    String fallbackStage = '',
  }) {
    if (payload == null) {
      return OrganizedPayload(stage: fallbackStage, sections: const []);
    }
    final raw = payload['sections'];
    return OrganizedPayload(
      stage: '${payload['stage'] ?? fallbackStage}',
      sections: [
        for (final item in (raw is List ? raw : const []))
          if (item is Map<String, dynamic>)
            OrganizedSection.fromJson(item)
          else if (item is Map)
            OrganizedSection.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }

  static OrganizedPayload fromTopicState(
    TopicSegmentationState state, {
    required String stage,
    String? stageTaskId,
  }) {
    final staged = stageTaskId == null ? null : state.stageByTask[stageTaskId];
    final runs = (staged != null && staged.isNotEmpty)
        ? staged.values
        : state.rollingByAnchor.values;
    return OrganizedPayload(
      stage: stage,
      sections: [for (final run in runs) ..._sectionsOfRun(run)],
    );
  }

  static List<OrganizedSection> _sectionsOfRun(TopicRunSegmentation run) {
    return [
      for (final section in run.sections)
        OrganizedSection(
          anchorId: run.runKey,
          title: section.title,
          brief: section.brief.isNotEmpty ? section.brief : section.summary,
          overview: section.overview.isNotEmpty
              ? section.overview
              : (section.summary.isNotEmpty ? section.summary : section.brief),
          tags: section.tags,
          startAtMs: section.startAtMs > 0 ? section.startAtMs : run.startAtMs,
          endAtMs: section.endAtMs > 0 ? section.endAtMs : run.endAtMs,
          paragraphs: [
            for (final paragraph in section.paragraphs)
              OrganizedParagraph(
                speaker: paragraph.speaker,
                text: paragraph.text,
                startAtMs: paragraph.startAtMs,
                endAtMs: paragraph.endAtMs,
                srcUtteranceIds: paragraph.srcUtteranceIds,
              ),
          ],
          summary: section.summary.isNotEmpty ? section.summary : section.brief,
          evidenceSliceIds: section.evidenceSliceIds,
        ),
    ];
  }
}

class OrganizePassResult {
  const OrganizePassResult({
    required this.sections,
    this.modelCalls = 0,
    this.inputChars = 0,
    this.outputChars = 0,
    this.error,
  });

  final List<OrganizedSection> sections;
  final int modelCalls;
  final int inputChars;
  final int outputChars;
  final String? error;

  bool get ok => error == null;
}

class OrganizePassService {
  OrganizePassService({
    required ChatCompletion chat,
    required String Function() modelResolver,
    bool Function()? ready,
  }) : _chat = chat,
       _modelResolver = modelResolver,
       _ready = ready;

  final ChatCompletion _chat;
  final String Function() _modelResolver;
  final bool Function()? _ready;

  static const int _chunkSize = 8;

  Future<OrganizePassResult> merge({
    required List<OrganizedSection> sections,
    required String prompt,
    int overlapSections = 3,
    int overlapMinutes = 0,
    bool overlapByMinutes = false,
  }) async {
    if (sections.isEmpty) {
      return const OrganizePassResult(sections: []);
    }
    final model = _modelResolver().trim();
    if (model.isEmpty || _ready?.call() == false) {
      return const OrganizePassResult(
        sections: [],
        error: '云端模型未就绪，未改写上一轮整理结果',
      );
    }
    final grouped = <String, List<OrganizedSection>>{};
    for (final section in sections) {
      grouped.putIfAbsent(section.anchorId, () => []).add(section);
    }
    final merged = <OrganizedSection>[];
    var calls = 0;
    var inputChars = 0;
    var outputChars = 0;
    for (final entry in grouped.entries) {
      if (entry.value.length < 2) {
        merged.addAll(entry.value);
        continue;
      }
      final chunks = _chunks(
        entry.value,
        overlapSections: overlapSections,
        overlapMinutes: overlapMinutes,
        overlapByMinutes: overlapByMinutes,
      );
      for (final chunk in chunks) {
        final fresh = chunk.fresh;
        if (fresh.length < 2 && chunk.context.isEmpty) {
          merged.addAll(fresh);
          continue;
        }
        final payload = <String, dynamic>{
          if (chunk.context.isNotEmpty)
            'overlapContext': [
              for (var i = 0; i < chunk.context.length; i++)
                _publicSection(i, chunk.context[i]),
            ],
          'sections': [
            for (var i = 0; i < fresh.length; i++) _publicSection(i, fresh[i]),
          ],
        };
        final user = jsonEncode(payload);
        final system = _systemPrompt(prompt);
        calls += 1;
        inputChars += system.length + user.length;
        final String raw;
        try {
          raw = await _chat.complete(
            [ChatMessage.system(system), ChatMessage.user(user)],
            model: model,
            temperature: 0.2,
            maxTokens: 3200,
          );
        } catch (e) {
          return OrganizePassResult(
            sections: const [],
            modelCalls: calls,
            inputChars: inputChars,
            outputChars: outputChars,
            error: '$e',
          );
        }
        outputChars += raw.length;
        final parsed = _parse(raw, fresh, entry.key);
        if (parsed == null) {
          return OrganizePassResult(
            sections: const [],
            modelCalls: calls,
            inputChars: inputChars,
            outputChars: outputChars,
            error: '模型没有返回可解析的整理结果，已保留上一轮',
          );
        }
        merged.addAll(parsed);
      }
    }
    return OrganizePassResult(
      sections: merged,
      modelCalls: calls,
      inputChars: inputChars,
      outputChars: outputChars,
    );
  }

  String _systemPrompt(String prompt) {
    final style = prompt.trim().isEmpty
        ? '把同一话题的相邻阶段合并成更连贯的长段。'
        : prompt.trim();
    return '''
$style

你收到的是上一轮已经整理好的阶段，不是原始逐句转写。只依据这些阶段里的事实，不要编造新的事件、人名或结论。
overlapContext 只用来衔接，不要原样重复输出。
按内容或时间事件合并阶段，不要按逐词逐句或原始短切片切碎。
只输出一个 JSON 对象，不要 Markdown：
{"sections":[{"title":"","brief":"","summary":"","overview":"","sourceIndexes":[0],"paragraphs":[{"speaker":"","text":""}]}]}
sourceIndexes 指向本次 sections 数组的下标。能合并的阶段放进同一个 sourceIndexes。
若只返回 summary，将同时用作 brief 与 overview。不要把情绪或其他工程标记写进标题、摘要或段落。
'''
        .trim();
  }

  Map<String, dynamic> _publicSection(int index, OrganizedSection section) => {
    'i': index,
    'title': section.title,
    'brief': section.brief,
    'overview': section.overview,
    if (section.summary.isNotEmpty) 'summary': section.summary,
    'paragraphs': [
      for (final paragraph in section.paragraphs)
        {'speaker': paragraph.speaker, 'text': paragraph.text},
    ],
  };

  List<_Chunk> _chunks(
    List<OrganizedSection> sections, {
    required int overlapSections,
    required int overlapMinutes,
    required bool overlapByMinutes,
  }) {
    if (sections.length <= _chunkSize) {
      return [_Chunk(context: const [], fresh: sections)];
    }
    final chunks = <_Chunk>[];
    var start = 0;
    while (start < sections.length) {
      final end = (start + _chunkSize).clamp(0, sections.length);
      final fresh = sections.sublist(start, end);
      final context = <OrganizedSection>[];
      if (start > 0) {
        if (overlapByMinutes && overlapMinutes > 0) {
          final cutoff = fresh.first.startAtMs - overlapMinutes * 60 * 1000;
          for (var i = start - 1; i >= 0; i--) {
            if (sections[i].endAtMs < cutoff && context.isNotEmpty) break;
            context.insert(0, sections[i]);
            if (context.length >= 4) break;
          }
        } else if (overlapSections > 0) {
          final from = (start - overlapSections).clamp(0, start);
          context.addAll(sections.sublist(from, start));
        }
      }
      chunks.add(_Chunk(context: context, fresh: fresh));
      if (end >= sections.length) break;
      start = end;
    }
    return chunks;
  }

  List<OrganizedSection>? _parse(
    String raw,
    List<OrganizedSection> fresh,
    String anchorId,
  ) {
    final jsonText = _extractJsonObject(raw);
    if (jsonText == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final rawSections = decoded['sections'];
    if (rawSections is! List || rawSections.isEmpty) return null;
    final parsed = <OrganizedSection>[];
    for (final item in rawSections) {
      if (item is! Map) continue;
      final map = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item);
      final indexes = <int>[
        for (final n in (map['sourceIndexes'] as List? ?? const []))
          if (n is num) n.toInt(),
      ].where((i) => i >= 0 && i < fresh.length).toList();
      final sources = indexes.isEmpty
          ? fresh
          : [for (final i in indexes) fresh[i]];
      final startAt = sources
          .map((s) => s.startAtMs)
          .reduce((a, b) => a < b ? a : b);
      final endAt = sources
          .map((s) => s.endAtMs)
          .reduce((a, b) => a > b ? a : b);
      final sourceParagraphs = <OrganizedParagraph>[
        for (final source in sources)
          for (final paragraph in source.paragraphs)
            if (paragraph.text.trim().isNotEmpty) paragraph,
      ];
      final rawParagraphs = map['paragraphs'];
      final paragraphs = rawParagraphs is List
          ? _alignOutputParagraphs(
              rawParagraphs: rawParagraphs,
              sourceParagraphs: sourceParagraphs,
              fallbackStartAtMs: startAt,
              fallbackEndAtMs: endAt,
            )
          : const <OrganizedParagraph>[];
      final fallbackParagraphs = paragraphs.isEmpty
          ? [
              for (final source in sources)
                for (final paragraph in source.paragraphs)
                  if (paragraph.text.trim().isNotEmpty) paragraph,
            ]
          : paragraphs;
      final copy = SectionCopy.fromModel(map);
      final title = copy.title;
      final brief = copy.brief;
      final overview = copy.overview;
      final summary = copy.summary;
      if (title.isEmpty && fallbackParagraphs.isEmpty) continue;
      final inheritedEvidence = <String>[
        for (final source in sources) ...source.evidenceSliceIds,
      ];
      parsed.add(
        OrganizedSection(
          anchorId: anchorId,
          title: title.isEmpty ? sources.first.title : title,
          brief: brief.isEmpty ? sources.first.brief : brief,
          overview: overview.isEmpty ? sources.first.overview : overview,
          tags: [for (final source in sources) ...source.tags],
          startAtMs: startAt,
          endAtMs: endAt,
          paragraphs: fallbackParagraphs,
          summary: summary.isEmpty
              ? (brief.isEmpty ? sources.first.summary : brief)
              : summary,
          evidenceSliceIds: SectionCopy.evidenceSliceIds(
            map,
            fallback: inheritedEvidence,
          ),
        ),
      );
    }
    return parsed.isEmpty ? null : parsed;
  }

  String? _extractJsonObject(String raw) {
    final trimmed = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(trimmed);
    final body = fence != null ? fence.group(1)!.trim() : trimmed;
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return body.substring(start, end + 1);
  }

  /// 将模型合并后的输出段落单调对齐回 `sourceParagraphs`，精确保留每段的起止时间戳与 `srcUtteranceIds`。
  static List<OrganizedParagraph> _alignOutputParagraphs({
    required List<dynamic> rawParagraphs,
    required List<OrganizedParagraph> sourceParagraphs,
    required int fallbackStartAtMs,
    required int fallbackEndAtMs,
  }) {
    final drafts = <({String speaker, String text, List<int> explicitIdx})>[];
    for (final item in rawParagraphs) {
      if (item is! Map) continue;
      final text = '${item['text'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final spkRaw = '${item['speaker'] ?? ''}'.trim();
      final speaker = spkRaw.isEmpty ? '未区分' : spkRaw;
      final explicit = <int>[
        for (final n in (item['sourceParagraphIndexes'] as List? ?? const []))
          if (n is num) n.toInt(),
      ].where((i) => i >= 0 && i < sourceParagraphs.length).toList();
      drafts.add((speaker: speaker, text: text, explicitIdx: explicit));
    }
    if (drafts.isEmpty) return const [];

    final m = drafts.length;
    final k = sourceParagraphs.length;
    if (k == 0) {
      return _proportionalFallbackParagraphs(
        drafts,
        fallbackStartAtMs,
        fallbackEndAtMs,
      );
    }

    if (m == 1) {
      final d = drafts.single;
      final matched = d.explicitIdx.isNotEmpty
          ? [for (final i in d.explicitIdx) sourceParagraphs[i]]
          : sourceParagraphs;
      return [
        _buildAlignedParagraph(
          speaker: d.speaker,
          text: d.text,
          matchedSources: matched,
        ),
      ];
    }

    // 正常合并场景（k >= m）：用单调连续划分 DP 将 [0..k-1] 划分为 m 段，最大化文本与说话人相似度
    if (k >= m) {
      final outGrams = [for (final d in drafts) _charFeatures(d.text)];
      final srcGrams = [for (final s in sourceParagraphs) _charFeatures(s.text)];
      final outSpk = [for (final d in drafts) lifeSpeakerLabel(d.speaker)];
      final srcSpk = [
        for (final s in sourceParagraphs) lifeSpeakerLabel(s.speaker),
      ];

      double spanScore(int outIdx, int sStart, int sEnd) {
        if (drafts[outIdx].explicitIdx.isNotEmpty) {
          final expFirst = drafts[outIdx].explicitIdx.first;
          final expLast = drafts[outIdx].explicitIdx.last;
          if (sStart == expFirst && sEnd == expLast) return 100.0;
        }
        final unionSrc = <String>{};
        var spkMatches = 0;
        for (var r = sStart; r <= sEnd; r++) {
          unionSrc.addAll(srcGrams[r]);
          if (outSpk[outIdx].isNotEmpty && outSpk[outIdx] == srcSpk[r]) {
            spkMatches++;
          }
        }
        final og = outGrams[outIdx];
        var overlap = 0;
        for (final g in og) {
          if (unionSrc.contains(g)) overlap++;
        }
        final denom = og.length + unionSrc.length;
        final dice = denom == 0 ? 0.0 : (2.0 * overlap) / denom;
        final spkRatio = spkMatches / (sEnd - sStart + 1);
        return dice * 2.0 + spkRatio * 0.45;
      }

      // dp[i][j] = 前 i 个输出段覆盖前 j 个源段的最大得分（i in 1..m, j in i..k）
      const negInf = -1e12;
      final dp = List.generate(m + 1, (_) => List<double>.filled(k + 1, negInf));
      final split = List.generate(m + 1, (_) => List<int>.filled(k + 1, 0));
      dp[0][0] = 0.0;
      for (var i = 1; i <= m; i++) {
        final maxJ = k - (m - i);
        for (var j = i; j <= maxJ; j++) {
          var bestPrev = i - 1;
          var bestVal = negInf;
          for (var p = i - 1; p < j; p++) {
            final cand = dp[i - 1][p] + spanScore(i - 1, p, j - 1);
            if (cand > bestVal) {
              bestVal = cand;
              bestPrev = p;
            }
          }
          dp[i][j] = bestVal;
          split[i][j] = bestPrev;
        }
      }

      final ranges = List<(int, int)>.filled(m, (0, 0));
      var curEnd = k;
      for (var i = m; i >= 1; i--) {
        final prev = split[i][curEnd];
        ranges[i - 1] = (prev, curEnd - 1);
        curEnd = prev;
      }

      return [
        for (var i = 0; i < m; i++)
          _buildAlignedParagraph(
            speaker: drafts[i].speaker,
            text: drafts[i].text,
            matchedSources: sourceParagraphs.sublist(
              ranges[i].$1,
              ranges[i].$2 + 1,
            ),
          ),
      ];
    }

    // 罕见扩拆场景（m > k）：按顺序映射并在共享同一源段的多个输出段内部按字数比例切分时间
    final assignedSrc = List<int>.generate(
      m,
      (i) => ((i * k) ~/ m).clamp(0, k - 1),
    );
    final result = <OrganizedParagraph>[];
    var i = 0;
    while (i < m) {
      final srcIdx = assignedSrc[i];
      var j = i;
      while (j + 1 < m && assignedSrc[j + 1] == srcIdx) {
        j++;
      }
      final src = sourceParagraphs[srcIdx];
      if (i == j) {
        result.add(
          _buildAlignedParagraph(
            speaker: drafts[i].speaker,
            text: drafts[i].text,
            matchedSources: [src],
          ),
        );
      } else {
        final subDrafts = drafts.sublist(i, j + 1);
        final subParas = _proportionalFallbackParagraphs(
          subDrafts,
          src.startAtMs,
          src.endAtMs > src.startAtMs ? src.endAtMs : src.startAtMs + 1000,
          sharedUtteranceIds: src.srcUtteranceIds,
        );
        result.addAll(subParas);
      }
      i = j + 1;
    }
    return result;
  }

  static OrganizedParagraph _buildAlignedParagraph({
    required String speaker,
    required String text,
    required List<OrganizedParagraph> matchedSources,
  }) {
    final startMs = matchedSources
        .map((s) => s.startAtMs)
        .reduce((a, b) => a < b ? a : b);
    final rawEndMs = matchedSources
        .map((s) => s.endAtMs)
        .reduce((a, b) => a > b ? a : b);
    final endMs = rawEndMs > startMs ? rawEndMs : startMs + 200;
    final ids = <String>{
      for (final s in matchedSources) ...s.srcUtteranceIds,
    }.toList();
    return OrganizedParagraph(
      speaker: speaker,
      text: text,
      startAtMs: startMs,
      endAtMs: endMs,
      srcUtteranceIds: ids,
    );
  }

  static List<OrganizedParagraph> _proportionalFallbackParagraphs(
    List<({String speaker, String text, List<int> explicitIdx})> drafts,
    int startAtMs,
    int endAtMs, {
    List<String> sharedUtteranceIds = const [],
  }) {
    final weights = [
      for (final d in drafts) math.max(1, d.text.runes.length),
    ];
    final totalW = weights.fold<int>(0, (a, b) => a + b);
    final span = math.max(drafts.length * 200, endAtMs - startAtMs);
    var cursor = startAtMs;
    final out = <OrganizedParagraph>[];
    for (var i = 0; i < drafts.length; i++) {
      final isLast = i == drafts.length - 1;
      final dur = math.max(200, (span * weights[i] / totalW).round());
      final segEnd = isLast
          ? math.max(cursor + 1, startAtMs + span)
          : cursor + dur;
      out.add(
        OrganizedParagraph(
          speaker: drafts[i].speaker,
          text: drafts[i].text,
          startAtMs: cursor,
          endAtMs: segEnd,
          srcUtteranceIds: sharedUtteranceIds,
        ),
      );
      cursor = segEnd;
    }
    return out;
  }

  static Set<String> _charFeatures(String text) {
    final clean = text
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
        .toLowerCase();
    if (clean.isEmpty) return const {};
    final runes = clean.runes.toList();
    final set = <String>{};
    for (var i = 0; i < runes.length; i++) {
      set.add(String.fromCharCode(runes[i]));
      if (i + 1 < runes.length) {
        set.add(String.fromCharCodes([runes[i], runes[i + 1]]));
      }
    }
    return set;
  }
}

class _Chunk {
  const _Chunk({required this.context, required this.fresh});

  final List<OrganizedSection> context;
  final List<OrganizedSection> fresh;
}

Future<void> writeStageOverlay({
  required TopicSegmentationStore store,
  required String taskId,
  required List<OrganizedSection> sections,
  required int evaluatedAtMs,
}) async {
  final byAnchor = <String, List<OrganizedSection>>{};
  for (final section in sections) {
    byAnchor.putIfAbsent(section.anchorId, () => []).add(section);
  }
  await store.readModifyWrite((current) {
    var state = current;
    for (final entry in byAnchor.entries) {
      final startAt = entry.value
          .map((s) => s.startAtMs)
          .reduce((a, b) => a < b ? a : b);
      final endAt = entry.value
          .map((s) => s.endAtMs)
          .reduce((a, b) => a > b ? a : b);
      final covered = <String>{
        for (final section in entry.value)
          for (final paragraph in section.paragraphs)
            ...paragraph.srcUtteranceIds,
      };
      state = state.withStageRun(
        taskId,
        TopicRunSegmentation(
          runKey: entry.key,
          startAtMs: startAt,
          endAtMs: endAt,
          sections: [
            for (final section in entry.value) section.toTopicSection(),
          ],
          evaluatedAtMs: evaluatedAtMs,
          coveredUtteranceEndMs: endAt,
          coveredUtteranceIds: covered,
        ),
      );
    }
    return state;
  });
}
