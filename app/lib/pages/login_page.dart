library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/auth_service.dart';

/// 登录页：外脑 OAuth（主）+ 微信原生 / Apple / Google 原生入口（按可用性动态展示）。
///
/// 不在 App 内收集账号或密码——所有鉴权均由系统安全浏览器或微信完成，App 只接收回调与令牌。
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
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _runSignIn(Future<String?> Function() action) async {
    final err = await action();
    if (!mounted) return;
    // err == null 也可能是「用户取消」（静默返回）：只有真正建立了会话才算登录成功。
    if (err == null && widget.auth.isSignedIn) widget.onSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final auth = widget.auth;
    final blocked = auth.signInBlockedReason;
    final wechatBlocked = auth.wechatSignInBlockedReason;
    final showWechat = auth.shouldShowWechatSignIn;
    final canUseWechat = showWechat && wechatBlocked == null;
    final showApple = auth.shouldShowAppleSignIn;
    final canUseApple = auth.isAppleSignInEnabled;
    final showGoogle = auth.shouldShowGoogleSignIn;
    final canUseGoogle = auth.isGoogleSignInEnabled;
    final hasSecondaryMethods = showWechat || showApple || showGoogle;
    final oauthBusy = auth.isBusy && auth.activeChannel == AuthChannel.oauth;
    final wechatBusy = auth.isBusy && auth.activeChannel == AuthChannel.wechat;
    final appleBusy = auth.isBusy && auth.activeChannel == AuthChannel.apple;
    final googleBusy = auth.isBusy && auth.activeChannel == AuthChannel.google;
    final error = auth.lastError;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              32,
              24,
              32,
              RCDims.pageBottomPad,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: c.sep),
                      ),
                      child: Icon(
                        Icons.graphic_eq_rounded,
                        size: 32,
                        color: c.label,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
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
                  if (error != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      error,
                      key: const Key('login-error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: c.danger),
                    ),
                  ],
                  SizedBox(height: error != null ? 20 : 32),
                  Semantics(
                    button: true,
                    label: '使用外脑账号登录',
                    child: FilledButton.icon(
                      key: const Key('login-submit'),
                      onPressed: (auth.isBusy || blocked != null)
                          ? null
                          : () => _runSignIn(auth.signInWithOAuth),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.label,
                        foregroundColor: c.bg,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: oauthBusy
                          ? SizedBox(
                              key: const Key('login-busy'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.bg,
                              ),
                            )
                          : const Icon(Icons.key_rounded, size: 20),
                      label: Text(
                        oauthBusy ? '正在打开授权页…' : '使用外脑账号登录',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (hasSecondaryMethods) ...[
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Expanded(child: Divider(height: 1, color: c.sep)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '其他登录方式',
                            style: TextStyle(fontSize: 12, color: c.sec),
                          ),
                        ),
                        Expanded(child: Divider(height: 1, color: c.sep)),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (showWechat)
                    _buildSocialButton(
                      c: c,
                      buttonKey: const Key('login-wechat'),
                      busyKey: const Key('login-wechat-busy'),
                      semanticsLabel: '微信登录',
                      label: wechatBusy ? '正在拉起微信…' : '微信登录',
                      busy: wechatBusy,
                      icon: Icon(
                        Icons.chat_bubble_rounded,
                        size: 20,
                        color: (!auth.isBusy && canUseWechat)
                            ? const Color(0xFF07C160)
                            : c.ax,
                      ),
                      onPressed: (!auth.isBusy && canUseWechat)
                          ? () => _runSignIn(auth.signInWithWechat)
                          : null,
                    ),
                  if (showApple) ...[
                    if (showWechat) const SizedBox(height: 12),
                    _buildSocialButton(
                      c: c,
                      buttonKey: const Key('login-apple'),
                      busyKey: const Key('login-apple-busy'),
                      semanticsLabel: '通过 Apple 登录',
                      label: appleBusy ? '正在连接 Apple…' : '通过 Apple 登录',
                      busy: appleBusy,
                      icon: Icon(
                        Icons.apple,
                        size: 22,
                        color: (!auth.isBusy && canUseApple) ? c.label : c.ax,
                      ),
                      onPressed: (!auth.isBusy && canUseApple)
                          ? () => _runSignIn(auth.signInWithApple)
                          : null,
                    ),
                  ],
                  if (showGoogle) ...[
                    if (showWechat || showApple) const SizedBox(height: 12),
                    _buildSocialButton(
                      c: c,
                      buttonKey: const Key('login-google'),
                      busyKey: const Key('login-google-busy'),
                      semanticsLabel: '通过 Google 登录',
                      label: googleBusy ? '正在连接 Google…' : '通过 Google 登录',
                      busy: googleBusy,
                      icon: Opacity(
                        opacity: (!auth.isBusy && canUseGoogle) ? 1.0 : 0.38,
                        child: const SizedBox(
                          width: 20,
                          height: 20,
                          child: CustomPaint(painter: _GoogleLogoPainter()),
                        ),
                      ),
                      onPressed: (!auth.isBusy && canUseGoogle)
                          ? () => _runSignIn(auth.signInWithGoogle)
                          : null,
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
                  const SizedBox(height: 20),
                  Text(
                    // 微信按钮未开通/未启用时，文案不出现「或微信」。
                    canUseWechat
                        ? '授权将在系统浏览器或微信中完成，App 不会获取你的密码。'
                        : '登录将在系统浏览器中完成，App 不会获取你的密码。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: c.sec, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSocialButton({
    required RCColorScheme c,
    required Key buttonKey,
    required Key busyKey,
    required String semanticsLabel,
    required String label,
    required bool busy,
    required Widget icon,
    required VoidCallback? onPressed,
  }) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: OutlinedButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: c.label,
          disabledForegroundColor: busy ? c.label : c.ax,
          backgroundColor: c.card,
          disabledBackgroundColor: c.card,
          side: BorderSide(
            color: (onPressed == null && !busy)
                ? c.sep.withValues(alpha: 0.6)
                : c.sep,
          ),
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: busy
            ? SizedBox(
                key: busyKey,
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.label,
                ),
              )
            : icon,
        label: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 标准四色 Google `G` 矢量徽标，无需外部 PNG 资源即可跟随系统分辨率锐利绘制。
class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = s * 0.2;
    final radius = (s - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    Paint arcPaint(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // 红（右上至左上）、黄（左下弧）、绿（底弧）、蓝（右下弧 + 横杆）
    canvas.drawArc(rect, 3.55, 1.98, false, arcPaint(const Color(0xFFEA4335)));
    canvas.drawArc(rect, 2.28, 1.32, false, arcPaint(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, 0.85, 1.48, false, arcPaint(const Color(0xFF34A853)));
    canvas.drawArc(rect, -0.05, 0.95, false, arcPaint(const Color(0xFF4285F4)));

    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(
      Offset(center.dx + stroke * 0.05, center.dy + stroke * 0.04),
      Offset(center.dx + radius, center.dy + stroke * 0.04),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}
