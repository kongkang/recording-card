library;

import 'package:flutter/material.dart';
import '../core/theme/tokens.dart';
import '../services/auth_service.dart';

/// Passwords are entered only on the system OAuth page, never accepted locally.
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.auth,
    required this.onSignedIn,
    this.authorize,
  });
  final AuthService auth;
  final VoidCallback onSignedIn;
  final Future<void> Function()? authorize;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String? _error;
  bool _busy = false;
  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Dynamic seam compiles in the isolated baseline before A's facade lands.
      if (widget.authorize != null) {
        await widget.authorize!();
      } else {
        await (widget.auth as dynamic).signInWithOAuth();
      }
      if (!widget.auth.isSignedIn) throw StateError('系统授权未完成，请重试');
      if (mounted) widget.onSignedIn();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is NoSuchMethodError
              ? 'OAuth服务未配置，请检查应用配置'
              : '授权失败，请检查网络或授权配置后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: RCColors.bg,
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '录音卡',
                key: Key('login-title'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                '登录后同步你的录音记录',
                key: Key('login-subtitle'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: RCColors.sec),
              ),
              const SizedBox(height: 36),
              TextField(
                key: const Key('login-account'),
                readOnly: true,
                decoration: _deco('账号将在系统授权页选择'),
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('login-password'),
                readOnly: true,
                obscureText: true,
                decoration: _deco('密码仅在系统授权页输入'),
                style: const TextStyle(fontSize: 15),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('login-error'),
                  style: const TextStyle(fontSize: 13, color: RCColors.danger),
                ),
              ],
              const SizedBox(height: 28),
              FilledButton(
                key: const Key('login-submit'),
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: RCColors.label,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  _busy ? '正在授权…' : '系统授权登录',
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
