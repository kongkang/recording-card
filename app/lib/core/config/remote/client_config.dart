library;

import 'endpoint_resolver.dart';

/// Public configuration only. No provider key, client secret or account token.
/// Reference-client callback reuse is an explicit, default-off compatibility
/// mode. Do not install another app handling reai-mobile on the test device.
class ClientConfig {
  const ClientConfig({
    this.hasApiBaseDefine = false,
    this.apiBaseDefineValue = '',
    this.oauthClientId = referencePublicClientId,
    this.oauthBaseUrl = 'https://block2-api.wainao.chat',
    String? oauthRedirectUri,
    this.oauthReuseReferenceClient = false,
    this.oauthScope = 'mobile:full profile:read',
    this.modelGatewayBaseUrl = '',
    this.textModel = '',
    this.trustedHosts = kTrustedEndpointHosts,
  }) : oauthRedirectUri =
           oauthRedirectUri ??
           (oauthReuseReferenceClient
               ? referenceOAuthRedirectUri
               : independentOAuthRedirectUri);

  static const referencePublicClientId = '58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo';
  static const referenceOAuthRedirectUri = 'reai-mobile://callback';
  static const independentOAuthRedirectUri = 'recording-card://callback';

  static const ClientConfig instance = ClientConfig(
    hasApiBaseDefine: bool.hasEnvironment('RC_API_BASE'),
    apiBaseDefineValue: String.fromEnvironment('RC_API_BASE'),
    oauthClientId: String.fromEnvironment(
      'RC_OAUTH_CLIENT_ID',
      defaultValue: referencePublicClientId,
    ),
    oauthBaseUrl: String.fromEnvironment(
      'RC_OAUTH_BASE_URL',
      defaultValue: 'https://block2-api.wainao.chat',
    ),
    oauthReuseReferenceClient: bool.fromEnvironment(
      'RC_OAUTH_REUSE_REFERENCE_CLIENT',
      defaultValue: false,
    ),
    oauthRedirectUri: String.fromEnvironment(
      'RC_OAUTH_REDIRECT_URI',
      defaultValue: bool.fromEnvironment('RC_OAUTH_REUSE_REFERENCE_CLIENT')
          ? referenceOAuthRedirectUri
          : independentOAuthRedirectUri,
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

  /// Public build flag RC_OAUTH_REUSE_REFERENCE_CLIENT; never grants Auth.
  final bool oauthReuseReferenceClient;
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
