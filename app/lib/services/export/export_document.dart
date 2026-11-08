/// 导出用的文档 DTO —— 与业务模型 SummaryCard 解耦。
///
/// 为什么单独建一层 DTO：
/// - 导出器只关心「标题 / 统计 / 概览 / 章节 / Markdown 原文」这五类中立信息，
///   不依赖 SummaryCard 的字段结构，模型改动不会波及导出实现；
/// - 单元测试可以脱离业务模型直接构造文档；
/// - 本文件是纯 Dart（不 import Flutter），可在命令行脚本里直接跑逻辑验证。
library;

/// 一节内容：标题 + 正文（可选）+ 条目列表（可选）。
class ExportSection {
  const ExportSection({
    required this.heading,
    this.bullets = const <String>[],
    this.body,
    this.ordered = false,
  });

  /// 章节标题，如「逻辑结构」「信息点」「行动项」「来源记录」。
  final String heading;

  /// 条目列表；[ordered] 为 true 时按 1. 2. 3. 编号渲染（如「行动项」）。
  final List<String> bullets;

  /// 章节正文（可选），如「信息点」里每条要展开的细节。
  final String? body;

  /// 是否按有序列表渲染。
  final bool ordered;

  /// 该节是否没有任何可展示内容。
  bool get isEmpty =>
      heading.trim().isEmpty &&
      (body == null || body!.trim().isEmpty) &&
      bullets.every((b) => b.trim().isEmpty);
}

/// 一份待导出的文档。
class ExportDocument {
  const ExportDocument({
    required this.title,
    this.meta = '',
    this.overview = '',
    this.sections = const <ExportSection>[],
    this.markdown = '',
  });

  /// 总结标题（文件名与文档一级标题都用它）。
  final String title;

  /// 统计行，如「11 月 3 日—11 月 7 日 · 6 条记录」。
  final String meta;

  /// 概览正文。
  final String overview;

  /// 逻辑结构 / 信息点 / 行动项 / 来源记录等章节。
  final List<ExportSection> sections;

  /// 完整 Markdown 原文；Markdown / Word / PDF 都会用到（PDF 与图片在没有章节时回退解析它）。
  final String markdown;

  /// 文档是否完全没有内容（导出前据此提示，而不是产出一个空文件）。
  bool get isEmpty =>
      title.trim().isEmpty &&
      overview.trim().isEmpty &&
      markdown.trim().isEmpty &&
      sections.every((s) => s.isEmpty);

  /// 去掉空章节后的章节列表，渲染器统一使用它，避免出现「空标题」。
  List<ExportSection> get visibleSections =>
      sections.where((s) => !s.isEmpty).toList(growable: false);

  /// 标题兜底：标题为空时用「总结」，避免文件名/一级标题出现空白。
  String get safeTitle => title.trim().isEmpty ? '总结' : title.trim();
}
