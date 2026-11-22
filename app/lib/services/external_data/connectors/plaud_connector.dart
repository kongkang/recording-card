/// Plaud 录音与转写连接器（支持账号 REST API 与 Plaud MCP 网关，无限翻页同步）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class PlaudConnector extends ExternalDataConnector {
  PlaudConnector({this.requestDelay = const Duration(milliseconds: 280)});

  static const Map<String, String> regionUrls = {
    'global': 'https://api.plaud.ai',
    'eu': 'https://api-euc1.plaud.ai',
    'apac': 'https://api-apne1.plaud.ai',
  };

  final Duration requestDelay;

  @override
  String get id => 'plaud';

  @override
  String get name => 'Plaud';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.recorders;

  @override
  String get protocolBadge => 'API / MCP';

  @override
  String get subtitle => '同步 Plaud Note / NotePin 云端录音转写逐字稿与 AI 摘要';

  @override
  String get setupGuide =>
      'API 模式：填写 Plaud 账号 Bearer Access Token（或合作开发者 Token）并选择数据区；'
      '若通过本地/远程 Plaud MCP 网关接入，可切换为 MCP 模式并填写端点 URL。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'mode',
      label: '接入模式',
      required: true,
      defaultValue: 'api',
      options: [
        ExternalFieldOption('api', 'Plaud API'),
        ExternalFieldOption('mcp', 'Plaud MCP 网关'),
      ],
    ),
    ExternalFieldSpec(
      key: 'region',
      label: '服务区域',
      required: true,
      defaultValue: 'global',
      options: [
        ExternalFieldOption('global', 'Global (api.plaud.ai)'),
        ExternalFieldOption('apac', '亚太 (api-apne1)'),
        ExternalFieldOption('eu', '欧洲 (api-euc1)'),
        ExternalFieldOption('custom', '自定义地址'),
      ],
    ),
    ExternalFieldSpec(
      key: 'accessToken',
      label: 'Bearer Access Token',
      hint: 'Plaud Access Token',
      isSecret: true,
      required: true,
    ),
    ExternalFieldSpec(
      key: 'baseUrl',
      label: '自定义地址 / MCP URL（选填）',
      hint: 'https://api.plaud.ai 或 MCP 端点 URL',
      required: false,
    ),
  ];

  String _resolveBaseUrl(Map<String, String> cfg) {
    final custom = (cfg['baseUrl'] ?? '').trim();
    if (custom.isNotEmpty) return custom.replaceFirst(RegExp(r'/+$'), '');
    final region = cfg['region'] ?? 'global';
    if (region == 'custom') {
      throw const ExternalConnectorException('自定义区域请填写 Plaud API 或 MCP 地址');
    }
    return regionUrls[region] ?? regionUrls['global']!;
  }

  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer ${ExternalHttpHelper.normalizeToken(token)}',
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
      throw const ExternalConnectorException('请先填写 Plaud Access Token');
    }
    final mode = cfg['mode'] == 'mcp' ? 'mcp' : 'api';
    final baseUrl = _resolveBaseUrl(cfg);
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      if (mode == 'mcp') {
        final sid = await _mcpInitialize(client, baseUrl, token);
        final res = await ExternalHttpHelper.postMcpJsonRpc(
          client: client,
          endpointUrl: baseUrl,
          bearerToken: token,
          method: 'tools/list',
          params: const {},
          rpcId: 2,
          sessionId: sid,
          requestDelay: requestDelay,
          serviceName: name,
        );
        final tools = (res['result'] is Map &&
                (res['result'] as Map)['tools'] is List)
            ? (res['result'] as Map)['tools'] as List
            : const [];
        return ExternalTestResult(
          message: '连接成功（Plaud MCP，${tools.length} 个工具）',
          countHint: tools.length,
        );
      }

      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/file/simple/web', {
            'skip': '0',
            'limit': '1',
            'is_trash': '2',
            'sort_by': 'start_time',
            'is_desc': 'true',
          }),
          headers: _headers(token),
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final parsed = _extractFileList(map);
      final sample = parsed.items.isNotEmpty
          ? '${parsed.items.first['title'] ?? parsed.items.first['filename'] ?? ''}'
                .trim()
          : null;
      return ExternalTestResult(
        message: parsed.total != null
            ? '连接成功（共 ${parsed.total} 条录音）'
            : '连接成功，Plaud Token 鉴权有效',
        countHint: parsed.total ?? parsed.items.length,
        sampleTitle: (sample != null && sample.isNotEmpty) ? sample : null,
      );
    } finally {
      if (owned) client.close();
    }
  }

  Future<String?> _mcpInitialize(
    http.Client client,
    String endpoint,
    String token,
  ) async {
    try {
      final res = await ExternalHttpHelper.postMcpJsonRpc(
        client: client,
        endpointUrl: endpoint,
        bearerToken: token,
        method: 'initialize',
        params: const {
          'protocolVersion': '2024-11-05',
          'capabilities': <String, dynamic>{},
          'clientInfo': {'name': 'recording_card', 'version': '1.0.0'},
        },
        rpcId: 1,
        requestDelay: requestDelay,
        serviceName: name,
      );
      return res['sessionId'] as String?;
    } on ExternalConnectorException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) rethrow;
      return null;
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
      throw const ExternalConnectorException('请先填写 Plaud Access Token');
    }
    final mode = cfg['mode'] == 'mcp' ? 'mcp' : 'api';
    final baseUrl = _resolveBaseUrl(cfg);
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      if (mode == 'mcp') {
        return await _syncViaMcp(
          client: client,
          endpoint: baseUrl,
          token: token,
          existingDeviceNames: existingDeviceNames,
          itemFingerprints: itemFingerprints,
          onBatch: onBatch,
          onProgress: onProgress,
          isCancelled: isCancelled,
          incremental: incremental,
        );
      }
      return await _syncViaApi(
        client: client,
        baseUrl: baseUrl,
        token: token,
        existingDeviceNames: existingDeviceNames,
        itemFingerprints: itemFingerprints,
        onBatch: onBatch,
        onProgress: onProgress,
        isCancelled: isCancelled,
        incremental: incremental,
      );
    } finally {
      if (owned) client.close();
    }
  }

  Future<ExternalConnectorSyncReport> _syncViaApi({
    required http.Client client,
    required String baseUrl,
    required String token,
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
  }) async {
    const pageLimit = 50;
    final headers = _headers(token);
    var skip = 0;
    var pageNum = 0;
    var fetched = 0;
    var skippedExisting = 0;
    var updated = 0;
    var consecutiveAllExisting = 0;
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
          message: '正在拉取 Plaud 第 $pageNum 页录音列表（skip=$skip）…',
        ),
      );
      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/file/simple/web', {
            'skip': '$skip',
            'limit': '$pageLimit',
            'is_trash': '2',
            'sort_by': 'start_time',
            'is_desc': 'true',
          }),
          headers: headers,
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final parsed = _extractFileList(map);
      if (parsed.items.isEmpty) break;

      final batch = <ExternalRecordDraft>[];
      final nextFps = <String, String>{};
      var pageNew = 0;
      var pageOld = 0;

      for (final item in parsed.items) {
        if (isCancelled()) {
          cancelled = true;
          fullBackfill = false;
          break;
        }
        final fileId = '${item['file_id'] ?? item['id'] ?? ''}'.trim();
        if (fileId.isEmpty) continue;
        final fp = '${item['edit_time'] ?? item['status'] ?? item['version'] ?? ''}'.trim();
        final devName = deviceNameFor(fileId);
        final already = existingDeviceNames.contains(devName);
        if (already && (fp.isEmpty || itemFingerprints[fileId] == fp)) {
          skippedExisting += 1;
          pageOld += 1;
          continue;
        }
        if (already) updated += 1;
        pageNew += 1;

        final detailResp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(baseUrl, '/file/detail/$fileId'),
            headers: headers,
          ),
        );
        final detailMap = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(detailResp.bodyBytes, allowMalformed: true),
        );
        final detailData = detailMap?['data'] is Map
            ? Map<String, dynamic>.from(detailMap!['data'] as Map)
            : (detailMap ?? item);

        final draft = _parseDetailToDraft(fileId, item, detailData, fp);
        if (draft != null) {
          batch.add(draft);
          nextFps[fileId] = fp;
          fetched += 1;
        }
      }

      if (batch.isNotEmpty) {
        await onBatch(batch, nextFps);
      }
      if (cancelled) break;

      if (incremental && pageNew == 0 && pageOld > 0) {
        consecutiveAllExisting += 1;
        if (consecutiveAllExisting >= 2) break;
      } else if (pageNew > 0) {
        consecutiveAllExisting = 0;
      }

      skip += parsed.items.length;
      if (parsed.hasMore == false) break;
      if (parsed.total != null && skip >= parsed.total!) break;
      if (parsed.hasMore == null && parsed.items.length < pageLimit) break;
    }

    return ExternalConnectorSyncReport(
      pagesScanned: pageNum,
      fetched: fetched,
      skippedExisting: skippedExisting,
      updated: updated,
      cancelled: cancelled,
      completedFullBackfill: fullBackfill && !cancelled,
    );
  }

  Future<ExternalConnectorSyncReport> _syncViaMcp({
    required http.Client client,
    required String endpoint,
    required String token,
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
  }) async {
    final sessionId = await _mcpInitialize(client, endpoint, token);
    var rpcId = 2;
    String? cursor;
    final visited = <String>{};
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
          message: '正在通过 Plaud MCP 拉取第 $pageNum 页录音…',
        ),
      );
      final res = await ExternalHttpHelper.postMcpJsonRpc(
        client: client,
        endpointUrl: endpoint,
        bearerToken: token,
        method: 'tools/call',
        params: {
          'name': 'list_recordings',
          'arguments': {'limit': 50, 'cursor': ?cursor},
        },
        rpcId: rpcId++,
        sessionId: sessionId,
        requestDelay: requestDelay,
        serviceName: name,
      );
      final parsed = _extractMcpRecordings(res['result']);
      if (parsed.items.isEmpty) break;

      final batch = <ExternalRecordDraft>[];
      final nextFps = <String, String>{};
      for (final item in parsed.items) {
        final fileId = '${item['file_id'] ?? item['id'] ?? ''}'.trim();
        if (fileId.isEmpty) continue;
        final fp = '${item['edit_time'] ?? item['updated_at'] ?? ''}'.trim();
        final already = existingDeviceNames.contains(deviceNameFor(fileId));
        if (already && (fp.isEmpty || itemFingerprints[fileId] == fp)) {
          skippedExisting += 1;
          continue;
        }
        if (already) updated += 1;
        final draft = _parseDetailToDraft(fileId, item, item, fp);
        if (draft != null) {
          batch.add(draft);
          nextFps[fileId] = fp;
          fetched += 1;
        }
      }
      if (batch.isNotEmpty) {
        await onBatch(batch, nextFps);
      }
      final next = parsed.nextCursor;
      if (!parsed.hasMore ||
          next == null ||
          next.isEmpty ||
          !visited.add(next)) {
        break;
      }
      cursor = next;
    }

    return ExternalConnectorSyncReport(
      pagesScanned: pageNum,
      fetched: fetched,
      skippedExisting: skippedExisting,
      updated: updated,
      cancelled: cancelled,
      completedFullBackfill: fullBackfill && !cancelled,
    );
  }

  static ({List<Map<String, dynamic>> items, bool? hasMore, int? total})
  _extractFileList(Map<String, dynamic>? map) {
    if (map == null) return (items: const [], hasMore: false, total: null);
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : map;
    final rawList =
        data['list'] ?? data['data_file_list'] ?? data['files'] ?? map['list'];
    final items = <Map<String, dynamic>>[
      if (rawList is List)
        for (final x in rawList)
          if (x is Map) Map<String, dynamic>.from(x),
    ];
    final hasMoreVal = data['has_more'] ?? map['has_more'];
    final hasMore = hasMoreVal is bool
        ? hasMoreVal
        : (hasMoreVal == 1 || hasMoreVal == 'true' ? true : null);
    final total =
        (data['total'] as num?)?.toInt() ??
        (data['data_file_total'] as num?)?.toInt();
    return (items: items, hasMore: hasMore, total: total);
  }

  static ({List<Map<String, dynamic>> items, bool hasMore, String? nextCursor})
  _extractMcpRecordings(Object? result) {
    if (result is! Map) {
      return (items: const [], hasMore: false, nextCursor: null);
    }
    final res = Map<String, dynamic>.from(result);
    var text = '';
    if (res['content'] is List) {
      for (final c in res['content'] as List) {
        if (c is Map && c['text'] != null) text += '${c['text']}\n';
      }
    }
    final decoded = text.trim().isNotEmpty
        ? ExternalHttpHelper.tryDecodeAny(text.trim())
        : res;
    if (decoded is List) {
      return (
        items: [
          for (final x in decoded)
            if (x is Map) Map<String, dynamic>.from(x),
        ],
        hasMore: false,
        nextCursor: null,
      );
    }
    if (decoded is Map) {
      final dm = Map<String, dynamic>.from(decoded);
      final extracted = _extractFileList(dm);
      final nextCur = '${dm['next_cursor'] ?? dm['nextCursor'] ?? ''}'.trim();
      return (
        items: extracted.items,
        hasMore: extracted.hasMore == true || nextCur.isNotEmpty,
        nextCursor: nextCur.isEmpty ? null : nextCur,
      );
    }
    return (items: const [], hasMore: false, nextCursor: null);
  }

  static ExternalRecordDraft? _parseDetailToDraft(
    String fileId,
    Map<String, dynamic> summaryItem,
    Map<String, dynamic> detail,
    String fingerprint,
  ) {
    final title =
        '${detail['title'] ?? detail['filename'] ?? summaryItem['title'] ?? summaryItem['filename'] ?? 'Plaud 录音'}'
            .trim();
    final createdAt = ExternalHttpHelper.parseTimestamp(
      detail['start_time'] ??
          detail['create_time'] ??
          summaryItem['start_time'] ??
          summaryItem['create_time'],
    );
    final rawDuration =
        (detail['duration'] as num?)?.toDouble() ??
        (summaryItem['duration'] as num?)?.toDouble() ??
        0;
    // Plaud 部分端点以毫秒返回 duration（通常 > 86400），部分以秒返回
    final durationSec = rawDuration > 86400 ? rawDuration / 1000 : rawDuration;

    final summaryObj = detail['summary'];
    var summaryText = '';
    if (summaryObj is String) {
      summaryText = summaryObj.trim();
    } else if (summaryObj is Map) {
      final overview = '${summaryObj['overview'] ?? ''}'.trim();
      final keyPoints = summaryObj['key_points'] is List
          ? [
              for (final p in summaryObj['key_points'] as List)
                if ('$p'.trim().isNotEmpty) '• ${'$p'.trim()}',
            ].join('\n')
          : '';
      summaryText = [
        if (overview.isNotEmpty) overview,
        if (keyPoints.isNotEmpty) keyPoints,
      ].join('\n\n').trim();
    }
    if (summaryText.isEmpty) {
      summaryText = '${detail['ai_note'] ?? ''}'.trim();
    }

    final turns = <ExternalTurnDraft>[];
    final transcriptObj = detail['transcript'];
    final rawSegments = (transcriptObj is Map
            ? transcriptObj['segments']
            : null) ??
        detail['trans_result'] ??
        detail['segments'];
    if (rawSegments is List) {
      for (final seg in rawSegments) {
        if (seg is! Map) continue;
        final m = Map<String, dynamic>.from(seg);
        final text = '${m['text'] ?? m['content'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        final spk = '${m['speaker'] ?? m['speaker_name'] ?? ''}'.trim();
        final startMs = _toMs(m['start_ms'], m['start_time'] ?? m['start']);
        final endMs = _toMs(m['end_ms'], m['end_time'] ?? m['end']);
        turns.add(
          ExternalTurnDraft(
            speaker: spk.isEmpty ? '未区分' : spk,
            text: text,
            startMs: startMs,
            endMs: endMs,
          ),
        );
      }
    }

    final transcriptLines = turns
        .map((t) => t.speaker == '未区分' ? t.text : '${t.speaker}：${t.text}')
        .join('\n');
    final rawText = transcriptLines.isNotEmpty
        ? transcriptLines
        : '${detail['transcript_text'] ?? ''}'.trim();
    final content = [
      if (summaryText.isNotEmpty) summaryText,
      if (rawText.isNotEmpty && rawText != summaryText) rawText,
    ].join('\n\n').trim();

    if (title.isEmpty && content.isEmpty && turns.isEmpty) return null;

    final tags = <String>[
      if (detail['tags'] is List)
        for (final t in detail['tags'] as List)
          if ('$t'.trim().isNotEmpty) '$t'.trim(),
    ];

    return ExternalRecordDraft(
      externalId: fileId,
      title: title,
      content: content.isNotEmpty ? content : title,
      rawText: rawText,
      summary: summaryText,
      createdAt: createdAt,
      durationSec: durationSec,
      tags: tags,
      turns: turns,
      fingerprint: fingerprint,
    );
  }

  static int _toMs(Object? msVal, Object? secVal) {
    if (msVal is num) return msVal.round().clamp(0, 1 << 30);
    if (secVal is num) {
      return secVal > 86400
          ? secVal.round().clamp(0, 1 << 30)
          : (secVal * 1000).round().clamp(0, 1 << 30);
    }
    return 0;
  }
}
