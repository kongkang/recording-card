/// 导出编排 —— 对外唯一入口：一站式完成「生成文件 → 调起系统分享面板」。
///
/// 文件落到 `临时目录/exports/`：
/// - 临时目录由系统回收，不需要额外权限（iOS 沙盒 / Android 应用私有缓存）；
/// - iPadOS / macOS 的 `UIActivityViewController` popover 强制要求非空 `sharePositionOrigin`，
///   调用方传入触发按钮的 [shareAnchorKey] 或 [sharePositionOrigin] 即可对全部 4 种格式生效；
/// - 分享前会清理 `exports/` 里 3 天前的旧产物，避免缓存无限膨胀。
///
/// 失败一律抛 [ExportException]（中文 message），不吞异常、不做静默降级。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'export_document.dart';
import 'export_exception.dart';
import 'export_naming.dart';
import 'image_exporter.dart';
import 'markdown_exporter.dart';
import 'pdf_exporter.dart';
import 'word_exporter.dart';

/// 导出格式（与导出面板一一对应：仅区分格式，所有格式均导出完整两部分内容）。
enum ExportFormat {
  /// PDF（A4 分页）。
  pdf,

  /// Word 文档（RTF / HTML，.doc 兼容方案）。
  word,

  /// Markdown 文档。
  markdown,

  /// 长图（PNG）。
  image,
}

/// 格式元信息：菜单文案、扩展名、MIME、文件名标注。
extension ExportFormatInfo on ExportFormat {
  /// 中文名，同时作为 [ExportResult.shareLabel]（页面提示交给它拼文案）。
  String get label => switch (this) {
        ExportFormat.pdf => 'PDF',
        ExportFormat.word => 'Word 文档',
        ExportFormat.markdown => 'Markdown',
        ExportFormat.image => '图片',
      };

  /// 文件扩展名（不含点）。
  String get fileExtension => switch (this) {
        ExportFormat.pdf => 'pdf',
        ExportFormat.word => 'doc',
        ExportFormat.markdown => 'md',
        ExportFormat.image => 'png',
      };

  /// 分享给系统时声明的 MIME 类型；iOS 依据它决定"按图片/文档"处理。
  String get mimeType => switch (this) {
        ExportFormat.pdf => 'application/pdf',
        ExportFormat.word => 'application/msword',
        ExportFormat.markdown => 'text/markdown',
        ExportFormat.image => 'image/png',
      };

  /// 所有格式均导出完整内容，不再额外区分标注。
  String? get nameTag => null;
}

/// 导出结果。
class ExportResult {
  const ExportResult({required this.path, required this.shareLabel});

  /// 落盘文件的绝对路径。
  final String path;

  /// 格式名（如「PDF」），页面可直接拼提示文案。
  final String shareLabel;
}

class ExportService {
  ExportService({
    PdfExporter? pdfExporter,
    ImageExporter? imageExporter,
    MarkdownExporter? markdownExporter,
    WordExporter? wordExporter,
    DateTime Function()? clock,
    WordFlavor wordFlavor = WordFlavor.rtf,
    Future<Directory> Function()? outputDirectoryProvider,
    Future<ShareResult> Function(ShareParams params)? shareLauncher,
  })  : _wordFlavor = wordFlavor,
        _pdfExporter = pdfExporter ?? const PdfExporter(),
        _imageExporter = imageExporter ?? const ImageExporter(),
        _markdownExporter = markdownExporter ?? const MarkdownExporter(),
        _wordExporter = wordExporter ?? const WordExporter(),
        _clock = clock ?? DateTime.now,
        _outputDirectoryProvider =
            outputDirectoryProvider ?? _defaultOutputDirectory,
        _shareLauncher = shareLauncher ?? SharePlus.instance.share;

  final PdfExporter _pdfExporter;
  final ImageExporter _imageExporter;
  final MarkdownExporter _markdownExporter;
  final WordExporter _wordExporter;

  /// 「Word 文档」的内容格式（默认 RTF，理由见 word_exporter.dart 顶部对照表）。
  final WordFlavor _wordFlavor;
  final DateTime Function() _clock;
  final Future<Directory> Function() _outputDirectoryProvider;
  final Future<ShareResult> Function(ShareParams params) _shareLauncher;

  /// 旧产物保留时长。
  static const Duration _retention = Duration(days: 3);

