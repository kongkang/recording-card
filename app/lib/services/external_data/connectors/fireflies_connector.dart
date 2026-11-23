/// Fireflies.ai GraphQL API 连接器（`transcripts(limit, skip)` 无限翻页）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class FirefliesConnector extends ExternalDataConnector {
  FirefliesConnector({this.requestDelay = const Duration(milliseconds: 280)});

  static const String defaultEndpointUrl = 'https://api.fireflies.ai/graphql';

  final Duration requestDelay;

  @override
  String get id => 'fireflies';

  @override
  String get name => 'Fireflies.ai';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.recorders;

  @override
  String get protocolBadge => 'GraphQL';

  @override
  String get subtitle => '通过 Fireflies GraphQL API 分页同步会议纪要、行动项与逐字稿';

  @override
  String get setupGuide =>
      '在 Fireflies.ai「Integrations -> Fireflies API」复制 API Key，作为 Bearer Token 鉴权。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'apiKey',
      label: 'API Key',
      hint: 'Fireflies API Key',
      isSecret: true,
      required: true,
    ),
    ExternalFieldSpec(
      key: 'endpointUrl',
      label: 'GraphQL 地址（选填）',
      hint: defaultEndpointUrl,
      required: false,
      defaultValue: defaultEndpointUrl,
    ),
  ];

  Future<Map<String, dynamic>> _postGraphQl({
    required http.Client client,
    required String endpointUrl,
    required String apiKey,
    required String query,
    Map<String, dynamic> variables = const {},
  }) async {
    final resp = await ExternalHttpHelper.sendWithRetry(
      requestDelay: requestDelay,
      serviceName: name,
      request: () => client.post(
        Uri.parse(endpointUrl),
        headers: {
          'Authorization': 'Bearer ${ExternalHttpHelper.normalizeToken(apiKey)}',
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
        },
        body: jsonEncode({'query': query, 'variables': variables}),
      ),
    );
    final map = ExternalHttpHelper.tryDecodeMap(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
    if (map == null) {
      throw const ExternalConnectorException('Fireflies 返回了无法解析的 JSON 数据');
    }
    if (map['errors'] is List && (map['errors'] as List).isNotEmpty) {
      final msg =
          ExternalHttpHelper.extractErrorMessage(map) ?? 'GraphQL 查询错误';
      throw ExternalConnectorException('Fireflies 接口错误：$msg');
    }
    final data = map['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final apiKey = cfg['apiKey'] ?? '';
    if (apiKey.isEmpty) {
      throw const ExternalConnectorException('请先填写 Fireflies API Key');
    }
    final endpoint = ExternalHttpHelper.normalizeBaseUrl(
      cfg['endpointUrl'] ?? '',
      defaultEndpointUrl,
    );
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final data = await _postGraphQl(
        client: client,
        endpointUrl: endpoint,
        apiKey: apiKey,
        query: 'query { user { user_id name email } }',
      );
      final user = data['user'] is Map
          ? Map<String, dynamic>.from(data['user'] as Map)
          : const <String, dynamic>{};
      final userName = '${user['name'] ?? user['email'] ?? ''}'.trim();
      return ExternalTestResult(
        message: userName.isNotEmpty
            ? '连接成功（账号：$userName）'
            : '连接成功，Fireflies API 鉴权有效',
        sampleTitle: userName.isEmpty ? null : userName,
      );
    } finally {
      if (owned) client.close();
    }
  }

  static const String _listQuery = r'''
query GetTranscripts($limit: Int, $skip: Int) {
  transcripts(limit: $limit, skip: $skip) {
    id
    title
    date
    duration
    summary {
      overview
      short_summary
      action_items
    }
    sentences {
      index
      speaker_name
      speaker_id
      text
      start_time
      end_time
    }
  }
}
''';

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
      throw const ExternalConnectorException('请先填写 Fireflies API Key');
    }
    final endpoint = ExternalHttpHelper.normalizeBaseUrl(
      cfg['endpointUrl'] ?? '',
      defaultEndpointUrl,
    );

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      const pageLimit = 50;
      var skip = 0;
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
            message: '正在拉取 Fireflies 第 $pageNum 页会议转写（skip=$skip）…',
          ),
        );
        final data = await _postGraphQl(
          client: client,
          endpointUrl: endpoint,
          apiKey: apiKey,
          query: _listQuery,
          variables: {'limit': pageLimit, 'skip': skip},
        );
        final rawList = data['transcripts'] is List
            ? data['transcripts'] as List
            : const [];
        if (rawList.isEmpty) break;

        final batch = <ExternalRecordDraft>[];
        final nextFps = <String, String>{};
        var pageNew = 0;
        var pageOld = 0;

        for (final item in rawList) {
          if (item is! Map) continue;
          final tr = Map<String, dynamic>.from(item);
          final trId = '${tr['id'] ?? ''}'.trim();
          if (trId.isEmpty) continue;

          final sentences = tr['sentences'] is List
              ? tr['sentences'] as List
              : const [];
          final summaryMap = tr['summary'] is Map
              ? Map<String, dynamic>.from(tr['summary'] as Map)
              : const <String, dynamic>{};
          final overview =
              '${summaryMap['overview'] ?? summaryMap['short_summary'] ?? ''}'
                  .trim();
          final actionItems = '${summaryMap['action_items'] ?? ''}'.trim();
          final fp = '${tr['date'] ?? ''}_${sentences.length}_${overview.length}';

          final devName = deviceNameFor(trId);
          final already = existingDeviceNames.contains(devName);
          if (already && (itemFingerprints[trId] == fp)) {
            skippedExisting += 1;
            pageOld += 1;
            continue;
          }
          if (already) updated += 1;
          pageNew += 1;

          final turns = <ExternalTurnDraft>[];
          for (final rawS in sentences) {
            if (rawS is! Map) continue;
            final text = '${rawS['text'] ?? ''}'.trim();
            if (text.isEmpty) continue;
            final spk = '${rawS['speaker_name'] ?? ''}'.trim();
            final startSec = (rawS['start_time'] as num?)?.toDouble() ?? 0;
            final endSec = (rawS['end_time'] as num?)?.toDouble() ?? startSec;
            turns.add(
              ExternalTurnDraft(
                speaker: spk.isNotEmpty
                    ? spk
                    : (rawS['speaker_id'] != null
                          ? '说话人 ${rawS['speaker_id']}'
                          : '未区分'),
                text: text,
                startMs: (startSec * 1000).round().clamp(0, 1 << 30),
                endMs: (endSec * 1000).round().clamp(0, 1 << 30),
              ),
            );
          }

          final rawText = turns
              .map(
                (t) => t.speaker == '未区分' ? t.text : '${t.speaker}：${t.text}',
              )
              .join('\n');
          final sumBlock = [
            if (overview.isNotEmpty) overview,
            if (actionItems.isNotEmpty) '行动项：\n$actionItems',
          ].join('\n\n').trim();
          final content = [
            if (sumBlock.isNotEmpty) sumBlock,
            if (rawText.isNotEmpty) rawText,
          ].join('\n\n').trim();

          final rawDur = (tr['duration'] as num?)?.toDouble() ?? 0;
          // Fireflies duration 单位通常为分钟（或部分兼容源为秒）
          final durationSec = rawDur > 0 && rawDur < 600 ? rawDur * 60 : rawDur;

          batch.add(
            ExternalRecordDraft(
              externalId: trId,
              title: '${tr['title'] ?? 'Fireflies 会议记录'}'.trim(),
              content: content.isNotEmpty ? content : '${tr['title'] ?? ''}',
              rawText: rawText,
              summary: sumBlock,
              createdAt: ExternalHttpHelper.parseTimestamp(tr['date']),
              durationSec: durationSec,
              turns: turns,
              fingerprint: fp,
            ),
          );
          nextFps[trId] = fp;
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

        skip += rawList.length;
        if (rawList.length < pageLimit) break;
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
