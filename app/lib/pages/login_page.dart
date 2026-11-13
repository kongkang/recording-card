library;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/auth_service.dart';

/// 登录页：系统浏览器 OAuth（主）+ 微信原生登录（按配置与安装情况展示）。
///
/// 不在 App 内收集密码——授权页由服务方承载，App 只接收回调与令牌。
/// 账号输入框是可选的「登录提示」（预填服务方登录页），不是凭据。
///
/// 状态全部读 [AuthService]（busy / 错误文案 / 通道），本页不自维护副本，
/// 避免与服务的代次/门控状态漂移。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, required this.onSignedIn});
  final AuthService auth;
  final VoidCallback onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    _account.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final err = await widget.auth.signInWithOAuth(
      loginHint: _account.text.trim().isEmpty ? null : _account.text.trim(),
    );
    if (!mounted) return;
    // err == null 也可能是「用户取消」（静默返回）：只有真正建立了会话才算登录成功。
    if (err == null && widget.auth.isSignedIn) widget.onSignedIn();
  }

  Future<void> _submitWechat() async {
    final err = await widget.auth.signInWithWechat();
    if (!mounted) return;
    // 取消同样静默返回 null；以会话建立为准。
    if (err == null && widget.auth.isSignedIn) widget.onSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final auth = widget.auth;
    final blocked = auth.signInBlockedReason;
    final wechatBlocked = auth.wechatSignInBlockedReason;
    final showWechat = auth.shouldShowWechatSignIn;
    final oauthBusy = auth.isBusy && auth.activeChannel == AuthChannel.oauth;
    final wechatBusy = auth.isBusy && auth.activeChannel == AuthChannel.wechat;
    final error = auth.lastError;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '录音卡',
                  key: const Key('login-title'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: c.label,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '登录后同步你的录音记录',
                  key: const Key('login-subtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: c.sec),
                ),
                const SizedBox(height: 36),
                TextField(
                  key: const Key('login-account'),
                  controller: _account,
                  decoration: _deco(c, '账号（可选）'),
                  style: TextStyle(fontSize: 15, color: c.ink),
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => auth.isBusy ? null : _submit(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    key: const Key('login-error'),
                    style: TextStyle(fontSize: 13, color: c.danger),
                  ),
                ],
                const SizedBox(height: 28),
                Semantics(
                  button: true,
                  label: '通过浏览器登录',
                  child: FilledButton(
                    key: const Key('login-submit'),
                    onPressed:
                        (auth.isBusy || blocked != null) ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.label,
                      foregroundColor: c.bg,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: oauthBusy
                        ? SizedBox(
                            key: const Key('login-busy'),
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: c.bg,
                            ),
                          )
                        : const Text(
                            '登录',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                if (showWechat) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    button: true,
                    label: '微信登录',
                    child: OutlinedButton.icon(
                      key: const Key('login-wechat'),
                      onPressed: (auth.isBusy || wechatBlocked != null)
                          ? null
                          : _submitWechat,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.label,
                        side: BorderSide(color: c.sep),
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: wechatBusy
                          ? SizedBox(
                              key: const Key('login-wechat-busy'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.label,
                              ),
                            )
                          : const Icon(Icons.chat_bubble_rounded, size: 20),
                      label: Text(
                        wechatBusy ? '正在拉起微信…' : '微信登录',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                if (blocked != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    blocked,
                    key: const Key('login-blocked'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: c.sec, height: 1.5),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  // 微信按钮未展示时（未配置 AppID / 未装微信），文案不能出现「或微信」。
                  showWechat ? '授权将在系统浏览器或微信中完成，App 不会获取你的密码。' : '登录将在系统浏览器中完成，App 不会获取你的密码。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: c.sec, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _deco(RCColorScheme c, String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 15, color: c.ax),
        filled: true,
        fillColor: c.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.sep),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.sep),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.label),
        ),
      );
}
