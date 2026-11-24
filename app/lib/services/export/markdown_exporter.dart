/// Markdown 导出 —— 写 UTF-8 的 .md 文件，内容以文档结构或自带 Markdown 原文为准。
///
/// 规则：
/// - 若文档已采用「第一部分 + 第二部分」结构化导出，按结构化章节实时合成最新 Markdown；
/// - 独立导出的 `.md` 绝不暴露 `/var/mobile/...`、`/Users/...` 等本机沙盒绝对路径，
///   图片统一使用干净的相对引用 `images/<basename>` 或 `[现场图片：<说明>]`；
/// - 纯 Dart 实现（dart:io + dart:convert），便于命令行脚本验证。
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

  /// 将图片本地沙盒路径脱敏为干净的相对路径 `images/<basename>`（网络链接保持不变）。
  static String sanitizeImagePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return '';
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      return trimmed;
    }
    final cleaned = trimmed.replaceFirst(RegExp(r'^file://', caseSensitive: false), '');
    final segments = cleaned
        .split(RegExp(r'[/\\]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList(growable: false);
    if (segments.isEmpty) return '';
    return 'images/${segments.last}';
  }

  static String _sanitizeRawMarkdownPaths(String md) {
    return md.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'),
      (m) {
        final alt = (m.group(1) ?? '').trim();
        final rawTarget = (m.group(2) ?? '').trim();
        final safeTarget = sanitizeImagePath(rawTarget);
        if (safeTarget.isEmpty) {
          final label = alt.isEmpty ? '现场照片' : alt;
          return '[现场图片：$label]';
        }
        return '![$alt]($safeTarget)';
      },
    );
  }

  /// 纯函数：拼出最终 Markdown 文本（导出器与单测共用同一入口）。
  static String buildMarkdownContent(ExportDocument doc) {
    // 若已生成「图文纪要 + 文字记录」两部分结构化文档，始终以结构化版本合成最新 Markdown
    // （确保切换 AI 智能优化版 / 原文、或标记说话人后即时反映在 .md 中）。
    if (doc.hasTwoPartStructure) {
      return buildMarkdownFromDocument(doc);
    }

    final raw = _sanitizeRawMarkdownPaths(doc.markdown.trim());

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

  /// 没有 Markdown 原文（或采用两部分导出结构）时，用结构化字段合成 Markdown。
  static String buildMarkdownFromDocument(ExportDocument doc) {
    final buffer = StringBuffer()
      ..writeln('# ${doc.safeTitle}')
      ..writeln();
    if (doc.meta.trim().isNotEmpty) {
      buffer
        ..writeln('> ${doc.meta.trim()}')
        ..writeln();
    }
    if (!doc.hasTwoPartStructure && doc.overview.trim().isNotEmpty) {
      buffer
        ..writeln('## 概览')
        ..writeln()
        ..writeln(doc.overview.trim())
        ..writeln();
    }
    for (final section in doc.visibleSections) {
      if (section.isPartHeader) {
        buffer
          ..writeln('---')
          ..writeln()
          ..writeln('## ${section.heading.trim()}')
          ..writeln();
        continue;
      }
      final headingPrefix = doc.hasTwoPartStructure ? '###' : '##';
      buffer
        ..writeln('$headingPrefix ${section.heading.trim()}')
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
      for (final img in section.images) {
        final caption = img.caption.trim().isEmpty ? '现场照片' : img.caption.trim();
        final safeRel = sanitizeImagePath(img.path);
        if (safeRel.isNotEmpty) {
          buffer.writeln('![$caption]($safeRel)');
        } else {
          buffer.writeln('- [现场图片：$caption]');
        }
      }
      buffer.writeln();
    }
    return '${buffer.toString().trimRight()}\n';
  }
}
