/// 图片导出 —— 优先截取页面上的 [RepaintBoundary]，拿不到就退化为"文本长图"。
///
/// 两种路径：
/// 1. **页面截图**（主线会传 `captureKey`）：把 key 指向的 RepaintBoundary 用
///    `toImage(pixelRatio: 2.0)` 截成 PNG —— 所见即所得，和用户在屏幕上看到的一致；
/// 2. **文本长图**（captureKey 为空 / 拿不到可用边界）：用 [DocumentRenderer] 把
///    ExportDocument 用 TextPainter 画成一张长图，带高度上限与截断提示。
///
/// 注意：截图只包含「当前已绘制」的可视内容（滚动区域外不会出现在图里），
/// 这是 RepaintBoundary 的固有限制，也是产品上「导出图片」的常规语义。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'document_renderer.dart';
import 'export_document.dart';
import 'export_exception.dart';

class ImageExporter {
  const ImageExporter({this.renderer = const DocumentRenderer()});

  final DocumentRenderer renderer;

  /// 生成 PNG 并落盘，返回路径。
  Future<String> write(
    ExportDocument doc,
    String path, {
    GlobalKey? captureKey,
    double pixelRatio = 2.0,
  }) async {
    final bytes = await buildPngBytes(doc, captureKey: captureKey, pixelRatio: pixelRatio);
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object catch (e, st) {
      throw ExportException('图片文件写入失败，请检查存储空间后重试', cause: e, stackTrace: st);
    }
  }

  /// 生成 PNG 字节（不落盘，便于复用与测试）。
  Future<Uint8List> buildPngBytes(
    ExportDocument doc, {
    GlobalKey? captureKey,
    double pixelRatio = 2.0,
  }) async {
    // 完整两部分（图文纪要 + 文字记录）直接渲染整份长图，避免屏幕截图只包含可视区域
    if (doc.hasTwoPartStructure) {
      return renderer.renderLongImagePng(doc);
    }
    if (captureKey != null) {
      final captured = await _captureBoundaryPng(captureKey, pixelRatio: pixelRatio);
      if (captured != null) return captured;
      // 边界不可用（key 未挂载 / 命中屏幕根节点）时不报错，按设计退化为文本长图
      debugPrint('[export] 未找到可截取的 RepaintBoundary，退化为文本长图导出');
    }
    return renderer.renderLongImagePng(doc);
  }

  /// 截取 key 指向的 RepaintBoundary；不可用时返回 null。
  Future<Uint8List?> _captureBoundaryPng(GlobalKey key, {required double pixelRatio}) async {
    final context = key.currentContext;
    if (context == null) return null;
    final boundary = _nearestBoundary(context.findRenderObject());
    if (boundary == null) return null;
    if (boundary.size.isEmpty) return null;

    // 上一帧还在等待绘制时 toImage 会抛 "was not painted"，先等一帧
    if (boundary.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
    }

    ui.Image? image;
    try {
      const maxRgbaBytes = 36 * 1024 * 1024;
      var effectiveRatio = pixelRatio;
      final estBytes =
          boundary.size.width * boundary.size.height * pixelRatio * pixelRatio * 4;
      if (estBytes > maxRgbaBytes && boundary.size.width > 0 && boundary.size.height > 0) {
        final scale = (maxRgbaBytes /
                (boundary.size.width * boundary.size.height * 4))
            .clamp(0.25, pixelRatio * pixelRatio);
        effectiveRatio = scale >= 1.0 ? 1.0 : 0.75;
      }
      image = await boundary.toImage(pixelRatio: effectiveRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw const ExportException('图片导出失败：页面截图为空');
      }
      return data.buffer.asUint8List();
    } on ExportException {
      rethrow;
    } on Object catch (e, st) {
      throw ExportException('图片导出失败：截取当前页面出错，请重试', cause: e, stackTrace: st);
    } finally {
      image?.dispose();
    }
  }

  /// 从给定渲染对象向上找最近的 RepaintBoundary。
  ///
  /// 若最近的边界就是屏幕根节点（`RenderView` 的直接子节点），返回 null ——
  /// 那等于把整个 App 界面（含顶栏/底栏）截下来，不符合「导出这份总结」的语义。
  RenderRepaintBoundary? _nearestBoundary(RenderObject? object) {
    var node = object;
    while (node != null) {
      if (node is RenderRepaintBoundary) {
        return node.parent is RenderView ? null : node;
      }
      node = node.parent;
    }
    return null;
  }
}
