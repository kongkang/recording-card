/// OAuth 登录编排 —— 授权 URL → 系统浏览器 → 回调 state 校验 → 换票 →
/// profile → token 落安全存储。失败不建会话、不保留半套 token。
library;

import 'auth_launcher.dart';
import 'oauth_client.dart';
import 'oauth_token_store.dart';

class OAuthLoginResult {
  const OAuthLoginResult({
    required this.account,
    required this.tokens,
    required this.profile,
  });

  final String account;
  final OAuthTokens tokens;
  final Map<String, dynamic> profile;
}

/// 登录编排接缝：生产用 [OAuthLoginCoordinator]，测试注入 Fake。
abstract class OAuthSignIn {
  Future<OAuthLoginResult> signIn({String? loginHint, String? prompt});
}

class OAuthLoginCoordinator implements OAuthSignIn {
  OAuthLoginCoordinator({
    required this.oauth,
    required this.tokens,
    required this.launcher,
    required this.callbackScheme,
  });

  final OAuthClient oauth;
  final OAuthTokenStore tokens;
  final AuthLauncher launcher;
  final String callbackScheme;

  @override
  Future<OAuthLoginResult> signIn({
    String? loginHint,
    String? prompt,
  }) async {
    final request = oauth.createAuthorizationRequest(
      loginHint: loginHint,
      prompt: prompt,
    );
    final callback = await launcher.launch(request.url, callbackScheme);
    final uri = Uri.tryParse(callback);
    if (uri == null || uri.scheme != callbackScheme) {
      throw const OAuthException('invalid_callback', '授权回调格式错误');
    }

    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      throw OAuthException(
        error,
        uri.queryParameters['error_description'] ?? '授权被拒绝',
      );
    }
    if (uri.queryParameters['state'] != request.state) {
      throw const OAuthException('state_mismatch', 'state 校验失败，拒绝登录');
    }
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const OAuthException('missing_code', '授权回调缺少 code');
    }

    final issued = await oauth.exchangeCode(
      code: code,
      codeVerifier: request.codeVerifier,
    );
    final profile = await oauth.fetchProfile(issued.accessToken);
    final account = _accountFrom(profile);
    if (account == null) {
      throw const OAuthException('invalid_profile', 'profile 缺少账号标识');
    }
    await tokens.save(issued);
    return OAuthLoginResult(account: account, tokens: issued, profile: profile);
  }

  String? _accountFrom(Map<String, dynamic> profile) {
    for (final key in ['email', 'name', 'sub', 'id']) {
      final value = profile[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}
