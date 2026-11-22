/// Omi 云端 Developer API 连接器（`GET /v1/dev/user/conversations` Offset 无限翻页）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class OmiCloudConnector extends ExternalDataConnector {
  OmiCloudConnector({this.requestDelay = const Duration(milliseconds: 280)});

  static const String defaultBaseUrl = 'https://api.omi.me';

  final Duration requestDelay;

  @override
  String get id => 'omi_cloud';

  @override
  String get name => 'Omi 云端';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.recorders;

  @override
  String get protocolBadge => 'Dev API v1';

  @override
  String get subtitle => '通过 Omi Developer API Key 同步云端历史对话与转录片段';

  @override
  String get setupGuide =>
      '在 Omi App「Settings -> Developer」创建 Developer API Key（前缀 omi_dev_）。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'apiKey',
      label: 'Developer API Key',
      hint: 'omi_dev_...',
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
    'Authorization': 'Bearer ${ExternalHttpHelper.normalizeToken(apiKey)}',
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
      throw const ExternalConnectorException('请先填写 Omi Developer API Key');
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
          ExternalHttpHelper.buildUri(baseUrl, '/v1/dev/user/conversations', {
            'limit': '1',
            'offset': '0',
          }),
          headers: _headers(apiKey),
        ),
      );
      final list = _extractList(utf8.decode(resp.bodyBytes, allowMalformed: true));
      final firstTitle = list.isNotEmpty
          ? _extractTitle(list.first)
          : null;
      return ExternalTestResult(
        message: '连接成功，Omi 云端接口鉴权有效',
        countHint: list.length,
        sampleTitle: (firstTitle != null && firstTitle.isNotEmpty)
            ? firstTitle
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
      throw const ExternalConnectorException('请先填写 Omi Developer API Key');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final headers = _headers(apiKey);

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      const pageLimit = 50;
      var offset = 0;
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
            message: '正在拉取 Omi 云端第 $pageNum 页对话（offset=$offset）…',
          ),
        );
        final resp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(baseUrl, '/v1/dev/user/conversations', {
              'limit': '$pageLimit',
              'offset': '$offset',
              'include_transcript': 'true',
            }),
            headers: headers,
          ),
        );
        final list = _extractList(
          utf8.decode(resp.bodyBytes, allowMalformed: true),
        );
        if (list.isEmpty) break;

        final batch = <ExternalRecordDraft>[];
        final nextFps = <String, String>{};
        var pageNew = 0;
        var pageOld = 0;

        for (final conv in list) {
          final convId = '${conv['id'] ?? ''}'.trim();
          if (convId.isEmpty) continue;
          final fp = '${conv['finished_at'] ?? conv['started_at'] ?? ''}'.trim();
          final devName = deviceNameFor(convId);
          final already = existingDeviceNames.contains(devName);
          if (already && (fp.isEmpty || itemFingerprints[convId] == fp)) {
            skippedExisting += 1;
            pageOld += 1;
            continue;
          }
          if (already) updated += 1;
          pageNew += 1;

          final structured = conv['structured'] is Map
              ? Map<String, dynamic>.from(conv['structured'] as Map)
              : const <String, dynamic>{};
          final title = _extractTitle(conv);
          final overview = '${structured['overview'] ?? ''}'.trim();
          final categoryTag = '${structured['category'] ?? ''}'.trim();

          final startedAt = ExternalHttpHelper.parseTimestamp(
            conv['started_at'] ?? conv['created_at'],
          );
          final finishedAt = ExternalHttpHelper.tryParseTimestamp(
            conv['finished_at'],
          );
          final durationSec = finishedAt != null
              ? finishedAt.difference(startedAt).inMilliseconds / 1000.0
              : 0.0;

          final turns = <ExternalTurnDraft>[];
          final rawSegs = conv['transcript_segments'];
          if (rawSegs is List) {
            for (final seg in rawSegs) {
              if (seg is! Map) continue;
              final text = '${seg['text'] ?? ''}'.trim();
              if (text.isEmpty) continue;
              final spk = seg['is_user'] == true
                  ? '我'
                  : ('${seg['speaker'] ?? ''}'.trim().isNotEmpty
                        ? '${seg['speaker']}'.trim()
                        : (seg['speaker_id'] != null
                              ? '说话人 ${seg['speaker_id']}'
                              : '未区分'));
              final startSec = (seg['start'] as num?)?.toDouble() ?? 0;
              final endSec = (seg['end'] as num?)?.toDouble() ?? startSec;
              turns.add(
                ExternalTurnDraft(
                  speaker: spk,
                  text: text,
                  startMs: (startSec * 1000).round().clamp(0, 1 << 30),
                  endMs: (endSec * 1000).round().clamp(0, 1 << 30),
                ),
              );
            }
          }

          final rawText = turns
              .map(
                (t) => t.speaker == '未区分' ? t.text : '${t.speaker}：${t.text}',
              )
              .join('\n');
          final content = [
            if (overview.isNotEmpty) overview,
            if (rawText.isNotEmpty) rawText,
          ].join('\n\n').trim();

          batch.add(
            ExternalRecordDraft(
              externalId: convId,
              title: title.isEmpty ? 'Omi 对话' : title,
              content: content.isNotEmpty ? content : title,
              rawText: rawText,
              summary: overview,
              createdAt: startedAt,
              updatedAt: finishedAt,
              durationSec: durationSec > 0 ? durationSec : 0,
              tags: [if (categoryTag.isNotEmpty) categoryTag],
              turns: turns,
              fingerprint: fp,
            ),
          );
          nextFps[convId] = fp;
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

        offset += list.length;
        if (list.length < pageLimit) break;
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

  static List<Map<String, dynamic>> _extractList(String raw) {
    final decoded = ExternalHttpHelper.tryDecodeAny(raw);
    if (decoded is List) {
      return [
        for (final x in decoded)
          if (x is Map) Map<String, dynamic>.from(x),
      ];
    }
    if (decoded is Map) {
      final list = decoded['conversations'] ?? decoded['data'] ?? decoded['items'];
      if (list is List) {
        return [
          for (final x in list)
            if (x is Map) Map<String, dynamic>.from(x),
        ];
      }
    }
    return const [];
  }

  static String _extractTitle(Map<String, dynamic> conv) {
    final structured = conv['structured'];
    if (structured is Map) {
      final t = '${structured['title'] ?? ''}'.trim();
      if (t.isNotEmpty) return t;
    }
    return '${conv['title'] ?? ''}'.trim();
  }
}
