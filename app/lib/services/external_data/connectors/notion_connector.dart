/// Notion OpenAPI 连接器（`POST /v1/search` + `GET /v1/blocks/{id}/children` 无限翻页）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class NotionConnector extends ExternalDataConnector {
  NotionConnector({this.requestDelay = const Duration(milliseconds: 350)});

  static const String defaultBaseUrl = 'https://api.notion.com';
  static const String notionVersion = '2022-06-28';

  final Duration requestDelay;

  @override
  String get id => 'notion';

  @override
  String get name => 'Notion';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'REST API';

  @override
  String get subtitle => '通过 Notion Integration Token 全量翻页读取已授权页面与块正文';

  @override
  String get setupGuide =>
      '在 notion.so/my-integrations 创建 Internal Integration 并为需要同步的页面/数据库开启 Connections 授权。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'apiToken',
      label: 'Integration Token',
      hint: 'ntn_... 或 secret_...',
      isSecret: true,
      required: true,
    ),
    ExternalFieldSpec(
      key: 'baseUrl',
      label: 'API 基址（选填）',
      hint: defaultBaseUrl,
      required: false,
      defaultValue: defaultBaseUrl,
    ),
    ExternalFieldSpec(
      key: 'query',
      label: '关键词过滤（选填）',
      hint: '留空则同步所有已授权页面',
      required: false,
    ),
  ];

  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer ${ExternalHttpHelper.normalizeToken(token)}',
    'Notion-Version': notionVersion,
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
  };

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = cfg['apiToken'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 Notion Integration Token');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/v1/users/me'),
          headers: _headers(token),
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final botName = '${map?['name'] ?? ''}'.trim();
      return ExternalTestResult(
        message: botName.isNotEmpty
            ? '连接成功（Integration：$botName）'
            : '连接成功，Notion Token 鉴权有效',
        sampleTitle: botName.isEmpty ? null : botName,
      );
    } finally {
      if (owned) client.close();
    }
  }

  @override
  Future<ExternalConnectorSyncReport> sync({
    required Map<String, String> config,
    required Set<String> existingDeviceNames,
    required Map<String, String> itemFingerprints,
    required Future<void> Function(
      List<ExternalRecordDraft> batch,
      Map<String, String> updatedFingerprints,
    )
    onBatch,
    required void Function(ExternalSyncProgress progress) onProgress,
    required bool Function() isCancelled,
    required bool incremental,
    DateTime? lastSyncAt,
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = cfg['apiToken'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 Notion Integration Token');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final queryText = cfg['query'] ?? '';
    final headers = _headers(token);

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      String? cursor;
      final visitedCursors = <String>{};
      var pageNum = 0;
      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
      var consecutiveUnchangedPages = 0;
      var cancelled = false;
      var fullBackfill = true;

      while (true) {
        if (isCancelled()) {
          cancelled = true;
          fullBackfill = false;
          break;
        }
        pageNum += 1;
        onProgress(
          ExternalSyncProgress(
            page: pageNum,
            fetched: fetched,
            added: fetched,
            message: '正在拉取 Notion 第 $pageNum 页页面列表…',
          ),
        );

        final body = <String, dynamic>{
          'filter': {'property': 'object', 'value': 'page'},
          'sort': {
            'direction': 'descending',
            'timestamp': 'last_edited_time',
          },
          'page_size': 100,
          if (queryText.isNotEmpty) 'query': queryText,
          'start_cursor': ?cursor,
        };

        final resp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.post(
            ExternalHttpHelper.buildUri(baseUrl, '/v1/search'),
            headers: headers,
            body: jsonEncode(body),
          ),
        );

        final data = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(resp.bodyBytes, allowMalformed: true),
        );
        if (data == null) {
          throw const ExternalConnectorException('Notion 返回了无法解析的 JSON 数据');
        }
        final results = data['results'] is List
            ? data['results'] as List
            : const [];
        final batch = <ExternalRecordDraft>[];
        final nextFingerprints = <String, String>{};
        var pageNewOrUpdated = 0;
        var pageExistingCount = 0;

        for (final item in results) {
          if (isCancelled()) {
            cancelled = true;
            fullBackfill = false;
            break;
          }
          if (item is! Map) continue;
          final page = Map<String, dynamic>.from(item);
          final pageId = '${page['id'] ?? ''}'.trim();
          if (pageId.isEmpty) continue;

          final editedAtRaw = '${page['last_edited_time'] ?? ''}'.trim();
          final devName = deviceNameFor(pageId);
          final alreadyExists = existingDeviceNames.contains(devName);
          final prevFp = itemFingerprints[pageId];
          if (alreadyExists && (prevFp == null || prevFp == editedAtRaw)) {
            skippedExisting += 1;
            pageExistingCount += 1;
            continue;
          }

          pageNewOrUpdated += 1;
          if (alreadyExists) updated += 1;

          final title = _extractPageTitle(page);
          final tags = _extractPageTags(page);
          final createdAt = ExternalHttpHelper.parseTimestamp(
            page['created_time'] ?? page['last_edited_time'],
          );
          final updatedAt = ExternalHttpHelper.tryParseTimestamp(
            page['last_edited_time'],
          );
          final blocksText = await _fetchAllBlocksText(
            client: client,
            baseUrl: baseUrl,
            headers: headers,
            blockId: pageId,
            isCancelled: isCancelled,
          );
          if (isCancelled()) {
            cancelled = true;
            fullBackfill = false;
            break;
          }

          final pageUrl = '${page['url'] ?? ''}'.trim();
          final content = [
            if (blocksText.isNotEmpty) blocksText,
            if (pageUrl.isNotEmpty) '原文链接：$pageUrl',
          ].join('\n\n').trim();

          batch.add(
            ExternalRecordDraft(
              externalId: pageId,
              title: title.isEmpty ? 'Notion 页面' : title,
              content: content.isNotEmpty ? content : title,
              createdAt: createdAt,
              updatedAt: updatedAt,
              tags: tags,
              fingerprint: editedAtRaw,
            ),
          );
          nextFingerprints[pageId] = editedAtRaw;
          fetched += 1;
          onProgress(
            ExternalSyncProgress(
              page: pageNum,
              fetched: fetched,
              added: fetched,
              message: '正在读取 Notion 第 $pageNum 页内容（已处理 $fetched 条）…',
            ),
          );
        }

        if (batch.isNotEmpty) {
          await onBatch(batch, nextFingerprints);
        }
        if (cancelled) break;

        if (incremental && pageNewOrUpdated == 0 && pageExistingCount > 0) {
          consecutiveUnchangedPages += 1;
          if (consecutiveUnchangedPages >= 2) {
            break;
          }
        } else if (pageNewOrUpdated > 0) {
          consecutiveUnchangedPages = 0;
        }

        final hasMore = data['has_more'] == true;
        final nextCursor = '${data['next_cursor'] ?? ''}'.trim();
        if (!hasMore ||
            nextCursor.isEmpty ||
            nextCursor == 'null' ||
            nextCursor == cursor ||
            !visitedCursors.add(nextCursor)) {
          break;
        }
        cursor = nextCursor;
      }

      return ExternalConnectorSyncReport(
        pagesScanned: pageNum,
        fetched: fetched,
        skippedExisting: skippedExisting,
        updated: updated,
        cancelled: cancelled,
        completedFullBackfill: fullBackfill && !cancelled,
      );
    } finally {
      if (owned) client.close();
    }
  }

  Future<String> _fetchAllBlocksText({
    required http.Client client,
    required String baseUrl,
    required Map<String, String> headers,
    required String blockId,
    required bool Function() isCancelled,
  }) async {
    final lines = <String>[];
    String? cursor;
    final visited = <String>{};
    while (true) {
      if (isCancelled()) break;
      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/v1/blocks/$blockId/children', {
            'page_size': '100',
            'start_cursor': ?cursor,
          }),
          headers: headers,
        ),
      );
      final data = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      if (data == null) break;
      final results = data['results'] is List
          ? data['results'] as List
          : const [];
      for (final rawBlock in results) {
        if (rawBlock is! Map) continue;
        final line = _extractBlockLine(Map<String, dynamic>.from(rawBlock));
        if (line.isNotEmpty) lines.add(line);
      }
      final hasMore = data['has_more'] == true;
      final next = '${data['next_cursor'] ?? ''}'.trim();
      if (!hasMore ||
          next.isEmpty ||
          next == 'null' ||
          next == cursor ||
          !visited.add(next)) {
        break;
      }
      cursor = next;
    }
    return lines.join('\n').trim();
  }

  static String _extractPageTitle(Map<String, dynamic> page) {
    final props = page['properties'];
    if (props is Map) {
      for (final entry in props.values) {
        if (entry is! Map) continue;
        if (entry['type'] == 'title' || entry['id'] == 'title') {
          final text = _plainTextFromRichList(entry['title']);
          if (text.isNotEmpty) return text;
        }
      }
    }
    final titleList = page['title'];
    return _plainTextFromRichList(titleList);
  }

  static List<String> _extractPageTags(Map<String, dynamic> page) {
    final tags = <String>[];
    final props = page['properties'];
    if (props is! Map) return tags;
    for (final entry in props.values) {
      if (entry is! Map) continue;
      final type = '${entry['type'] ?? ''}';
      if (type == 'multi_select' && entry['multi_select'] is List) {
        for (final item in entry['multi_select'] as List) {
          if (item is Map) {
            final name = '${item['name'] ?? ''}'.trim();
            if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
          }
        }
      } else if (type == 'select' && entry['select'] is Map) {
        final name = '${(entry['select'] as Map)['name'] ?? ''}'.trim();
        if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
      }
    }
    return tags;
  }

  static String _extractBlockLine(Map<String, dynamic> block) {
    final type = '${block['type'] ?? ''}'.trim();
    if (type.isEmpty) return '';
    final payload = block[type];
    if (payload is! Map) return '';
    final text = _plainTextFromRichList(payload['rich_text']);
    if (text.isEmpty) return '';
    return switch (type) {
      'heading_1' => '# $text',
      'heading_2' => '## $text',
      'heading_3' => '### $text',
      'bulleted_list_item' => '• $text',
      'numbered_list_item' => '- $text',
      'to_do' => (payload['checked'] == true ? '[x] ' : '[ ] ') + text,
      'quote' => '> $text',
      _ => text,
    };
  }

  static String _plainTextFromRichList(Object? raw) {
    if (raw is! List) return '';
    final buf = StringBuffer();
    for (final item in raw) {
      if (item is Map) {
        final pt = item['plain_text'] ?? (item['text'] is Map ? (item['text'] as Map)['content'] : null);
        if (pt != null) buf.write('$pt');
      }
    }
    return buf.toString().trim();
  }
}
