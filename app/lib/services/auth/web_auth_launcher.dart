/// OAuth 浏览器跳转抽象层。
///
/// 生产实现 [FlutterWebAuthLauncher]：
/// iOS 用 ASWebAuthenticationSession（应用内系统浏览器，共用 Safari 登录态），
/// Android 用内嵌页截住 `reai-mobile://callback`。业务层只依赖 [WebAuthLauncher] 接口。
///
/// 另有：
/// - [UnavailableWebAuthLauncher]：门控用的空实现（`isSupported == false`）；
/// - [FakeWebAuthLauncher]：单测直接跑通「回调 → 换码 → 建会话」全链路。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'oauth_exception.dart';

/// 拉起系统浏览器完成授权，并等待自定义 scheme 回调。
abstract interface class WebAuthLauncher {
  /// 当前构建是否具备真实授权能力。
  ///
  /// UI 应先看它再决定是否允许点击登录（false 时点击必然失败）。
  bool get isSupported;

  /// 打开授权页并等待回调。
  ///
  /// 返回回调 URL（含 `code` / `state` 或 `error`）。
  /// 用户取消抛 [OAuthCancelledException]；
  /// 组件不可用 / 系统无浏览器抛 [OAuthLauncherUnavailableException]。
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  });
}

/// 真实实现：调起系统浏览器授权页。
class FlutterWebAuthLauncher implements WebAuthLauncher {
  const FlutterWebAuthLauncher();

  @override
  bool get isSupported => true;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    try {
      // Android 上当仍复用 reai-mobile 回调时用内嵌页规避外脑 App 同 scheme 抢占选择框；
      // 若已配置独立回调 scheme 或走 Google 登录（Google 禁止内嵌 WebView），切回 Chrome Custom Tabs。
      final isGoogleLogin =
          authorizeUrl.queryParameters['login_type']?.toLowerCase() == 'google';
      if (defaultTargetPlatform == TargetPlatform.android &&
          callbackScheme == 'reai-mobile' &&
          !isGoogleLogin) {
        final raw = await const MethodChannel('com.reai.recordingcard/oauth')
            .invokeMethod<String>('authenticate', {'url': authorizeUrl.toString()});
        if (raw == null || raw.isEmpty) {
          throw const OAuthCancelledException();
        }
        return Uri.parse(raw);
      }
      final result = await FlutterWebAuth2.authenticate(
        url: authorizeUrl.toString(),
        callbackUrlScheme: callbackScheme,
        // iOS 偏好 ephemeral=false：复用系统浏览器登录态，避免每次都要重新输入账号
        options: const FlutterWebAuth2Options(preferEphemeral: false),
      );
      return Uri.parse(result);
    } on OAuthException {
      rethrow;
    } on Exception catch (error) {
      final text = error.toString();
      // flutter_web_auth_2 用 PlatformException('CANCELED') / 'canceled' 表示用户取消
      if (text.toLowerCase().contains('cancel')) {
        throw const OAuthCancelledException();
      }
      debugPrint('[auth] 浏览器授权失败：$text');
      throw const OAuthLauncherUnavailableException('无法打开登录页面，请稍后重试');
    }
  }
}

/// 空实现：告诉调用方「没有浏览器授权组件」，不做任何跳转。
class UnavailableWebAuthLauncher implements WebAuthLauncher {
  const UnavailableWebAuthLauncher();

  @override
  bool get isSupported => false;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    throw const OAuthLauncherUnavailableException();
  }
}

/// 测试实现：直接返回预设回调 URL（或模拟取消 / 组件不可用）。
class FakeWebAuthLauncher implements WebAuthLauncher {
  FakeWebAuthLauncher({
    this.callbackResult,
    this.supported = true,
    this.throwUnavailable = false,
  });

  /// 预设回调；null 表示模拟用户取消。
  final Uri? callbackResult;

  /// [isSupported] 返回值。
  final bool supported;

  /// true 表示模拟「组件不可用」。
  final bool throwUnavailable;

  /// 最近一次 launch 收到的授权 URL（断言参数用）。
  Uri? lastAuthorizeUrl;

  /// 最近一次 launch 收到的回调 scheme（断言参数用）。
  String? lastCallbackScheme;

  /// launch 被调用次数。
  int launchCount = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    launchCount++;
    lastAuthorizeUrl = authorizeUrl;
    lastCallbackScheme = callbackScheme;
    if (throwUnavailable) {
      throw const OAuthLauncherUnavailableException();
    }
    final result = callbackResult;
    if (result == null) {
      throw const OAuthCancelledException();
    }
    return result;
  }
}
