/// OAuth 客户端配置 —— 经 `--dart-define` 注入，禁止把某产品的默认
/// client id / redirect 硬编码为本 App 的注册（见 AGENTS 真实性红线）。
library;

class OAuthConfig {
  const OAuthConfig({
    required this.baseUrl,
    required this.clientId,
    required this.redirectUri,
    required this.scope,
  });

  static const fromEnvironment = OAuthConfig(
    baseUrl: String.fromEnvironment('RC_OAUTH_BASE_URL'),
    clientId: String.fromEnvironment('RC_OAUTH_CLIENT_ID'),
    redirectUri: String.fromEnvironment('RC_OAUTH_REDIRECT_URI',
        defaultValue: 'recordingcard://oauth/callback'),
    scope: String.fromEnvironment('RC_OAUTH_SCOPE',
        defaultValue: 'profile:read offline_access'),
  );

  final String baseUrl;
  final String clientId;
  final String redirectUri;
  final String scope;

  bool get isConfigured {
    if (clientId.trim().isEmpty) return false;
    final uri = Uri.tryParse(baseUrl.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty;
  }

  String get _base => baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

  Uri get authorizeUri => Uri.parse('$_base/oauth/authorize');
  Uri get tokenUri => Uri.parse('$_base/oauth/token');
  Uri get profileUri => Uri.parse('$_base/oauth/profile');
}
