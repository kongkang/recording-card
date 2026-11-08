/// 文档块布局 —— 把 [ExportDocument] 归一成「带语义的文本块」序列。
///
/// 纯 Dart（不 import Flutter）：PDF / 图片两条路径共用同一份块序列，
/// 也方便在命令行脚本里断言顺序与内容，避免渲染代码里夹带业务判断。
///
/// 为什么需要这一层：
/// - 渲染器（TextPainter）只认块类型与文本，不认业务字段；
/// - Markdown 回退解析（只有 md 没有结构化字段时）也收敛到这里，
///   保证「章节优先、Markdown 兜底」的策略只有一处。
library;

import 'export_document.dart';

/// 块类型（语义化，渲染器据此决定字号/字重/是否编号）。
enum DocBlockKind {
  /// 文档一级标题（文档名）。
  title,

  /// 统计行（时间范围 · N 条记录），弱化小字。
  meta,

  /// 章节标题。
  heading,

  /// Markdown 三级及更深的小标题。
  subheading,

  /// 普通段落。
  paragraph,

  /// 无序条目。
  bullet,

  /// 有序条目（渲染时按序号编号）。
  numbered,

  /// 引用/说明性小字。
  note,

  /// 分隔线。
  divider,
}

/// 一个可排版的文本块。
class DocBlock {
  const DocBlock(this.kind, this.text, {this.index});

  final DocBlockKind kind;

  /// 已剥掉 Markdown 行内标记的纯文本；[DocBlockKind.divider] 时为空字符串。
  final String text;

  /// 有序条目的序号（从 1 开始），其它类型为 null。
  final int? index;

  @override
  String toString() => 'DocBlock($kind, index=$index, ${text.isEmpty ? '' : '"$text"'})';
}

/// 把文档转成块序列。
///
/// 策略：
/// 1. 有结构化章节时以章节为准（标题 → 统计 → 概览 → 各章节），Markdown 原文不再重复进入正文；
/// 2. 章节为空（只有 Markdown 或只有概览）时用轻量 Markdown 解析兜底，
///    保证「导出 PDF/图片」永远有内容可排；
/// 3. 什么都没有时给一行占位说明，防止产出空白文件。
List<DocBlock> buildDocBlocks(ExportDocument doc, {bool preferMarkdown = false}) {
  final sections = doc.visibleSections;
  final hasStructure = sections.isNotEmpty || doc.overview.trim().isNotEmpty;

  if (preferMarkdown && doc.markdown.trim().isNotEmpty) {
    return buildDocBlocksFromMarkdown(doc.markdown, title: doc.safeTitle, meta: doc.meta);
  }

  if (!hasStructure) {
    if (doc.markdown.trim().isNotEmpty) {
      return buildDocBlocksFromMarkdown(doc.markdown, title: doc.safeTitle, meta: doc.meta);
    }
    return <DocBlock>[
      DocBlock(DocBlockKind.title, doc.safeTitle),
      if (doc.meta.trim().isNotEmpty) DocBlock(DocBlockKind.meta, doc.meta.trim()),
      const DocBlock(DocBlockKind.paragraph, '（本次总结没有可导出的内容）'),
    ];
  }

  final blocks = <DocBlock>[
    DocBlock(DocBlockKind.title, doc.safeTitle),
    if (doc.meta.trim().isNotEmpty) DocBlock(DocBlockKind.meta, doc.meta.trim()),
  ];

  if (doc.overview.trim().isNotEmpty) {
    blocks
      ..add(const DocBlock(DocBlockKind.heading, '概览'))
      ..add(DocBlock(DocBlockKind.paragraph, doc.overview.trim()));
  }

  for (final section in sections) {
    blocks.add(DocBlock(DocBlockKind.heading, oneline(section.heading)));
    final body = section.body?.trim() ?? '';
    if (body.isNotEmpty) {
      blocks.add(DocBlock(DocBlockKind.paragraph, body));
    }
    var no = 0;
    for (final bullet in section.bullets) {
      final text = bullet.trim();
      if (text.isEmpty) continue;
      if (section.ordered) {
        no++;
        blocks.add(DocBlock(DocBlockKind.numbered, text, index: no));
      } else {
        blocks.add(DocBlock(DocBlockKind.bullet, text));
      }
    }
  }
  return blocks;
}

