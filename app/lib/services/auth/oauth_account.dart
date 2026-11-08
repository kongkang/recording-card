/// 登录账号信息（OAuth `/profile` 返回的最小身份）。
///
/// 只保留展示与去重需要的字段；**不存手机号等敏感字段**，避免 PII 落进 token
/// bundle 被持久化。
library;

/// 账号身份。
class OAuthAccount {
  const OAuthAccount({
    required this.userId,
    this.name,
    this.email,
    this.avatarUrl,
  });

  /// 服务端用户 ID（必填，缺了就无法确认身份）。
  final String userId;

  /// 显示名（服务端 `display_name` / `name` / `username`）。
  final String? name;

  /// 邮箱（可能为空；仅用于展示与提示，不做登录凭据）。
  final String? email;

  /// 头像地址。
  final String? avatarUrl;

  /// 界面展示用名字：显示名 > 邮箱 > userId。
  String get displayName {
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) return n;
    final m = email?.trim() ?? '';
    if (m.isNotEmpty) return m;
    return userId;
  }

  /// 从 `/profile` 响应解析。
  ///
  /// 兼容两种常见外层：直接对象，或包一层 `{data: {...}}`。
  /// 缺 `user_id` / `id` / `sub` 时抛 [FormatException]——
  /// 身份缺失属于协议错误，不能当成「登录成功但没名字」。
  factory OAuthAccount.fromProfile(Map<String, dynamic> json) {
    final payload = _unwrap(json);
    final rawId = payload['user_id'] ?? payload['id'] ?? payload['sub'];
    if (rawId is! String || rawId.trim().isEmpty) {
      throw const FormatException('profile 缺少 user_id');
    }
    return OAuthAccount(
      userId: rawId.trim(),
      name: _nullableString(
        payload['display_name'] ?? payload['name'] ?? payload['username'],
      ),
      email: _nullableString(payload['email']),
      avatarUrl: _nullableString(payload['avatar_url']),
    );
  }

  /// 反序列化（从 secure storage 的 token bundle 恢复）。
  factory OAuthAccount.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    if (userId is! String || userId.isEmpty) {
      throw const FormatException('account.user_id 缺失');
    }
    return OAuthAccount(
      userId: userId,
      name: _nullableString(json['name']),
      email: _nullableString(json['email']),
      avatarUrl: _nullableString(json['avatar_url']),
    );
  }

  /// 序列化（写入 token bundle）。
  Map<String, dynamic> toJson() => {
        'user_id': userId,
        if (name != null) 'name': name,
        if (email != null) 'email': email,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
      };

  static Map<String, dynamic> _unwrap(Map<String, dynamic> json) {
    if (!json.containsKey('data')) return json;
    final data = json['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const FormatException('profile.data 结构非法');
  }

  static String? _nullableString(Object? value) {
    if (value == null) return null;
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    // 非字符串字段（数字 id 等）按缺失处理，不抛：它不是身份必需的。
    return null;
  }

  @override
  String toString() => 'OAuthAccount($userId)';
}
