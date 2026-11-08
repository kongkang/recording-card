/// 文档渲染器 —— 用 Flutter 自己的文字排版把 [ExportDocument] 画成 PNG（A4 分页 / 长图两种）。
///
/// ## 为什么用"画图"而不是"直接排 PDF"
///
/// 中文在 PDF 里必须靠内嵌字体（见 `pdf_assembler.dart` 顶部注释的调研结论）。
/// 本条链路选择「TextPainter 画布 → PNG → 嵌入 PDF」：
/// 字体回退完全交给引擎（iOS PingFang / Android Noto Sans CJK），
/// 不需要打包字体、不需要读系统字体文件，也不会出现方块字。
///
/// ## 关键约束
/// - 不继承用户系统字号（`TextScaler.noScaling`）：导出是纸面文档，字号必须稳定；
/// - 分页有上限（[DocumentPageOptions.maxPages]）与长图高度上限（[LongImageOptions.maxPixelHeight]），
///   防止超长内容把内存打爆；
/// - 所有尺寸都在「逻辑像素」空间里排版，最后按 pixelRatio 放大栅格化，保证 2x 清晰度。
library;

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
    this.maxPages = 40,
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

  /// 最大页数；超出时截断并标注，避免一次导出吃掉过多内存。
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

/// 长图参数（图片导出降级路径使用）。
class LongImageOptions {
  const LongImageOptions({this.pixelRatio = 1.5, this.maxPixelHeight = 12000});

  /// 长图倍率：1.5 → 宽 810px。
  /// 为什么不沿用 2.0：一张长图是**单次** `toImage`，像素总量 = 宽 × 高，
  /// 12000px 高时 810×12000×4B ≈ 39MB，已接近移动端单张位图的安全区；
  /// 2.0 会到 ~52MB，低端机有 OOM 风险。
  final double pixelRatio;

  /// 长图最大像素高度；超出截断并写明建议改用 PDF。
  final int maxPixelHeight;
}

/// A4 等比分页的文档渲染器。
class DocumentRenderer {
  const DocumentRenderer({this.options = const DocumentPageOptions()});

  final DocumentPageOptions options;

  /// 渲染为多页 PNG（每张都是 A4 比例整页），可直接嵌入 PDF。
  Future<List<Uint8List>> renderPngPages(
    ExportDocument doc, {
    bool preferMarkdown = false,
    DocumentPageOptions? pageOptions,
  }) async {
    final o = pageOptions ?? options;
    final laidOut = _paginate(buildDocBlocks(doc, preferMarkdown: preferMarkdown), o);
    try {
      final pngs = <Uint8List>[];
      for (var i = 0; i < laidOut.pages.length; i++) {
        final picture = _recordPage(
          laidOut.pages[i],
          o,
          doc: doc,
          pageIndex: i,
          totalPages: laidOut.pages.length,
        );
        try {
          final image = await picture.toImage(o.pixelWidth, o.pixelHeight);
          try {
            pngs.add(await _encodePng(image));
          } finally {
            image.dispose();
          }
        } finally {
          picture.dispose();
        }
      }
      return pngs;
    } finally {
      laidOut.dispose();
    }
  }

