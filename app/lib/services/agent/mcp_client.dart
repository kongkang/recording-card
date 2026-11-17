/// 轻量 HTTP JSON-RPC 2.0 MCP 客户端（跑在后台 Worker Isolate）。
///
/// 针对用户在设置或对话中添加的自定义 `https://` MCP 端点，提供 `tools/list` 与
/// `tools/call` 能力，请求失败优雅降级为文本错误说明，不中断 Agent 主循环。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'web_search_client.dart';

class AgentMcpToolSpec {
  const AgentMcpToolSpec({
    required this.endpointId,
    required this.endpointName,
    required this.endpointUrl,
    required this.name,
    required this.description,
    this.inputSchema = const {},
  });

  final String endpointId;
  final String endpointName;
  final String endpointUrl;
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

class AgentMcpClient {
  AgentMcpClient({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _timeout = timeout ?? const Duration(seconds: 8);

  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;
  int _rpcId = 1;

  Future<List<AgentMcpToolSpec>> listTools({
    required String endpointId,
    required String endpointName,
    required String endpointUrl,
  }) async {
    if (!WebSearchClient.isAllowedPublicHttps(endpointUrl)) return const [];
    final res = await _postRpc(endpointUrl, 'tools/list', const {});
    final result = res['result'];
    if (result is! Map) return const [];
    final tools = result['tools'];
    if (tools is! List) return const [];
    final out = <AgentMcpToolSpec>[];
    for (final t in tools) {
      if (t is! Map) continue;
      final name = '${t['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final schema = t['inputSchema'];
      out.add(
        AgentMcpToolSpec(
          endpointId: endpointId,
          endpointName: endpointName,
          endpointUrl: endpointUrl,
          name: name,
          description: '${t['description'] ?? ''}'.trim(),
          inputSchema: schema is Map
              ? Map<String, dynamic>.from(schema)
              : const {},
        ),
      );
    }
    return out;
  }

  Future<String> callTool({
    required String endpointUrl,
    required String toolName,
    Map<String, dynamic> arguments = const {},
  }) async {
    if (!WebSearchClient.isAllowedPublicHttps(endpointUrl)) {
      return 'MCP 地址仅支持公网 https:// 端点：$endpointUrl';
    }
    final res = await _postRpc(endpointUrl, 'tools/call', {
      'name': toolName,
      'arguments': arguments,
    });
    if (res['error'] != null) {
      return 'MCP 工具调用失败：${jsonEncode(res['error'])}';
    }
    final result = res['result'];
    if (result is String) return result;
    if (result is Map) {
      final content = result['content'];
      if (content is List) {
        final texts = <String>[];
        for (final item in content) {
          if (item is Map && item['text'] != null) {
            texts.add('${item['text']}');
          }
        }
        if (texts.isNotEmpty) return texts.join('\n');
      }
      return jsonEncode(result);
    }
    return '$result';
  }

  Future<Map<String, dynamic>> _postRpc(
    String endpointUrl,
    String method,
    Map<String, dynamic> params,
  ) async {
    final res = await _client
        .post(
          Uri.parse(endpointUrl),
          headers: const {
            'Content-Type': 'application/json; charset=utf-8',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': _rpcId++,
            'method': method,
            'params': params,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('MCP 响应不是 JSON 对象');
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
