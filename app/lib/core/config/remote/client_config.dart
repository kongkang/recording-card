library;

import 'endpoint_resolver.dart';

/// 客户端远程配置：OAuth 端点与凭据经 `--dart-define` 注入（借鉴 reai_mobile_app）。
///
/// ```sh
/// flutter run --dart-define=RC_API_BASE=https://api.example.com \
///   --dart-define=RC_OAUTH_CLIENT_ID=recording-card
/// ```
///
/// 未配置端点时 [apiBase] 为 null：App 以本地会话运行，不发起业务网络请求
/// （诚实边界写在 AGENTS.md，不写在界面上）。
class ClientConfig {
  const ClientConfig._({
    required this.hasApiBaseDefine,
    required this.apiBaseDefineValue,
    required this.oauthClientId,
  });

  static const ClientConfig instance = ClientConfig._(
    hasApiBaseDefine: bool.hasEnvironment('RC_API_BASE'),
    apiBaseDefineValue: String.fromEnvironment('RC_API_BASE'),
    oauthClientId: String.fromEnvironment('RC_OAUTH_CLIENT_ID',
        defaultValue: 'recording-card'),
  );

  final bool hasApiBaseDefine;
  final String apiBaseDefineValue;
  final String oauthClientId;

  /// 严格校验后的 OAuth 端点；null = 本地会话模式。
  String? get apiBase => sanitizeTrustedEndpoint(resolveEndpoint(
        hasDartDefine: hasApiBaseDefine,
        dartDefineValue: apiBaseDefineValue,
      ));

  /// 是否配置了远程后端。
  bool get hasRemoteBackend => apiBase != null;
}
