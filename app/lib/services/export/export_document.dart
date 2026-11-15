/// 导出用的文档 DTO —— 与业务模型 SummaryCard 解耦。
///
/// 每次导出均输出完整两部分：
/// 1. 第一部分：图文纪要（标题 / 统计 / 概览与现场图 / 逻辑结构 / 信息点与配图 / 行动项 / 来源记录）
/// 2. 第二部分：文字记录（默认「AI 智能优化版」，可切「原文」，含确认后说话人标记）
library;

/// 导出中第二部分「文字记录」的内容版本。
enum TranscriptExportMode {
  /// AI 智能优化版（去口水词与错别字、保持原意与说话人归属）。
  aiOptimized,

  /// 原始转写原文（保留停顿/口语词与未润色表达）。
  rawOriginal,
}

extension TranscriptExportModeInfo on TranscriptExportMode {
  String get label => switch (this) {
        TranscriptExportMode.aiOptimized => 'AI 智能优化版',
        TranscriptExportMode.rawOriginal => '原文',
      };
}

/// 导出文档内嵌的场景照片条目。
class ExportImageItem {
  const ExportImageItem({required this.path, this.caption = ''});

  /// 本地照片路径（为空或文件不存在时渲染器/Markdown 退化展示图注）。
  final String path;

  /// 图片说明（如记录标题 + 拍摄时间）。
  final String caption;
}

/// 一节内容：标题 + 正文（可选）+ 条目列表（可选）+ 配图（可选）。
class ExportSection {
  const ExportSection({
    required this.heading,
    this.bullets = const <String>[],
    this.body,
    this.ordered = false,
    this.isPartHeader = false,
    this.images = const <ExportImageItem>[],
  });

  /// 章节标题，如「第一部分：图文纪要」「逻辑结构」「信息点」「行动项」。
  final String heading;

  /// 条目列表；[ordered] 为 true 时按 1. 2. 3. 编号渲染（如「行动项」）。
  final List<String> bullets;

  /// 章节正文（可选），如「信息点」细节或「文字记录」段落。
  final String? body;

  /// 是否按有序列表渲染。
  final bool ordered;

  /// 是否为分部大标题（用于清晰分隔「第一部分：图文纪要」与「第二部分：文字记录」）。
  final bool isPartHeader;

  /// 章节关联的现场图片。
  final List<ExportImageItem> images;

  /// 该节是否没有任何可展示内容。
  bool get isEmpty =>
      heading.trim().isEmpty &&
      (body == null || body!.trim().isEmpty) &&
      bullets.every((b) => b.trim().isEmpty) &&
      images.isEmpty;
}

/// 一份待导出的文档。
class ExportDocument {
  const ExportDocument({
    required this.title,
    this.meta = '',
    this.overview = '',
    this.sections = const <ExportSection>[],
    this.markdown = '',
    this.transcriptMode = TranscriptExportMode.aiOptimized,
    this.overviewImages = const <ExportImageItem>[],
  });

  /// 总结标题（文件名与文档一级标题都用它）。
  final String title;

  /// 统计行，如「11 月 3 日—11 月 7 日 · 6 条记录」。
  final String meta;

  /// 概览正文。
  final String overview;

  /// 完整章节列表。
  final List<ExportSection> sections;

  /// Markdown 兜底原文；若启用两部分结构化导出，渲染器直接按 sections 合成完整内容。
  final String markdown;

  /// 文字记录版本（AI 智能优化版 / 原文）。
  final TranscriptExportMode transcriptMode;

  /// 概览附带的关键现场图片。
  final List<ExportImageItem> overviewImages;

  /// 是否已采用「第一部分：图文纪要 + 第二部分：文字记录」两部分结构。
  bool get hasTwoPartStructure => sections.any((s) => s.isPartHeader);

  /// 文档是否完全没有内容（导出前据此提示，而不是产出一个空文件）。
  bool get isEmpty =>
      title.trim().isEmpty &&
      overview.trim().isEmpty &&
      markdown.trim().isEmpty &&
      overviewImages.isEmpty &&
      sections.every((s) => s.isEmpty);

  /// 去掉空章节后的章节列表，渲染器统一使用它，避免出现「空标题」。
  List<ExportSection> get visibleSections =>
      sections.where((s) => !s.isEmpty).toList(growable: false);

  /// 标题兜底：标题为空时用「总结」，避免文件名/一级标题出现空白。
  String get safeTitle => title.trim().isEmpty ? '总结' : title.trim();
}
