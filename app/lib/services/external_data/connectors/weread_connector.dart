/// 微信读书网页版 API 连接器（`/user/notebooks` + `/book/bookmarklist` + `/review/list`）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class WeReadConnector extends ExternalDataConnector {
  WeReadConnector({this.requestDelay = const Duration(milliseconds: 300)});

  static const String defaultBaseUrl = 'https://i.weread.qq.com';

  final Duration requestDelay;

  @override
  String get id => 'weread';

  @override
  String get name => '微信读书';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'Web API';

  @override
  String get subtitle => '通过网页版 Cookie 同步书架中全部书籍的划线与个人想法';

  @override
  String get setupGuide =>
      '登录网页版 weread.qq.com，在浏览器开发者工具任意请求头中复制完整 Cookie（含 wr_vid / wr_skey）粘贴至此。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'cookie',
      label: '网页版 Cookie',
      hint: 'wr_vid=...; wr_skey=...;',
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

  Map<String, String> _headers(String cookie) => {
    'Cookie': cookie.trim(),
    'Referer': 'https://weread.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Accept': 'application/json',
  };

  static void _assertValidBody(Map<String, dynamic>? map) {
    if (map == null) {
      throw const ExternalConnectorException('微信读书返回了无法解析的 JSON 数据');
    }
    final errCode = (map['errcode'] ?? map['errCode']) as num?;
    if (errCode != null && errCode.toInt() != 0) {
      final code = errCode.toInt();
      if (code == -2012 || code == -2010 || code == -2013) {
        throw ExternalConnectorException(
          '微信读书登录态已过期，请重新从网页版复制 Cookie（errcode=$code）',
          statusCode: 401,
          apiCode: '$code',
        );
      }
      final msg = '${map['errmsg'] ?? map['errMsg'] ?? '错误码 $code'}'.trim();
      throw ExternalConnectorException(
        '微信读书接口错误：$msg',
        apiCode: '$code',
      );
    }
  }

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final cookie = cfg['cookie'] ?? '';
    if (cookie.isEmpty) {
      throw const ExternalConnectorException('请先填写微信读书 Cookie');
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
          ExternalHttpHelper.buildUri(baseUrl, '/user/notebooks'),
          headers: _headers(cookie),
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      _assertValidBody(map);
      final books = map!['books'] is List ? map['books'] as List : const [];
      String? sampleTitle;
      if (books.isNotEmpty && books.first is Map) {
        final firstBook = books.first as Map;
        final meta = firstBook['book'] is Map
            ? firstBook['book'] as Map
            : firstBook;
        final t = '${meta['title'] ?? ''}'.trim();
        if (t.isNotEmpty) sampleTitle = t;
      }
      return ExternalTestResult(
        message: '连接成功（发现 ${books.length} 本有笔记书籍）',
        countHint: books.length,
        sampleTitle: sampleTitle,
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
    final cookie = cfg['cookie'] ?? '';
    if (cookie.isEmpty) {
      throw const ExternalConnectorException('请先填写微信读书 Cookie');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final headers = _headers(cookie);

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      onProgress(
        const ExternalSyncProgress(
          page: 1,
          fetched: 0,
          added: 0,
          message: '正在获取微信读书有笔记书架…',
        ),
      );
      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/user/notebooks'),
          headers: headers,
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      _assertValidBody(map);
      final books = map!['books'] is List ? map['books'] as List : const [];

      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
      var batchIdx = 0;
      var cancelled = false;
      final batch = <ExternalRecordDraft>[];
      final nextFps = <String, String>{};

      for (var i = 0; i < books.length; i++) {
        if (isCancelled()) {
          cancelled = true;
          break;
        }
        final entry = books[i];
        if (entry is! Map) continue;
        final bookEntry = Map<String, dynamic>.from(entry);
        final meta = bookEntry['book'] is Map
            ? Map<String, dynamic>.from(bookEntry['book'] as Map)
            : bookEntry;
        final bookId = '${bookEntry['bookId'] ?? meta['bookId'] ?? ''}'.trim();
        if (bookId.isEmpty) continue;

        final fp =
            '${bookEntry['sort'] ?? 0}|'
            '${bookEntry['bookmarkCount'] ?? 0}|'
            '${bookEntry['noteCount'] ?? 0}|'
            '${bookEntry['reviewCount'] ?? 0}';
        final devName = deviceNameFor(bookId);
        final already = existingDeviceNames.contains(devName);
        if (already && itemFingerprints[bookId] == fp) {
          skippedExisting += 1;
          continue;
        }
        if (already) updated += 1;

        final bmResp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(
              baseUrl,
              '/book/bookmarklist',
              {'bookId': bookId},
            ),
            headers: headers,
          ),
        );
        final bmJson = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(bmResp.bodyBytes, allowMalformed: true),
        );
        _assertValidBody(bmJson);

        final revResp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(baseUrl, '/review/list', {
              'bookId': bookId,
              'listType': '11',
              'mine': '1',
              'synckey': '0',
              'listMode': '0',
            }),
            headers: headers,
          ),
        );
        final revJson = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(revResp.bodyBytes, allowMalformed: true),
        );
        _assertValidBody(revJson);

        final bookTitle = '${meta['title'] ?? '微信读书 $bookId'}'.trim();
        final author = '${meta['author'] ?? ''}'.trim();
        final categoryTag = '${meta['category'] ?? ''}'.trim();
        final formatted = _formatBookNotes(
          bookTitle: bookTitle,
          author: author,
          bookmarkData: bmJson!,
          reviewData: revJson!,
        );
        if (formatted.content.isEmpty) continue;

        final createdAt = ExternalHttpHelper.parseTimestamp(
          formatted.latestTs ?? bookEntry['sort'],
        );

        batch.add(
          ExternalRecordDraft(
            externalId: bookId,
            title: author.isNotEmpty ? '$bookTitle · $author' : bookTitle,
            content: formatted.content,
            createdAt: createdAt,
            updatedAt: createdAt,
            tags: [if (categoryTag.isNotEmpty) categoryTag, '读书笔记'],
            fingerprint: fp,
          ),
        );
        nextFps[bookId] = fp;
        fetched += 1;

        if (batch.length >= 10) {
          batchIdx += 1;
          onProgress(
            ExternalSyncProgress(
              page: batchIdx,
              fetched: fetched,
              added: fetched,
              message: '正在同步微信读书笔记（${i + 1}/${books.length} 本）…',
            ),
          );
          await onBatch(
            List<ExternalRecordDraft>.from(batch),
            Map<String, String>.from(nextFps),
          );
          batch.clear();
          nextFps.clear();
        }
      }

      if (batch.isNotEmpty) {
        batchIdx += 1;
        await onBatch(batch, nextFps);
      }

      return ExternalConnectorSyncReport(
        pagesScanned: batchIdx == 0 ? 1 : batchIdx,
        fetched: fetched,
        skippedExisting: skippedExisting,
        updated: updated,
        cancelled: cancelled,
        completedFullBackfill: !cancelled,
      );
    } finally {
      if (owned) client.close();
    }
  }

  static ({String content, int? latestTs}) _formatBookNotes({
    required String bookTitle,
    required String author,
    required Map<String, dynamic> bookmarkData,
    required Map<String, dynamic> reviewData,
  }) {
    final chapterNames = <int, String>{};
    final chapters = bookmarkData['chapters'];
    if (chapters is List) {
      for (final ch in chapters) {
        if (ch is! Map) continue;
        final uid = (ch['chapterUid'] as num?)?.toInt();
        final title = '${ch['title'] ?? ''}'.trim();
        if (uid != null && title.isNotEmpty) {
          chapterNames[uid] = title;
        }
      }
    }

    int? latestTs;
    void trackTs(Object? v) {
      if (v is num && v > 0) {
        final t = v.toInt();
        if (latestTs == null || t > latestTs!) latestTs = t;
      }
    }

    final lines = <String>[];
    if (author.isNotEmpty) {
      lines.add('《$bookTitle》 · $author');
    }

    final reviews = reviewData['reviews'] is List
        ? reviewData['reviews'] as List
        : const [];
    final reviewNotes = <String>[];
    for (final r in reviews) {
      if (r is! Map) continue;
      final item = r['review'] is Map ? r['review'] as Map : r;
      trackTs(item['createTime']);
      final thought = '${item['content'] ?? ''}'.trim();
      final quote = '${item['abstract'] ?? ''}'.trim();
      if (thought.isEmpty && quote.isEmpty) continue;
      if (quote.isNotEmpty && thought.isNotEmpty) {
        reviewNotes.add('> $quote\n想法：$thought');
      } else if (thought.isNotEmpty) {
        reviewNotes.add('想法：$thought');
      } else {
        reviewNotes.add('> $quote');
      }
    }
    if (reviewNotes.isNotEmpty) {
      lines.add('## 个人想法');
      lines.addAll(reviewNotes);
    }

    final marks = bookmarkData['updated'] is List
        ? bookmarkData['updated'] as List
        : const [];
    String? lastChapter;
    final markLines = <String>[];
    for (final m in marks) {
      if (m is! Map) continue;
      trackTs(m['createTime']);
      final text = '${m['markText'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final chUid = (m['chapterUid'] as num?)?.toInt();
      final chTitle =
          '${m['chapterName'] ?? (chUid != null ? chapterNames[chUid] : '') ?? ''}'
              .trim();
      if (chTitle.isNotEmpty && chTitle != lastChapter) {
        markLines.add('### $chTitle');
        lastChapter = chTitle;
      }
      markLines.add('• $text');
    }
    if (markLines.isNotEmpty) {
      lines.add('## 书籍划线');
      lines.addAll(markLines);
    }

    return (content: lines.join('\n\n').trim(), latestTs: latestTs);
  }
}
