/// 网络层统一异常。
///
/// 三条原则：
/// 1. **类型化**：调用方按类型分支（未登录 / 超时 / 网络 / 服务端错误 / 解析失败），
///    不要解析 message 字符串；
/// 2. **中文文案**：[ApiException.message] 可以直接展示给用户，
///    技术细节放在 [ApiException.cause] 里只给日志；
/// 3. **不吞异常**：要么正常返回，要么抛这里的类型，绝不「失败了但看着像成功」。
library;

/// 网络层异常基类。
sealed class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.cause,
  });

  /// 用户可读中文文案。
  final String message;

  /// HTTP 状态码（无响应时为 null）。
  final int? statusCode;

  /// 服务端业务错误码（响应体里的 `error` / `code`）。
  final String? code;

  /// 底层原因，仅用于日志。
  final Object? cause;

  /// 是否为「需要重新登录」（UI 据此跳登录页）。
  bool get requiresSignIn => this is ApiUnauthorizedException;

  /// 是否值得重试（超时 / 网络 / 5xx）。
  bool get isRetryable =>
      this is ApiTimeoutException ||
      this is ApiNetworkException ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() {
    final parts = [
      runtimeType.toString(),
      if (statusCode != null) 'HTTP $statusCode',
      if (code != null) code,
      message,
    ];
    return '(${parts.join(' | ')})';
  }
}

/// 未登录 / 登录已过期（401 且刷新失败）。上层应引导回登录页。
class ApiUnauthorizedException extends ApiException {
  const ApiUnauthorizedException([super.message = '登录已过期，请重新登录'])
      : super(statusCode: 401);
}

/// 请求超时。
class ApiTimeoutException extends ApiException {
  /// 默认文案（需要「默认文案 + 底层原因」时显式引用，避免重复字符串）。
  static const String defaultMessage = '请求超时，请检查网络后重试';

  const ApiTimeoutException([super.message = defaultMessage, Object? cause])
      : super(cause: cause);
}

/// 网络不可用（DNS / 连接失败 / TLS / socket 异常）。
class ApiNetworkException extends ApiException {
  /// 默认文案。
  static const String defaultMessage = '网络连接失败，请检查网络后重试';

  const ApiNetworkException([super.message = defaultMessage, Object? cause])
      : super(cause: cause);
}

/// 服务端返回非 2xx（401 已被单独归一成 [ApiUnauthorizedException]）。
class ApiHttpException extends ApiException {
  const ApiHttpException(
    super.message, {
    required super.statusCode,
    super.code,
    this.bodyPreview,
    super.cause,
  });

  /// 响应体前若干字符（截断，避免把整段音频错误响应塞进日志）。
  final String? bodyPreview;

  @override
  String toString() => 'ApiHttpException(HTTP $statusCode | $message)';
}

/// 响应体不是预期结构（JSON 解析失败 / 字段缺失）。
class ApiFormatException extends ApiException {
  /// 默认文案。
  static const String defaultMessage = '服务返回的数据格式不正确';

  const ApiFormatException([super.message = defaultMessage, Object? cause])
      : super(cause: cause);
}

/// 能力未配置（端点或模型名缺失），调用前就应判掉。
class ApiNotConfiguredException extends ApiException {
  const ApiNotConfiguredException([super.message = '该功能尚未配置，暂时不可用']);
}
