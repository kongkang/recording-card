/// Messages are deliberately local/static: never include HTTP bodies, token,
/// callback URI, authorization code or SDK exception text in diagnostics.
class AuthException implements Exception {
  const AuthException(this.code, this.message, {this.statusCode});
  final String code;
  final String message;
  final int? statusCode;
  @override
  String toString() => 'AuthException($code, ${statusCode ?? '-'}): $message';
}

class AuthRequiredException extends AuthException {
  const AuthRequiredException()
    : super('auth_required', '未登录或授权已过期，请重新授权', statusCode: 401);
}

class AuthCancelledException extends AuthException {
  const AuthCancelledException() : super('cancelled', '已取消授权');
}