/// 轻量 Markdown 解析（只处理标题 / 列表 / 引用 / 分隔线 / 段落），**不是**完整 Markdown 语义。
///
/// 之所以自己写而不是引依赖：导出只需要「可读的文本流」，
/// 完整 Markdown 解析器的表格、代码块、HTML 等在纸质文档里并不需要。
List<DocBlock> buildDocBlocksFromMarkdown(
  String markdown, {
  String? title,
  String? meta,
}) {
  final blocks = <DocBlock>[];
  final headingText = (title ?? '').trim();
  if (headingText.isNotEmpty) {
    blocks.add(DocBlock(DocBlockKind.title, headingText));
  }
  if (meta != null && meta.trim().isNotEmpty) {
    blocks.add(DocBlock(DocBlockKind.meta, meta.trim()));
  }

  final lines = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final paragraph = StringBuffer();
  var sawFirstLevelHeading = false;

  void flushParagraph() {
    final text = paragraph.toString().trim();
    paragraph.clear();
    if (text.isEmpty) return;
    // 首行的 `# 标题` 与文档标题重复时跳过，避免正文首个一级标题重复出现
    if (!sawFirstLevelHeading && headingText.isNotEmpty && text == headingText) {
      sawFirstLevelHeading = true;
      return;
    }
    blocks.add(DocBlock(DocBlockKind.paragraph, text));
  }

  var orderedNo = 0;
  for (final rawLine in lines) {
    final line = rawLine.trimRight();
    final trimmed = line.trim();

    if (trimmed.isEmpty) {
      flushParagraph();
      orderedNo = 0;
      continue;
    }

    // 分隔线
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(const DocBlock(DocBlockKind.divider, ''));
      orderedNo = 0;
      continue;
    }

    // 标题：`#` ~ `######`
    final headingMatch = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (headingMatch != null) {
      flushParagraph();
      final level = headingMatch.group(1)!.length;
      final text = stripInlineMarkdown(headingMatch.group(2)!.trim());
      if (level == 1) {
        sawFirstLevelHeading = true;
        // 一级标题与文档标题相同就不再重复
        if (headingText.isEmpty || text != headingText) {
          blocks.add(DocBlock(DocBlockKind.heading, text));
        }
      } else if (level <= 2) {
        blocks.add(DocBlock(DocBlockKind.heading, text));
      } else {
        blocks.add(DocBlock(DocBlockKind.subheading, text));
      }
      orderedNo = 0;
      continue;
    }

    // 引用
    if (trimmed.startsWith('>')) {
      flushParagraph();
      blocks.add(DocBlock(DocBlockKind.note, stripInlineMarkdown(trimmed.replaceFirst(RegExp(r'^>\s?'), ''))));
      orderedNo = 0;
      continue;
    }

    // 无序列表
    final bulletMatch = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
    if (bulletMatch != null) {
      flushParagraph();
      blocks.add(DocBlock(DocBlockKind.bullet, stripInlineMarkdown(bulletMatch.group(1)!.trim())));
      orderedNo = 0;
      continue;
    }

    // 有序列表
    final orderedMatch = RegExp(r'^(\d+)[.)]\s+(.*)$').firstMatch(trimmed);
    if (orderedMatch != null) {
      flushParagraph();
      final n = int.tryParse(orderedMatch.group(1)!) ?? (orderedNo + 1);
      orderedNo = n;
      blocks.add(DocBlock(DocBlockKind.numbered, stripInlineMarkdown(orderedMatch.group(2)!.trim()), index: n));
      continue;
    }

    // 普通段落行：软换行合并（中文直接相连，西文补空格，见 smartJoin）
    final text = stripInlineMarkdown(trimmed);
    if (paragraph.isEmpty) {
      paragraph.write(text);
    } else {
      paragraph.write(smartJoin(paragraph.toString(), text));
    }
  }
  flushParagraph();

  if (blocks.isEmpty) {
    blocks.add(DocBlock(DocBlockKind.paragraph, (title ?? '总结').trim()));
  }
  return blocks;
}

/// 去掉行内 Markdown 标记（`**粗体**`、`` `代码` ``、`[文本](链接)`、`~~删除~~`、行尾 `#` 等），
/// 只保留可读文字 —— PDF/图片是「所见即所得」的纸面，星号会显得很脏。
String stripInlineMarkdown(String text) {
  // 注意：replaceAll 的替换串**不支持** $1/$2 分组引用，必须用 replaceAllMapped
  var s = text;
  s = s.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\(([^)]*)\)'), (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]*)\]\(([^)]*)\)'), (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(RegExp(r'(\*\*|__)(.*?)\1', dotAll: true), (m) => m.group(2) ?? '');
  // 只处理成对的单星号；单个下划线不动（文件名/变量名里的 snake_case 不该被吃掉）
  s = s.replaceAllMapped(RegExp(r'\*(.*?)\*', dotAll: true), (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(RegExp(r'~~(.*?)~~', dotAll: true), (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1) ?? '');
  s = s.replaceAll(RegExp(r'^\s*[-*+]\s+'), '');
  return s.trim();
}

/// 段落软换行合并：两侧都是 CJK 时不加空格，否则补一个空格。
String smartJoin(String left, String right) {
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;
  final a = left.codeUnitAt(left.length - 1);
  final b = right.codeUnitAt(0);
  if (isCjkCodeUnit(a) || isCjkCodeUnit(b)) return '$left$right';
  return '$left $right';
}

/// 判断码点是否属于 CJK（含中文标点、全角字符、假名、韩文）。
bool isCjkCodeUnit(int codeUnit) {
  return (codeUnit >= 0x3000 && codeUnit <= 0x9FFF) ||
      (codeUnit >= 0xF900 && codeUnit <= 0xFAFF) ||
      (codeUnit >= 0xFF00 && codeUnit <= 0xFFEF) ||
      (codeUnit >= 0xAC00 && codeUnit <= 0xD7AF);
}

/// 单行化：把多行小标题（如「信息点」下带换行的标题）压成一行。
String oneline(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
