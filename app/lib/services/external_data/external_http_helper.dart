/// 第三方数据接入通用 HTTP、重试、MCP JSON-RPC 2.0、HTML/ENML 清洗与时间解析辅助。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'external_connector.dart';

class ExternalHttpHelper {
  const ExternalHttpHelper._();

  static String normalizeToken(String raw) {
    var v = raw.trim();
    final lower = v.toLowerCase();
    if (lower.startsWith('bearer ')) {
      v = v.substring(7).trim();
    } else if (lower.startsWith('token ')) {
      v = v.substring(6).trim();
    }
    return v;
  }

  static String normalizeBaseUrl(String raw, String fallback) {
    final trimmed = raw.trim();
    final chosen = trimmed.isEmpty ? fallback : trimmed;
    return chosen.replaceFirst(RegExp(r'/+$'), '');
  }

  static Uri buildUri(
    String baseUrl,
    String path, [
    Map<String, String>? query,
  ]) {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final normPath = path.isEmpty
        ? ''
        : (path.startsWith('/') ? path : '/$path');
    final uri = Uri.parse('$base$normPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  /// 仅当显式允许且目标为本地/局域网地址时，允许自签名 HTTPS 证书（例如 Obsidian Local REST API）。
  static bool isPrivateOrLoopbackHost(String host) {
    final h = host.trim().toLowerCase();
    if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
    if (ipv4 == null) return h.endsWith('.local');
    final a = int.tryParse(ipv4.group(1)!) ?? -1;
    final b = int.tryParse(ipv4.group(2)!) ?? -1;
    if (a == 10 || a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  static http.Client resolveClient({
    http.Client? override,
    bool allowLocalSelfSigned = false,
    String? targetBaseUrl,
  }) {
    if (override != null) return override;
    if (allowLocalSelfSigned && targetBaseUrl != null) {
      final uri = Uri.tryParse(targetBaseUrl.trim());
      if (uri != null &&
          uri.scheme.toLowerCase() == 'https' &&
          isPrivateOrLoopbackHost(uri.host)) {
        final io = HttpClient()
          ..badCertificateCallback = (_, host, _) =>
              isPrivateOrLoopbackHost(host);
        return IOClient(io);
      }
    }
    return http.Client();
  }

  static Future<http.Response> sendWithRetry({
    required Future<http.Response> Function() request,
    Duration requestDelay = const Duration(milliseconds: 220),
    Duration timeout = const Duration(seconds: 20),
    int maxRetries = 2,
    String serviceName = '第三方服务',
  }) async {
    try {
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        if (requestDelay > Duration.zero && attempt > 0) {
          await Future<void>.delayed(requestDelay);
        }
        final resp = await request().timeout(timeout);
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw ExternalConnectorException(
            '$serviceName 鉴权失败，请检查 Token / Cookie 或权限范围',
            statusCode: resp.statusCode,
          );
        }
        final retryable =
            resp.statusCode == 429 ||
            resp.statusCode == 502 ||
            resp.statusCode == 503 ||
            resp.statusCode == 504;
        if (retryable && attempt < maxRetries) {
          if (requestDelay > Duration.zero) {
            final sec = int.tryParse((resp.headers['retry-after'] ?? '').trim());
            final wait = sec != null && sec > 0
                ? Duration(seconds: sec.clamp(1, 10))
                : Duration(milliseconds: 900 * (1 << attempt));
            await Future<void>.delayed(wait);
          }
          continue;
        }
        if (resp.statusCode == 429) {
          throw ExternalConnectorException(
            '$serviceName 接口触发限流（HTTP 429），请稍后重试',
            statusCode: 429,
          );
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
          final decoded = tryDecodeMap(bodyText);
          final serverMsg = extractErrorMessage(decoded);
          throw ExternalConnectorException(
            serverMsg != null
                ? '$serviceName 请求失败（HTTP ${resp.statusCode}）：$serverMsg'
                : '$serviceName 请求失败（HTTP ${resp.statusCode}）',
            statusCode: resp.statusCode,
          );
        }
        return resp;
      }
      throw ExternalConnectorException('$serviceName 请求失败，请稍后重试');
    } on ExternalConnectorException {
      rethrow;
    } on TimeoutException {
      throw ExternalConnectorException('连接 $serviceName 超时，请检查网络后重试');
    } on SocketException catch (e) {
      throw ExternalConnectorException('连接 $serviceName 失败：${e.message}');
    } on http.ClientException catch (e) {
      throw ExternalConnectorException('请求 $serviceName 失败：${e.message}');
    }
  }

  static Map<String, dynamic>? tryDecodeMap(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      return null;
    }
    return null;
  }

  static Object? tryDecodeAny(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } on Object {
      return null;
    }
  }

