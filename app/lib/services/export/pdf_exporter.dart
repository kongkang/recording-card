/// PDF 导出 —— 「文本 → 多页 PNG（系统字体）→ PDF 页面图片」。
///
/// 中文字体方案的选择与理由见 `pdf_assembler.dart` 顶部注释（结论：
/// iOS 读不到系统字体文件、打包字体又超出本模块职责范围，因此放弃 `PdfTtfFont`，
/// 改用 Flutter 引擎自己排中文，再把整页 PNG 塞进 PDF）。
///
/// 本文件负责 Flutter 侧（回忆渲染），纯 Dart 的 PDF 结构组装在 [PdfAssembler]。
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
    // 1) 逐页渲染成 PNG（中文由系统字体负责，见文件头注释）
    final pages = await renderer.renderPngPages(doc, pageOptions: pageOptions);
    // 2) 组装 PDF（纯 Dart）
    final bytes = await assembler.buildPdfFromPngPages(
      pages,
      title: doc.safeTitle,
      subject: doc.meta.trim().isEmpty ? null : doc.meta.trim(),
    );
    if (bytes.isEmpty) {
      throw const ExportException('PDF 生成失败：输出内容为空');
    }
    // 3) 落盘
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
