/// 总结导出 —— 5 种格式生成真实文件字节，分享经 [ExportSharer] 接缝。
///
/// - Markdown / 完整文档：UTF-8 文本
/// - Word：最小合法 docx（zip + document.xml）
/// - 图片：dart:ui 渲染 A4 版面 PNG
/// - PDF：把同一版面 PNG 嵌入 A4 单页（不依赖 CJK 字体资产）
/// - 分享：share_plus 调系统分享；测试注入 FakeSharer，不触发平台通道
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../core/models/summary.dart';

enum ExportFormat {
  fullDoc('完整文档', 'txt', 'text/plain'),
  markdown('Markdown', 'md', 'text/markdown'),
  pdf('PDF', 'pdf', 'application/pdf'),
  image('图片', 'png', 'image/png'),
  word('Word 文档', 'docx',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document');

  const ExportFormat(this.label, this.extension, this.mimeType);

  final String label;
  final String extension;
  final String mimeType;
}

class ExportArtifact {
  const ExportArtifact({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
  });

  final String fileName;
  final Uint8List bytes;
  final String mimeType;
}

abstract class ExportSharer {
  Future<void> share(ExportArtifact artifact);
}

/// 生产实现：写临时文件后调系统分享面板。
class SharePlusSharer implements ExportSharer {
  const SharePlusSharer();

  @override
  Future<void> share(ExportArtifact artifact) async {
    final dir = await Directory.systemTemp.createTemp('recording-card-export');
    final file = File('${dir.path}/${artifact.fileName}');
    await file.writeAsBytes(artifact.bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: artifact.mimeType)],
      subject: artifact.fileName,
    ));
  }
}

class ExportService {
  ExportService({ExportSharer? sharer}) : sharer = sharer ?? const SharePlusSharer();

  final ExportSharer sharer;

  Future<ExportArtifact> build(SummaryCard card, ExportFormat format) async {
    final base = _baseName(card);
    final List<int> bytes = switch (format) {
      ExportFormat.markdown => utf8.encode(card.markdown ?? _fullDoc(card)),
      ExportFormat.fullDoc => utf8.encode(_fullDoc(card)),
      ExportFormat.word => _buildDocx(card),
      ExportFormat.image => await _renderPng(card),
      ExportFormat.pdf => await _buildPdf(await _renderPng(card)),
    };
    return ExportArtifact(
      fileName: '$base.${format.extension}',
      bytes: Uint8List.fromList(bytes),
      mimeType: format.mimeType,
    );
  }

  Future<void> share(ExportArtifact artifact) => sharer.share(artifact);

  static String _baseName(SummaryCard card) {
    final raw = (card.title ?? '总结').trim();
    final clean = raw.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return clean.isEmpty ? 'summary' : clean;
  }

  static String _fullDoc(SummaryCard card) {
    final b = StringBuffer()
      ..writeln(card.title ?? '总结')
      ..writeln(card.subDesc ?? '')
      ..writeln()
      ..writeln('概览')
      ..writeln(card.overview ?? '')
      ..writeln()
      ..writeln('逻辑结构');
    for (final branch in card.structure) {
      b.writeln('${branch.name}：${branch.leaves.join(' / ')}');
    }
    b
      ..writeln()
      ..writeln('信息点');
    for (final p in card.points) {
      b
        ..writeln(p.title)
        ..writeln(p.detail);
      for (final s in p.sources) {
        b.writeln('来源：${s.label} · ${s.range}');
      }
      b.writeln();
    }
    b.writeln('行动项');
    for (final t in card.todos) {
      b.writeln('- $t');
    }
    b
      ..writeln()
      ..writeln('来源记录')
      ..writeln(card.srcDesc ?? '');
    return b.toString();
  }

  static List<int> _buildDocx(SummaryCard card) {
    String esc(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    String para(String text, {bool bold = false}) =>
        '<w:p><w:r>${bold ? '<w:rPr><w:b/></w:rPr>' : ''}'
        '<w:t xml:space="preserve">${esc(text)}</w:t></w:r></w:p>';

    final body = StringBuffer()
      ..write(para(card.title ?? '总结', bold: true))
      ..write(para(card.subDesc ?? ''))
      ..write(para('概览', bold: true))
      ..write(para(card.overview ?? ''))
      ..write(para('逻辑结构', bold: true));
    for (final branch in card.structure) {
      body.write(para('${branch.name}：${branch.leaves.join(' / ')}'));
    }
    body.write(para('信息点', bold: true));
    for (final p in card.points) {
      body
        ..write(para(p.title, bold: true))
        ..write(para(p.detail));
      for (final s in p.sources) {
        body.write(para('来源：${s.label} · ${s.range}'));
      }
    }
    body.write(para('行动项', bold: true));
    for (final t in card.todos) {
      body.write(para('☐ $t'));
    }
    body
      ..write(para('来源记录', bold: true))
      ..write(para(card.srcDesc ?? ''));

    const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>';
    const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';
    final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
        '</w:sectPr></w:body></w:document>';

    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
    final archive = Archive()
      ..addFile(ArchiveFile('[Content_Types].xml', 0, bytes(contentTypes)))
      ..addFile(ArchiveFile('_rels/.rels', 0, bytes(rels)))
      ..addFile(ArchiveFile('word/document.xml', 0, bytes(document)));
    return ZipEncoder().encode(archive);
  }

  static Future<Uint8List> _buildPdf(Uint8List png) async {
    final doc = pw.Document();
    final image = pw.MemoryImage(png);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(0),
      build: (context) =>
          pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
    return doc.save();
  }

  static Future<Uint8List> _renderPng(SummaryCard card) async {
    const width = 1240.0;
    const height = 1754.0;
    const margin = 72.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = const ui.Color(0xFFFAFAF8),
    );

    var y = margin;
    void draw(
      String text, {
      double size = 24,
      bool bold = false,
      ui.Color color = const ui.Color(0xFF1D1D1F),
      double gap = 16,
    }) {
      if (text.trim().isEmpty) return;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            color: color,
            height: 1.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - margin * 2);
      painter.paint(canvas, ui.Offset(margin, y));
      y += painter.height + gap;
    }

    const ink = ui.Color(0xFF1D1D1F);
    const sec = ui.Color(0xFF8A8A8E);
    draw(card.title ?? '总结', size: 44, bold: true, gap: 8);
    draw(card.subDesc ?? '', size: 21, color: sec, gap: 30);
    draw('概览', size: 30, bold: true, gap: 8);
    draw(card.overview ?? '', size: 23, gap: 28);
    draw('逻辑结构', size: 30, bold: true, gap: 8);
    for (final branch in card.structure) {
      draw('${branch.name}：${branch.leaves.join(' / ')}', size: 22, gap: 6);
    }
    draw('信息点', size: 30, bold: true, gap: 8);
    for (final p in card.points) {
      draw('• ${p.title}', size: 24, bold: true, color: ink, gap: 4);
      draw(p.detail, size: 21, color: ink, gap: 12);
    }
    draw('行动项', size: 30, bold: true, gap: 8);
    for (final t in card.todos) {
      draw('☐ $t', size: 22, gap: 6);
    }
    draw('来源记录', size: 30, bold: true, gap: 8);
    draw(card.srcDesc ?? '', size: 20, color: sec, gap: 4);

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return data!.buffer.asUint8List();
  }
}
