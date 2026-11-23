/// 得到大脑（Get 笔记）开放平台 OpenAPI 客户端。
///
/// 文档基址：`https://www.biji.com/openapi`
/// 接口域名：`https://openapi.biji.com`
/// 鉴权请求头：`Authorization: gk_live_...`（无 `Bearer ` 前缀）+ `X-Client-ID: cli_...`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class GetNoteApiException implements Exception {
  const GetNoteApiException(this.message, {this.statusCode, this.apiCode});

  final String message;
  final int? statusCode;
  final int? apiCode;

  @override
  String toString() => message;
}

class GetNoteTurn {
  const GetNoteTurn({
    required this.speaker,
    required this.text,
    this.startMs = 0,
    this.endMs = 0,
  });

  final String speaker;
  final String text;
  final int startMs;
  final int endMs;
}

class GetNoteSummary {
  const GetNoteSummary({
    required this.noteId,
    required this.title,
    required this.noteType,
    required this.content,
    required this.refContent,
    required this.createdAt,
    this.updatedAt,
    this.source = '',
    this.tags = const [],
    this.hasAudio = false,
  });

  final String noteId;
  final String title;
  final String noteType;
  final String content;
  final String refContent;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String source;
  final List<String> tags;
  final bool hasAudio;

  static const Set<String> _audioMeetingTypes = {
    'recorder_audio',
    'meeting',
    'local_audio',
    'audio',
    'voice',
    'recording',
    'ai_audio',
    'class_audio',
  };

  bool get isAudioOrMeeting {
    if (hasAudio) return true;
    final t = noteType.trim().toLowerCase();
    if (_audioMeetingTypes.contains(t)) return true;
    return t.contains('audio') ||
        t.contains('meeting') ||
        t.contains('record') ||
        t.contains('voice');
  }
}

class GetNoteDetail extends GetNoteSummary {
  const GetNoteDetail({
    required super.noteId,
    required super.title,
    required super.noteType,
    required super.content,
    required super.refContent,
    required super.createdAt,
    super.updatedAt,
    super.source,
    super.tags,
    super.hasAudio,
    this.summary = '',
    this.audioDurationSec = 0,
    this.audioPlayUrl,
    this.rawTranscript = '',
    this.turns = const [],
  });

  final String summary;
  final double audioDurationSec;
  final String? audioPlayUrl;
  final String rawTranscript;
  final List<GetNoteTurn> turns;
}

class GetNoteListPage {
  const GetNoteListPage({
    required this.notes,
    required this.hasMore,
    this.nextCursor,
    this.total,
  });

  final List<GetNoteSummary> notes;
  final bool hasMore;
  final String? nextCursor;
  final int? total;
}

class GetNoteTestResult {
  const GetNoteTestResult({required this.noteCountHint, this.sampleTitle});

  final int noteCountHint;
  final String? sampleTitle;
}

class GetNoteClient {
  GetNoteClient({
    this.baseUrl = defaultBaseUrl,
    http.Client Function()? clientFactory,
    http.Client? httpClient,
    this.requestDelay = const Duration(milliseconds: 520),
    this.timeout = const Duration(seconds: 15),
    this.maxRetries = 2,
  }) : _clientFactory = clientFactory,
       _sharedClient = httpClient;

  static const String defaultBaseUrl = 'https://openapi.biji.com';

  final String baseUrl;
  final http.Client Function()? _clientFactory;
  final http.Client? _sharedClient;
  final Duration requestDelay;
  final Duration timeout;
  final int maxRetries;

  DateTime? _lastRequestAt;

  /// 标准化 API Key：去掉首尾空白与误粘贴的 `Bearer ` 前缀。
  static String normalizeApiKey(String raw) {
    var v = raw.trim();
    if (v.toLowerCase().startsWith('bearer ')) {
      v = v.substring(7).trim();
    }
    return v;
  }

