library;

/// Approved reference service host. Exact match only: subdomains are NOT trusted.
const List<String> kTrustedEndpointHosts = ['block2-api.wainao.chat'];

bool isValidHttpUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// Never accepts an empty allowlist, credentials, queries, non-default ports,
/// fragments or suffix-matching lookalike hosts. Callers must fail, not fall back.
String? sanitizeTrustedEndpoint(
  String? value, {
  Iterable<String> trustedHosts = kTrustedEndpointHosts,
}) {
  final trimmed = value?.trim() ?? '';
  final uri = Uri.tryParse(trimmed);
  final hosts = trustedHosts.map((h) => h.toLowerCase()).toSet();
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      hosts.isEmpty ||
      !hosts.contains(uri.host.toLowerCase()) ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return trimmed.replaceFirst(RegExp(r'/+$'), '');
}

/// A present but invalid override must not silently choose another endpoint.
String? resolveEndpoint({
  required bool hasDartDefine,
  required String dartDefineValue,
  String? compileDefault,
}) {
  if (hasDartDefine) {
    return isValidHttpUrl(dartDefineValue) ? dartDefineValue.trim() : null;
  }
  return compileDefault == null || compileDefault.isEmpty
      ? null
      : compileDefault;
}