  static String? extractErrorMessage(Map<String, dynamic>? map) {
    if (map == null) return null;
    for (final k in const [
      'message',
      'msg',
      'error_description',
      'detail',
      'errmsg',
      'error',
    ]) {
      final val = map[k];
      if (val is Map) {
        final nested = extractErrorMessage(Map<String, dynamic>.from(val));
        if (nested != null) return nested;
      }
      final s = '${val ?? ''}'.trim();
      if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
    }
    final errs = map['errors'];
    if (errs is List && errs.isNotEmpty) {
      final first = errs.first;
      if (first is Map) {
        final nested = extractErrorMessage(Map<String, dynamic>.from(first));
        if (nested != null) return nested;
      }
      final s = '$first'.trim();
      if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
    }
    return null;
  }

  static DateTime? tryParseTimestamp(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final n = value.toInt();
      if (n <= 0) return null;
      final ms = n < 100000000000 ? n * 1000 : n;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final s = '$value'.trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    final numVal = num.tryParse(s);
    if (numVal != null) {
      return tryParseTimestamp(numVal);
    }
    final normalized =
        s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s;
    return DateTime.tryParse(normalized)?.toLocal();
  }

  static DateTime parseTimestamp(Object? value) =>
      tryParseTimestamp(value) ?? DateTime.now();

  /// 将 HTML / Evernote ENML 清洗为可读纯文本，保留换行与复选框语义。
  static String stripHtmlOrXml(String raw) {
    if (raw.trim().isEmpty) return '';
    var text = raw;
    text = text.replaceAll(
      RegExp(r'<\?xml[^>]*\?>|<!DOCTYPE[^>]*>', caseSensitive: false),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
      '',
    );
    text = text.replaceAll(
      RegExp(
        r'<en-todo\b[^>]*checked\s*=\s*["\x27]true["\x27][^>]*/?>',
        caseSensitive: false,
      ),
      '[x] ',
    );
    text = text.replaceAll(
      RegExp(r'<en-todo\b[^>]*/?>', caseSensitive: false),
      '[ ] ',
    );
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text = text.replaceAll(
      RegExp(r'<li\b[^>]*>', caseSensitive: false),
      '• ',
    );
    text = text.replaceAll(
      RegExp(
        r'</(p|div|li|h[1-6]|tr|blockquote|section|article|en-note)>',
        caseSensitive: false,
      ),
      '\n',
    );
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.join('\n').trim();
  }

  /// 调用基于 Streamable HTTP (JSON / SSE) 的 MCP JSON-RPC 2.0 服务。
  static Future<Map<String, dynamic>> postMcpJsonRpc({
    required http.Client client,
    required String endpointUrl,
    required String bearerToken,
    required String method,
    required Map<String, dynamic> params,
    int rpcId = 1,
    String? sessionId,
    Duration requestDelay = const Duration(milliseconds: 220),
    String serviceName = 'MCP 服务',
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json, text/event-stream',
      if (bearerToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${normalizeToken(bearerToken)}',
      if (sessionId != null && sessionId.trim().isNotEmpty)
        'Mcp-Session-Id': sessionId.trim(),
    };
    final resp = await sendWithRetry(
      requestDelay: requestDelay,
      serviceName: serviceName,
      request: () => client.post(
        Uri.parse(endpointUrl.trim()),
        headers: headers,
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': rpcId,
          'method': method,
          'params': params,
        }),
      ),
    );
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
    Map<String, dynamic>? payload = tryDecodeMap(raw);
    if (payload == null) {
      // 兼容 Streamable HTTP 返回的 `data: {...}` SSE 帧
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final jsonPart = trimmed.substring(5).trim();
        if (jsonPart.isEmpty || jsonPart == '[DONE]') continue;
        final parsed = tryDecodeMap(jsonPart);
        if (parsed != null &&
            (parsed.containsKey('result') || parsed.containsKey('error'))) {
          payload = parsed;
        }
      }
    }
    if (payload == null) {
      throw ExternalConnectorException('$serviceName 返回了无法解析的 MCP 响应');
    }
    if (payload['error'] != null) {
      final err = payload['error'];
      final msg = err is Map
          ? ('${err['message'] ?? err['code'] ?? err}'.trim())
          : '$err'.trim();
      throw ExternalConnectorException('$serviceName MCP 调用失败：$msg');
    }
    final nextSid =
        resp.headers['mcp-session-id'] ?? resp.headers['Mcp-Session-Id'];
    return {
      'result': payload['result'],
      if (nextSid != null && nextSid.trim().isNotEmpty) 'sessionId': nextSid,
    };
  }
}
