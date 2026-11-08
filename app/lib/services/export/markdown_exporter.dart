/// Markdown 导出 —— 写 UTF-8 的 .md 文件，内容以文档自带 Markdown 原文为准。
///
/// 规则：
/// - 内容 = `doc.markdown`；
/// - 如果原文里没有一级标题（首个非空行不是 `# ...`），把 `doc.title` 作为 `#` 一级标题补在最前；
/// - 原文为空时按结构化字段合成一份 Markdown（保证导出的 .md 不是空文件）。
///
/// 纯 Dart 实现（dart:io + dart:convert），便于命令行脚本验证。
library;

import 'dart:convert';
import 'dart:io';

import 'export_document.dart';
import 'export_exception.dart';

class MarkdownExporter {
  const MarkdownExporter();

  /// 生成 .md 文件，返回落盘路径。[path] 由调用方（ExportService）负责命名与目录。
  Future<String> write(ExportDocument doc, String path) async {
    final content = buildMarkdownContent(doc);
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      // UTF-8 编码；不写 BOM —— 主流编辑器（VS Code / Typora / Obsidian）对 UTF-8 无 BOM 更友好
      await file.writeAsString(content, encoding: utf8, flush: true);
      return file.path;
    } on Object catch (e, st) {
      throw ExportException('Markdown 文件写入失败，请检查存储空间后重试', cause: e, stackTrace: st);
    }
  }

  /// 纯函数：拼出最终 Markdown 文本（导出器与单测共用同一入口）。
  static String buildMarkdownContent(ExportDocument doc) {
    final raw = doc.markdown.trim();

    if (raw.isEmpty) {
      return buildMarkdownFromDocument(doc);
    }

    final firstLine = raw
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');

    // 已有任何一级标题就以原文为准（尊重总结生成时的 Markdown 原貌）
    if (firstLine.startsWith('# ')) {
      return raw.endsWith('\n') ? raw : '$raw\n';
    }

    final title = doc.safeTitle;
    return '# $title\n\n$raw${raw.endsWith('\n') ? '' : '\n'}';
  }

  /// 没有 Markdown 原文时，用结构化字段合成 Markdown。
  static String buildMarkdownFromDocument(ExportDocument doc) {
    final buffer = StringBuffer()
      ..writeln('# ${doc.safeTitle}')
      ..writeln();
    if (doc.meta.trim().isNotEmpty) {
      buffer
        ..writeln('> ${doc.meta.trim()}')
        ..writeln();
    }
    if (doc.overview.trim().isNotEmpty) {
      buffer
        ..writeln('## 概览')
        ..writeln()
        ..writeln(doc.overview.trim())
        ..writeln();
    }
    for (final section in doc.visibleSections) {
      buffer
        ..writeln('## ${section.heading.trim()}')
        ..writeln();
      final body = section.body?.trim() ?? '';
      if (body.isNotEmpty) {
        buffer
          ..writeln(body)
          ..writeln();
      }
      var no = 0;
      for (final bullet in section.bullets) {
        final text = bullet.trim();
        if (text.isEmpty) continue;
        if (section.ordered) {
          no++;
          buffer.writeln('$no. $text');
        } else {
          buffer.writeln('- $text');
        }
      }
      buffer.writeln();
    }
    return '${buffer.toString().trimRight()}\n';
  }
}
