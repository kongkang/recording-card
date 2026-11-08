library;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/auth_service.dart';

/// 登录页：账号 + 密码；错误文案行内呈现（界面不留占位标注）。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, required this.onSignedIn});
  final AuthService auth;
  final VoidCallback onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final err = widget.auth.signIn(_account.text, _password.text);
    setState(() => _error = err);
    if (err == null) widget.onSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RCColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('录音卡',
                    key: Key('login-title'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text('登录后同步你的录音记录',
                    key: Key('login-subtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: RCColors.sec)),
                const SizedBox(height: 36),
                TextField(
                  key: const Key('login-account'),
                  controller: _account,
                  decoration: _deco('账号'),
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('login-password'),
                  controller: _password,
                  obscureText: true,
                  decoration: _deco('密码'),
                  style: const TextStyle(fontSize: 15),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      key: const Key('login-error'),
                      style: const TextStyle(fontSize: 13, color: RCColors.danger)),
                ],
                const SizedBox(height: 28),
                FilledButton(
                  key: const Key('login-submit'),
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: RCColors.label,
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('登录', style: TextStyle(fontSize: 15)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _deco(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: RCColors.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: RCColors.sep),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: RCColors.sep),
        ),
      );
}
