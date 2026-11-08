/// OAuth token 持久化 —— 单条 JSON 原子写入安全存储，避免 access/refresh
/// 分 key 写入时进程被杀造成错配。
library;

import 'dart:convert';

import 'oauth_client.dart';
import 'secure_store.dart';

class OAuthTokenStore {
  OAuthTokenStore(this._store);

  static const storageKey = 'rc-oauth-tokens-v1';

  final SecureStore _store;

  Future<OAuthTokens?> read() async {
    final raw = await _store.read(storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return OAuthTokens.fromJson(decoded);
    } catch (_) {
      // 损坏 token 包按未登录处理；不在这里删除，便于诊断
      return null;
    }
  }

  Future<void> save(OAuthTokens tokens) =>
      _store.write(storageKey, jsonEncode(tokens.toJson()));

  Future<void> clear() => _store.delete(storageKey);
}
