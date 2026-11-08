library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/storage/kv_store.dart';
import 'oauth/oauth_client.dart';
import 'oauth/oauth_login_coordinator.dart';
import 'oauth/oauth_token_store.dart';

/// 登录会话（KvStore 持久化；未配置端点时为本地会话，不发起网络请求）。
class AuthSession {
  const AuthSession({required this.account, required this.issuedAt});
  final String account;
  final DateTime issuedAt;
}

/// 鉴权服务：OAuth 模式（kIsOAuthAuthMode）+ 远端已配置时走远端流程；
/// 否则建立本地会话，不发起任何网络请求（真实性红线，见 AGENTS.md）。
class AuthService extends ChangeNotifier {
  AuthService({
    KvStore? storage,
    OAuthSignIn? oauthLogin,
    OAuthTokenStore? oauthTokens,
  })  : _storage = storage ?? MemoryKvStore(),
        _oauthLogin = oauthLogin,
        _oauthTokens = oauthTokens {
    _restore();
  }

  static const storageKey = 'rc-auth-v1';

  final KvStore _storage;
  final OAuthSignIn? _oauthLogin;
  final OAuthTokenStore? _oauthTokens;
  AuthSession? session;

  bool get isSignedIn => session != null;

  /// 配置了 OAuth 登录器才走远端；否则本地会话（不发起网络请求）。
  bool get useRemoteOAuth => _oauthLogin != null;

  /// 本地会话登录。远端 OAuth 模式下禁止绕过系统授权。
  String? signIn(String account, String password) {
    if (useRemoteOAuth) return '请使用系统授权登录';
    final a = account.trim();
    if (a.isEmpty) return '请输入账号';
    if (password.isEmpty) return '请输入密码';
    final issuedAt = DateTime.now();
    session = AuthSession(account: a, issuedAt: issuedAt);
    unawaited(_storage.setString(
      storageKey,
      jsonEncode({'account': a, 'issuedAt': issuedAt.toIso8601String()}),
    ));
    notifyListeners();
    return null;
  }

  /// 远端 OAuth 登录：授权页 → 回调校验 → 换票 → profile。返回 null 成功。
  Future<String?> signInWithOAuth({String? loginHint}) async {
    final coordinator = _oauthLogin;
    if (coordinator == null) return '未配置 OAuth 登录';
    try {
      final result = await coordinator.signIn(loginHint: loginHint);
      final issuedAt = DateTime.now();
      session = AuthSession(account: result.account, issuedAt: issuedAt);
      unawaited(_storage.setString(
        storageKey,
        jsonEncode({
          'account': result.account,
          'issuedAt': issuedAt.toIso8601String(),
        }),
      ));
      notifyListeners();
      return null;
    } on OAuthException catch (e) {
      return e.message.isEmpty ? '登录失败' : e.message;
    } catch (e) {
      return '登录失败：$e';
    }
  }

  void signOut() {
    session = null;
    unawaited(_storage.remove(storageKey));
    unawaited(_oauthTokens?.clear() ?? Future.value());
    notifyListeners();
  }

  void _restore() {
    final raw = _storage.getString(storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final account = decoded['account'];
      final issuedAt = DateTime.tryParse(decoded['issuedAt'] as String? ?? '');
      if (account is String && account.isNotEmpty && issuedAt != null) {
        session = AuthSession(account: account, issuedAt: issuedAt);
      }
    } catch (_) {
      // 损坏数据按未登录处理，不阻塞启动
    }
  }
}
