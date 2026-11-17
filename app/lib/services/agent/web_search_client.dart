/// 联网搜索与网页正文提取（跑在后台 Worker Isolate，免 Key 双路直连 + 可选自定义 API）。
///
/// 策略：
/// 1. 若用户配了 `customSearchApiUrl`（仅允许 https），优先向其 POST `{query, limit}`；
/// 2. 否则依次走内置免 Key HTTPS 搜索：`cn.bing.com` → `html.duckduckgo.com` 兜底；
/// 3. `fetchPage` 严格校验 https 公网地址（拒绝 localhost / 内网 IP），去标签提纯正文。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'snippet': snippet,
  };
}

class WebSearchClient {
  WebSearchClient({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _timeout = timeout ?? const Duration(seconds: 10);

  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;

  static const _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  Future<List<WebSearchResult>> search(
    String query, {
    int limit = 5,
    String customApiUrl = '',
    String customApiKey = '',
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return const [];
    final capped = limit.clamp(1, 10);

    final custom = customApiUrl.trim();
    if (custom.isNotEmpty) {
      if (!isAllowedPublicHttps(custom)) {
        throw ArgumentError('自定义搜索地址必须为公网 https:// 地址');
      }
      return _searchCustomApi(
        cleanQuery,
        limit: capped,
        url: custom,
        apiKey: customApiKey.trim(),
      );
    }

    final errors = <String>[];
    try {
      final bing = await _searchBing(cleanQuery, limit: capped);
      if (bing.isNotEmpty) return bing;
    } on Object catch (e) {
      errors.add('Bing: $e');
    }

    try {
      final ddg = await _searchDuckDuckGo(cleanQuery, limit: capped);
      if (ddg.isNotEmpty) return ddg;
    } on Object catch (e) {
      errors.add('DuckDuckGo: $e');
    }

    if (errors.isNotEmpty) {
      throw StateError('联网搜索失败（${errors.join('；')}）');
    }
    return const [];
  }

  Future<String> fetchPage(String rawUrl, {int maxChars = 6000}) async {
    final url = rawUrl.trim();
    if (!isAllowedPublicHttps(url)) {
      throw ArgumentError('出于安全基线，仅支持抓取公网 https:// 网页');
    }
    final res = await _client
        .get(
          Uri.parse(url),
          headers: const {
            'User-Agent': _userAgent,
            'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        )
        .timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('抓取网页失败（HTTP ${res.statusCode}）');
    }
    final raw = utf8.decode(res.bodyBytes, allowMalformed: true);
    final plain = stripHtmlToText(raw);
    if (plain.length <= maxChars) return plain;
    return '${plain.substring(0, maxChars)}\n...(已截断，共 ${plain.length} 字符)';
  }

  Future<List<WebSearchResult>> _searchCustomApi(
    String query, {
    required int limit,
    required String url,
    required String apiKey,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final res = await _client
        .post(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode({
            'query': query,
            'limit': limit,
            'max_results': limit,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('自定义搜索返回 HTTP ${res.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = switch (decoded) {
      {'results': final List items} => items,
      {'data': final List items} => items,
      {'items': final List items} => items,
      final List items => items,
      _ => const [],
    };
    final out = <WebSearchResult>[];
    for (final item in list.take(limit)) {
      if (item is! Map) continue;
      final title = '${item['title'] ?? item['name'] ?? ''}'.trim();
      final link = '${item['url'] ?? item['link'] ?? ''}'.trim();
      final snippet =
          '${item['snippet'] ?? item['content'] ?? item['description'] ?? ''}'
              .trim();
      if (title.isEmpty && snippet.isEmpty) continue;
      out.add(WebSearchResult(title: title, url: link, snippet: snippet));
    }
    return out;
  }

  Future<List<WebSearchResult>> _searchBing(
    String query, {
    required int limit,
  }) async {
    final uri = Uri.https('cn.bing.com', '/search', {
      'q': query,
      'count': '$limit',
    });
    final res = await _client
        .get(
          uri,
          headers: const {
            'User-Agent': _userAgent,
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'zh-CN,zh;q=0.9',
          },
        )
        .timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
    final html = utf8.decode(res.bodyBytes, allowMalformed: true);
    return parseBingHtml(html, limit: limit);
  }

  Future<List<WebSearchResult>> _searchDuckDuckGo(
    String query, {
    required int limit,
  }) async {
    final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': query});
    final res = await _client
        .get(
          uri,
          headers: const {
            'User-Agent': _userAgent,
            'Accept': 'text/html,application/xhtml+xml',
          },
        )
        .timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
    final html = utf8.decode(res.bodyBytes, allowMalformed: true);
    return parseDuckDuckGoHtml(html, limit: limit);
  }

  static List<WebSearchResult> parseBingHtml(String html, {int limit = 5}) {
    final blockRe = RegExp(
      r'<li[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>([\s\S]*?)</li>',
      caseSensitive: false,
    );
    final linkRe = RegExp(
      r'<h2[^>]*>[\s\S]*?<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    final snippetRe = RegExp(
      r'<div[^>]*class="[^"]*\bb_caption\b[^"]*"[^>]*>([\s\S]*?)</div>|<p[^>]*>([\s\S]*?)</p>',
      caseSensitive: false,
    );
    final out = <WebSearchResult>[];
    for (final m in blockRe.allMatches(html)) {
      if (out.length >= limit) break;
      final block = m.group(1) ?? '';
      final lm = linkRe.firstMatch(block);
      if (lm == null) continue;
      final url = decodeEntities(lm.group(1) ?? '').trim();
      final title = stripHtmlToText(lm.group(2) ?? '').trim();
      var snippet = '';
      for (final sm in snippetRe.allMatches(block)) {
        final cand = stripHtmlToText(sm.group(1) ?? sm.group(2) ?? '').trim();
        if (cand.isNotEmpty) {
          snippet = cand;
          break;
        }
      }
      if (title.isEmpty && snippet.isEmpty) continue;
      out.add(WebSearchResult(title: title, url: url, snippet: snippet));
    }
    return out;
  }

  static List<WebSearchResult> parseDuckDuckGoHtml(
    String html, {
    int limit = 5,
  }) {
    final linkRe = RegExp(
      r'<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    final snipRe = RegExp(
      r'class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</(?:a|div|span)>',
      caseSensitive: false,
    );
    final links = linkRe.allMatches(html).toList();
    final snips = snipRe.allMatches(html).toList();
    final out = <WebSearchResult>[];
    for (var i = 0; i < links.length && out.length < limit; i++) {
      final rawHref = decodeEntities(links[i].group(1) ?? '').trim();
      final resolvedUrl = _unwrapDuckDuckGoUrl(rawHref);
      final title = stripHtmlToText(links[i].group(2) ?? '').trim();
      final snippet = i < snips.length
          ? stripHtmlToText(snips[i].group(1) ?? '').trim()
          : '';
      if (title.isEmpty && snippet.isEmpty) continue;
      out.add(
        WebSearchResult(title: title, url: resolvedUrl, snippet: snippet),
      );
    }
    return out;
  }

  static String _unwrapDuckDuckGoUrl(String href) {
    final normalized = href.startsWith('//') ? 'https:$href' : href;
    final uri = Uri.tryParse(normalized);
    final uddg = uri?.queryParameters['uddg'];
    if (uddg != null && uddg.isNotEmpty) return uddg;
    return normalized;
  }

  static bool isAllowedPublicHttps(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.isScheme('https')) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'localhost' || host.endsWith('.local')) return false;
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(host);
    if (ipv4 != null) {
      final a = int.tryParse(ipv4.group(1)!) ?? 0;
      final b = int.tryParse(ipv4.group(2)!) ?? 0;
      if (a == 10 || a == 127 || a == 0) return false;
      if (a == 169 && b == 254) return false;
      if (a == 172 && b >= 16 && b <= 31) return false;
      if (a == 192 && b == 168) return false;
    }
    return true;
  }

  static String stripHtmlToText(String html) {
    var s = html;
    s = s.replaceAll(
      RegExp(r'<(script|style|noscript|svg)[^>]*>[\s\S]*?</\1>',
          caseSensitive: false),
      ' ',
    );
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(
      RegExp(r'</(p|div|li|h[1-6]|tr|section|article)>', caseSensitive: false),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = decodeEntities(s);
    s = s.replaceAll(RegExp(r'[ \t\r]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n+'), '\n');
    return s.trim();
  }

  static String decodeEntities(String input) => input
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');

  void close() {
    if (_ownsClient) _client.close();
  }
}
