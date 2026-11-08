library;

/// build-time 鉴权模式开关（借鉴 reai_mobile_app 同名机制）。
///
/// 默认 `oauth`；端点未配置（RC_API_BASE 空）时回落本地会话，不发起网络请求。
const String kAuthMode = String.fromEnvironment(
  'RC_AUTH_MODE',
  defaultValue: 'oauth',
);

const bool kIsOAuthAuthMode = kAuthMode == 'oauth';
