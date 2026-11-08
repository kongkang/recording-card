library;

import 'endpoint_resolver.dart';

/// 客户端远程配置：API 主机与 OAuth 凭据经 `--dart-define` 注入。
///
/// ```sh
/// flutter run \
///   --dart-define=RC_API_BASE=https://block2-api.wainao.chat \
///   --dart-define=RC_OAUTH_CLIENT_ID=recording-card \
///   --dart-define=RC_OAUTH_REDIRECT=recording-card://callback
/// ```
///
/// 优先级：dart-define（合法 https）> 编译默认（[defaultApiBase]）。
/// 编译默认指向自有模型网关 `https://block2-api.wainao.chat`，
/// 因此**正常构建的产物默认就是「远端模式」**：登录必须走真实 OAuth，
/// 不再有「任意账号密码即通过」的本地假会话。
///
/// 注意：`String.fromEnvironment` 里空字符串等价于「未定义」，所以
/// `--dart-define=RC_API_BASE=` 不能用来关闭后端；关闭登录能力的开关是
/// `RC_OAUTH_CLIENT_ID` 留空（[normalizedOAuthClientId] 为空即「未配置登录服务」）。
class ClientConfig {
  const ClientConfig._({
    required this.hasApiBaseDefine,
    required this.apiBaseDefineValue,
    required this.oauthClientId,
  });

  /// 显式注入用（测试 / 多环境构建）：绕过 dart-define 直接给出字段值。
  ///
  /// 生产路径一律用 [instance]，避免各处自造配置导致行为不一致。
  const ClientConfig.forTesting({
    this.hasApiBaseDefine = false,
    this.apiBaseDefineValue = '',
    this.oauthClientId = '',
  });

  /// 编译默认 API 主机（不含网关路径）。
  static const String defaultApiBase = 'https://block2-api.wainao.chat';

  /// 与 reai_mobile_app 共用的 OAuth public client（owner 决定先复用，后续可换）。
  static const String defaultOAuthClientId = '58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo';

  static const ClientConfig instance = ClientConfig._(
    hasApiBaseDefine: bool.hasEnvironment('RC_API_BASE'),
    apiBaseDefineValue: String.fromEnvironment('RC_API_BASE'),
    oauthClientId: String.fromEnvironment(
      'RC_OAUTH_CLIENT_ID',
      defaultValue: defaultOAuthClientId,
    ),
  );

  final bool hasApiBaseDefine;
  final String apiBaseDefineValue;
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

  /// 是否配置了远程后端（正常构建恒为 true）。
  bool get hasRemoteBackend => apiBase != null;

  /// OAuth public client id；空字符串表示未配置登录服务。
  String get normalizedOAuthClientId => oauthClientId.trim();
}
