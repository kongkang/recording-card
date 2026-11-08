library;

import 'package:flutter/foundation.dart';

import '../core/config/auth_mode.dart';
import '../core/config/remote/client_config.dart';

/// 登录会话（进程内保存；sessionStorage 级语义，TODO 接 shared_preferences 持久化）。
class AuthSession {
  const AuthSession({required this.account, required this.issuedAt});
  final String account;
  final DateTime issuedAt;
}

/// 鉴权服务：OAuth 模式（kIsOAuthAuthMode）+ 远端已配置时走远端流程；
/// 否则建立本地会话，不发起任何网络请求（真实性红线，见 AGENTS.md）。
class AuthService extends ChangeNotifier {
  AuthService({ClientConfig? config}) : _config = config ?? ClientConfig.instance;

  final ClientConfig _config;
  AuthSession? session;

  bool get isSignedIn => session != null;
  bool get useRemoteOAuth => kIsOAuthAuthMode && _config.hasRemoteBackend;

  /// 登录：校验非空后建立会话；返回 null 表示成功，否则为错误文案。
  ///
  /// TODO(oauth-backend)：远端模式接入真实 OAuth2 授权码流程
  /// （全量移植 reai_mobile_app lib/core/config/remote/client_config.dart +
  /// token 刷新），端点经 RC_API_BASE 配置、host 过可信白名单后生效。
  String? signIn(String account, String password) {
    final a = account.trim();
    if (a.isEmpty) return '请输入账号';
    if (password.isEmpty) return '请输入密码';
    session = AuthSession(account: a, issuedAt: DateTime.now());
    notifyListeners();
    return null;
  }

  void signOut() {
    session = null;
    notifyListeners();
  }
}
