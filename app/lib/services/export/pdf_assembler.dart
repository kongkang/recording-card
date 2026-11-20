/// PDF 组装 —— 支持流式嵌入不透明 RGB 位图帧或 PNG 页面，组装为 A4 PDF 文件。
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_renderer.dart';
import 'export_exception.dart';

class PdfAssembler {
  const PdfAssembler();

  /// 流式消费 [pageStream]（已栅格化并释放 `ui.Image` 的 RGB 帧），免去纯 Dart PNG 二次解码与透明通道开销。
  Future<Uint8List> buildPdfFromRenderedPageStream(
    Stream<RenderedPdfPage> pageStream, {
    String? title,
    String? subject,
    String author = '录音卡',
  }) async {
    final document = pw.Document(
      title: title,
      author: author,
      subject: subject,
    );
    var pageCount = 0;

    await for (final page in pageStream) {
      pageCount++;
      if (page.rgbBytes.isEmpty || page.width <= 0 || page.height <= 0) {
        throw ExportException('PDF 生成失败：第 $pageCount 页渲染为空');
      }
      late final PdfImage pdfImage;
      try {
        pdfImage = PdfImage(
          document.document,
          image: page.rgbBytes,
          width: page.width,
          height: page.height,
          alpha: false,
        );
      } on Object catch (e, st) {
        throw ExportException(
          'PDF 生成失败：第 $pageCount 页图像无法写入',
          cause: e,
          stackTrace: st,
        );
      }
      final provider = pw.ImageProxy(pdfImage);
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (pw.Context context) => pw.Image(
            provider,
            fit: pw.BoxFit.contain,
            alignment: pw.Alignment.topCenter,
          ),
        ),
      );
    }

    if (pageCount == 0) {
      throw const ExportException('PDF 生成失败：没有可用的页面内容');
    }

    try {
      return await document.save();
    } on ExportException {
      rethrow;
    } on Object catch (e, st) {
      throw ExportException('PDF 生成失败：写入 PDF 结构时出错', cause: e, stackTrace: st);
    }
  }

  /// 流式消费 [pagePngStream] 并逐页写入 PDF（兼容直接传入 PNG 流的调用方）。
  Future<Uint8List> buildPdfFromPngPageStream(
    Stream<Uint8List> pagePngStream, {
    String? title,
    String? subject,
    String author = '录音卡',
  }) async {
    final document = pw.Document(
      title: title,
      author: author,
      subject: subject,
    );
    var pageCount = 0;

    await for (final bytes in pagePngStream) {
      pageCount++;
      if (bytes.isEmpty) {
        throw ExportException('PDF 生成失败：第 $pageCount 页渲染为空');
      }
      late final pw.MemoryImage image;
      try {
        image = pw.MemoryImage(bytes);
      } on Object catch (e, st) {
        throw ExportException(
          'PDF 生成失败：第 $pageCount 页图像无法解析',
          cause: e,
          stackTrace: st,
        );
      }
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (pw.Context context) => pw.Image(
            image,
            fit: pw.BoxFit.contain,
            alignment: pw.Alignment.topCenter,
          ),
        ),
      );
    }

    if (pageCount == 0) {
      throw const ExportException('PDF 生成失败：没有可用的页面内容');
    }

    try {
      return await document.save();
    } on ExportException {
      rethrow;
    } on Object catch (e, st) {
      throw ExportException('PDF 生成失败：写入 PDF 结构时出错', cause: e, stackTrace: st);
    }
  }

  /// 用 [pagePngs]（按页顺序，像素比例应与 A4 一致）组装 PDF，返回字节（向后兼容入口）。
  Future<Uint8List> buildPdfFromPngPages(
    List<Uint8List> pagePngs, {
    String? title,
    String? subject,
    String author = '录音卡',
  }) {
    if (pagePngs.isEmpty) {
      return Future<Uint8List>.error(
        const ExportException('PDF 生成失败：没有可用的页面内容'),
      );
    }
    return buildPdfFromPngPageStream(
      Stream<Uint8List>.fromIterable(pagePngs),
      title: title,
      subject: subject,
      author: author,
    );
  }
}
