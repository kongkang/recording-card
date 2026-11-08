/// PDF 组装 —— 把「每页一张 PNG」拼成 A4 的 PDF 文件。
///
/// ## 为什么 PDF 走"图片页"而不是矢量文字
///
/// pdf 包（Dart 实现）内置只有 Helvetica 等标准基字，**不含 CJK 字形**：
/// 直接 `pw.Text('总结')` 会渲染成空白/方块，甚至抛 `Unable to find font`。
/// 想在 PDF 里画中文，必须提供一个含中文字形的 TTF：
///
/// 1. 打进 `assets/fonts/` —— 本工程 assets 与 pubspec.yaml 不在导出模块的可改范围内，
///    而且思源黑体一个 Regular 就 ~10MB，对安装包体积代价很大；
/// 2. 读系统字体文件 —— **iOS 不可行**：沙盒里 `/System/Library/Fonts/PingFang.ttc`
///    既不可读（无权限），也不便于 `PdfTtfFont` 使用（.ttc 是字体集合，包只吃单字体 TTF；
///    且 iOS 只保证字体对 CoreText 可用，不承诺文件路径存在）；
///    Android 上 `/system/fonts/NotoSansCJK-Regular.ttc` 同样多为 ttc，且各厂商 ROM 路径不统一。
///
/// 因此这里采用**降级方案**：文字排版交给 Flutter 自己画。
/// 用 TextPainter 在离屏 Canvas 上把文本画成 PNG（渲染完全走系统字体，
/// 中文/emoji/不同系统字体回退都由引擎负责，效果与 App 内一致），
/// 再把 PNG 以 `pw.MemoryImage` 嵌入 PDF 的整页。
///
/// 代价：PDF 没有文字层（不可选中/搜索，文件体积略大）。取舍是"任何设备都能正确显示中文"，
/// 对本产品（把总结分享给同事看）是更重要的属性。若将来要在 pdf 里做可搜索文本，
/// 需要改为打包内嵌中文 TTF（改 pubspec.yaml + assets，并接受安装包体积增长）。
///
/// 本文件是纯 Dart（pdf 包本身是纯 Dart 实现），可在命令行脚本里直接验证组装结果。
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_exception.dart';

class PdfAssembler {
  const PdfAssembler();

  /// 用 [pagePngs]（按页顺序，像素比例应与 A4 一致）组装 PDF，返回字节。
  ///
  /// [title] / [subject] 写进 PDF 元信息，分享后在「文件详情」里能看到来源。
  Future<Uint8List> buildPdfFromPngPages(
    List<Uint8List> pagePngs, {
    String? title,
    String? subject,
    String author = '录音卡',
  }) async {
    if (pagePngs.isEmpty) {
      throw const ExportException('PDF 生成失败：没有可用的页面内容');
    }
    final images = <pw.MemoryImage>[];
    for (var i = 0; i < pagePngs.length; i++) {
      final bytes = pagePngs[i];
      if (bytes.isEmpty) {
        throw ExportException('PDF 生成失败：第 ${i + 1} 页渲染为空');
      }
      try {
        // MemoryImage 内部用 image 包解码；PNG/JPEG 都支持
        images.add(pw.MemoryImage(bytes));
      } on Object catch (e, st) {
        throw ExportException('PDF 生成失败：第 ${i + 1} 页图像无法解析', cause: e, stackTrace: st);
      }
    }

    try {
      final document = pw.Document(title: title, author: author, subject: subject);
      for (final image in images) {
        document.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            // 画布已自带页边距（文字排版时预留），PDF 页不再叠边距
            margin: pw.EdgeInsets.zero,
            build: (pw.Context context) => pw.Image(
              image,
              fit: pw.BoxFit.contain,
              // 画布按 A4 比例生成，contain 不会变形；顶部对齐防亚像素偏差露出白边
              alignment: pw.Alignment.topCenter,
            ),
          ),
        );
      }
      return await document.save();
    } on ExportException {
      rethrow;
    } on Object catch (e, st) {
      throw ExportException('PDF 生成失败：写入 PDF 结构时出错', cause: e, stackTrace: st);
    }
  }
}
