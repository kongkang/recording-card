/// 文档渲染器 —— 用 Flutter 自己的文字排版把 [ExportDocument] 画成 PNG（A4 流式分页 / 长图两种）。
///
/// ## 关键约束
/// - 不继承用户系统字号（`TextScaler.noScaling`）：导出是纸面文档，字号必须稳定；
/// - PDF 采用逐页流式栅格化（[renderPngPagesStream]）：每页 `ui.Image` / `ui.Picture` / `TextPainter`
///   在编码出单页 PNG 后立即释放，绝不同时驻留几十页未压缩位图；
/// - 长图限制最大像素高度与未压缩 RGBA 字节预算（[LongImageOptions]），防止低内存 iOS/Android OOM。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'document_layout.dart';
import 'export_document.dart';
import 'export_exception.dart';

/// 页面排版参数（A4 比例）。
class DocumentPageOptions {
  const DocumentPageOptions({
    this.logicalWidth = 540,
    this.margin = 40,
    this.pixelRatio = 2.0,
    this.maxPages = 500,
    this.footerReserve = 36,
  });

  /// A4 高宽比 841.89 / 595.28。
  static const double a4AspectRatio = 841.89 / 595.28;

  /// 版面逻辑宽度（A4 等比缩放）。
  final double logicalWidth;

  /// 页边距（四边一致）。
  final double margin;

  /// 栅格化倍率：2.0 → 1080×1528 px/页，正文 13.5pt 在 A4 上清晰可读。
  final double pixelRatio;

  /// 安全上限页数（流式分页可平稳承载数百页整周/整月转写，防极端死循环）。
  final int maxPages;

  /// 页脚预留高度（画页码）。
  final double footerReserve;

  /// 页面逻辑高度。
  double get pageHeight => logicalWidth * a4AspectRatio;

  /// 正文可用宽度。
  double get contentWidth => logicalWidth - margin * 2;

  /// 正文可用高度（扣掉上下边距与页脚）。
  double get contentHeight => pageHeight - margin * 2 - footerReserve;

  /// 输出像素宽。
  int get pixelWidth => (logicalWidth * pixelRatio).round();

  /// 输出像素高。
  int get pixelHeight => (pageHeight * pixelRatio).round();
}

/// 长图参数（限制像素高度与未压缩位图内存峰值，保障低端机不 OOM）。
class LongImageOptions {
  const LongImageOptions({
    this.pixelRatio = 1.5,
    this.maxPixelHeight = 12000,
    this.maxDecodedBytes = 36 * 1024 * 1024,
  });

  /// 长图基准倍率：1.5 → 宽 810px（超长文档会自动在 1.0~1.5 间平滑降倍率以容纳更多内容且不超内存上限）。
  final double pixelRatio;

  /// 长图最大像素高度（低于 iOS Metal / Android GLES3 的 16384 纹理硬上限）。
  final int maxPixelHeight;

  /// 单张未压缩 RGBA 位图最大字节预算（默认 36MB）。
  final int maxDecodedBytes;
}

/// 单页已栅格化的不透明 RGB 位图帧（供 PDF 流式嵌入，免去 PNG 编解码二次开销）。
class RenderedPdfPage {
  const RenderedPdfPage({
    required this.width,
    required this.height,
    required this.rgbBytes,
  });

  final int width;
  final int height;
  final Uint8List rgbBytes;
}

/// A4 等比分页的文档渲染器。
class DocumentRenderer {
  const DocumentRenderer({this.options = const DocumentPageOptions()});

  final DocumentPageOptions options;

