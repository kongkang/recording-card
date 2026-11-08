/// OAuth 流程异常。
///
/// 全部继承 [OAuthException]，`message` 一律是**可直接展示给用户的中文文案**；
/// 业务层按类型分支处理（例如「用户取消」不弹错误、「状态不匹配」引导重新登录），
/// 不要靠解析字符串判断。
library;

/// OAuth 异常基类。
sealed class OAuthException implements Exception {
  const OAuthException(this.message, {this.cause});

  /// 用户可读中文文案。
  final String message;

  /// 底层原因（网络异常、解析异常等），仅用于日志，不要展示给用户。
  final Object? cause;

  @override
  String toString() => '${runtimeType.toString()}: $message';
}

/// 未配置登录服务（缺少 client id / 授权端点）。
///
/// 这是「构建配置问题」，不是用户操作失败；UI 应展示 [message] 并禁用登录按钮。
class OAuthNotConfiguredException extends OAuthException {
  const OAuthNotConfiguredException([super.message = '未配置登录服务，暂时无法登录']);
}

/// 当前构建没有内置浏览器授权组件（缺 flutter_web_auth_2 依赖）。
///
/// 需要在 pubspec 增加 `flutter_web_auth_2` 并实现真实 [WebAuthLauncher] 才能登录。
class OAuthLauncherUnavailableException extends OAuthException {
  const OAuthLauncherUnavailableException([
    super.message = '当前构建未内置浏览器授权组件，暂时无法完成登录',
  ]);
}

/// 用户在系统浏览器里取消授权。UI 应静默留在登录页，不弹错误。
class OAuthCancelledException extends OAuthException {
  const OAuthCancelledException([super.message = '已取消登录']);
}

/// 回调 state 与本次请求不一致（CSRF 或回调重放），或授权会话已过期。
class OAuthStateMismatchException extends OAuthException {
  const OAuthStateMismatchException([
    super.message = '登录会话已失效，请重新登录',
  ]);
}

/// 授权码已过期/丢失（用户在网页停留过久、进程被回收）。
class OAuthPendingMissingException extends OAuthException {
  const OAuthPendingMissingException([
    super.message = '登录会话已失效，请重新登录',
  ]);
}

/// OAuth Server 返回的标准错误响应（`access_denied` / `invalid_grant` 等）。
class OAuthServerException extends OAuthException {
  const OAuthServerException({
    required this.code,
    required String message,
    this.statusCode,
    super.cause,
  }) : super(message);

  /// OAuth 错误码（如 `invalid_grant`）。
  final String code;

  /// HTTP 状态码（无响应时为 null）。
  final int? statusCode;

  @override
  String toString() => 'OAuthServerException($code, $statusCode): $message';
}

/// 网络层异常（DNS / 连接失败 / 超时 / TLS 等）。
class OAuthNetworkException extends OAuthException {
  const OAuthNetworkException([super.message = '网络异常，请稍后重试', Object? cause])
      : super(cause: cause);
}

/// 需要重新登录：没有 token、refresh token 失效或被撤销。
///
/// 业务接口 401 且刷新失败时统一抛它，由上层跳登录页。
class OAuthAuthRequiredException extends OAuthException {
  const OAuthAuthRequiredException([super.message = '登录已过期，请重新登录']);
}
