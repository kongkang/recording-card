library;

import 'endpoint_resolver.dart';

/// Public configuration only. No provider key, client secret or account token.
/// The reference public client is temporarily reusable by user approval, but
/// its server redirect allowlist MUST include recording-card://callback first.
class ClientConfig {
  const ClientConfig({
    this.hasApiBaseDefine = false,
    this.apiBaseDefineValue = '',
    this.oauthClientId = '58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo',
    this.oauthBaseUrl = 'https://block2-api.wainao.chat',
    this.oauthRedirectUri = 'recording-card://callback',
    this.oauthScope = 'mobile:full profile:read',
    this.modelGatewayBaseUrl = '',
    this.textModel = '',
    this.trustedHosts = kTrustedEndpointHosts,
  });

  static const ClientConfig instance = ClientConfig(
    hasApiBaseDefine: bool.hasEnvironment('RC_API_BASE'),
    apiBaseDefineValue: String.fromEnvironment('RC_API_BASE'),
    oauthClientId: String.fromEnvironment(
      'RC_OAUTH_CLIENT_ID',
      defaultValue: '58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo',
    ),
    oauthBaseUrl: String.fromEnvironment(
      'RC_OAUTH_BASE_URL',
      defaultValue: 'https://block2-api.wainao.chat',
    ),
    oauthRedirectUri: String.fromEnvironment(
      'RC_OAUTH_REDIRECT_URI',
      defaultValue: 'recording-card://callback',
    ),
    oauthScope: String.fromEnvironment(
      'RC_OAUTH_SCOPE',
      defaultValue: 'mobile:full profile:read',
    ),
    modelGatewayBaseUrl: String.fromEnvironment('RC_MODEL_GATEWAY_BASE_URL'),
    textModel: String.fromEnvironment('RC_TEXT_MODEL'),
  );

  final bool hasApiBaseDefine;
  final String apiBaseDefineValue;
  final String oauthClientId;
  final String oauthBaseUrl;
  final String oauthRedirectUri;
  final String oauthScope;
  final String modelGatewayBaseUrl;
  final String textModel;
  final List<String> trustedHosts;

  /// Legacy RC_API_BASE compatibility. No define still returns null.
  String? get apiBase => sanitizeTrustedEndpoint(
    resolveEndpoint(
      hasDartDefine: hasApiBaseDefine,
      dartDefineValue: apiBaseDefineValue,
    ),
    trustedHosts: trustedHosts,
  );
  bool get hasRemoteBackend => apiBase != null;

  /// RC_API_BASE overrides both OAuth and business base unless a gateway URL is
  /// explicitly supplied. Invalid overrides fail closed (never use defaults).
  String get effectiveOAuthBaseUrl =>
      hasApiBaseDefine ? apiBaseDefineValue : oauthBaseUrl;

  String get effectiveModelGatewayBaseUrl {
    if (modelGatewayBaseUrl.trim().isNotEmpty) return modelGatewayBaseUrl;
    final base = hasApiBaseDefine ? apiBaseDefineValue : oauthBaseUrl;
    return '${base.trim().replaceFirst(RegExp(r'/+$'), '')}/api/model-gateway/v1';
  }
}