  /// 导出并调起系统分享面板。
  ///
  /// - [captureKey]：图片导出截图用的 `RepaintBoundary` key（可选）。
  /// - [shareAnchorKey] / [sharePositionOrigin]：系统分享面板在 iPadOS / macOS 上的弹出锚点，
  ///   应对所有导出格式传入页头「导出」按钮的 GlobalKey 或矩形，防止 iPadOS Popover 崩溃。
  Future<ExportResult> export(
    ExportFormat format,
    ExportDocument doc, {
    GlobalKey? captureKey,
    GlobalKey? shareAnchorKey,
    Rect? sharePositionOrigin,
  }) async {
    if (doc.isEmpty) {
      throw const ExportException('没有可导出的内容');
    }

    final directory = await _ensureOutputDirectory();
    final now = _clock();
    final fileName = buildExportFileName(
      title: doc.safeTitle,
      time: now,
      extension: format.fileExtension,
      nameTag: format.nameTag,
    );
    final path = '${directory.path}${Platform.pathSeparator}$fileName';

    // 1) 生成文件
    try {
      switch (format) {
        case ExportFormat.pdf:
          await _pdfExporter.write(doc, path);
        case ExportFormat.word:
          await _wordExporter.write(doc, path, flavor: _wordFlavor);
        case ExportFormat.markdown:
          await _markdownExporter.write(doc, path);
        case ExportFormat.image:
          await _imageExporter.write(doc, path, captureKey: captureKey);
      }
    } on ExportException {
      rethrow;
    } on Object catch (e, st) {
      throw ExportException('${format.label} 导出失败，请重试', cause: e, stackTrace: st);
    }

    // 2) 校验产物确实落盘且非空（宁可报错，也不给用户"假装导出成功"）
    final file = File(path);
    if (!await file.exists()) {
      throw ExportException('${format.label} 导出失败：文件未生成', cause: path);
    }
    final length = await file.length();
    if (length == 0) {
      throw ExportException('${format.label} 导出失败：生成的文件为空', cause: path);
    }

    // 3) 调起系统分享面板
    final resolvedOrigin = _resolveShareOrigin(
      explicitOrigin: sharePositionOrigin,
      shareAnchorKey: shareAnchorKey,
      captureKey: captureKey,
    );
    await _share(format, doc, path, length, resolvedOrigin);
    return ExportResult(path: path, shareLabel: format.label);
  }

  /// 调起系统分享（share_plus 13.x：`SharePlus.instance.share(ShareParams(...))`）。
  Future<void> _share(
    ExportFormat format,
    ExportDocument doc,
    String path,
    int length,
    Rect? shareOrigin,
  ) async {
    final params = ShareParams(
      files: <XFile>[XFile(path, mimeType: format.mimeType, length: length)],
      title: doc.safeTitle,
      subject: doc.safeTitle,
      sharePositionOrigin: shareOrigin,
    );
    try {
      await _shareLauncher(params);
    } on Object catch (e, st) {
      throw ExportException(
        '${format.label} 已生成，但调起系统分享面板失败；可稍后重试',
        cause: e,
        stackTrace: st,
      );
    }
  }

  Rect? _resolveShareOrigin({
    Rect? explicitOrigin,
    GlobalKey? shareAnchorKey,
    GlobalKey? captureKey,
  }) {
    if (explicitOrigin != null &&
        explicitOrigin.width > 0 &&
        explicitOrigin.height > 0) {
      return explicitOrigin;
    }
    final fromAnchor = _anchorRect(shareAnchorKey);
    if (fromAnchor != null) return fromAnchor;
    return _anchorRect(captureKey);
  }

  /// 用 GlobalKey 的渲染框计算非空分享锚点（iPadOS UIPopoverPresentationController 必填）。
  Rect? _anchorRect(GlobalKey? key) {
    final context = key?.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
    final origin = box.localToGlobal(Offset.zero);
    final rect = origin & box.size;
    if (rect.width <= 0 || rect.height <= 0) return null;
    return rect;
  }

  /// 输出目录：`临时目录/exports/`，并顺带清理过期产物。
  Future<Directory> _ensureOutputDirectory() async {
    final Directory base;
    try {
      base = await _outputDirectoryProvider();
    } on Object catch (e, st) {
      throw ExportException('无法定位导出目录，请检查设备存储状态', cause: e, stackTrace: st);
    }
    try {
      await base.create(recursive: true);
    } on Object catch (e, st) {
      throw ExportException('无法创建导出目录，请检查存储空间', cause: e, stackTrace: st);
    }
    await _pruneOldFiles(base);
    return base;
  }

  /// 清理超过 [_retention] 的旧导出文件；失败不影响本次导出（仅记录日志）。
  Future<void> _pruneOldFiles(Directory directory) async {
    try {
      final cutoff = _clock().subtract(_retention);
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } on Object catch (e) {
          debugPrint('[export] 清理旧导出文件失败：$e');
        }
      }
    } on Object catch (e) {
      debugPrint('[export] 扫描导出目录失败：$e');
    }
  }

  static Future<Directory> _defaultOutputDirectory() async {
    final temp = await getTemporaryDirectory();
    return Directory('${temp.path}${Platform.pathSeparator}exports');
  }
}