  /// 逐页流式输出不透明 RGB 位图帧（PDF 导出高速低内存主路径）：
  /// 每完成一页立即调用 `image.dispose()`、`picture.dispose()` 与 `page.disposePainters()`，
  /// 且跳过 PNG 编码与纯 Dart PNG 二次解码，直接交由原生 C `zlib` 写入 PDF。
  Stream<RenderedPdfPage> renderPdfPagesStream(
    ExportDocument doc, {
    bool preferMarkdown = false,
    DocumentPageOptions? pageOptions,
  }) async* {
    final o = pageOptions ?? options;
    final blocks = buildDocBlocks(doc, preferMarkdown: preferMarkdown);
    final images = await _loadDocImages(blocks, maxTargetWidth: o.pixelWidth);
    try {
      final laidOut = _paginate(blocks, o, images: images);
      try {
        final totalPages = laidOut.pages.length;
        final w = o.pixelWidth;
        final h = o.pixelHeight;
        for (var i = 0; i < totalPages; i++) {
          final page = laidOut.pages[i];
          late final Uint8List rgbBytes;
          final picture = _recordPage(
            page,
            o,
            doc: doc,
            pageIndex: i,
            totalPages: totalPages,
          );
          try {
            final image = await picture.toImage(w, h);
            try {
              rgbBytes = await _extractOpaqueRgb(image, w, h);
            } finally {
              image.dispose();
            }
          } finally {
            picture.dispose();
            page.disposePainters();
          }
          yield RenderedPdfPage(width: w, height: h, rgbBytes: rgbBytes);
          if (i + 1 < totalPages) {
            await Future<void>.microtask(() {});
          }
        }
      } finally {
        laidOut.dispose();
      }
    } finally {
      _disposeImages(images);
    }
  }

  /// 逐页流式渲染 A4 PNG：每编码完一页立即 dispose 该页 `ui.Image`、`ui.Picture` 与 `TextPainter`，
  /// 内存峰值恒定为单页位图（~6.6MB），避免多页长文档同时驻留导致 OOM。
  Stream<Uint8List> renderPngPagesStream(
    ExportDocument doc, {
    bool preferMarkdown = false,
    DocumentPageOptions? pageOptions,
  }) async* {
    final o = pageOptions ?? options;
    final blocks = buildDocBlocks(doc, preferMarkdown: preferMarkdown);
    final images = await _loadDocImages(blocks, maxTargetWidth: o.pixelWidth);
    try {
      final laidOut = _paginate(blocks, o, images: images);
      try {
        final totalPages = laidOut.pages.length;
        for (var i = 0; i < totalPages; i++) {
          final page = laidOut.pages[i];
          late final Uint8List pngBytes;
          final picture = _recordPage(
            page,
            o,
            doc: doc,
            pageIndex: i,
            totalPages: totalPages,
          );
          try {
            final image = await picture.toImage(o.pixelWidth, o.pixelHeight);
            try {
              pngBytes = await _encodePng(image);
            } finally {
              image.dispose();
            }
          } finally {
            picture.dispose();
            page.disposePainters();
          }
          yield pngBytes;
          if (i + 1 < totalPages) {
            await Future<void>.microtask(() {});
          }
        }
      } finally {
        laidOut.dispose();
      }
    } finally {
      _disposeImages(images);
    }
  }

  /// 渲染为多页 PNG 列表（向后兼容入口；PDF 导出主路径优先走 [renderPngPagesStream]）。
  Future<List<Uint8List>> renderPngPages(
    ExportDocument doc, {
    bool preferMarkdown = false,
    DocumentPageOptions? pageOptions,
  }) {
    return renderPngPagesStream(
      doc,
      preferMarkdown: preferMarkdown,
      pageOptions: pageOptions,
    ).toList();
  }

