library;

/// 端点配置解析（纯函数，便于单测）。模式借鉴 reai_mobile_app endpoint_resolver。
///
/// `String.fromEnvironment` 是编译期常量、无法在测试进程内切换，故把优先级
/// 逻辑抽成不依赖编译期常量的纯函数：dart-define（有效）> 编译默认。
///
/// 可信 host 白名单当前为空：后端域名未定（docs/SDK-CAPABILITY.md 数据边界），
/// 域名落地后在 [kTrustedEndpointHosts] 登记，防 OAuth token 被导向非自有主机。
const List<String> kTrustedEndpointHosts = [
  // TODO(oauth-backend)：后端域名确定后登记
];

bool _isTrustedHost(String host) {
  final h = host.toLowerCase();
  for (final root in kTrustedEndpointHosts) {
    if (h == root || h.endsWith('.$root')) return true;
  }
  return false;
}

/// 宽松校验：合法 http/https URL（开发联调允许 http 内网）。
bool isValidHttpUrl(String? value) {
  if (value == null) return false;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.host.isNotEmpty;
}

/// 严格校验：https + 可信 host + 无 query/fragment，去除尾部斜杠。
/// OAuth 业务端点用；不通过返回 null（消费侧回落本地会话模式）。
String? sanitizeTrustedEndpoint(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (kTrustedEndpointHosts.isNotEmpty && !_isTrustedHost(uri.host)) return null;
  if (uri.hasQuery || uri.hasFragment) return null;
  return trimmed.replaceFirst(RegExp(r'/+$'), '');
}

/// 按优先级解析端点：dart-define（有效）> 编译默认；均为空返回 null（本地会话）。
String? resolveEndpoint({
  required bool hasDartDefine,
  required String dartDefineValue,
  String? compileDefault,
}) {
  if (hasDartDefine && isValidHttpUrl(dartDefineValue)) {
    return dartDefineValue.trim();
  }
  if (compileDefault != null && compileDefault.isNotEmpty) {
    return compileDefault;
  }
  return null;
}
