/// Word 导出（兼容方案）—— 不引入 docx 依赖，产出"Word 可打开"的 .doc 文件。
///
/// 提供两种内容格式（[WordFlavor]），默认 RTF：
///
/// | 格式 | Word | WPS | Pages / TextEdit（macOS/iOS） | 说明 |
/// |------|------|-----|-------------------------------|------|
/// | RTF（默认） | ✅ | ✅ | ✅ | 纯文本标记语言，靠内容嗅探（`{\rtf`）识别，与扩展名无关 |
/// | HTML + Office 命名空间 | ✅ | ✅ | ❌ | macOS 系按扩展名判定，`.doc` 里有 HTML 会被当成**纯文本** |
///
/// 上面这套结论是实测的（macOS `textutil` / `file` 判定）：
/// - `file --mime-type` 对「RTF 内容 + .doc 扩展名」→ `text/rtf`，
///   `textutil -convert txt` 能正确还原中文；
/// - 同一份 .doc 若内容是 HTML，`file` 判为 `text/html`，但 `textutil -info`
///   报告 `Type: plain text`，也就是 Pages/TextEdit 会把它当纯文本打开。
///
/// 因此默认选 RTF：产品要求是「Word / WPS / Pages 都能打开」，
/// 而 HTML-.doc 这条老技巧只对 Word/WPS 成立。RTF 同样是纯文本、零依赖、
/// 中文用 `\uN?` 转义（与内容编码无关），三种软件都能正确显示。
/// 需要切回 HTML 方案时，构造 `WordExporter(flavor: WordFlavor.html)`
/// 或调用 `WordExporter.write(..., flavor: WordFlavor.html)` 即可，对外契约不变。
///
/// 注意：这是**兼容性方案**，不是严格意义的 OOXML 文档；若将来需要页眉页脚、
/// 修订记录等高级能力，再引入 docx 依赖替换本文件即可，接口不变。
///
/// 纯 Dart 实现（dart:io + dart:convert），便于命令行脚本验证。
library;

import 'dart:convert';
import 'dart:io';

import 'export_document.dart';
import 'export_exception.dart';

/// 「Word 文档」的两种内容格式。
enum WordFlavor {
  /// RTF（默认，兼容 Word / WPS / Pages）。
  rtf,

  /// HTML + Office 命名空间（仅 Word / WPS 可靠）。
  html,
}

class WordExporter {
  const WordExporter({this.flavor = WordFlavor.rtf});

  /// 默认内容格式。
  final WordFlavor flavor;