  /// 渲染为一张长图（带纹理高度与 RGBA 内存预算双重安全上限）。
  ///
  /// 超过 [LongImageOptions.maxPixelHeight] 或 [LongImageOptions.maxDecodedBytes] 时自动降倍率并安全截断，
  /// 在末尾注明完整内容可改用 PDF 导出。
  Future<Uint8List> renderLongImagePng(
    ExportDocument doc, {
    bool preferMarkdown = false,
    DocumentPageOptions? pageOptions,
    LongImageOptions longImage = const LongImageOptions(),
  }) async {
    final o = pageOptions ?? options;
    final blocks = buildDocBlocks(doc, preferMarkdown: preferMarkdown);
    final maxImgWidth = (o.logicalWidth * longImage.pixelRatio).round();
    final images = await _loadDocImages(blocks, maxTargetWidth: maxImgWidth);
    try {
      final laidOut = _paginate(blocks, o, images: images);
      try {
        final pages = laidOut.pages;

        // 文档末页只取实际用到的高度，避免长图底部留一大片空白
        double pageSliceHeight(int i) => i == pages.length - 1
            ? (o.margin + pages[i].used + o.margin * 0.6)
            : o.pageHeight;

        var totalFullLogicalHeight = 0.0;
        for (var i = 0; i < pages.length; i++) {
          totalFullLogicalHeight += pageSliceHeight(i);
        }

        // 在 [1.0, longImage.pixelRatio] 范围内自适应计算安全栅格化倍率，尽量不截断中长篇文档且绝不突破内存上限
        final minRatio = math.min(1.0, longImage.pixelRatio);
        var ratio = longImage.pixelRatio;
        if (totalFullLogicalHeight > 0) {
          final maxRatioByHeight = longImage.maxPixelHeight / totalFullLogicalHeight;
          final maxRatioByBytes = math.sqrt(
            longImage.maxDecodedBytes /
                (4.0 * o.logicalWidth * totalFullLogicalHeight),
          );
          final safeIdeal = math.min(maxRatioByHeight, maxRatioByBytes);
          if (safeIdeal < ratio) {
            ratio = safeIdeal.clamp(minRatio, longImage.pixelRatio);
          }
        }

        final pixelWidth = math.max(1, (o.logicalWidth * ratio).round());
        final maxPixelsByBytes = math.max(
          1,
          longImage.maxDecodedBytes ~/ (pixelWidth * 4),
        );
        final effectiveMaxPixelHeight = math.min(
          longImage.maxPixelHeight,
          maxPixelsByBytes,
        );
        // 预留截断提示高度余量
        const noteReserveLogical = 44.0;
        final maxLogicalHeight = effectiveMaxPixelHeight / ratio;

        final included = <int>[];
        var logicalHeight = 0.0;
        var truncated = false;
        for (var i = 0; i < pages.length; i++) {
          final sliceHeight = pageSliceHeight(i);
          final reserve = i < pages.length - 1 ? noteReserveLogical : 0.0;
          if (logicalHeight + sliceHeight + reserve > maxLogicalHeight) {
            truncated = true;
            break;
          }
          included.add(i);
          logicalHeight += sliceHeight;
        }
        if (included.isEmpty) {
          throw const ExportException('图片导出失败：内容超出单张图片高度上限，请改用 PDF 导出');
        }

        final notePainter = truncated
            ? _layoutNote('内容过长，长图已截断；完整内容请导出 PDF', o)
            : null;
        if (notePainter != null) {
          logicalHeight = math.min(
            maxLogicalHeight,
            logicalHeight + notePainter.height + 12,
          );
        }
        final minHeight = math.min(maxLogicalHeight, o.margin * 2 + 120);
        if (logicalHeight < minHeight) logicalHeight = minHeight;

        final pixelHeight = math
            .min(effectiveMaxPixelHeight, (logicalHeight * ratio).round())
            .clamp(1, effectiveMaxPixelHeight);

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(ratio);
        // 白底（导出文档固定浅色底，深色模式下也保持可打印）
        canvas.drawRect(
          Rect.fromLTWH(0, 0, o.logicalWidth, pixelHeight / ratio),
          Paint()..color = const Color(0xFFFFFFFF),
        );

        var offsetY = 0.0;
        for (final pageIndex in included) {
          _paintPlacedItems(canvas, pages[pageIndex], o, offsetY);
          offsetY += pageSliceHeight(pageIndex);
        }

        notePainter?.paint(
          canvas,
          Offset(
            o.margin,
            (pixelHeight / ratio) - notePainter.height - o.margin * 0.6,
          ),
        );

        final picture = recorder.endRecording();
        try {
          final image = await picture.toImage(pixelWidth, pixelHeight);
          try {
            return await _encodePng(image);
          } finally {
            image.dispose();
          }
        } finally {
          picture.dispose();
          notePainter?.dispose();
        }
      } finally {
        laidOut.dispose();
      }
    } finally {
      _disposeImages(images);
    }
  }

