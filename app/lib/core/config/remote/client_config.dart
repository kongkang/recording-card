library;

import 'endpoint_resolver.dart';

/// 客户端远程配置：API 主机、模型下载源与 OAuth 凭据经 `--dart-define` 注入。
///
/// ```sh
/// flutter run \
///   --dart-define=RC_API_BASE=https://block2-api.wainao.chat \
///   --dart-define=RC_MODEL_BASE=https://dl.wainao.chat/reai/models \
///   --dart-define=RC_OAUTH_CLIENT_ID=recording-card \
///   --dart-define=RC_OAUTH_REDIRECT=recording-card://callback
/// ```
///
/// 优先级：dart-define（合法 http/https）> 编译默认。
class ClientConfig {
  const ClientConfig._({
    required this.hasApiBaseDefine,
    required this.apiBaseDefineValue,
    required this.hasModelBaseDefine,
    required this.modelBaseDefineValue,
    required this.oauthClientId,
  });

  /// 显式注入用（测试 / 多环境构建）：绕过 dart-define 直接给出字段值。
  ///
  /// 生产路径一律用 [instance]，避免各处自造配置导致行为不一致。
  const ClientConfig.forTesting({
    this.hasApiBaseDefine = false,
    this.apiBaseDefineValue = '',
    this.hasModelBaseDefine = false,
    this.modelBaseDefineValue = '',
    this.oauthClientId = '',
  });

  /// 编译默认 API 主机（不含网关路径）。
  static const String defaultApiBase = 'https://block2-api.wainao.chat';

  /// 编译默认离线语音/声纹模型 CDN 根路径（Android 默认源 & iOS 低版本兜底源）。
  static const String defaultModelBase = 'https://dl.wainao.chat/reai/models';

  /// 与 reai_mobile_app 共用的 OAuth public client（owner 决定先复用，后续可换）。
  static const String defaultOAuthClientId = '58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo';

  static const ClientConfig instance = ClientConfig._(
    hasApiBaseDefine: bool.hasEnvironment('RC_API_BASE'),
    apiBaseDefineValue: String.fromEnvironment('RC_API_BASE'),
    hasModelBaseDefine: bool.hasEnvironment('RC_MODEL_BASE'),
    modelBaseDefineValue: String.fromEnvironment('RC_MODEL_BASE'),
    oauthClientId: String.fromEnvironment(
      'RC_OAUTH_CLIENT_ID',
      defaultValue: defaultOAuthClientId,
    ),
  );

  final bool hasApiBaseDefine;
  final String apiBaseDefineValue;
  final bool hasModelBaseDefine;
  final String modelBaseDefineValue;
  final String oauthClientId;

  /// 严格校验后的 API 主机（https、无 query/fragment、去尾斜杠）。
  ///
  /// 同时接受 `String.fromEnvironment` 里的原始值与编译默认值；
  /// dart-define 值非法时**回落编译默认**（而不是整体失效），
  /// 这样拼错一个联调参数不会让 App 静默进入「无后端」状态。
  String? get apiBase =>
      sanitizeTrustedEndpoint(
        resolveEndpoint(
          hasDartDefine: hasApiBaseDefine,
          dartDefineValue: apiBaseDefineValue,
          compileDefault: defaultApiBase,
        ),
      ) ??
      sanitizeTrustedEndpoint(defaultApiBase);

  /// 显式通过 `--dart-define=RC_MODEL_BASE=...` 指定的合法 HTTP(S) 模型源；未传则 null。
  String? get explicitModelBase {
    if (!hasModelBaseDefine || !isValidHttpUrl(modelBaseDefineValue)) {
      return null;
    }
    return modelBaseDefineValue.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  /// 默认 HTTP 模型下载源（当未走 iOS Apple-Hosted 时使用）。
  String get fallbackModelBase => defaultModelBase;

  /// 是否配置了远程后端（正常构建恒为 true）。
  bool get hasRemoteBackend => apiBase != null;

  /// OAuth public client id；空字符串表示未配置登录服务。
  String get normalizedOAuthClientId => oauthClientId.trim();
}
