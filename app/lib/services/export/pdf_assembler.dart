/// PDF 组装 —— 逐页即时 `zlib`（`/FlateDecode`）流式写入 PDF 1.4，杜绝多页未压缩位图堆积内存。
///
/// ## 内存安全设计
/// - [writePdfFromRenderedPageStream]：每收到一页 [RenderedPdfPage]，**立即**在循环当轮调用
///   原生 C `zlib.encode(page.rgbBytes)` 压缩为 `~80–150 KB` 的 `/FlateDecode` 流并直接刷入
///   [RandomAccessFile] 落盘，随后该页原始 `4.95 MB` RGB 缓冲与压缩块均可立即被 GC 回收，
///   实现严格的 `O(1)` 单页内存占用；
/// - [buildPdfFromRenderedPageStream]：内存缓冲版同样逐页立即 `zlib.encode`，仅驻留压缩后的字节块。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_renderer.dart';
import 'export_exception.dart';

abstract class _PdfByteSink {
  int get offset;
  Future<void> writeBytes(List<int> bytes);

  Future<void> writeAscii(String text) => writeBytes(latin1.encode(text));
}

class _FilePdfByteSink extends _PdfByteSink {
  _FilePdfByteSink(this._raf);

  final RandomAccessFile _raf;
  int _offset = 0;

  @override
  int get offset => _offset;

  @override
  Future<void> writeBytes(List<int> bytes) async {
    if (bytes.isEmpty) return;
    await _raf.writeFrom(bytes);
    _offset += bytes.length;
  }
}

class _MemoryPdfByteSink extends _PdfByteSink {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  int get offset => _builder.length;

