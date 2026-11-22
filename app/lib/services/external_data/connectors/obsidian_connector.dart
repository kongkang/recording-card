/// Obsidian Local REST API 连接器（递归遍历 `/vault/` 全部 Markdown 笔记）。
library;

import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class ObsidianConnector extends ExternalDataConnector {
  ObsidianConnector({this.requestDelay = const Duration(milliseconds: 40)});

  static const String defaultBaseUrl = 'http://127.0.0.1:27123';

  final Duration requestDelay;

  @override
  String get id => 'obsidian';

  @override
  String get name => 'Obsidian';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'Local REST';

  @override
  String get subtitle => '通过 Obsidian Local REST API 插件全量遍历 Vault Markdown 笔记';

  @override
  String get setupGuide =>
      '在 Obsidian 社区插件市场安装并启用「Local REST API」，复制 API Key 与端口（HTTP 27123 或 HTTPS 27124）。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'baseUrl',
      label: '插件服务地址',
      hint: 'http://127.0.0.1:27123 或 https://127.0.0.1:27124',
      required: true,
      defaultValue: defaultBaseUrl,
    ),
    ExternalFieldSpec(
      key: 'apiKey',
      label: 'API Key',
      hint: 'Local REST API Bearer Token',
      isSecret: true,
      required: true,
    ),
    ExternalFieldSpec(
      key: 'folder',
      label: '子目录过滤（选填）',
      hint: '例如 Daily/，留空扫描整个 Vault',
      required: false,
    ),
    ExternalFieldSpec(
      key: 'allowSelfSigned',
      label: '允许本机自签名 HTTPS 证书',
      helperText: '使用 27124 HTTPS 默认自签证书且目标是本机/局域网地址时开启',
      required: false,
      isBoolean: true,
      defaultValue: 'false',
    ),
  ];

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final apiKey = cfg['apiKey'] ?? '';
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    if (apiKey.isEmpty) {
      throw const ExternalConnectorException('请先填写 Obsidian API Key');
    }
    final allowSelfSigned = cfg['allowSelfSigned'] == 'true';
    final owned = httpClient == null;
    final client = ExternalHttpHelper.resolveClient(
      override: httpClient,
      allowLocalSelfSigned: allowSelfSigned,
      targetBaseUrl: baseUrl,
    );
    try {
      final token = ExternalHttpHelper.normalizeToken(apiKey);
      final resp = await ExternalHttpHelper.sendWithRetry(
        requestDelay: requestDelay,
        serviceName: name,
        request: () => client.get(
          ExternalHttpHelper.buildUri(baseUrl, '/vault/'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final files = map?['files'] is List ? map!['files'] as List : const [];
      return ExternalTestResult(
        message: '连接成功（根目录 ${files.length} 项）',
        countHint: files.length,
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
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    if (apiKey.isEmpty) {
      throw const ExternalConnectorException('请先填写 Obsidian API Key');
    }
    final token = ExternalHttpHelper.normalizeToken(apiKey);
    final allowSelfSigned = cfg['allowSelfSigned'] == 'true';
    final rawFolder = (cfg['folder'] ?? '')
        .trim()
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final rootDir = rawFolder.isEmpty ? '' : '$rawFolder/';

    final owned = httpClient == null;
    final client = ExternalHttpHelper.resolveClient(
      override: httpClient,
      allowLocalSelfSigned: allowSelfSigned,
      targetBaseUrl: baseUrl,
    );
    try {
      final queue = Queue<String>()..add(rootDir);
      final visitedDirs = <String>{};
      final mdPaths = <String>[];
      var dirPage = 0;
      var cancelled = false;

      while (queue.isNotEmpty) {
        if (isCancelled()) {
          cancelled = true;
          break;
        }
        final dir = queue.removeFirst();
        if (!visitedDirs.add(dir)) continue;
        dirPage += 1;
        onProgress(
          ExternalSyncProgress(
            page: dirPage,
            fetched: mdPaths.length,
            added: 0,
            message: '正在扫描 Obsidian 目录 ${dir.isEmpty ? "/" : dir}…',
          ),
        );
        final resp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            _vaultUri(baseUrl, dir),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          ),
        );
        final map = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(resp.bodyBytes, allowMalformed: true),
        );
        final files = map?['files'] is List ? map!['files'] as List : const [];
        for (final entry in files) {
          final rel = entry is Map
              ? '${entry['path'] ?? entry['name'] ?? ''}'.trim()
              : '$entry'.trim();
          if (rel.isEmpty) continue;
          final full = rel.startsWith(dir) ? rel : '$dir$rel';
          if (full.endsWith('/')) {
            if (!visitedDirs.contains(full)) queue.add(full);
          } else if (full.toLowerCase().endsWith('.md')) {
            mdPaths.add(full);
          }
        }
      }

      if (cancelled) {
        return const ExternalConnectorSyncReport(
          cancelled: true,
          completedFullBackfill: false,
        );
      }

      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
      final batch = <ExternalRecordDraft>[];
      final batchFps = <String, String>{};
      var batchIdx = 0;

      for (var i = 0; i < mdPaths.length; i++) {
        if (isCancelled()) {
          cancelled = true;
          break;
        }
        final path = mdPaths[i];
        final resp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            _vaultUri(baseUrl, path),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.olrapi.note+json, text/markdown',
            },
          ),
        );
        final rawText = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final jsonNote = ExternalHttpHelper.tryDecodeMap(rawText);

        var content = rawText;
        var title = _titleFromPath(path);
        var tags = <String>[];
        DateTime createdAt = DateTime.now();
        DateTime? updatedAt;
        var fingerprint = '${rawText.length}';

        if (jsonNote != null && jsonNote.containsKey('content')) {
          content = '${jsonNote['content'] ?? ''}'.trim();
          final fm = jsonNote['frontmatter'] is Map
              ? Map<String, dynamic>.from(jsonNote['frontmatter'] as Map)
              : const <String, dynamic>{};
          final fmTitle = '${fm['title'] ?? ''}'.trim();
          if (fmTitle.isNotEmpty) title = fmTitle;
          if (jsonNote['tags'] is List) {
            tags = [
              for (final t in jsonNote['tags'] as List)
                if ('$t'.trim().isNotEmpty) '$t'.trim().replaceFirst('#', ''),
            ];
          }
          final stat = jsonNote['stat'] is Map
              ? Map<String, dynamic>.from(jsonNote['stat'] as Map)
              : null;
          final ctime = stat?['ctime'];
          final mtime = stat?['mtime'];
          createdAt = ExternalHttpHelper.parseTimestamp(
            fm['date'] ?? fm['created'] ?? ctime ?? mtime,
          );
          updatedAt = ExternalHttpHelper.tryParseTimestamp(mtime);
          fingerprint = '${mtime ?? ''}_${jsonNote['size'] ?? content.length}';
        }

        final devName = deviceNameFor(path);
        final alreadyExists = existingDeviceNames.contains(devName);
        final prevFp = itemFingerprints[path];
        if (alreadyExists && (prevFp == null || prevFp == fingerprint)) {
          skippedExisting += 1;
          continue;
        }
        if (alreadyExists) updated += 1;

        batch.add(
          ExternalRecordDraft(
            externalId: path,
            title: title,
            content: content.isNotEmpty ? content : title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: tags,
            fingerprint: fingerprint,
          ),
        );
        batchFps[path] = fingerprint;
        fetched += 1;

        if (batch.length >= 20) {
          batchIdx += 1;
          onProgress(
            ExternalSyncProgress(
              page: batchIdx,
              fetched: fetched,
              added: fetched,
              message: '正在写入 Obsidian 笔记（已处理 ${i + 1}/${mdPaths.length}）…',
            ),
          );
          await onBatch(
            List<ExternalRecordDraft>.from(batch),
            Map<String, String>.from(batchFps),
          );
          batch.clear();
          batchFps.clear();
        }
      }

      if (batch.isNotEmpty) {
        batchIdx += 1;
        await onBatch(batch, batchFps);
      }

      return ExternalConnectorSyncReport(
        pagesScanned: batchIdx == 0 ? dirPage : batchIdx,
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

  static Uri _vaultUri(String baseUrl, String relativePath) {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (relativePath.isEmpty) {
      return Uri.parse('$base/vault/');
    }
    final encoded = relativePath
        .split('/')
        .map((seg) => seg.isEmpty ? '' : Uri.encodeComponent(seg))
        .join('/');
    return Uri.parse('$base/vault/$encoded');
  }

  static String _titleFromPath(String path) {
    final last = path.split('/').last;
    return last.toLowerCase().endsWith('.md')
        ? last.substring(0, last.length - 3)
        : last;
  }
}