  /// 渲染为一张长图（图片导出在拿不到 RepaintBoundary 时的降级路径）。
  ///
  /// 超过 [LongImageOptions.maxPixelHeight] 时只保留能放下的整页，并在末尾注明已截断。
  Future<Uint8List> renderLongImagePng(
    ExportDocument doc, {
    bool preferMarkdown = false,
    DocumentPageOptions? pageOptions,
    LongImageOptions longImage = const LongImageOptions(),
  }) async {
    final o = pageOptions ?? options;
    final laidOut = _paginate(buildDocBlocks(doc, preferMarkdown: preferMarkdown), o);
    try {
      final pages = laidOut.pages;
      final ratio = longImage.pixelRatio;
      final maxLogicalHeight = longImage.maxPixelHeight / ratio;

      // 文档末页只取实际用到的高度，避免长图底部留一大片空白
      double pageSliceHeight(int i) =>
          i == pages.length - 1 ? (o.margin + pages[i].used + o.margin * 0.6) : o.pageHeight;

      final included = <int>[];
      var logicalHeight = 0.0;
      var truncated = false;
      for (var i = 0; i < pages.length; i++) {
        final sliceHeight = pageSliceHeight(i);
        if (logicalHeight + sliceHeight > maxLogicalHeight) {
          truncated = true;
          break;
        }
        included.add(i);
        logicalHeight += sliceHeight;
      }
      if (included.isEmpty) {
        throw const ExportException('图片导出失败：内容超出单张图片高度上限，请改用 PDF 导出');
      }

      // 截断提示占用底部空间
      final notePainter = truncated ? _layoutNote('内容过长，长图已截断；完整内容请导出 PDF', o) : null;
      if (notePainter != null) {
        logicalHeight += notePainter.height + 12;
      }
      final minHeight = o.margin * 2 + 120;
      if (logicalHeight < minHeight) logicalHeight = minHeight;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(ratio);
      // 白底（导出文档固定浅色底，深色模式下也保持可打印）
      canvas.drawRect(
        Rect.fromLTWH(0, 0, o.logicalWidth, logicalHeight),
        Paint()..color = const Color(0xFFFFFFFF),
      );

      var offsetY = 0.0;
      for (final pageIndex in included) {
        _paintPlacedItems(canvas, pages[pageIndex], o, offsetY);
        offsetY += pageSliceHeight(pageIndex);
      }

      notePainter?.paint(canvas, Offset(o.margin, logicalHeight - notePainter.height - o.margin * 0.6));

      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(
          (o.logicalWidth * ratio).round(),
          (logicalHeight * ratio).round(),
        );
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
  }

  // ---------------------------------------------------------------------------
  // 排版
  // ---------------------------------------------------------------------------

  /// 把块序列排进若干页（逻辑坐标，y=0 表示正文区顶部）。
  _PaginatedDoc _paginate(List<DocBlock> blocks, DocumentPageOptions o) {
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
          pages.add(_Page());
          page = pages.last;
        }
        final gap2 = page.items.isEmpty ? 0.0 : spec.gapBefore;
        page.items.add(_PlacedItem.divider(y: page.used + gap2));
        page.used += gap2 + spec.gapAfter + 1;
        continue;
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
          pages.add(_Page());
          continue;
        }

