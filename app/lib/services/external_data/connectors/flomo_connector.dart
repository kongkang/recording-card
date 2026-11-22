/// flomo（浮墨笔记）连接器：支持官方 MCP（JSON-RPC 2.0）与 REST 接口无限翻页读取。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class FlomoConnector extends ExternalDataConnector {
  FlomoConnector({this.requestDelay = const Duration(milliseconds: 280)});

  static const String defaultMcpUrl = 'https://flomoapp.com/mcp';
  static const String defaultRestBaseUrl = 'https://flomoapp.com/api/v1';

  final Duration requestDelay;

  @override
  String get id => 'flomo';

  @override
  String get name => 'flomo';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'MCP / REST';

  @override
  String get subtitle => '通过 flomo 官方 MCP（PRO/MAX）或 REST Token 全量拉取笔记与标签';

  @override
  String get setupGuide =>
      '官方 MCP 模式：在 flomo 网页版「设置 -> MCP / API -> MCP」生成 Token（默认地址 https://flomoapp.com/mcp）；'
      '若使用自建代理或 REST 接口可切换为 REST 模式。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'mode',
      label: '接入模式',
      required: true,
      defaultValue: 'mcp',
      options: [
        ExternalFieldOption('mcp', '官方 MCP（推荐）'),
        ExternalFieldOption('rest', 'REST API'),
      ],
    ),
    ExternalFieldSpec(
      key: 'token',
      label: 'Bearer Token',
      hint: 'flomo MCP Token 或 Access Token',
      isSecret: true,
      required: true,
    ),
    ExternalFieldSpec(
      key: 'endpointUrl',
      label: '接口地址（选填）',
      hint: 'MCP 默认 https://flomoapp.com/mcp',
      required: false,
    ),
    ExternalFieldSpec(
      key: 'tagFilter',
      label: '标签过滤（选填）',
      hint: '例如 读书，留空同步全部笔记',
      required: false,
    ),
  ];

  String _resolveEndpoint(Map<String, String> cfg) {
    final mode = cfg['mode'] == 'rest' ? 'rest' : 'mcp';
    final raw = (cfg['endpointUrl'] ?? '').trim();
    if (raw.isNotEmpty) return raw.replaceFirst(RegExp(r'/+$'), '');
    return mode == 'mcp' ? defaultMcpUrl : defaultRestBaseUrl;
  }

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = cfg['token'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 flomo Bearer Token');
    }
    final mode = cfg['mode'] == 'rest' ? 'rest' : 'mcp';
    final endpoint = _resolveEndpoint(cfg);
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      if (mode == 'mcp') {
        final sid = await _mcpInitialize(client, endpoint, token);
        final listRes = await ExternalHttpHelper.postMcpJsonRpc(
          client: client,
          endpointUrl: endpoint,
          bearerToken: token,
          method: 'tools/list',
          params: const {},
          rpcId: 2,
          sessionId: sid,
          requestDelay: requestDelay,
          serviceName: name,
        );
        final result = listRes['result'] is Map
            ? Map<String, dynamic>.from(listRes['result'] as Map)
            : const <String, dynamic>{};
        final tools = result['tools'] is List
            ? result['tools'] as List
            : const [];
        return ExternalTestResult(
          message: '连接成功（flomo MCP，发现 ${tools.length} 个工具）',
          countHint: tools.length,
        );
      }

      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(
            endpoint,
            '/memo/latest_updated_desc',
            {'limit': '1'},
          ),
          headers: {
            'Authorization':
                'Bearer ${ExternalHttpHelper.normalizeToken(token)}',
            'Accept': 'application/json',
          },
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final list = _extractRestMemoList(map);
      return ExternalTestResult(
        message: '连接成功（REST 接口返回 ${list.length} 条样例）',
        countHint: list.length,
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
      // 部分简版 MCP 代理不要求 initialize 握手，直接 tools/call
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
    final token = cfg['token'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 flomo Bearer Token');
    }
    final mode = cfg['mode'] == 'rest' ? 'rest' : 'mcp';
    final endpoint = _resolveEndpoint(cfg);
    final tagFilter = cfg['tagFilter'] ?? '';

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      if (mode == 'mcp') {
        return await _syncViaMcp(
          client: client,
          endpoint: endpoint,
          token: token,
          tagFilter: tagFilter,
          existingDeviceNames: existingDeviceNames,
          itemFingerprints: itemFingerprints,
          onBatch: onBatch,
          onProgress: onProgress,
          isCancelled: isCancelled,
          incremental: incremental,
        );
      }
      return await _syncViaRest(
        client: client,
        endpoint: endpoint,
        token: token,
        tagFilter: tagFilter,
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

  Future<ExternalConnectorSyncReport> _syncViaMcp({
    required http.Client client,
    required String endpoint,
    required String token,
    required String tagFilter,
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
    String? untilCursor;
    String? pageCursor;
    final visitedCursors = <String>{};
    final seenInRun = <String>{};

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
          message: '正在通过 flomo MCP 拉取第 $pageNum 页笔记…',
        ),
      );

      final args = <String, dynamic>{
        'limit': 50,
        if (tagFilter.isNotEmpty) 'tag': tagFilter,
        'cursor': ?pageCursor,
        if (pageCursor == null && untilCursor != null) 'until': untilCursor,
      };
      final res = await ExternalHttpHelper.postMcpJsonRpc(
        client: client,
        endpointUrl: endpoint,
        bearerToken: token,
        method: 'tools/call',
        params: {'name': 'memo_search', 'arguments': args},
        rpcId: rpcId++,
        sessionId: sessionId,
        requestDelay: requestDelay,
        serviceName: name,
      );
      final parsed = _parseMcpMemoSearchResult(res['result']);
      if (parsed.items.isEmpty) break;

      // 若列表仅含 ID 而无正文，批量调用 memo_batch_get 补齐
      final missingBodyIds = <String>[
        for (final m in parsed.items)
          if (m.id.isNotEmpty && m.content.isEmpty) m.id,
      ];
      final detailById = <String, _FlomoRawMemo>{};
      if (missingBodyIds.isNotEmpty) {
        final batchRes = await ExternalHttpHelper.postMcpJsonRpc(
          client: client,
          endpointUrl: endpoint,
          bearerToken: token,
          method: 'tools/call',
          params: {
            'name': 'memo_batch_get',
            'arguments': {'ids': missingBodyIds},
          },
          rpcId: rpcId++,
          sessionId: sessionId,
          requestDelay: requestDelay,
          serviceName: name,
        );
        for (final full in _parseMcpMemoSearchResult(batchRes['result']).items) {
          if (full.id.isNotEmpty) detailById[full.id] = full;
        }
      }

      final batch = <ExternalRecordDraft>[];
      final nextFps = <String, String>{};
      var pageNew = 0;
      var pageOld = 0;
      DateTime? oldestSeenAt;

      for (final rawMemo in parsed.items) {
        final memo = detailById[rawMemo.id] ?? rawMemo;
        if (memo.id.isEmpty || !seenInRun.add(memo.id)) continue;
        if (oldestSeenAt == null || memo.createdAt.isBefore(oldestSeenAt)) {
          oldestSeenAt = memo.createdAt;
        }
        final devName = deviceNameFor(memo.id);
        final already = existingDeviceNames.contains(devName);
        final fp = memo.fingerprint;
        if (already && (itemFingerprints[memo.id] == fp)) {
          skippedExisting += 1;
          pageOld += 1;
          continue;
        }
        if (already) updated += 1;
        pageNew += 1;
        batch.add(memo.toDraft());
        nextFps[memo.id] = fp;
        fetched += 1;
      }

      if (batch.isNotEmpty) {
        await onBatch(batch, nextFps);
      }

      if (incremental && pageNew == 0 && pageOld > 0) {
        consecutiveAllExisting += 1;
        if (consecutiveAllExisting >= 2) break;
      } else if (pageNew > 0) {
        consecutiveAllExisting = 0;
      }

      final nextCur = parsed.nextCursor;
      if (nextCur != null && nextCur.isNotEmpty) {
        if (!visitedCursors.add(nextCur)) break;
        pageCursor = nextCur;
        continue;
      }
      if (!parsed.hasMore && parsed.items.length < 50) {
        break;
      }
      if (oldestSeenAt == null || (pageNew == 0 && pageOld == 0)) {
        break;
      }
      final nextUntil = oldestSeenAt
          .subtract(const Duration(seconds: 1))
          .toIso8601String();
      if (nextUntil == untilCursor || !visitedCursors.add('u:$nextUntil')) {
        break;
      }
      untilCursor = nextUntil;
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

  Future<ExternalConnectorSyncReport> _syncViaRest({
    required http.Client client,
    required String endpoint,
    required String token,
    required String tagFilter,
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
    const pageLimit = 200;
    final seenInRun = <String>{};
    String? latestUpdatedAt;
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
          message: '正在通过 flomo REST 拉取第 $pageNum 页笔记…',
        ),
      );

      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(endpoint, '/memo/latest_updated_desc', {
            'limit': '$pageLimit',
            'latest_updated_at': ?latestUpdatedAt,
            if (tagFilter.isNotEmpty) 'tag': tagFilter,
          }),
          headers: {
            'Authorization':
                'Bearer ${ExternalHttpHelper.normalizeToken(token)}',
            'Accept': 'application/json',
          },
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final rawList = _extractRestMemoList(map);
      if (rawList.isEmpty) break;

      final batch = <ExternalRecordDraft>[];
      final nextFps = <String, String>{};
      var pageNew = 0;
      var pageOld = 0;
      int? oldestEpochSec;

      for (final raw in rawList) {
        if (raw is! Map) continue;
        final memo = _parseRestMemo(Map<String, dynamic>.from(raw));
        if (memo == null || !seenInRun.add(memo.id)) continue;
        if (tagFilter.isNotEmpty && !memo.tags.contains(tagFilter)) {
          continue;
        }
        final sec = (memo.updatedAt ?? memo.createdAt).millisecondsSinceEpoch ~/
            1000;
        if (oldestEpochSec == null || sec < oldestEpochSec) {
          oldestEpochSec = sec;
        }
        final devName = deviceNameFor(memo.id);
        final already = existingDeviceNames.contains(devName);
        if (already && itemFingerprints[memo.id] == memo.fingerprint) {
          skippedExisting += 1;
          pageOld += 1;
          continue;
        }
        if (already) updated += 1;
        pageNew += 1;
        batch.add(memo.toDraft());
        nextFps[memo.id] = memo.fingerprint;
        fetched += 1;
      }

      if (batch.isNotEmpty) {
        await onBatch(batch, nextFps);
      }
      if (incremental && pageNew == 0 && pageOld > 0) {
        consecutiveAllExisting += 1;
        if (consecutiveAllExisting >= 2) break;
      } else if (pageNew > 0) {
        consecutiveAllExisting = 0;
      }

      if (rawList.length < pageLimit ||
          oldestEpochSec == null ||
          (pageNew == 0 && pageOld == 0)) {
        break;
      }
      final nextStamp = '${oldestEpochSec - 1}';
      if (nextStamp == latestUpdatedAt) break;
      latestUpdatedAt = nextStamp;
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

  static List<dynamic> _extractRestMemoList(Map<String, dynamic>? map) {
    if (map == null) return const [];
    final data = map['data'];
    if (data is List) return data;
    if (data is Map) {
      final inner = data['memos'] ?? data['list'] ?? data['items'];
      if (inner is List) return inner;
    }
    final top = map['memos'] ?? map['list'] ?? map['items'];
    if (top is List) return top;
    return const [];
  }

  static _FlomoRawMemo? _parseRestMemo(Map<String, dynamic> m) {
    final id = '${m['slug'] ?? m['id'] ?? m['memo_id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final rawContent = '${m['content'] ?? ''}'.trim();
    final content = ExternalHttpHelper.stripHtmlOrXml(rawContent);
    final createdAt = ExternalHttpHelper.parseTimestamp(
      m['created_at'] ?? m['updated_at'],
    );
    final updatedAt = ExternalHttpHelper.tryParseTimestamp(m['updated_at']);
    final tags = _parseTags(m['tags'], content);
    return _FlomoRawMemo(
      id: id,
      content: content,
      createdAt: createdAt,
      updatedAt: updatedAt,
      tags: tags,
    );
  }

  static ({List<_FlomoRawMemo> items, bool hasMore, String? nextCursor})
  _parseMcpMemoSearchResult(Object? result) {
    if (result is! Map) {
      return (items: const [], hasMore: false, nextCursor: null);
    }
    final resMap = Map<String, dynamic>.from(result);
    String? nextCursor = _nonEmpty(resMap['nextCursor'] ?? resMap['next_cursor']);
    var hasMore = resMap['hasMore'] == true || resMap['has_more'] == true;
    final directMemos = resMap['memos'] ?? resMap['items'];
    if (directMemos is List) {
      return (
        items: [
          for (final item in directMemos)
            if (item is Map)
              ?_parseRestMemo(Map<String, dynamic>.from(item)),
        ],
        hasMore: hasMore,
        nextCursor: nextCursor,
      );
    }

    final contentList = resMap['content'] is List
        ? resMap['content'] as List
        : const [];
    final textChunks = <String>[];
    for (final c in contentList) {
      if (c is Map && c['text'] != null) {
        textChunks.add('${c['text']}');
      }
    }
    final joined = textChunks.join('\n').trim();
    if (joined.isEmpty) {
      return (items: const [], hasMore: false, nextCursor: null);
    }

    final decoded = ExternalHttpHelper.tryDecodeAny(joined);
    if (decoded is List) {
      return (
        items: [
          for (final item in decoded)
            if (item is Map)
              ?_parseRestMemo(Map<String, dynamic>.from(item)),
        ],
        hasMore: hasMore,
        nextCursor: nextCursor,
      );
    }
    if (decoded is Map) {
      final dm = Map<String, dynamic>.from(decoded);
      nextCursor ??= _nonEmpty(dm['nextCursor'] ?? dm['next_cursor']);
      hasMore = hasMore || dm['hasMore'] == true || dm['has_more'] == true;
      final list = _extractRestMemoList(dm);
      return (
        items: [
          for (final item in list)
            if (item is Map)
              ?_parseRestMemo(Map<String, dynamic>.from(item)),
        ],
        hasMore: hasMore,
        nextCursor: nextCursor,
      );
    }

    // 兜底解析文本行格式：`- [2026-06-06 14:30:21] #tag 内容...`
    final linePattern = RegExp(
      r'^[-*•]?\s*\[(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?)\]\s*(.+)$',
    );
    final items = <_FlomoRawMemo>[];
    for (final line in joined.split(RegExp(r'\r?\n'))) {
      final m = linePattern.firstMatch(line.trim());
      if (m == null) continue;
      final ts = ExternalHttpHelper.parseTimestamp(m.group(1));
      var body = m.group(2)!.trim();
      String id = '${ts.millisecondsSinceEpoch}_${items.length}';
      final slugMatch = RegExp(r'\bslug[:=]\s*([A-Za-z0-9_-]+)').firstMatch(body);
      if (slugMatch != null) {
        id = slugMatch.group(1)!;
        body = body.replaceFirst(slugMatch.group(0)!, '').trim();
      }
      final cleaned = ExternalHttpHelper.stripHtmlOrXml(body);
      items.add(
        _FlomoRawMemo(
          id: id,
          content: cleaned,
          createdAt: ts,
          tags: _parseTags(null, cleaned),
        ),
      );
    }
    return (items: items, hasMore: hasMore, nextCursor: nextCursor);
  }

  static String? _nonEmpty(Object? val) {
    if (val == null) return null;
    final s = '$val'.trim();
    return s.isEmpty || s.toLowerCase() == 'null' ? null : s;
  }

  static List<String> _parseTags(Object? rawTags, String content) {
    final out = <String>[];
    if (rawTags is List) {
      for (final t in rawTags) {
        final s = (t is Map ? '${t['name'] ?? ''}' : '$t')
            .trim()
            .replaceFirst('#', '');
        if (s.isNotEmpty && !out.contains(s)) out.add(s);
      }
    }
    for (final m in RegExp(r'(?:^|\s)#([^\s#]+)').allMatches(content)) {
      final tag = m.group(1)!.trim();
      if (tag.isNotEmpty && !out.contains(tag)) out.add(tag);
    }
    return out;
  }
}

class _FlomoRawMemo {
  const _FlomoRawMemo({
    required this.id,
    required this.content,
    required this.createdAt,
    this.updatedAt,
    this.tags = const [],
  });

  final String id;
  final String content;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<String> tags;

  String get fingerprint =>
      '${(updatedAt ?? createdAt).millisecondsSinceEpoch}_${content.length}';

  ExternalRecordDraft toDraft() {
    final firstLine = content
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => 'flomo 笔记');
    final title = firstLine.length <= 28
        ? firstLine
        : '${firstLine.substring(0, 28)}…';
    return ExternalRecordDraft(
      externalId: id,
      title: title,
      content: content.isNotEmpty ? content : title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      tags: tags,
      fingerprint: fingerprint,
    );
  }
}
