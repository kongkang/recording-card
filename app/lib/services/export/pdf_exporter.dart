/// PDF 导出 —— 「文本 → 流式逐页栅格化（即时释放 ui.Image）→ PDF 页面」。
library;

import 'dart:io';

import 'document_renderer.dart';
import 'export_document.dart';
import 'export_exception.dart';
import 'pdf_assembler.dart';

class PdfExporter {
  const PdfExporter({
    this.renderer = const DocumentRenderer(),
    this.assembler = const PdfAssembler(),
  });

  final DocumentRenderer renderer;
  final PdfAssembler assembler;

  /// 生成 PDF 并落盘，返回路径。
  ///
  /// [pageOptions] 可覆盖默认 A4 排版参数（一般不用传）。
  Future<String> write(
    ExportDocument doc,
    String path, {
    DocumentPageOptions? pageOptions,
  }) async {
    final pageStream = renderer.renderPdfPagesStream(
      doc,
      pageOptions: pageOptions,
    );
    final bytes = await assembler.buildPdfFromRenderedPageStream(
      pageStream,
      title: doc.safeTitle,
      subject: doc.meta.trim().isEmpty ? null : doc.meta.trim(),
    );
    if (bytes.isEmpty) {
      throw const ExportException('PDF 生成失败：输出内容为空');
    }
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object catch (e, st) {
      throw ExportException('PDF 文件写入失败，请检查存储空间后重试', cause: e, stackTrace: st);
    }
  }
}
