/// Readwise Export API v2 连接器（`/api/v2/export/` `nextPageCursor` 无限翻页）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class ReadwiseConnector extends ExternalDataConnector {
  ReadwiseConnector({this.requestDelay = const Duration(milliseconds: 350)});

  static const String defaultBaseUrl = 'https://readwise.io/api/v2';

  final Duration requestDelay;

  @override
  String get id => 'readwise';

  @override
  String get name => 'Readwise';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'REST v2';

  @override
  String get subtitle => '通过 Readwise Access Token 全量翻页导出书籍、文章划线与笔记';

  @override
  String get setupGuide =>
      '访问 readwise.io/access_token 获取 Access Token，支持 Kindle / Reader / 播客等全部来源划线自动增量同步。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'accessToken',
      label: 'Access Token',
      hint: 'Readwise Token',
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
  ];

  Map<String, String> _headers(String token) => {
    'Authorization': 'Token ${ExternalHttpHelper.normalizeToken(token)}',
    'Accept': 'application/json',
  };

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = cfg['accessToken'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 Readwise Access Token');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/auth/'),
          headers: _headers(token),
        ),
      );
      return const ExternalTestResult(message: '连接成功，Readwise Token 鉴权有效');
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
    final token = cfg['accessToken'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 Readwise Access Token');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final headers = _headers(token);

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      String? pageCursor;
      final visitedCursors = <String>{};
      var pageNum = 0;
      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
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
            message: '正在拉取 Readwise 第 $pageNum 页导出数据…',
          ),
        );

        final query = <String, String>{
          'pageCursor': ?pageCursor,
          if (incremental && lastSyncAt != null && pageCursor == null)
            'updatedAfter': lastSyncAt.toUtc().toIso8601String(),
        };
        final resp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(baseUrl, '/export/', query),
            headers: headers,
          ),
        );
        final data = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(resp.bodyBytes, allowMalformed: true),
        );
        if (data == null) {
          throw const ExternalConnectorException('Readwise 返回了无法解析的 JSON 数据');
        }
        final results = data['results'] is List
            ? data['results'] as List
            : const [];
        final batch = <ExternalRecordDraft>[];
        final nextFps = <String, String>{};

        for (final item in results) {
          if (item is! Map) continue;
          final book = Map<String, dynamic>.from(item);
          if (book['is_deleted'] == true) continue;
          final bookId = '${book['user_book_id'] ?? book['id'] ?? ''}'.trim();
          if (bookId.isEmpty) continue;

          final highlights = book['highlights'] is List
              ? book['highlights'] as List
              : const [];
          final lines = <String>[];
          final docNote = '${book['document_note'] ?? ''}'.trim();
          final summary = '${book['summary'] ?? ''}'.trim();
          if (summary.isNotEmpty) lines.add(summary);
          if (docNote.isNotEmpty) lines.add('文档笔记：$docNote');

          DateTime? latestAt;
          var activeHighlightCount = 0;
          for (final rawH in highlights) {
            if (rawH is! Map) continue;
            if (rawH['is_deleted'] == true) continue;
            final text = '${rawH['text'] ?? ''}'.trim();
            final note = '${rawH['note'] ?? ''}'.trim();
            if (text.isEmpty && note.isEmpty) continue;
            activeHighlightCount += 1;
            final hlAt = ExternalHttpHelper.tryParseTimestamp(
              rawH['highlighted_at'] ?? rawH['updated'],
            );
            if (hlAt != null && (latestAt == null || hlAt.isAfter(latestAt))) {
              latestAt = hlAt;
            }
            if (text.isNotEmpty) lines.add('> $text');
            if (note.isNotEmpty) lines.add('笔记：$note');
          }
          if (lines.isEmpty) continue;

          final fp =
              '${activeHighlightCount}_${latestAt?.millisecondsSinceEpoch ?? 0}_${docNote.length}';
          final devName = deviceNameFor(bookId);
          final already = existingDeviceNames.contains(devName);
          if (already && itemFingerprints[bookId] == fp) {
            skippedExisting += 1;
            continue;
          }
          if (already) updated += 1;

          final title =
              '${book['readable_title'] ?? book['title'] ?? 'Readwise 摘录'}'
                  .trim();
          final author = '${book['author'] ?? ''}'.trim();
          final tags = <String>[
            if ('${book['category'] ?? ''}'.trim().isNotEmpty)
              '${book['category']}'.trim(),
            if ('${book['source'] ?? ''}'.trim().isNotEmpty)
              '${book['source']}'.trim(),
            if (book['book_tags'] is List)
              for (final t in book['book_tags'] as List)
                if (t is Map && '${t['name'] ?? ''}'.trim().isNotEmpty)
                  '${t['name']}'.trim(),
          ];

          batch.add(
            ExternalRecordDraft(
              externalId: bookId,
              title: author.isNotEmpty ? '$title · $author' : title,
              content: lines.join('\n\n'),
              summary: summary,
              createdAt: latestAt ?? DateTime.now(),
              updatedAt: latestAt,
              tags: tags,
              fingerprint: fp,
            ),
          );
          nextFps[bookId] = fp;
          fetched += 1;
        }

        if (batch.isNotEmpty) {
          await onBatch(batch, nextFps);
        }

        final rawNext = '${data['nextPageCursor'] ?? ''}'.trim();
        if (rawNext.isEmpty ||
            rawNext == 'null' ||
            rawNext == pageCursor ||
            !visitedCursors.add(rawNext)) {
          break;
        }
        pageCursor = rawNext;
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
}
