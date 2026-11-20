/// PDF 导出 —— 「文本 → 流式逐页栅格化（即时释放 ui.Image）→ 逐页即时 zlib 压缩流式落盘 PDF 1.4」。
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

  /// 生成 PDF 并直接逐页流式压缩写入 [path]，全程保持单页 `O(1)` 内存峰值，返回落盘路径。
  ///
  /// [pageOptions] 可覆盖默认 A4 排版参数（一般不用传）。
  Future<String> write(
    ExportDocument doc,
    String path, {
    DocumentPageOptions? pageOptions,
  }) async {
    final file = File(path);
    final pageStream = renderer.renderPdfPagesStream(
      doc,
      pageOptions: pageOptions,
    );
    await assembler.writePdfFromRenderedPageStream(
      pageStream,
      file,
      title: doc.safeTitle,
      subject: doc.meta.trim().isEmpty ? null : doc.meta.trim(),
    );
    if (!await file.exists() || await file.length() == 0) {
      throw const ExportException('PDF 生成失败：输出内容为空');
    }
    return file.path;
  }
}
