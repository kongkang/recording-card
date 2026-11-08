import 'auth_exception.dart';

/// Only AuthService publishes this after a successful authenticated /profile.
/// Tokens remain private to OAuthTokenStore and are not part of this view model.
class AuthSession {
  const AuthSession({
    required this.account,
    required this.issuedAt,
    this.userId,
    this.displayName,
  });
  final String account;
  final DateTime issuedAt;
  final String? userId;
  final String? displayName;

  factory AuthSession.fromProfile(
    Map<String, dynamic> json,
    DateTime issuedAt,
  ) {
    final data = json.containsKey('data') ? json['data'] : json;
    if (data is! Map ||
        data['user_id'] is! String ||
        (data['user_id'] as String).trim().isEmpty) {
      throw const AuthException('invalid_profile', '服务端未返回有效用户身份');
    }
    final email = data['email'];
    final name = data['display_name'] ?? data['username'];
    if ((email != null && email is! String) ||
        (name != null && name is! String)) {
      throw const AuthException('invalid_profile', '服务端用户资料格式无效');
    }
    return AuthSession(
      account: email is String && email.isNotEmpty
          ? email
          : data['user_id'] as String,
      issuedAt: issuedAt,
      userId: data['user_id'] as String,
      displayName: name as String?,
    );
  }
}