  Uri _buildUri(String path, [Map<String, String>? query]) {
    final trimmedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$trimmedBase$normalizedPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Future<void> _throttle() async {
    if (requestDelay <= Duration.zero) return;
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      final wait = requestDelay - elapsed;
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    required String clientId,
    required String apiKey,
    Map<String, String>? query,
  }) async {
    final cid = clientId.trim();
    final key = normalizeApiKey(apiKey);
    if (cid.isEmpty || key.isEmpty) {
      throw const GetNoteApiException('请先填写 Client ID 与 API Key');
    }

    final uri = _buildUri(path, query);
    final owned = _sharedClient == null;
    final client = _sharedClient ?? (_clientFactory?.call() ?? http.Client());
    try {
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        await _throttle();
        final resp = await client
            .get(
              uri,
              headers: <String, String>{
                'Authorization': key,
                'X-Client-ID': cid,
                'Accept': 'application/json',
              },
            )
            .timeout(timeout);

        final rawBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final decoded = _tryDecodeMap(rawBody);

        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw GetNoteApiException(
            '鉴权失败，请检查 Client ID 与 API Key 是否正确或已开通 OpenAPI 权限',
            statusCode: resp.statusCode,
          );
        }

        final retryable =
            resp.statusCode == 429 ||
            resp.statusCode == 502 ||
            resp.statusCode == 503 ||
            resp.statusCode == 504;
        if (retryable && attempt < maxRetries) {
          await _backoffWait(attempt, retryAfter: resp.headers['retry-after']);
          continue;
        }

        if (resp.statusCode == 429) {
          throw GetNoteApiException(
            '请求过于频繁，触发得到大脑 OpenAPI 限流，请稍后重试',
            statusCode: resp.statusCode,
          );
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          final serverMsg = _extractErrorMessage(decoded);
          throw GetNoteApiException(
            serverMsg != null
                ? '请求失败（HTTP ${resp.statusCode}）：$serverMsg'
                : '请求失败（HTTP ${resp.statusCode}）',
            statusCode: resp.statusCode,
          );
        }

        if (decoded == null) {
          throw const GetNoteApiException('得到大脑服务返回了无法解析的数据');
        }
        return _unwrapEnvelope(decoded, statusCode: resp.statusCode);
      }
      throw const GetNoteApiException('请求得到大脑 OpenAPI 失败，请稍后重试');
    } on GetNoteApiException {
      rethrow;
    } on TimeoutException {
      throw const GetNoteApiException('连接得到大脑 OpenAPI 超时，请检查网络后重试');
    } on SocketException catch (e) {
      throw GetNoteApiException('网络连接失败：${e.message}');
    } on http.ClientException catch (e) {
      throw GetNoteApiException('网络请求失败：${e.message}');
    } finally {
      if (owned) client.close();
    }
  }

  Future<void> _backoffWait(int attempt, {String? retryAfter}) async {
    if (requestDelay <= Duration.zero) return;
    final parsedSec = int.tryParse((retryAfter ?? '').trim());
    final wait = parsedSec != null && parsedSec > 0
        ? Duration(seconds: parsedSec.clamp(1, 10))
        : Duration(milliseconds: 1000 * (1 << attempt));
    await Future<void>.delayed(wait);
  }

  static Map<String, dynamic>? _tryDecodeMap(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } on Object {
      return null;
    }
    return null;
  }

  static String? _extractErrorMessage(Map<String, dynamic>? map) {
    if (map == null) return null;
    final h = map['h'];
    if (h is Map) {
      final err = '${h['e'] ?? h['msg'] ?? h['message'] ?? ''}'.trim();
      if (err.isNotEmpty) return err;
    }
    for (final k in const ['message', 'msg', 'error', 'detail']) {
      final s = '${map[k] ?? ''}'.trim();
      if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
    }
    return null;
  }

  static Map<String, dynamic> _unwrapEnvelope(
    Map<String, dynamic> body, {
    required int statusCode,
  }) {
    if (body.containsKey('h') && body['h'] is Map) {
      final h = Map<String, dynamic>.from(body['h'] as Map);
      final code = (h['c'] as num?)?.toInt() ?? 0;
      if (code != 0) {
        final msg = _extractErrorMessage(body) ?? '接口返回业务错误（$code）';
        throw GetNoteApiException(msg, statusCode: statusCode, apiCode: code);
      }
      final c = body['c'];
      if (c is Map<String, dynamic>) return c;
      if (c is Map) return Map<String, dynamic>.from(c);
      return const {};
    }

    if (body.containsKey('code')) {
      final rawCode = body['code'];
      final intCode = rawCode is num
          ? rawCode.toInt()
          : int.tryParse('$rawCode');
      if (intCode != null && intCode != 0) {
        final msg = _extractErrorMessage(body) ?? '接口返回业务错误（$intCode）';
        throw GetNoteApiException(
          msg,
          statusCode: statusCode,
          apiCode: intCode,
        );
      }
    }

    final data = body['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return body;
  }

  /// 拉取单页笔记列表。
  Future<GetNoteListPage> listNotes({
    required String clientId,
    required String apiKey,
    int pageSize = 50,
    String? cursor,
  }) async {
    final query = <String, String>{
      'page_size': pageSize.clamp(1, 100).toString(),
      if (cursor != null && cursor.trim().isNotEmpty) 'cursor': cursor.trim(),
    };
    final data = await _getJson(
      '/open/api/v1/resource/note/list',
      clientId: clientId,
      apiKey: apiKey,
      query: query,
    );

    final rawNotes =
        data['notes'] ?? data['list'] ?? data['items'] ?? const <dynamic>[];
    final notes = <GetNoteSummary>[
      if (rawNotes is List)
        for (final item in rawNotes)
          if (item is Map)
            _parseSummary(Map<String, dynamic>.from(item)),
    ];

    final pagination = data['pagination'] is Map
        ? Map<String, dynamic>.from(data['pagination'] as Map)
        : const <String, dynamic>{};

    final rawHasMore = data['has_more'] ?? pagination['has_more'];
    final explicitHasMore = rawHasMore == null
        ? null
        : (rawHasMore == true || rawHasMore == 1 || rawHasMore == 'true');

    final nextCursor = _extractNextCursor(
      data,
      pagination,
      hasMore: explicitHasMore == true,
    );
    final hasMore = explicitHasMore ?? (nextCursor != null);

    final total =
        (data['total'] as num?)?.toInt() ??
        (pagination['total'] as num?)?.toInt();

    return GetNoteListPage(
      notes: notes,
      hasMore: hasMore,
      nextCursor: hasMore ? nextCursor : null,
      total: total,
    );
  }

  /// 按契约优先级提取下一页游标：
  /// 新模式 `pagination.next_cursor` / `pagination.cursor` → 兼容字段 `data.cursor` → 旧 int64 `data.next_cursor`。
  static String? _extractNextCursor(
    Map<String, dynamic> data,
    Map<String, dynamic> pagination, {
    required bool hasMore,
  }) {
    final candidates = <Object?>[
      pagination['next_cursor'],
      pagination['cursor'],
      data['cursor'],
      data['next_cursor'],
    ];
    String? fallbackZero;
    for (final raw in candidates) {
      if (raw == null) continue;
      final s = '$raw'.trim();
      if (s.isEmpty || s.toLowerCase() == 'null') continue;
      if (s == '0') {
        fallbackZero ??= s;
        continue;
      }
      return s;
    }
    if (hasMore && fallbackZero != null) return fallbackZero;
    return null;
  }

  /// 获取单条笔记详情。
  Future<GetNoteDetail> getNoteDetail({
    required String clientId,
    required String apiKey,
    required String noteId,
  }) async {
    final id = noteId.trim();
    if (id.isEmpty) {
      throw const GetNoteApiException('笔记 ID 不能为空');
    }
    final data = await _getJson(
      '/open/api/v1/resource/note/detail',
      clientId: clientId,
      apiKey: apiKey,
      query: <String, String>{'id': id},
    );
    final root = data['note'] is Map
        ? Map<String, dynamic>.from(data['note'] as Map)
        : data;
    return _parseDetail(root, fallbackId: id);
  }

  /// 测试凭据与连通性。
  Future<GetNoteTestResult> testConnection({
    required String clientId,
    required String apiKey,
  }) async {
    final page = await listNotes(
      clientId: clientId,
      apiKey: apiKey,
      pageSize: 1,
    );
    return GetNoteTestResult(
      noteCountHint: page.total ?? page.notes.length,
      sampleTitle: page.notes.isNotEmpty ? page.notes.first.title : null,
    );
  }

  static GetNoteSummary _parseSummary(Map<String, dynamic> raw) {
    final noteId = _extractNoteId(raw);
    final noteType = '${raw['note_type'] ?? raw['noteType'] ?? ''}'
        .trim()
        .toLowerCase();
    final audioMap = raw['audio'] is Map
        ? Map<String, dynamic>.from(raw['audio'] as Map)
        : null;
    final hasAudio =
        audioMap != null ||
        raw['has_audio'] == true ||
        '${raw['audio_url'] ?? ''}'.trim().isNotEmpty ||
        ((raw['duration'] as num?)?.toDouble() ?? 0) > 0;

    return GetNoteSummary(
      noteId: noteId,
      title: '${raw['title'] ?? ''}'.trim(),
      noteType: noteType,
      content: '${raw['content'] ?? ''}'.trim(),
      refContent: '${raw['ref_content'] ?? raw['refContent'] ?? ''}'.trim(),
      createdAt: parseTimestamp(raw['created_at'] ?? raw['createdAt']),
      updatedAt: _tryParseTimestamp(raw['updated_at'] ?? raw['updatedAt']),
      source: '${raw['source'] ?? ''}'.trim(),
      tags: _parseTags(raw['tags']),
      hasAudio: hasAudio,
    );
  }

  static GetNoteDetail _parseDetail(
    Map<String, dynamic> raw, {
    required String fallbackId,
  }) {
    final base = _parseSummary(raw);
    final noteId = base.noteId.isNotEmpty ? base.noteId : fallbackId;
    final audioMap = raw['audio'] is Map
        ? Map<String, dynamic>.from(raw['audio'] as Map)
        : const <String, dynamic>{};

    final audioDuration =
        (audioMap['duration'] as num?)?.toDouble() ??
        (raw['duration'] as num?)?.toDouble() ??
        0;
    final rawPlayUrl =
        '${audioMap['play_url'] ?? audioMap['url'] ?? raw['audio_url'] ?? ''}'
            .trim();
    final audioPlayUrl = rawPlayUrl.isNotEmpty ? rawPlayUrl : null;

    final rawTranscript = _firstNonEmpty([
      audioMap['original'],
      raw['original_content'],
      raw['original'],
      raw['transcript'],
      audioMap['transcript'],
    ]);
    final summary = _firstNonEmpty([raw['summary'], raw['ai_summary']]);

    final turns = <GetNoteTurn>[];
    final rawSegments =
        audioMap['segments'] ??
        audioMap['utterances'] ??
        raw['segments'] ??
        raw['utterances'];
    if (rawSegments is List) {
      for (final item in rawSegments) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final text = _firstNonEmpty([m['text'], m['content']]);
        if (text.isEmpty) continue;
        final speaker = _firstNonEmpty([
          m['speaker'],
          m['speaker_name'],
          m['speaker_label'],
        ]);
        turns.add(
          GetNoteTurn(
            speaker: speaker.isEmpty ? '未区分' : speaker,
            text: text,
            startMs: _parseTurnOffsetMs(
              msValue: m['start_ms'],
              secValue: m['start'] ?? m['start_time'],
            ),
            endMs: _parseTurnOffsetMs(
              msValue: m['end_ms'],
              secValue: m['end'] ?? m['end_time'],
            ),
          ),
        );
      }
    }

    return GetNoteDetail(
      noteId: noteId,
      title: base.title,
      noteType: base.noteType,
      content: base.content,
      refContent: base.refContent,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
      source: base.source,
      tags: base.tags,
      hasAudio: base.hasAudio || audioDuration > 0 || audioPlayUrl != null,
      summary: summary,
      audioDurationSec: audioDuration > 0 ? audioDuration : 0,
      audioPlayUrl: audioPlayUrl,
      rawTranscript: rawTranscript,
      turns: turns,
    );
  }

  static String _extractNoteId(Map<String, dynamic> raw) {
    final s = '${raw['note_id'] ?? raw['noteId'] ?? ''}'.trim();
    if (s.isNotEmpty && s != 'null') return s;
    final id = raw['id'];
    if (id != null) {
      final str = '$id'.trim();
      if (str.isNotEmpty && str != 'null') return str;
    }
    return '';
  }

  static List<String> _parseTags(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      String? name;
      if (item is String) {
        name = item.trim();
      } else if (item is Map) {
        name = '${item['name'] ?? item['tag'] ?? item['title'] ?? ''}'.trim();
      }
      if (name != null && name.isNotEmpty && !out.contains(name)) {
        out.add(name);
      }
    }
    return out;
  }

  static String _firstNonEmpty(List<Object?> candidates) {
    for (final c in candidates) {
      if (c == null) continue;
      final s = '$c'.trim();
      if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
    }
    return '';
  }

  static int _parseTurnOffsetMs({Object? msValue, Object? secValue}) {
    final msNum = _asDouble(msValue);
    if (msNum != null) {
      return msNum <= 0 ? 0 : msNum.round().clamp(0, 1 << 30);
    }
    final secNum = _asDouble(secValue);
    if (secNum != null) {
      return secNum <= 0 ? 0 : (secNum * 1000).round().clamp(0, 1 << 30);
    }
    return 0;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static DateTime parseTimestamp(Object? value) =>
      _tryParseTimestamp(value) ?? DateTime.now();

  static DateTime? _tryParseTimestamp(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final n = value.toInt();
      if (n <= 0) return null;
      // < 1e11 视作 Unix 秒，否则视作毫秒
      final ms = n < 100000000000 ? n * 1000 : n;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final s = '$value'.trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    final numVal = int.tryParse(s);
    if (numVal != null) {
      return _tryParseTimestamp(numVal);
    }
    final normalized =
        s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s;
    return DateTime.tryParse(normalized)?.toLocal();
  }
}
