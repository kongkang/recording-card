/// 手动总结文章 —— 用户勾选若干录音后，把全部来源交给云端模型生成
/// 结构化文章（标题 / 概览 / 分节 / 行动项 / 来源），并用输入集合白名单
/// 过滤 sourceIds；输出缺失或非法时抛 [AnalysisException]，绝不伪造。
library;

import 'dart:convert';

import '../model_gateway/model_gateway_client.dart';
import 'incremental_refine.dart' show AnalysisException;

// 调用方只 import 本文件即可捕获云端异常；复用 incremental_refine 的定义。
export 'incremental_refine.dart' show AnalysisException;

/// 参与总结的一条录音来源。
class SummaryArticleSource {
  const SummaryArticleSource({
    required this.recordingId,
    required this.title,
    required this.cleanText,
  });

  final String recordingId;
  final String title;
  final String cleanText;
}

/// 文章中的一个小节。
class SummaryArticleSection {
  const SummaryArticleSection({required this.heading, required this.body});

  final String heading;
  final String body;
}

/// 手动总结生成的文章。
class SummaryArticle {
  const SummaryArticle({
    required this.title,
    required this.overview,
    required this.sections,
    required this.actionItems,
    required this.sourceIds,
  });

  final String title;
  final String overview;
  final List<SummaryArticleSection> sections;
  final List<String> actionItems;

  /// 已按输入集合过滤的来源 recordingId（保持模型输出顺序、去重）。
  final List<String> sourceIds;
}

abstract class SummaryArticleService {
  Future<SummaryArticle> generate(List<SummaryArticleSource> sources);
}

/// 云端总结文章：OpenAI-compatible chat，输入全部来源 JSON，
/// 输出单个 JSON 对象；解析失败或结构缺失抛 [AnalysisException]。
class CloudSummaryArticleService implements SummaryArticleService {
  CloudSummaryArticleService({
    required this.gateway,
    required this.model,
    this.temperature = 0.1,
  });

  final ModelGatewayClient gateway;
  final String model;
  final double temperature;

  static const _systemPrompt = '''
你是录音总结助手。输入是 JSON 对象，sources 数组中的每项包含 recordingId、title、cleanText。
请基于全部来源整理一篇结构化总结文章，只依据输入内容，不编造身份或事实，使用中文。
只输出一个 JSON 对象，不要输出 Markdown 代码块或解释，格式：
{"title": "文章标题", "overview": "整体概览", "sections": [{"heading": "小节标题", "body": "小节正文"}], "actionItems": ["行动项"], "sourceIds": ["来源 recordingId"]}
要求：
1. sections 至少一项，每项的 heading 与 body 均非空。
2. actionItems 没有内容时输出空数组。
3. sourceIds 只能取输入 sources 中的 recordingId，不得编造或使用其他值。
4. 不要遗漏任何来源中与主题相关的信息。''';

  @override
  Future<SummaryArticle> generate(List<SummaryArticleSource> sources) async {
    if (sources.isEmpty) {
      throw const AnalysisException('没有可总结的来源');
    }
    final content = await gateway.chat(
      model: model,
      temperature: temperature,
      messages: [
        const ChatMessage(role: 'system', content: _systemPrompt),
        ChatMessage(
          role: 'user',
          content: jsonEncode({
            'sources': [
              for (final source in sources)
                {
                  'recordingId': source.recordingId,
                  'title': source.title,
                  'cleanText': source.cleanText,
                },
            ],
          }),
        ),
      ],
    );
    return _parse(content, sources);
  }

  SummaryArticle _parse(String content, List<SummaryArticleSource> sources) {
    final decoded = _decodeObject(content);
    final title = _requiredText(decoded, 'title');
    final overview = _requiredText(decoded, 'overview');

    final rawSections = _requiredList(decoded, 'sections');
    if (rawSections.isEmpty) {
      throw const AnalysisException('模型返回的 sections 为空');
    }
    final sections = <SummaryArticleSection>[];
    for (final item in rawSections) {
      if (item is! Map) {
        throw const AnalysisException('模型返回的 sections 项不是对象');
      }
      final heading = item['heading'];
      final body = item['body'];
      if (heading is! String ||
          heading.trim().isEmpty ||
          body is! String ||
          body.trim().isEmpty) {
        throw const AnalysisException('模型返回的 sections 项缺少 heading 或 body');
      }
      sections.add(
        SummaryArticleSection(heading: heading.trim(), body: body.trim()),
      );
    }

    final actionItems = <String>[];
    for (final item in _requiredList(decoded, 'actionItems')) {
      if (item is! String) {
        throw const AnalysisException('模型返回的 actionItems 项不是文本');
      }
      final text = item.trim();
      if (text.isNotEmpty) actionItems.add(text);
    }

    // 来源白名单：只保留输入中真实存在的 recordingId，未知 id 过滤不伪造。
    final allowed = {for (final source in sources) source.recordingId};
    final sourceIds = <String>[];
    final seen = <String>{};
    for (final item in _requiredList(decoded, 'sourceIds')) {
      if (item is! String) continue;
      final id = item.trim();
      if (!allowed.contains(id) || !seen.add(id)) continue;
      sourceIds.add(id);
    }

    return SummaryArticle(
      title: title,
      overview: overview,
      sections: List.unmodifiable(sections),
      actionItems: List.unmodifiable(actionItems),
      sourceIds: List.unmodifiable(sourceIds),
    );
  }

  /// 解析 JSON 对象；允许整体被 Markdown fence 或说明文字包裹。
  Map<String, dynamic> _decodeObject(String content) {
    final text = content.trim();
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded != null) {
      throw const AnalysisException('模型返回不是 JSON 对象');
    }

    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const AnalysisException('模型未返回 JSON 对象');
    }
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      throw const AnalysisException('模型返回的 JSON 无法解析');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AnalysisException('模型返回不是 JSON 对象');
    }
    return decoded;
  }

  String _requiredText(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw AnalysisException('模型返回缺少 $key');
    }
    return value.trim();
  }

  List<Object?> _requiredList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! List) {
      throw AnalysisException('模型返回缺少 $key 数组');
    }
    return List<Object?>.from(value);
  }
}
