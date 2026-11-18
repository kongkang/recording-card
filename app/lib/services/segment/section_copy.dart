/// 清洗阶段标题 / 摘要字段映射。
///
/// 模型可能只回 `summary`，也可能同时给 `brief` / `overview`。
/// 用户可见的事件卡摘要优先用 `summary`，并回填到现有 `brief` / `overview`，
/// 避免中长轮因为字段名不一致而把摘要丢掉。
library;

class SectionCopy {
  const SectionCopy({
    required this.title,
    required this.brief,
    required this.overview,
    required this.summary,
  });

  final String title;
  final String brief;
  final String overview;
  final String summary;

  factory SectionCopy.fromModel(Map<dynamic, dynamic> map) {
    String read(String key) => '${map[key] ?? ''}'.trim();
    final title = read('title');
    final summary = read('summary');
    final briefRaw = read('brief');
    final overviewRaw = read('overview');
    final brief = briefRaw.isNotEmpty ? briefRaw : summary;
    final overview = overviewRaw.isNotEmpty
        ? overviewRaw
        : (summary.isNotEmpty ? summary : brief);
    final resolvedSummary = summary.isNotEmpty ? summary : brief;
    return SectionCopy(
      title: title,
      brief: brief,
      overview: overview,
      summary: resolvedSummary,
    );
  }

  /// 事件卡 2–3 行生活摘要：优先 summary，否则 brief。
  String get cardSummary => summary.isNotEmpty ? summary : brief;

  static List<String> evidenceSliceIds(
    Map<dynamic, dynamic> map, {
    Iterable<String> fallback = const [],
  }) {
    final raw = map['evidenceSliceIds'] ?? map['evidence_slice_ids'];
    final ids = <String>[
      if (raw is List)
        for (final v in raw)
          if ('$v'.trim().isNotEmpty) '$v'.trim(),
    ];
    if (ids.isNotEmpty) {
      return [...{...ids}];
    }
    return [...{for (final id in fallback) if (id.trim().isNotEmpty) id.trim()}];
  }
}
