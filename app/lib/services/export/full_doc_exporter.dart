/// 「完整文档」导出 —— 一份包含全部内容的可读 PDF。
///
/// 产品语义取舍：「完整文档」不是「把所有格式各导一份」，而是
/// **标题 + 统计行 + 概览 + 全部章节（逻辑结构 / 信息点 / 行动项 / 来源记录）**
/// 合成一份可直接转发、打印的文档，因此选 PDF（复用 [PdfExporter] 的图片页方案，
/// 中文渲染与 PDF/图片两个入口完全一致）。
///
/// 为什么不把 Markdown 原文也塞进去：设计基线明确「『全部』Tab 不含 Markdown 原文」，
/// 原文属于调试/二次加工用途，需要时应选「Markdown」导出（内容 = 原始 md 全文）。
///
/// 文件名会带「完整文档」标注（由 [ExportService] 传入 `nameTag`），
/// 避免和「PDF」导出混在同一个分享列表里分不清哪份是哪份。
library;

import 'document_renderer.dart';
import 'export_document.dart';
import 'pdf_exporter.dart';

class FullDocExporter {
  const FullDocExporter({this.pdfExporter = const PdfExporter()});

  final PdfExporter pdfExporter;

  /// 生成「完整文档」PDF 并落盘，返回路径。
  Future<String> write(
    ExportDocument doc,
    String path, {
    DocumentPageOptions? pageOptions,
  }) {
    // 结构化内容优先；章节为空时 DocumentRenderer 会自动回退解析 Markdown，保证不产出空文档
    return pdfExporter.write(doc, path, pageOptions: pageOptions);
  }
}