  @override
  Future<void> writeBytes(List<int> bytes) async {
    if (bytes.isEmpty) return;
    _builder.add(bytes);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

class PdfAssembler {
  const PdfAssembler();

  static const double _a4WidthPt = 595.28;
  static const double _a4HeightPt = 841.89;

  /// 流式消费 [pageStream]，逐页立即用原生 C `zlib.encode` 压缩并直接写入 [file]，
  /// 全程仅保持单页内存峰值（`O(1)` RAM）。返回总页数。
  Future<int> writePdfFromRenderedPageStream(
    Stream<RenderedPdfPage> pageStream,
    File file, {
    String? title,
    String? subject,
    String author = '录音卡',
  }) async {
    await file.parent.create(recursive: true);
    RandomAccessFile? raf;
    var succeeded = false;
    try {
      raf = await file.open(mode: FileMode.writeOnly);
      final sink = _FilePdfByteSink(raf);
      final pageCount = await _writeStreamedPdf14(
        pageStream,
        sink,
        title: title,
        subject: subject,
        author: author,
      );
      await raf.flush();
      await raf.close();
      raf = null;
      succeeded = true;
      return pageCount;
    } on ExportException {
      rethrow;
    } on Object catch (e, st) {
      throw ExportException(
        'PDF 文件写入失败，请检查存储空间后重试',
        cause: e,
        stackTrace: st,
      );
    } finally {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (!succeeded) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// 流式消费 [pageStream]（每页立即 `zlib.encode` 释放原始 `rgbBytes`，内存中仅保存压缩分块），返回完整 PDF 字节。
  Future<Uint8List> buildPdfFromRenderedPageStream(
    Stream<RenderedPdfPage> pageStream, {
    String? title,
    String? subject,
    String author = '录音卡',
  }) async {
    final sink = _MemoryPdfByteSink();
    await _writeStreamedPdf14(
      pageStream,
      sink,
      title: title,
      subject: subject,
      author: author,
    );
    return sink.takeBytes();
  }

  Future<int> _writeStreamedPdf14(
    Stream<RenderedPdfPage> pageStream,
    _PdfByteSink sink, {
    String? title,
    String? subject,
    required String author,
  }) async {
    // PDF 1.4 头与二进制标记注释
    await sink.writeBytes(const <int>[
      0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, // %PDF-1.4\n
      0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A, // %\xE2\xE3\xCF\xD3\n
    ]);

    // 预留固定根对象编号：1 = Catalog, 2 = Pages, 3 = Info
    final offsets = <int, int>{};
    final pageObjIds = <int>[];
    var nextObjId = 4;
    var pageCount = 0;

    await for (final page in pageStream) {
      pageCount++;
      final w = page.width;
      final h = page.height;
      final rgb = page.rgbBytes;
      if (rgb.isEmpty || w <= 0 || h <= 0) {
        throw ExportException('PDF 生成失败：第 $pageCount 页渲染为空');
      }
      if (rgb.length != w * h * 3) {
        throw ExportException('PDF 生成失败：第 $pageCount 页像素尺寸异常');
      }

      // 关键：在当前迭代立即用 dart:io 原生 C zlib 压缩，不把 4.95MB 未压缩 RGB 留到后续页！
      late final Uint8List compressedRgb;
      try {
        compressedRgb = Uint8List.fromList(zlib.encode(rgb));
      } on Object catch (e, st) {
        throw ExportException(
          'PDF 生成失败：第 $pageCount 页图像压缩失败',
          cause: e,
          stackTrace: st,
        );
      }

      final imgObjId = nextObjId++;
      final contentObjId = nextObjId++;
      final pageObjId = nextObjId++;
      pageObjIds.add(pageObjId);

      // 1) Image XObject (/DeviceRGB + /FlateDecode)
      offsets[imgObjId] = sink.offset;
      await sink.writeAscii(
        '$imgObjId 0 obj\n'
        '<< /Type /XObject /Subtype /Image /Width $w /Height $h '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 '
        '/Filter /FlateDecode /Length ${compressedRgb.length} >>\n'
        'stream\n',
      );
      await sink.writeBytes(compressedRgb);
      await sink.writeAscii('\nendstream\nendobj\n');

      // 2) Page Content Stream（A4 BoxFit.contain + Alignment.topCenter）
      final scale = math.min(_a4WidthPt / w, _a4HeightPt / h);
      final drawW = w * scale;
      final drawH = h * scale;
      final dx = (_a4WidthPt - drawW) / 2.0;
      final dy = _a4HeightPt - drawH;
      final contentCmd =
          'q\n${_fmtPt(drawW)} 0 0 ${_fmtPt(drawH)} ${_fmtPt(dx)} ${_fmtPt(dy)} cm\n/Im1 Do\nQ\n';
      final contentBytes = latin1.encode(contentCmd);

      offsets[contentObjId] = sink.offset;
      await sink.writeAscii(
        '$contentObjId 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n',
      );
      await sink.writeBytes(contentBytes);
      await sink.writeAscii('\nendstream\nendobj\n');

      // 3) Page Dictionary
      offsets[pageObjId] = sink.offset;
      await sink.writeAscii(
        '$pageObjId 0 obj\n'
        '<< /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 ${_fmtPt(_a4WidthPt)} ${_fmtPt(_a4HeightPt)}] '
        '/Resources << /ProcSet [/PDF /ImageC] /XObject << /Im1 $imgObjId 0 R >> >> '
        '/Contents $contentObjId 0 R >>\n'
        'endobj\n',
      );
    }

    if (pageCount == 0) {
      throw const ExportException('PDF 生成失败：没有可用的页面内容');
    }

    try {
      // 1 0 obj: Catalog
      offsets[1] = sink.offset;
      await sink.writeAscii('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

      // 2 0 obj: Pages
      final kidsRefs = pageObjIds.map((id) => '$id 0 R').join(' ');
      offsets[2] = sink.offset;
      await sink.writeAscii(
        '2 0 obj\n<< /Type /Pages /Kids [$kidsRefs] /Count $pageCount >>\nendobj\n',
      );

      // 3 0 obj: Info（UTF-16BE BOM 十六进制字符串，完整支持中文标题/摘要元信息）
      final infoFields = <String>[
        '/Producer ${_pdfUtf16BeHex('录音卡 PDF')}',
        if (author.trim().isNotEmpty) '/Author ${_pdfUtf16BeHex(author.trim())}',
        if (title != null && title.trim().isNotEmpty)
          '/Title ${_pdfUtf16BeHex(title.trim())}',
        if (subject != null && subject.trim().isNotEmpty)
          '/Subject ${_pdfUtf16BeHex(subject.trim())}',
      ];
      offsets[3] = sink.offset;
      await sink.writeAscii('3 0 obj\n<< ${infoFields.join(' ')} >>\nendobj\n');

      // xref 表（每项严格 20 字节：`oooooooooo ggggg n \n`）
      final xrefOffset = sink.offset;
      final xrefBuf = StringBuffer()
        ..write('xref\n0 $nextObjId\n')
        ..write('0000000000 65535 f \n');
      for (var id = 1; id < nextObjId; id++) {
        final pos = offsets[id] ?? 0;
        xrefBuf.write('${pos.toString().padLeft(10, '0')} 00000 n \n');
      }
      await sink.writeAscii(xrefBuf.toString());

      // trailer
      await sink.writeAscii(
        'trailer\n'
        '<< /Size $nextObjId /Root 1 0 R /Info 3 0 R >>\n'
        'startxref\n'
        '$xrefOffset\n'
        '%%EOF\n',
      );
      return pageCount;
    } on Object catch (e, st) {
      throw ExportException('PDF 生成失败：写入 PDF 结构时出错', cause: e, stackTrace: st);
    }
  }

  static String _fmtPt(double v) {
    final s = v.toStringAsFixed(3);
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _pdfUtf16BeHex(String text) {
    final sb = StringBuffer('<FEFF');
    for (final unit in text.codeUnits) {
      sb.write(unit.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
    sb.write('>');
    return sb.toString();
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
