/// 语雀 OpenAPI v2 连接器（`/user` + `/users/{login}/repos` + `/repos/{ns}/docs` Offset 无限翻页）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class YuqueConnector extends ExternalDataConnector {
  YuqueConnector({this.requestDelay = const Duration(milliseconds: 280)});

  static const String defaultBaseUrl = 'https://www.yuque.com/api/v2';

  final Duration requestDelay;

  @override
  String get id => 'yuque';

  @override
  String get name => '语雀';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'OpenAPI v2';

  @override
  String get subtitle => '通过语雀 X-Auth-Token 连续翻页同步个人/空间知识库与文档正文';

  @override
  String get setupGuide =>
      '在语雀「账户设置 -> Token」生成具备读取知识库与文档权限的 Token；企业空间可修改 API 基址。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'token',
      label: 'X-Auth-Token',
      hint: '语雀个人访问 Token',
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
      key: 'repoNamespace',
      label: '指定知识库（选填）',
      hint: '如 username/notes，留空同步全部知识库',
      required: false,
    ),
  ];

  Map<String, String> _headers(String token) => {
    'X-Auth-Token': ExternalHttpHelper.normalizeToken(token),
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = cfg['token'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写语雀 X-Auth-Token');
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
          ExternalHttpHelper.buildUri(baseUrl, '/user'),
          headers: _headers(token),
        ),
      );
      final map = ExternalHttpHelper.tryDecodeMap(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      final data = map?['data'] is Map
          ? Map<String, dynamic>.from(map!['data'] as Map)
          : const <String, dynamic>{};
      final userName = '${data['name'] ?? data['login'] ?? ''}'.trim();
      final booksCount = (data['books_count'] as num?)?.toInt();
      return ExternalTestResult(
        message: userName.isNotEmpty
            ? '连接成功（用户：$userName）'
            : '连接成功，语雀 Token 有效',
        countHint: booksCount,
        sampleTitle: userName.isEmpty ? null : userName,
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
    final token = cfg['token'] ?? '';
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写语雀 X-Auth-Token');
    }
    final baseUrl = ExternalHttpHelper.normalizeBaseUrl(
      cfg['baseUrl'] ?? '',
      defaultBaseUrl,
    );
    final explicitRepo = cfg['repoNamespace'] ?? '';
    final headers = _headers(token);

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final repos = <({String namespace, String name})>[];
      if (explicitRepo.isNotEmpty) {
        repos.add((namespace: explicitRepo, name: explicitRepo));
      } else {
        final userResp = await ExternalHttpHelper.sendWithRetry(
          requestDelay: requestDelay,
          serviceName: name,
          request: () => client.get(
            ExternalHttpHelper.buildUri(baseUrl, '/user'),
            headers: headers,
          ),
        );
        final userBody = ExternalHttpHelper.tryDecodeMap(
          utf8.decode(userResp.bodyBytes, allowMalformed: true),
        );
        final userData = userBody?['data'] is Map
            ? Map<String, dynamic>.from(userBody!['data'] as Map)
            : const <String, dynamic>{};
        final login = '${userData['login'] ?? userData['id'] ?? ''}'.trim();
        if (login.isEmpty) {
          throw const ExternalConnectorException('无法获取语雀当前用户 login');
        }

        const repoLimit = 100;
        var repoOffset = 0;
        while (true) {
          if (isCancelled()) break;
          final resp = await ExternalHttpHelper.sendWithRetry(
            requestDelay: requestDelay,
            serviceName: name,
            request: () => client.get(
              ExternalHttpHelper.buildUri(baseUrl, '/users/$login/repos', {
                'offset': '$repoOffset',
                'limit': '$repoLimit',
              }),
              headers: headers,
            ),
          );
          final body = ExternalHttpHelper.tryDecodeMap(
            utf8.decode(resp.bodyBytes, allowMalformed: true),
          );
          final list = body?['data'] is List
              ? body!['data'] as List
              : const [];
          if (list.isEmpty) break;
          for (final item in list) {
            if (item is! Map) continue;
            final slug = '${item['slug'] ?? ''}'.trim();
            final ns = '${item['namespace'] ?? ''}'.trim();
            final repoKey = ns.isNotEmpty
                ? ns
                : (slug.isNotEmpty ? '$login/$slug' : '${item['id'] ?? ''}');
            final repoName = '${item['name'] ?? repoKey}'.trim();
            if (repoKey.isNotEmpty) {
              repos.add((namespace: repoKey, name: repoName));
            }
          }
          repoOffset += list.length;
          if (list.length < repoLimit) break;
        }
      }

      const docLimit = 100;
      var pageNum = 0;
      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
      var cancelled = false;

      for (final repo in repos) {
        if (isCancelled()) {
          cancelled = true;
          break;
        }
        var offset = 0;
        while (true) {
          if (isCancelled()) {
            cancelled = true;
            break;
          }
          pageNum += 1;
          onProgress(
            ExternalSyncProgress(
              page: pageNum,
              fetched: fetched,
              added: fetched,
              message: '正在拉取语雀「${repo.name}」文档列表（offset=$offset）…',
            ),
          );

          final resp = await ExternalHttpHelper.sendWithRetry(
            requestDelay: requestDelay,
            serviceName: name,
            request: () => client.get(
              ExternalHttpHelper.buildUri(
                baseUrl,
                '/repos/${repo.namespace}/docs',
                {'offset': '$offset', 'limit': '$docLimit'},
              ),
              headers: headers,
            ),
          );
          final body = ExternalHttpHelper.tryDecodeMap(
            utf8.decode(resp.bodyBytes, allowMalformed: true),
          );
          final docs = body?['data'] is List
              ? body!['data'] as List
              : const [];
          if (docs.isEmpty) break;

          final batch = <ExternalRecordDraft>[];
          final nextFps = <String, String>{};
          for (final rawDoc in docs) {
            if (isCancelled()) {
              cancelled = true;
              break;
            }
            if (rawDoc is! Map) continue;
            final doc = Map<String, dynamic>.from(rawDoc);
            final rawId = '${doc['id'] ?? doc['slug'] ?? ''}'.trim();
            final slug = '${doc['slug'] ?? doc['id'] ?? ''}'.trim();
            if (rawId.isEmpty || slug.isEmpty) continue;
            final externalId = '${repo.namespace}_$rawId';
            final updatedRaw = '${doc['updated_at'] ?? ''}'.trim();
            final devName = deviceNameFor(externalId);
            final alreadyExists = existingDeviceNames.contains(devName);
            final prevFp = itemFingerprints[externalId];
            if (alreadyExists && (prevFp == null || prevFp == updatedRaw)) {
              skippedExisting += 1;
              continue;
            }

            if (alreadyExists) updated += 1;
            final detailResp = await ExternalHttpHelper.sendWithRetry(
              requestDelay: requestDelay,
              serviceName: name,
              request: () => client.get(
                ExternalHttpHelper.buildUri(
                  baseUrl,
                  '/repos/${repo.namespace}/docs/$slug',
                  {'raw': '1'},
                ),
                headers: headers,
              ),
            );
            final detailMap = ExternalHttpHelper.tryDecodeMap(
              utf8.decode(detailResp.bodyBytes, allowMalformed: true),
            );
            final detail = detailMap?['data'] is Map
                ? Map<String, dynamic>.from(detailMap!['data'] as Map)
                : doc;
            final title = '${detail['title'] ?? doc['title'] ?? slug}'.trim();
            final mdBody = '${detail['body'] ?? ''}'.trim();
            final htmlBody = '${detail['body_html'] ?? ''}'.trim();
            final content = mdBody.isNotEmpty
                ? mdBody
                : ExternalHttpHelper.stripHtmlOrXml(htmlBody);
            final desc = '${detail['description'] ?? doc['description'] ?? ''}'
                .trim();

            batch.add(
              ExternalRecordDraft(
                externalId: externalId,
                title: title,
                content: content.isNotEmpty ? content : desc,
                summary: desc,
                createdAt: ExternalHttpHelper.parseTimestamp(
                  detail['created_at'] ?? doc['created_at'] ?? updatedRaw,
                ),
                updatedAt: ExternalHttpHelper.tryParseTimestamp(updatedRaw),
                tags: [if (repo.name.isNotEmpty) repo.name],
                fingerprint: updatedRaw,
              ),
            );
            nextFps[externalId] = updatedRaw;
            fetched += 1;
            onProgress(
              ExternalSyncProgress(
                page: pageNum,
                fetched: fetched,
                added: fetched,
                message: '正在同步语雀「${repo.name}」（已处理 $fetched 篇）…',
              ),
            );
          }

          if (batch.isNotEmpty) {
            await onBatch(batch, nextFps);
          }
          if (cancelled) break;

          offset += docs.length;
          final metaTotal = (body?['meta'] is Map
              ? ((body!['meta'] as Map)['total'] as num?)?.toInt()
              : null);
          if (docs.length < docLimit ||
              (metaTotal != null && offset >= metaTotal)) {
            break;
          }
        }
        if (cancelled) break;
      }

      return ExternalConnectorSyncReport(
        pagesScanned: pageNum,
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
}