        final painter = _layoutText(remaining, spec, maxWidth);
        if (painter.height <= available) {
          page.items.add(_PlacedItem.text(painter: painter, x: o.margin + spec.indent, y: page.used + gap));
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
            // 本页已无有效空间，换页重排
            pages.add(_Page());
            continue;
          }
          // 页高配置异常时的兜底：至少吃一个字符，保证向前推进
          headText = remaining.substring(0, 1);
        }
        final headPainter = _layoutText(headText, spec, maxWidth);
        page.items.add(_PlacedItem.text(painter: headPainter, x: o.margin + spec.indent, y: page.used + gap));
        page.used += gap + headPainter.height + spec.gapAfter;
        remaining = remaining.substring(headText.length).trimLeft();
      }
    }

    if (truncated) {
      // 末页追加截断提示；末页放不下就单开一页写明
      final page = pages.last;
      final notePainter = _layoutText(
        '（内容过长，仅导出前 ${o.maxPages} 页）',
        _specFor(DocBlockKind.note),
        o.contentWidth,
      );
      if (page.used + notePainter.height + 12 <= o.contentHeight) {
        page.items.add(_PlacedItem.text(painter: notePainter, x: o.margin, y: page.used + 12));
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
  void _paintPlacedItems(Canvas canvas, _Page page, DocumentPageOptions o, double offsetY) {
    for (final item in page.items) {
      final y = o.margin + item.y + offsetY;
      final painter = item.painter;
      if (painter != null) {
        painter.paint(canvas, Offset(item.x, y));
      } else {
        // 分隔线
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

  void _paintFooter(Canvas canvas, DocumentPageOptions o, {required int pageIndex, required int totalPages}) {
    final style = const TextStyle(fontSize: 10, color: Color(0xFF8A8A8E));
    final left = TextPainter(
      text: TextSpan(text: '录音卡 · 总结导出', style: style),
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
          // 不指定 fontFamily：交给系统默认（iOS PingFang / Android Noto Sans CJK），
          // 中文与 emoji 的字体回退由引擎负责，这是本方案能稳定出中文的根本原因。
        ),
      ),
      textDirection: TextDirection.ltr,
      // 导出是纸面文档：不接受系统字号缩放
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

  /// 找出「能在 [targetHeight] 高度内放下」的最大字符前缀长度。
  ///
  /// 做法是按高度比例逐步回缩再试排（最多 6 轮）：
  /// 文本换行后高度与字符数近似正比，用 `目标高度 / 实际高度` 做比例就能 2~3 轮收敛，
  /// 比 `getPositionForOffset` 更稳（后者在行边界附近会多含一行或含不进一整行）。
  /// 只有「一个块跨页」时才会走到这里，正常文档每块都一次排下，不会有额外开销。
  int _fitByRatio(String text, _BlockSpec spec, double maxWidth, double targetHeight) {
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
      default:
        return block.text;
    }
  }

  _BlockSpec _specFor(DocBlockKind kind) {
    switch (kind) {
      case DocBlockKind.title:
        return const _BlockSpec(size: 26, weight: FontWeight.w700, color: Color(0xFF1D1D1F), lineHeight: 1.35, gapAfter: 10);
      case DocBlockKind.meta:
        return const _BlockSpec(size: 12.5, weight: FontWeight.w400, color: Color(0xFF8A8A8E), lineHeight: 1.4, gapBefore: 2, gapAfter: 18);
      case DocBlockKind.heading:
        return const _BlockSpec(size: 16, weight: FontWeight.w600, color: Color(0xFF1D1D1F), lineHeight: 1.4, gapBefore: 18, gapAfter: 7);
      case DocBlockKind.subheading:
        return const _BlockSpec(size: 14, weight: FontWeight.w600, color: Color(0xFF3C3C43), lineHeight: 1.45, gapBefore: 12, gapAfter: 5);
      case DocBlockKind.paragraph:
        return const _BlockSpec(size: 13.5, weight: FontWeight.w400, color: Color(0xFF3C3C43), lineHeight: 1.62, gapAfter: 9);
      case DocBlockKind.bullet:
      case DocBlockKind.numbered:
        return const _BlockSpec(size: 13.5, weight: FontWeight.w400, color: Color(0xFF3C3C43), lineHeight: 1.58, gapAfter: 6, indent: 12);
      case DocBlockKind.note:
        return const _BlockSpec(size: 12, weight: FontWeight.w400, color: Color(0xFF8A8A8E), lineHeight: 1.5, gapAfter: 8);
      case DocBlockKind.divider:
        return const _BlockSpec(size: 1, weight: FontWeight.w400, color: Color(0xFFE4E4E0), lineHeight: 1, gapBefore: 10, gapAfter: 10);
    }
  }

  Future<Uint8List> _encodePng(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const ExportException('图片编码失败：无法生成 PNG 数据');
    }
    return data.buffer.asUint8List();
  }
}

/// 文本块样式。
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
}

class _PlacedItem {
  _PlacedItem.text({required this.painter, required this.x, required this.y});

  /// 分隔线不持有文本，painter 为 null 时按 1px 横线绘制。
  _PlacedItem.divider({required this.y}) : painter = null, x = 0;

  final TextPainter? painter;
  final double x;
  final double y;
}

class _PaginatedDoc {
  _PaginatedDoc(this.pages, this.truncated);

  final List<_Page> pages;
  final bool truncated;

  /// 释放 TextPainter（TextPainter 持有原生资源，必须显式 dispose）。
  void dispose() {
    for (final page in pages) {
      for (final item in page.items) {
        item.painter?.dispose();
      }
    }
  }
}
