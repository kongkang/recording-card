library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../core/models/record.dart';
import '../../core/models/summary.dart';

class ExportBlock {
  const ExportBlock(this.text, {this.level = 0});
  final String text;
  final int level;
}

/// One complete semantic document backs all five formats; never just viewport.
class ExportDocument {
  ExportDocument(this.summary, this.sources, {this.completedTodos = const {}});
  final SummaryCard summary;
  final List<RecordEvent> sources;
  final Set<int> completedTodos;
  List<ExportBlock> get blocks => [
    ExportBlock(summary.title ?? '录音总结', level: 1),
    ExportBlock(summary.subDesc ?? '${sources.length} 条记录'),
    const ExportBlock('概览', level: 2),
    ExportBlock(summary.overview ?? ''),
    const ExportBlock('逻辑结构', level: 2),
    for (final branch in summary.structure) ...[
      ExportBlock(branch.name, level: 3),
      for (final leaf in branch.leaves) ExportBlock('• $leaf'),
    ],
    const ExportBlock('信息点', level: 2),
    for (final point in summary.points) ...[
      ExportBlock(point.title, level: 3),
      ExportBlock(point.detail),
      for (final ref in point.sources)
        ExportBlock('来源：${ref.label} · ${ref.range} [${ref.eventId}]'),
    ],
    const ExportBlock('行动项', level: 2),
    for (final (i, todo) in summary.todos.indexed) ...[
      ExportBlock('${completedTodos.contains(i) ? '[x]' : '[ ]'} $todo'),
      if (i < summary.todoSources.length)
        for (final ref in summary.todoSources[i])
          ExportBlock('行动项来源：${ref.label} · ${ref.range} [${ref.eventId}]'),
    ],
    const ExportBlock('不确定性', level: 2),
    for (final text in summary.uncertainties) ExportBlock(text),
    const ExportBlock('完整来源索引', level: 2),
    for (final ref in summary.sources)
      ExportBlock('来源：${ref.label} · ${ref.range} [${ref.eventId}]'),
    const ExportBlock('来源记录', level: 2),
    if (summary.srcDesc?.isNotEmpty == true) ExportBlock(summary.srcDesc!),
    for (final record in sources) ...[
      ExportBlock(record.title, level: 3),
      ExportBlock(
        '${record.time} · ${record.dur} · ${record.srcMap} [${record.id}]',
      ),
      ExportBlock('说话人：${record.speakers}（推测归类，非已验证身份）'),
      if (record.mark.isNotEmpty) ExportBlock('标记：${record.mark}'),
      ExportBlock(record.longText),
      const ExportBlock('对话详情', level: 4),
      for (final turn in record.dialog)
        ExportBlock('${turn.spk} · ${turn.src}\n${turn.text}'),
      const ExportBlock('原始数据', level: 4),
      for (final turn in record.raw)
        ExportBlock('${turn.spk} · ${turn.src}\n${turn.text}'),
    ],
  ];
  static String escapeHtml(String text) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(text);
  static String escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  String get markdown =>
      '${blocks.map((b) => b.level == 0 ? b.text : '${'#' * b.level} ${b.text}').join('\n\n')}\n';
  String get html =>
      '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(summary.title ?? '录音总结')}</title>
<style>body{font-family:system-ui,"PingFang SC","Noto Sans SC",sans-serif;background:#FAFAF8;color:#1D1D1F;line-height:1.8;margin:0}main{max-width:880px;margin:0 auto;padding:36px 24px}h1{font-size:28px}h2{border-bottom:1px solid #E4E4E0;padding-top:20px}h3{font-size:18px}p{white-space:pre-wrap;overflow-wrap:anywhere}h1,h2,h3,h4{break-after:avoid}@media print{body{background:white}main{padding:0}}</style>
</head><body><main>${blocks.map((b) => b.level == 0 ? '<p>${escapeHtml(b.text)}</p>' : '<h${b.level}>${escapeHtml(b.text)}</h${b.level}>').join('\n')}</main></body></html>\n''';

  Uint8List docx() {
    final zip = Archive();
    void add(String path, String text) {
      final bytes = utf8.encode(text);
      zip.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add(
      '[Content_Types].xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>''',
    );
    add(
      '_rels/.rels',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''',
    );
    add(
      'word/_rels/document.xml.rels',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''',
    );
    add(
      'word/styles.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Noto Sans SC"/><w:sz w:val="22"/><w:lang w:val="zh-CN" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>''',
    );
    final paragraphs = blocks.map((b) {
      final size = b.level == 1
          ? 40
          : b.level == 2
          ? 30
          : b.level > 0
          ? 26
          : 22;
      final runs = b.text
          .split('\n')
          .map(
            (line) =>
                '<w:r><w:rPr>${b.level > 0 ? '<w:b/>' : ''}<w:sz w:val="$size"/><w:rFonts w:eastAsia="Noto Sans SC"/></w:rPr><w:t xml:space="preserve">${escapeXml(line)}</w:t></w:r>',
          )
          .join('<w:r><w:br/></w:r>');
      return '<w:p><w:pPr><w:spacing w:after="140"/>${b.level > 0 ? '<w:keepNext/><w:outlineLvl w:val="${b.level - 1}"/>' : ''}</w:pPr>$runs</w:p>';
    }).join();
    add(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$paragraphs<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body></w:document>''',
    );
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }
}
