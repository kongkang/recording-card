/// Limitless Developer API 连接器（`GET /v1/lifelogs` `meta.lifelogs.nextCursor` 无限翻页）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class LimitlessConnector extends ExternalDataConnector {
  LimitlessConnector({this.requestDelay = const Duration(milliseconds: 280)});

  static const String defaultBaseUrl = 'https://api.limitless.ai';

  final Duration requestDelay;

  @override
  String get id => 'limitless';

  @override
  String get name => 'Limitless';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.recorders;

  @override
  String get protocolBadge => 'REST v1';

  @override
  String get subtitle => '通过 Limitless X-API-Key 连续翻页同步 Pendant 录音与 Lifelogs';

  @override
  String get setupGuide =>
      '在 Limitless Web / 桌面应用「Settings -> Developer」生成 API Key（X-API-Key）。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'apiKey',
      label: 'X-API-Key',
      hint: 'Limitless Developer API Key',
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

  Map<String, String> _headers(String apiKey) => {
    'X-API-Key': ExternalHttpHelper.normalizeToken(apiKey),
    'Accept': 'application/json',
  };

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final apiKey = cfg['apiKey'] ?? '';
    if (apiKey.isEmpty) {
      throw const ExternalConnectorException('请先填写 Limitless API Key');
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
          ExternalHttpHelper.buildUri(baseUrl, '/v1/lifelogs', {'limit': '1'}),
          headers: _headers(apiKey),
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final list = _extractLifelogs(map);
      final sampleTitle = list.isNotEmpty
          ? '${list.first['title'] ?? ''}'.trim()
          : null;
      return ExternalTestResult(
        message: '连接成功，Limitless API 鉴权有效',
        countHint: list.length,
        sampleTitle: (sampleTitle != null && sampleTitle.isNotEmpty)
            ? sampleTitle
            : null,
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
    final apiKey = cfg['apiKey'] ?? '';
    if (apiKey.isEmpty) {
      throw const ExternalConnectorException('请先填写 Limitless API Key');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final headers = _headers(apiKey);

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      String? cursor;
      final visitedCursors = <String>{};
      var pageNum = 0;
      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
      var consecutiveUnchanged = 0;
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
            message: '正在拉取 Limitless 第 $pageNum 页 Lifelogs…',
          ),
        );
        final resp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(baseUrl, '/v1/lifelogs', {
              'limit': '50',
              'includeMarkdown': 'true',
              'includeHeadings': 'true',
              'cursor': ?cursor,
            }),
            headers: headers,
          ),
        );
        final map = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(resp.bodyBytes, allowMalformed: true),
        );
        if (map == null) {
          throw const ExternalConnectorException('Limitless 返回了无法解析的 JSON 数据');
        }
        final list = _extractLifelogs(map);
        if (list.isEmpty) break;

        final batch = <ExternalRecordDraft>[];
        final nextFps = <String, String>{};
        var pageNew = 0;
        var pageOld = 0;

        for (final log in list) {
          final logId = '${log['id'] ?? ''}'.trim();
          if (logId.isEmpty) continue;
          final fp = '${log['updatedAt'] ?? log['endTime'] ?? ''}'.trim();
          final devName = deviceNameFor(logId);
          final already = existingDeviceNames.contains(devName);
          if (already && (fp.isEmpty || itemFingerprints[logId] == fp)) {
            skippedExisting += 1;
            pageOld += 1;
            continue;
          }
          if (already) updated += 1;
          pageNew += 1;

          final startTime = ExternalHttpHelper.parseTimestamp(log['startTime']);
          final endTime = ExternalHttpHelper.tryParseTimestamp(log['endTime']);
          final durationSec = endTime != null
              ? endTime.difference(startTime).inMilliseconds / 1000.0
              : 0.0;
          final title = '${log['title'] ?? 'Limitless 记录'}'.trim();
          final markdown = '${log['markdown'] ?? ''}'.trim();

          final turns = <ExternalTurnDraft>[];
          final contents = log['contents'];
          if (contents is List) {
            for (final node in contents) {
              if (node is! Map) continue;
              final text = '${node['content'] ?? ''}'.trim();
              if (text.isEmpty) continue;
              final spkRaw =
                  '${node['speakerName'] ?? node['speakerIdentifier'] ?? ''}'
                      .trim();
              final spk = spkRaw == 'user'
                  ? '我'
                  : (spkRaw.isEmpty ? '未区分' : spkRaw);
              turns.add(
                ExternalTurnDraft(
                  speaker: spk,
                  text: text,
                  startMs: (node['startOffsetMs'] as num?)?.toInt() ?? 0,
                  endMs: (node['endOffsetMs'] as num?)?.toInt() ?? 0,
                ),
              );
            }
          }

          final joinedTurns = turns
              .map(
                (t) => t.speaker == '未区分' ? t.text : '${t.speaker}：${t.text}',
              )
              .join('\n');
          final body = markdown.isNotEmpty ? markdown : joinedTurns;

          batch.add(
            ExternalRecordDraft(
              externalId: logId,
              title: title,
              content: body.isNotEmpty ? body : title,
              rawText: joinedTurns,
              createdAt: startTime,
              updatedAt: endTime,
              durationSec: durationSec > 0 ? durationSec : 0,
              turns: turns,
              fingerprint: fp,
            ),
          );
          nextFps[logId] = fp;
          fetched += 1;
        }

        if (batch.isNotEmpty) {
          await onBatch(batch, nextFps);
        }

        if (incremental && pageNew == 0 && pageOld > 0) {
          consecutiveUnchanged += 1;
          if (consecutiveUnchanged >= 2) break;
        } else if (pageNew > 0) {
          consecutiveUnchanged = 0;
        }

        final meta = map['meta'] is Map
            ? Map<String, dynamic>.from(map['meta'] as Map)
            : const <String, dynamic>{};
        final lifelogsMeta = meta['lifelogs'] is Map
            ? Map<String, dynamic>.from(meta['lifelogs'] as Map)
            : const <String, dynamic>{};
        final nextCursor = '${lifelogsMeta['nextCursor'] ?? ''}'.trim();
        if (nextCursor.isEmpty ||
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

  static List<Map<String, dynamic>> _extractLifelogs(Map<String, dynamic>? m) {
    if (m == null) return const [];
    final data = m['data'] is Map ? m['data'] as Map : m;
    final raw = data['lifelogs'] ?? m['lifelogs'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }
}
