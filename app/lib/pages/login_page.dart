library;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/auth_service.dart';

/// 登录页：走系统浏览器完成 OAuth 授权（ASWebAuthenticationSession / Custom Tabs）。
///
/// 不在 App 内收集密码——授权页由服务方承载，App 只接收回调与令牌。
/// 账号输入框是可选的「登录提示」（预填服务方登录页），不是凭据。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, required this.onSignedIn});
  final AuthService auth;
  final VoidCallback onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  String? _error;
  bool _busy = false;

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
    if (!mounted) return;
    setState(() {
      _busy = widget.auth.isBusy;
      _error = widget.auth.lastError;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.auth.signInWithOAuth(
      loginHint: _account.text.trim().isEmpty ? null : _account.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) widget.onSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final blocked = widget.auth.signInBlockedReason;
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
                  onSubmitted: (_) => _busy ? null : _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
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
                    onPressed: (_busy || blocked != null) ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.label,
                      foregroundColor: c.bg,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _busy
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
                  '登录将在系统浏览器中完成，App 不会获取你的密码。',
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
