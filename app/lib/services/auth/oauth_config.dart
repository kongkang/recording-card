library;

import '../../core/config/remote/client_config.dart';
import '../../core/config/remote/endpoint_resolver.dart';

/// OAuth 2.0 客户端配置（Authorization Code + PKCE，public client，无 client_secret）。
///
/// 端点全部可用 `--dart-define` 覆盖，未覆盖时按 [ClientConfig.defaultApiBase]
/// 派生（默认指向自有网关 `https://block2-api.wainao.chat`）：
///
/// | 配置项 | dart-define | 缺省值 |
/// | --- | --- | --- |
/// | API 主机 | `RC_API_BASE` | `https://block2-api.wainao.chat` |
/// | 客户端 ID | `RC_OAUTH_CLIENT_ID` | 与 reai_mobile_app 共用（可在构建时替换） |
/// | 授权端点 | `RC_OAUTH_AUTH_URL` | `${apiBase}/oauth/authorize` |
/// | Token 端点 | `RC_OAUTH_TOKEN_URL` | `${apiBase}/oauth/token` |
/// | 回调地址 | `RC_OAUTH_REDIRECT` | `reai-mobile://callback` |
/// | 申请 scope | `RC_OAUTH_SCOPE` | 空（不传 scope，由服务端决定） |
///
/// 校验策略：[isConfigured] 要求 client id 非空，且授权/Token 端点均为
/// 「https + 无 query/fragment」的干净地址（[sanitizeTrustedEndpoint]）。
/// 不满足即视为未配置，登录入口返回明确错误而不是静默假登录。
class OAuthConfig {
  const OAuthConfig({
    required this.baseUrl,
    required this.authUrl,
    required this.tokenUrl,
    required this.profileUrl,
    required this.revokeUrl,
    this.deleteAccountUrl,
    this.socialProvidersUrl,
    this.socialProvidersOverride,
    required this.clientId,
    required this.redirectUri,
    required this.scope,
    this.wechatAppId = '',
    this.wechatUniversalLink = defaultWechatUniversalLink,
    this.wechatScope = 'mobile:full profile:read',
    this.accessTokenDefaultTtl = const Duration(hours: 1),
    this.refreshTokenDefaultTtl = const Duration(days: 30),
    this.pendingAuthorizationTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 20),
  });

  /// 外脑 `/oauth/authorize` `login_type` 白名单词表。
  static const Set<String> supportedLoginTypes = {
    'email',
    'phone',
    'wechat',
    'alipay',
    'google',
    'apple',
    'github',
  };

  /// 微信 Universal Link（与 app.cn.reai.com 的 AASA `/link/*` 路径绑定）。
  static const String defaultWechatUniversalLink = 'https://app.cn.reai.com/link/';

  /// 微信扩展 grant 的固定协议常量（与后端约定，不随环境变化）。
  static const String wechatGrantType =
      'urn:wainao:params:oauth:grant-type:wechat';

  /// `/oauth/token` 微信 grant 的 `app_type` 固定值。
  static const String wechatAppType = 'app';

  /// 从编译期环境解析配置。
  factory OAuthConfig.fromEnvironment({ClientConfig? clientConfig}) {
    final cfg = clientConfig ?? ClientConfig.instance;
    final base = cfg.apiBase;

    final authUrl = _resolveUrl(
      hasDartDefine: bool.hasEnvironment('RC_OAUTH_AUTH_URL'),
      dartDefineValue: const String.fromEnvironment('RC_OAUTH_AUTH_URL'),
      fallback: base == null ? null : '$base/oauth/authorize',
    );
    final tokenUrl = _resolveUrl(
      hasDartDefine: bool.hasEnvironment('RC_OAUTH_TOKEN_URL'),
      dartDefineValue: const String.fromEnvironment('RC_OAUTH_TOKEN_URL'),
      fallback: base == null ? null : '$base/oauth/token',
    );

    final redirect = const String.fromEnvironment(
      'RC_OAUTH_REDIRECT',
      // 复用 reai 的 OAuth 客户端：回调 scheme 必须与后端登记一致
      defaultValue: 'reai-mobile://callback',
    ).trim();

    final scope = const String.fromEnvironment('RC_OAUTH_SCOPE').trim();

    // profile / revoke 跟随授权端点同源（没有单独 define，避免配置漂移）。
    String? sibling(String path) {
      final origin = authUrl == null ? null : _originOf(authUrl);
      return origin == null ? null : '$origin$path';
    }

    final deleteAccountUrl = _resolveUrl(
      hasDartDefine: bool.hasEnvironment('RC_ACCOUNT_DELETE_URL'),
      dartDefineValue: const String.fromEnvironment('RC_ACCOUNT_DELETE_URL'),
      fallback: sibling('/account'),
    );

    return OAuthConfig(
      baseUrl: base,
      authUrl: authUrl,
      tokenUrl: tokenUrl,
      profileUrl: sibling('/profile'),
      revokeUrl: sibling('/oauth/revoke'),
      deleteAccountUrl: deleteAccountUrl,
      socialProvidersUrl: sibling('/auth/social/providers'),
      socialProvidersOverride: _resolveSocialProvidersOverride(),
      clientId: cfg.normalizedOAuthClientId,
      redirectUri: redirect,
      scope: scope,
      wechatAppId: _resolveWechatAppId(),
    );
  }

  /// 编译期社会化登录渠道覆盖（`RC_SOCIAL_PROVIDERS=apple,google`）；
  /// 未定义或空串返回 null（走线上 `/auth/social/providers` 自动探测）。
  static Set<String>? _resolveSocialProvidersOverride() {
    if (!const bool.hasEnvironment('RC_SOCIAL_PROVIDERS')) {
      return null;
    }
    final raw = const String.fromEnvironment('RC_SOCIAL_PROVIDERS').trim();
    if (raw.isEmpty) return null;
    final parsed = <String>{};
    for (final item in raw.split(',')) {
      final token = item.trim().toLowerCase();
      if (supportedLoginTypes.contains(token)) {
        parsed.add(token);
      }
    }
    if (parsed.isEmpty) return const <String>{};
    return Set<String>.unmodifiable(parsed);
  }

  /// 微信 AppID：`RC_WECHAT_APP_ID` 优先（本仓命名规范），回退兼容 reai 的
  /// `WECHAT_APP_ID`。缺省为空 = 未配置（fail-closed，登录页隐藏微信入口）。
  ///
  /// 注意与 `ios/Flutter/Wechat.xcconfig` 的 `WECHAT_APP_ID` 必须同值，
  /// 否则 iOS 回调 scheme 与注册的 AppID 不一致导致授权回不来。
  static String _resolveWechatAppId() {
    if (const bool.hasEnvironment('RC_WECHAT_APP_ID')) {
      return const String.fromEnvironment('RC_WECHAT_APP_ID').trim();
    }
    if (const bool.hasEnvironment('WECHAT_APP_ID')) {
      return const String.fromEnvironment('WECHAT_APP_ID').trim();
    }
    return '';
  }

  /// 当前编译产物使用的配置（全局单例语义，测试请直接 new 自己的实例）。
  static OAuthConfig get current => OAuthConfig.fromEnvironment();

  /// API 主机（不含网关路径）；null = 未配置后端。
  final String? baseUrl;

  /// 授权端点（浏览器打开的页面）；null = 未配置。
  final String? authUrl;

  /// Token 端点（换码 / 续期）；null = 未配置。
  final String? tokenUrl;

  /// 用户信息端点，用于登录后身份校验；null = 未配置。
  final String? profileUrl;

  /// 撤销端点（登出时尽力而为）；null = 未配置。
  final String? revokeUrl;

  /// 账号注销端点（`DELETE /account`）；null = 未配置。
  final String? deleteAccountUrl;

  /// 社会化登录渠道公开查询端点（`/auth/social/providers`）；null = 未配置。
  final String? socialProvidersUrl;

  /// 编译期覆盖社会化登录渠道白名单（null = 以服务端查询为准）。
  final Set<String>? socialProvidersOverride;

  /// public client id（空 = 未配置登录服务）。
  final String clientId;

  /// 回调地址，必须与 OAuth 应用登记值逐字符一致。
  final String redirectUri;

  /// 申请的 scope（空则不传该参数）。
  final String scope;

  /// 微信开放平台移动应用 AppID（公开客户端标识，不是 AppSecret）。
  ///
  /// 合法值必须以 `wx` 开头；空串或 `Wechat.xcconfig` 的占位符均视为未配置
  /// （见 [isWechatConfigured]，fail-closed）。
  final String wechatAppId;

  /// 微信回调 Universal Link（iOS UL 校验 + AASA 绑定）。
  final String wechatUniversalLink;

  /// 微信 grant 申请的 scope（与 reai_mobile_app 一致；待后端最终确认）。
  final String wechatScope;

  /// access_token 缺省有效期（服务端未返回 `expires_in` 时兜底）。
  final Duration accessTokenDefaultTtl;

  /// refresh_token 缺省有效期（服务端未返回 `refresh_expires_in` 时兜底）。
  final Duration refreshTokenDefaultTtl;

  /// 授权请求有效期：超过后旧 state/verifier 一律作废。
  final Duration pendingAuthorizationTtl;

  /// 单次 HTTP 请求超时。
  final Duration requestTimeout;

  /// 是否可用于登录（client id 与两个核心端点都齐）。
  bool get isConfigured =>
      clientId.trim().isNotEmpty && authUrl != null && tokenUrl != null;

  /// 微信登录是否配置就绪：合法 AppID 必须以 `wx` 开头（真 AppID 形如 `wx` + 16 位）。
  ///
  /// `Wechat.xcconfig` 占位串（如 `rc-wechat-disabled`）与空串都会判 false——
  /// iOS 侧 URL scheme 需要非空占位防 ITMS-90158，Dart 侧在此严格拦下。
  bool get isWechatConfigured =>
      wechatAppId.startsWith('wx') && wechatAppId.length > 2;

  /// 回调 scheme（`recording-card://callback` → `recording-card`）。
  String get callbackScheme {
    final uri = Uri.tryParse(redirectUri);
    return uri?.scheme ?? '';
  }

  /// 派生一份新配置（测试 / 联调覆盖字段用，避免到处 new 长构造）。
  OAuthConfig copyWith({
    String? baseUrl,
    String? authUrl,
    String? tokenUrl,
    String? profileUrl,
    String? revokeUrl,
    String? deleteAccountUrl,
    String? socialProvidersUrl,
    Set<String>? socialProvidersOverride,
    String? clientId,
    String? redirectUri,
    String? scope,
    String? wechatAppId,
    String? wechatUniversalLink,
    String? wechatScope,
    Duration? accessTokenDefaultTtl,
    Duration? refreshTokenDefaultTtl,
    Duration? pendingAuthorizationTtl,
    Duration? requestTimeout,
  }) {
    return OAuthConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      authUrl: authUrl ?? this.authUrl,
      tokenUrl: tokenUrl ?? this.tokenUrl,
      profileUrl: profileUrl ?? this.profileUrl,
      revokeUrl: revokeUrl ?? this.revokeUrl,
      deleteAccountUrl: deleteAccountUrl ?? this.deleteAccountUrl,
      socialProvidersUrl: socialProvidersUrl ?? this.socialProvidersUrl,
      socialProvidersOverride:
          socialProvidersOverride ?? this.socialProvidersOverride,
      clientId: clientId ?? this.clientId,
      redirectUri: redirectUri ?? this.redirectUri,
      scope: scope ?? this.scope,
      wechatAppId: wechatAppId ?? this.wechatAppId,
      wechatUniversalLink: wechatUniversalLink ?? this.wechatUniversalLink,
      wechatScope: wechatScope ?? this.wechatScope,
      accessTokenDefaultTtl:
          accessTokenDefaultTtl ?? this.accessTokenDefaultTtl,
      refreshTokenDefaultTtl:
          refreshTokenDefaultTtl ?? this.refreshTokenDefaultTtl,
      pendingAuthorizationTtl:
          pendingAuthorizationTtl ?? this.pendingAuthorizationTtl,
      requestTimeout: requestTimeout ?? this.requestTimeout,
    );
  }

  /// 端点解析：dart-define（合法 https）优先，否则用按 base 派生值。
  static String? _resolveUrl({
    required bool hasDartDefine,
    required String dartDefineValue,
    required String? fallback,
  }) {
    if (hasDartDefine) {
      final candidate = sanitizeTrustedEndpoint(dartDefineValue);
      if (candidate != null) return candidate;
      // 显式配了但非法：**不静默回落**，直接视为未配置，
      // 避免把 token 发到拼错的地址上（配置错误要在联调阶段暴露）。
      return null;
    }
    return sanitizeTrustedEndpoint(fallback);
  }

  /// 取 URL 的 origin（scheme + host + port），用于派生同源端点。
  static String? _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
}