  Future<Map<String, ui.Image>> _loadDocImages(
    List<DocBlock> blocks, {
    required int maxTargetWidth,
  }) async {
    final result = <String, ui.Image>{};
    for (final block in blocks) {
      if (block.kind != DocBlockKind.image) continue;
      final path = block.imagePath?.trim() ?? '';
      if (path.isEmpty || result.containsKey(path)) continue;
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        // 对体积较大的相机原图在解码阶段直接按版面宽度下采样，防止 12MP 多图解码撑爆内存
        final codec = bytes.length > 256 * 1024
            ? await ui.instantiateImageCodec(
                bytes,
                targetWidth: math.max(320, maxTargetWidth),
              )
            : await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        result[path] = frame.image;
      } catch (_) {
        // 无法读取或解码本地图片时回退为文本图注
      }
    }
    return result;
  }

  void _disposeImages(Map<String, ui.Image> images) {
    for (final img in images.values) {
      img.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // 排版
  // ---------------------------------------------------------------------------

  /// 把块序列排进若干页（逻辑坐标，y=0 表示正文区顶部）。
  _PaginatedDoc _paginate(
    List<DocBlock> blocks,
    DocumentPageOptions o, {
    Map<String, ui.Image> images = const {},
  }) {
    final pages = <_Page>[_Page()];
    final contentWidth = o.contentWidth;
    final contentHeight = o.contentHeight;
    var truncated = false;

    blocksLoop:
    for (final block in blocks) {
      final spec = _specFor(block.kind);
      final maxWidth = contentWidth - spec.indent;

      if (block.kind == DocBlockKind.divider) {
        var page = pages.last;
        final gap = page.items.isEmpty ? 0.0 : spec.gapBefore;
        if (page.used + gap + 1 > contentHeight && page.items.isNotEmpty) {
          if (pages.length >= o.maxPages) {
            truncated = true;
            break blocksLoop;
          }
          pages.add(_Page());
          page = pages.last;
        }
        final gap2 = page.items.isEmpty ? 0.0 : spec.gapBefore;
        page.items.add(_PlacedItem.divider(y: page.used + gap2));
        page.used += gap2 + spec.gapAfter + 1;
        continue;
      }

      if (block.kind == DocBlockKind.image) {
        final path = block.imagePath?.trim() ?? '';
        final img = path.isEmpty ? null : images[path];
        if (img != null) {
          final caption = block.text.trim();
          final captionSpec = _specFor(DocBlockKind.note);
          final captionPainter = caption.isNotEmpty
              ? _layoutText(caption, captionSpec, contentWidth)
              : null;
          final captionH =
              captionPainter == null ? 0.0 : (captionPainter.height + 4);
          final maxW = contentWidth;
          final maxH = math.min(contentHeight * 0.42, 220.0);
          final scale = math
              .min(maxW / img.width, maxH / img.height)
              .clamp(0.01, 2.0);
          final drawW = img.width * scale;
          final drawH = img.height * scale;

          var page = pages.last;
          final gap = page.items.isEmpty ? 0.0 : spec.gapBefore;
          if (page.used + gap + drawH + captionH > contentHeight &&
              page.items.isNotEmpty) {
            if (pages.length >= o.maxPages) {
              captionPainter?.dispose();
              truncated = true;
              break blocksLoop;
            }
            pages.add(_Page());
            page = pages.last;
          }
          final gap2 = page.items.isEmpty ? 0.0 : spec.gapBefore;
          final imgY = page.used + gap2;
          page.items.add(
            _PlacedItem.image(
              image: img,
              rect: Rect.fromLTWH(o.margin, imgY, drawW, drawH),
              y: imgY,
            ),
          );
          if (captionPainter != null) {
            page.items.add(
              _PlacedItem.text(
                painter: captionPainter,
                x: o.margin,
                y: imgY + drawH + 4,
              ),
            );
          }
          page.used += gap2 + drawH + captionH + spec.gapAfter;
          continue;
        }
      }

      final text = _composeText(block);
      if (text.trim().isEmpty) continue;

      var remaining = text;
      while (remaining.isNotEmpty) {
        if (pages.length > o.maxPages) {
          truncated = true;
          break blocksLoop;
        }
        final page = pages.last;
        final gap = page.items.isEmpty ? 0.0 : spec.gapBefore;
        final available = contentHeight - page.used - gap;

        // 剩余空间连一行都放不下 → 换页
        if (available < spec.size * 1.2 && page.items.isNotEmpty) {
          if (pages.length >= o.maxPages) {
            truncated = true;
            break blocksLoop;
          }
          pages.add(_Page());
          continue;
        }

        final painter = _layoutText(remaining, spec, maxWidth);
        if (painter.height <= available) {
          page.items.add(
            _PlacedItem.text(
              painter: painter,
              x: o.margin + spec.indent,
              y: page.used + gap,
            ),
          );
          page.used += gap + painter.height + spec.gapAfter;
          remaining = '';
          continue;
        }

        // 整块放不下（长段落 / 长条目）：按"能放下多高"切出前缀，剩下的顺延到下一页
        painter.dispose();
        final cut = _fitByRatio(remaining, spec, maxWidth, available);
        var headText = remaining.substring(0, cut).trimRight();
        if (headText.isEmpty) {
          if (page.items.isNotEmpty) {
            if (pages.length >= o.maxPages) {
              truncated = true;
              break blocksLoop;
            }
            pages.add(_Page());
            continue;
          }
          headText = remaining.substring(0, 1);
        }
        final headPainter = _layoutText(headText, spec, maxWidth);
        page.items.add(
          _PlacedItem.text(
            painter: headPainter,
            x: o.margin + spec.indent,
            y: page.used + gap,
          ),
        );
        page.used += gap + headPainter.height + spec.gapAfter;
        remaining = remaining.substring(headText.length).trimLeft();
      }
    }

    if (truncated) {
      final page = pages.last;
      final notePainter = _layoutText(
        '（内容过长，仅导出前 ${o.maxPages} 页）',
        _specFor(DocBlockKind.note),
        o.contentWidth,
      );
      if (page.used + notePainter.height + 12 <= o.contentHeight) {
        page.items.add(
          _PlacedItem.text(painter: notePainter, x: o.margin, y: page.used + 12),
        );
        page.used += notePainter.height + 12;
      } else {
        pages.add(
          _Page()
            ..items.add(_PlacedItem.text(painter: notePainter, x: o.margin, y: 0))
            ..used = notePainter.height,
        );
      }
    }

    return _PaginatedDoc(pages, truncated);
  }

  /// 一页画进 Picture（已按 pixelRatio 缩放，逻辑坐标直接可用）。
  ui.Picture _recordPage(
    _Page page,
    DocumentPageOptions o, {
    required ExportDocument doc,
    required int pageIndex,
    required int totalPages,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(o.pixelRatio);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, o.logicalWidth, o.pageHeight),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    _paintPlacedItems(canvas, page, o, 0);
    _paintFooter(canvas, o, pageIndex: pageIndex, totalPages: totalPages);
    return recorder.endRecording();
  }

  /// 把一页里的条目画到画布上；[offsetY] 用于长图拼接时整页下移。
  void _paintPlacedItems(
    Canvas canvas,
    _Page page,
    DocumentPageOptions o,
    double offsetY,
  ) {
    for (final item in page.items) {
      final y = o.margin + item.y + offsetY;
      final painter = item.painter;
      final img = item.image;
      final imgRect = item.imageRect;
      if (painter != null) {
        painter.paint(canvas, Offset(item.x, y));
      } else if (img != null && imgRect != null) {
        final dst = Rect.fromLTWH(imgRect.left, y, imgRect.width, imgRect.height);
        final src = Rect.fromLTWH(
          0,
          0,
          img.width.toDouble(),
          img.height.toDouble(),
        );
        canvas.save();
        canvas.clipRRect(
          RRect.fromRectAndRadius(dst, const Radius.circular(8)),
        );
        canvas.drawImageRect(
          img,
          src,
          dst,
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();
      } else {
        canvas.drawLine(
          Offset(o.margin, y),
          Offset(o.logicalWidth - o.margin, y),
          Paint()
            ..color = const Color(0xFFE4E4E0)
            ..strokeWidth = 1,
        );
      }
    }
  }

  void _paintFooter(
    Canvas canvas,
    DocumentPageOptions o, {
    required int pageIndex,
    required int totalPages,
  }) {
    const style = TextStyle(fontSize: 10, color: Color(0xFF8A8A8E));
    final left = TextPainter(
      text: const TextSpan(text: '录音卡 · 总结导出', style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final right = TextPainter(
      text: TextSpan(text: '第 ${pageIndex + 1} / $totalPages 页', style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final y = o.pageHeight - o.margin * 0.6 - left.height;
    left.paint(canvas, Offset(o.margin, y));
    right.paint(canvas, Offset(o.logicalWidth - o.margin - right.width, y));
    left.dispose();
    right.dispose();
  }

  TextPainter _layoutText(String text, _BlockSpec spec, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: spec.size,
          fontWeight: spec.weight,
          color: spec.color,
          height: spec.lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  TextPainter _layoutNote(String text, DocumentPageOptions o) => _layoutText(
    text,
    _specFor(DocBlockKind.note),
    o.contentWidth,
  );

  int _fitByRatio(
    String text,
    _BlockSpec spec,
    double maxWidth,
    double targetHeight,
  ) {
    if (text.length <= 1) return text.length;
    var take = text.length;
    for (var i = 0; i < 6 && take > 1; i++) {
      final painter = _layoutText(text.substring(0, take), spec, maxWidth);
      final height = painter.height;
      painter.dispose();
      if (height <= targetHeight) break;
      final ratio = (targetHeight / height).clamp(0.1, 0.95);
      take = (take * ratio).floor().clamp(1, take - 1);
    }
    return take;
  }

  String _composeText(DocBlock block) {
    switch (block.kind) {
      case DocBlockKind.bullet:
        return '· ${block.text}';
      case DocBlockKind.numbered:
        return '${block.index ?? 1}. ${block.text}';
      case DocBlockKind.image:
        final t = block.text.trim();
        return t.isEmpty ? '[现场图片]' : '[现场图片] $t';
      default:
        return block.text;
    }
  }

  _BlockSpec _specFor(DocBlockKind kind) {
    switch (kind) {
      case DocBlockKind.title:
        return const _BlockSpec(
          size: 26,
          weight: FontWeight.w700,
          color: Color(0xFF1D1D1F),
          lineHeight: 1.35,
          gapAfter: 10,
        );
      case DocBlockKind.meta:
        return const _BlockSpec(
          size: 12.5,
          weight: FontWeight.w400,
          color: Color(0xFF8A8A8E),
          lineHeight: 1.4,
          gapBefore: 2,
          gapAfter: 18,
        );
      case DocBlockKind.partHeader:
        return const _BlockSpec(
          size: 18.5,
          weight: FontWeight.w700,
          color: Color(0xFF1D1D1F),
          lineHeight: 1.38,
          gapBefore: 16,
          gapAfter: 10,
        );
      case DocBlockKind.heading:
        return const _BlockSpec(
          size: 16,
          weight: FontWeight.w600,
          color: Color(0xFF1D1D1F),
          lineHeight: 1.4,
          gapBefore: 18,
          gapAfter: 7,
        );
      case DocBlockKind.subheading:
        return const _BlockSpec(
          size: 14,
          weight: FontWeight.w600,
          color: Color(0xFF3C3C43),
          lineHeight: 1.45,
          gapBefore: 12,
          gapAfter: 5,
        );
      case DocBlockKind.paragraph:
        return const _BlockSpec(
          size: 13.5,
          weight: FontWeight.w400,
          color: Color(0xFF3C3C43),
          lineHeight: 1.62,
          gapAfter: 9,
        );
      case DocBlockKind.bullet:
      case DocBlockKind.numbered:
        return const _BlockSpec(
          size: 13.5,
          weight: FontWeight.w400,
          color: Color(0xFF3C3C43),
          lineHeight: 1.58,
          gapAfter: 6,
          indent: 12,
        );
      case DocBlockKind.image:
        return const _BlockSpec(
          size: 12,
          weight: FontWeight.w400,
          color: Color(0xFF8A8A8E),
          lineHeight: 1.5,
          gapBefore: 6,
          gapAfter: 10,
        );
      case DocBlockKind.note:
        return const _BlockSpec(
          size: 12,
          weight: FontWeight.w400,
          color: Color(0xFF8A8A8E),
          lineHeight: 1.5,
          gapAfter: 8,
        );
      case DocBlockKind.divider:
        return const _BlockSpec(
          size: 1,
          weight: FontWeight.w400,
          color: Color(0xFFE4E4E0),
          lineHeight: 1,
          gapBefore: 10,
          gapAfter: 10,
        );
    }
  }

  Future<Uint8List> _extractOpaqueRgb(ui.Image image, int w, int h) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw const ExportException('页面栅格化失败：无法读取像素数据');
    }
    final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final pixelCount = w * h;
    final rgb = Uint8List(pixelCount * 3);
    var srcIdx = 0;
    var dstIdx = 0;
    for (var p = 0; p < pixelCount; p++) {
      rgb[dstIdx] = rgba[srcIdx];
      rgb[dstIdx + 1] = rgba[srcIdx + 1];
      rgb[dstIdx + 2] = rgba[srcIdx + 2];
      srcIdx += 4;
      dstIdx += 3;
    }
    return rgb;
  }

  Future<Uint8List> _encodePng(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const ExportException('图片编码失败：无法生成 PNG 数据');
    }
    return data.buffer.asUint8List();
  }
}

class _BlockSpec {
  const _BlockSpec({
    required this.size,
    required this.weight,
    required this.color,
    required this.lineHeight,
    this.gapBefore = 0,
    this.gapAfter = 0,
    this.indent = 0,
  });

  final double size;
  final FontWeight weight;
  final Color color;
  final double lineHeight;
  final double gapBefore;
  final double gapAfter;
  final double indent;
}

class _Page {
  _Page();

  final List<_PlacedItem> items = <_PlacedItem>[];
  double used = 0;
  bool _paintersDisposed = false;

  void disposePainters() {
    if (_paintersDisposed) return;
    _paintersDisposed = true;
    for (final item in items) {
      item.painter?.dispose();
    }
  }
}

class _PlacedItem {
  _PlacedItem.text({required this.painter, required this.x, required this.y})
    : image = null,
      imageRect = null;

  _PlacedItem.image({required this.image, required Rect rect, required this.y})
    : painter = null,
      x = rect.left,
      imageRect = rect;

  _PlacedItem.divider({required this.y})
    : painter = null,
      image = null,
      imageRect = null,
      x = 0;

  final TextPainter? painter;
  final ui.Image? image;
  final Rect? imageRect;
  final double x;
  final double y;
}

class _PaginatedDoc {
  _PaginatedDoc(this.pages, this.truncated);

  final List<_Page> pages;
  final bool truncated;

  void dispose() {
    for (final page in pages) {
      page.disposePainters();
    }
  }
}
