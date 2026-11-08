library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'export_document.dart';
export 'export_document.dart';

enum ExportFormat { html, markdown, pdf, png, docx }

class RectOrigin {
  const RectOrigin(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
  ui.Rect get rect => ui.Rect.fromLTWH(left, top, width, height);
}

class ExportArtifact {
  const ExportArtifact({
    required this.files,
    required this.mimeType,
    required this.title,
  });
  final List<File> files;
  final String mimeType;
  final String title;
  File get file => files.first;
}

class ExportService {
  ExportService({
    Future<Directory> Function()? directory,
    Future<ByteData> Function()? fontLoader,
    this._shareFiles,
  }) : _directory = directory ?? getTemporaryDirectory,
       _fontLoader = fontLoader ?? (() => rootBundle.load(fontAsset));
  static const fontAsset = 'lib/services/export/assets/NotoSansSC-Regular.ttf';
  final Future<Directory> Function() _directory;
  final Future<ByteData> Function() _fontLoader;
  final Future<void> Function(ExportArtifact, RectOrigin?)? _shareFiles;
  Future<ByteData>? _font;
  Future<void>? _uiFont;
  Future<ByteData> _fontData() => _font ??= _fontLoader();

  Future<ExportArtifact> export(
    SummaryCard card,
    List<RecordEvent> sources,
    ExportFormat format, {
    Set<int> completedTodos = const {},
  }) async {
    if (card.state != SummaryState.done) throw StateError('只能导出已完成的总结');
    final sourceIds = sources.map((e) => e.id).toSet();
    if (!sourceIds.containsAll(card.srcIds) ||
        card.srcIds.toSet().length != sources.length) {
      throw StateError('导出来源不完整');
    }
    final doc = ExportDocument(card, sources, completedTodos: completedTodos);
    final root = await _directory();
    final out = await Directory(
      '${root.path}/recording-card-exports/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final title = card.title ?? '录音总结';
    final safe = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    final base = safe.isEmpty
        ? 'summary'
        : String.fromCharCodes(safe.runes.take(60));
    final names = <(String, Uint8List)>[];
    late String mime;
    switch (format) {
      case ExportFormat.html:
        names.add(('$base.html', Uint8List.fromList(utf8.encode(doc.html))));
        mime = 'text/html';
      case ExportFormat.markdown:
        names.add(('$base.md', Uint8List.fromList(utf8.encode(doc.markdown))));
        mime = 'text/markdown';
      case ExportFormat.docx:
        names.add(('$base.docx', doc.docx()));
        mime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case ExportFormat.pdf:
        names.add(('$base.pdf', await _pdf(doc)));
        mime = 'application/pdf';
      case ExportFormat.png:
        final pages = await _pngPages(doc);
        for (final (i, bytes) in pages.indexed) {
          names.add(('$base${pages.length > 1 ? '-${i + 1}' : ''}.png', bytes));
        }
        mime = 'image/png';
    }
    final files = <File>[];
    for (final (name, bytes) in names) {
      if (bytes.isEmpty) throw StateError('导出文件内容为空');
      final file = File('${out.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      files.add(file);
    }
    return ExportArtifact(
      files: List.unmodifiable(files),
      mimeType: mime,
      title: title,
    );
  }

  Future<Uint8List> _pdf(ExportDocument doc) async {
    final font = pw.Font.ttf(await _fontData());
    final pdf = pw.Document(title: doc.summary.title, author: '录音卡');
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        maxPages: 1000,
        theme: pw.ThemeData.withFont(base: font, bold: font),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ),
        build: (_) => [
          for (final b in doc.blocks)
            pw.Padding(
              padding: pw.EdgeInsets.only(top: b.level > 0 ? 12 : 4, bottom: 5),
              child: pw.Text(
                b.text,
                style: pw.TextStyle(
                  fontSize: b.level == 1
                      ? 22
                      : b.level == 2
                      ? 16
                      : b.level > 0
                      ? 13
                      : 10,
                  lineSpacing: 4,
                ),
              ),
            ),
        ],
      ),
    );
    return pdf.save();
  }

  Future<void> _loadUiFont() => _uiFont ??= () async {
    final loader = FontLoader('RecordingCardExportCJK');
    loader.addFont(_fontData());
    await loader.load();
  }();

  /// Flow layout of the whole semantic document, split into 1600px pages to
  /// bound mobile GPU/memory. Every line is exported; not a screenshot crop.
  Future<List<Uint8List>> _pngPages(ExportDocument doc) async {
    await _loadUiFont();
    const width = 1000.0, pageHeight = 1600.0, margin = 56.0;
    final pages = <Uint8List>[];
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    var y = margin;
    void background() => canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, pageHeight),
      ui.Paint()..color = const ui.Color(0xfffafaf8),
    );
    background();
    Future<void> finish() async {
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        width.toInt(),
        (y + margin).ceil().clamp(1, pageHeight.toInt()),
      );
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('图片编码失败');
        pages.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    for (final block in doc.blocks) {
      final size = block.level == 1
          ? 38.0
          : block.level == 2
          ? 29.0
          : block.level > 0
          ? 25.0
          : 22.0;
      final style = TextStyle(
        fontFamily: 'RecordingCardExportCJK',
        fontSize: size,
        height: 1.55,
        color: const ui.Color(0xff1d1d1f),
        fontWeight: block.level > 0 ? FontWeight.w600 : FontWeight.normal,
      );
      // Split using actual visual line boundaries, never UTF-16 fragments.
      final painter = TextPainter(
        text: TextSpan(text: block.text, style: style),
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: width - margin * 2);
      final metrics = painter.computeLineMetrics();
      if (block.level > 0) y += 20;
      for (final line in metrics) {
        if (y + line.height > pageHeight - margin) {
          await finish();
          recorder = ui.PictureRecorder();
          canvas = ui.Canvas(recorder);
          y = margin;
          background();
        }
        canvas.save();
        canvas.clipRect(
          ui.Rect.fromLTWH(margin, y, width - margin * 2, line.height),
        );
        painter.paint(
          canvas,
          ui.Offset(margin, y - (line.baseline - line.ascent)),
        );
        canvas.restore();
        y += line.height;
      }
      y += 16;
      painter.dispose();
    }
    await finish();
    return pages;
  }

  Future<void> share(ExportArtifact artifact, {RectOrigin? origin}) async {
    if (_shareFiles != null) {
      await _shareFiles(artifact, origin);
      return;
    }
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final file in artifact.files)
            XFile(file.path, mimeType: artifact.mimeType),
        ],
        title: artifact.title,
        subject: artifact.title,
        sharePositionOrigin: origin?.rect,
      ),
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw StateError('当前平台系统分享不可用');
    }
    // Dismissal is not external delivery and must not be labelled as success.
  }
}