  /// 生成 .doc 文件，返回落盘路径。
  Future<String> write(ExportDocument doc, String path, {WordFlavor? flavor}) async {
    final useFlavor = flavor ?? this.flavor;
    final content = buildContent(doc, useFlavor);
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      if (useFlavor == WordFlavor.html) {
        // 写 UTF-8 BOM：老版 Word（Windows）在 BOM 缺失时会把 UTF-8 误判为 GBK，中文变乱码
        final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(content)];
        await file.writeAsBytes(bytes, flush: true);
      } else {
        // RTF 全 ASCII（非 ASCII 一律 \uN? 转义），按 latin1 写即可，无需 BOM
        await file.writeAsBytes(latin1.encode(content), flush: true);
      }
      return file.path;
    } on Object catch (e, st) {
      throw ExportException('Word 文档写入失败，请检查存储空间后重试', cause: e, stackTrace: st);
    }
  }

  /// 按格式拼内容（导出器与单测共用）。
  static String buildContent(ExportDocument doc, [WordFlavor flavor = WordFlavor.rtf]) {
    switch (flavor) {
      case WordFlavor.rtf:
        return buildWordRtf(doc);
      case WordFlavor.html:
        return buildWordHtml(doc);
    }
  }

  // ===========================================================================
  // RTF（默认）
  // ===========================================================================

  /// 拼出 RTF 文本。
  static String buildWordRtf(ExportDocument doc) {
    final b = StringBuffer();
    // 文件头：\uc1 表示每个 \uN 后面跟 1 个回退字符（我们用 '?'）
    b.write(r'{\rtf1\ansi\ansicpg1252\deff0\uc1' '\n');
    b.write(r'{\fonttbl{\f0\fnil\fcharset0 PingFang SC;}{\f1\fnil\fcharset0 Georgia;}}' '\n');
    // 颜色表：1=主文字 2=正文 3=次要信息（与 App 设计 token 对齐）
    b.write(r'{\colortbl;\red29\green29\blue31;\red60\green60\blue67;\red138\green138\blue142;}' '\n');
    // A4 纸 + 2cm 边距（单位：twips，1cm ≈ 567）
    b.write(r'\paperw11906\paperh16838\margl1134\margr1134\margt1134\margb1134' '\n');

    _rtfParagraph(b, doc.safeTitle, fs: 34, bold: true, colorIndex: 1, spaceAfter: 120);
    if (doc.meta.trim().isNotEmpty) {
      _rtfParagraph(b, doc.meta.trim(), fs: 19, colorIndex: 3, spaceAfter: 260);
    }
    if (!doc.hasTwoPartStructure && doc.overview.trim().isNotEmpty) {
      _rtfParagraph(b, '概览', fs: 25, bold: true, colorIndex: 1, spaceBefore: 240, spaceAfter: 100);
      _rtfParagraph(b, doc.overview.trim(), fs: 22, colorIndex: 2, spaceAfter: 120);
    }
    for (final section in doc.visibleSections) {
      if (section.isPartHeader) {
        _rtfParagraph(
          b,
          section.heading.trim(),
          fs: 28,
          bold: true,
          colorIndex: 1,
          spaceBefore: 320,
          spaceAfter: 140,
        );
        continue;
      }
      _rtfParagraph(b, section.heading.trim(), fs: 25, bold: true, colorIndex: 1, spaceBefore: 240, spaceAfter: 100);
      final body = section.body?.trim() ?? '';
      if (body.isNotEmpty) {
        _rtfParagraph(b, body, fs: 22, colorIndex: 2, spaceAfter: 120);
      }
      var no = 0;
      for (final bullet in section.bullets) {
        final text = bullet.trim();
        if (text.isEmpty) continue;
        // 项目符号 U+2022 在 RTF 里要写成 \u8226?（prefix 是原始 RTF 片段，不做二次转义）
        final prefix = section.ordered ? '${++no}.' : r'\u8226?';
        _rtfParagraph(
          b,
          text,
          fs: 22,
          colorIndex: 2,
          spaceAfter: 80,
          leftIndent: 360,
          hangingIndent: 360,
          prefix: '$prefix\\tab ',
        );
      }
      for (final img in section.images) {
        final label = _safeImageLabel(img);
        _rtfParagraph(b, '[现场图片] $label', fs: 19, colorIndex: 3, spaceAfter: 100);
      }
    }
    b.write('}');
    return b.toString();
  }

  /// 输出一个 RTF 段落。
  ///
  /// [prefix] 是**未经转义**的 RTF 片段（项目符号 + \tab），因此单独拼接。
  static void _rtfParagraph(
    StringBuffer b,
    String text, {
    required int fs,
    bool bold = false,
    int colorIndex = 2,
    int spaceBefore = 0,
    int spaceAfter = 0,
    int leftIndent = 0,
    int hangingIndent = 0,
    String prefix = '',
  }) {
    b.write(r'\pard\pardirnatural\partightenfactor0');
    if (leftIndent > 0) b.write('\\li$leftIndent');
    if (hangingIndent > 0) b.write('\\fi-$hangingIndent');
    if (spaceBefore > 0) b.write('\\sb$spaceBefore');
    if (spaceAfter > 0) b.write('\\sa$spaceAfter');
    b.write('\\cf$colorIndex\\fs$fs\\f0 ');
    if (bold) b.write(r'\b ');
    if (prefix.isNotEmpty) b.write(prefix);
    b.write(escapeRtf(text));
    if (bold) b.write(r'\b0');
    b.write(r'\par' '\n');
  }

  /// RTF 文本转义：只输出 ASCII，非 ASCII 逐个转成 `\uN?`。
  ///
  /// 按 UTF-16 **码元**遍历，因此 emoji 等增补平面字符会被拆成代理对
  /// （两个 `\uN?`），Word 会重新拼成一个字符，不会乱码。
  static String escapeRtf(String text) {
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      if (unit == 0x0A) {
        out.write(r'\line ');
      } else if (unit == 0x0D) {
        continue;
      } else if (unit == 0x5C) {
        out.write(r'\\');
      } else if (unit == 0x7B) {
        out.write(r'\{');
      } else if (unit == 0x7D) {
        out.write(r'\}');
      } else if (unit < 0x20) {
        out.write(' ');
      } else if (unit < 0x80) {
        out.writeCharCode(unit);
      } else {
        // RTF 的 \uN 是有符号 16 位
        final signed = unit > 0x7FFF ? unit - 0x10000 : unit;
        out.write('\\u$signed?');
      }
    }
    return out.toString();
  }

  // ===========================================================================
  // HTML + Office 命名空间（备选，仅 Word/WPS 可靠）
  // ===========================================================================

  /// 拼出完整 HTML（导出器与单测共用）。
  static String buildWordHtml(ExportDocument doc) {
    final buffer = StringBuffer()..write(_head(doc.safeTitle));

    buffer.writeln('<h1>${_escape(doc.safeTitle)}</h1>');
    if (doc.meta.trim().isNotEmpty) {
      buffer.writeln('<p class="meta">${_escape(doc.meta.trim())}</p>');
    }
    if (!doc.hasTwoPartStructure && doc.overview.trim().isNotEmpty) {
      buffer.writeln('<h2>概览</h2>');
      buffer.writeln('<p>${_paragraphHtml(doc.overview.trim())}</p>');
    }
    for (final section in doc.visibleSections) {
      if (section.isPartHeader) {
        buffer.writeln(
          '<hr style="border:none;border-top:1px solid #E4E4E0;margin:18pt 0 8pt 0;">'
          '<h2 style="font-size:14pt;margin-top:6pt;">${_escape(section.heading.trim())}</h2>',
        );
        continue;
      }
      buffer.writeln('<h2>${_escape(section.heading.trim())}</h2>');
      final body = section.body?.trim() ?? '';
      if (body.isNotEmpty) {
        buffer.writeln('<p>${_paragraphHtml(body)}</p>');
      }
      final bullets = section.bullets.map((b) => b.trim()).where((b) => b.isNotEmpty).toList();
      if (bullets.isNotEmpty) {
        final tag = section.ordered ? 'ol' : 'ul';
        buffer.writeln('<$tag>');
        for (final bullet in bullets) {
          buffer.writeln('<li>${_paragraphHtml(bullet)}</li>');
        }
        buffer.writeln('</$tag>');
      }
      for (final img in section.images) {
        buffer.writeln(_imageHtml(img));
      }
    }

    buffer.write(_tail());
    return buffer.toString();
  }

  static String _head(String title) => '''
<html xmlns:o="urn:schemas-microsoft-com:office:office"
      xmlns:w="urn:schemas-microsoft-com:office:word"
      xmlns="http://www.w3.org/TR/REC-html40">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="ProgId" content="Word.Document">
<meta name="Generator" content="录音卡">
<title>${_escape(title)}</title>
<!--[if gte mso 9]><xml>
 <o:DocumentProperties><o:Title>${_escape(title)}</o:Title></o:DocumentProperties>
 <w:WordDocument><w:View>Print</w:View><w:Zoom>100</w:Zoom><w:DoNotOptimizeForBrowser/></w:WordDocument>
</xml><![endif]-->
<style>
<!--
@page WordSection1 { size: 595.3pt 841.9pt; margin: 56.7pt 56.7pt 56.7pt 56.7pt; }
div.WordSection1 { page: WordSection1; }
body { font-family: "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "SimSun", serif;
       font-size: 11pt; line-height: 1.55; color: #1D1D1F; }
h1 { font-size: 17pt; font-weight: 600; margin: 0 0 6pt 0; }
h2 { font-size: 12.5pt; font-weight: 600; margin: 14pt 0 5pt 0; }
p { margin: 0 0 6pt 0; }
p.meta { font-size: 9.5pt; color: #8A8A8E; margin-bottom: 12pt; }
ul, ol { margin: 0 0 8pt 0; padding-left: 18pt; }
li { margin: 0 0 3pt 0; }
-->
</style>
</head>
<body>
<div class="WordSection1">
''';

  static String _tail() => '''
</div>
</body>
</html>
''';

  /// 文本 → HTML 段落内容：转义 + 换行变 `<br>`。
  static String _paragraphHtml(String text) =>
      _escape(text).replaceAll('\r\n', '\n').replaceAll('\n', '<br>');

  static String _safeImageLabel(ExportImageItem img) {
    if (img.caption.trim().isNotEmpty) return img.caption.trim();
    final parts = img.path
        .trim()
        .split(RegExp(r'[/\\]'))
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? '现场照片' : parts.last;
  }

  static String _imageHtml(ExportImageItem img) {
    final label = _safeImageLabel(img);
    final path = img.path.trim();
    if (path.isNotEmpty) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          final b64 = base64Encode(file.readAsBytesSync());
          final mime = path.toLowerCase().endsWith('.png')
              ? 'image/png'
              : 'image/jpeg';
          return '<p><img src="data:$mime;base64,$b64" '
              'style="max-width:420pt;height:auto;border-radius:6pt;" /><br>'
              '<span class="meta">${_escape(label)}</span></p>';
        }
      } catch (_) {
        // 读取本地图片失败时回退为文本图注
      }
    }
    return '<p class="meta">[现场图片] ${_escape(label)}</p>';
  }

  /// HTML 转义（内容来自真实用户总结，必须转义，避免把文本当成标签解析）。
  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
