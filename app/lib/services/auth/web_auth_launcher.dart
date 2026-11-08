import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'auth_exception.dart';

abstract interface class WebAuthLauncher {
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  });
}

class FlutterWebAuthLauncher implements WebAuthLauncher {
  const FlutterWebAuthLauncher();
  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: authorizeUrl.toString(),
        callbackUrlScheme: callbackScheme,
        options: const FlutterWebAuth2Options(preferEphemeral: true),
      );
      return Uri.parse(result);
    } on PlatformException catch (e) {
      if (e.code.toLowerCase().contains('cancel')) {
        throw const AuthCancelledException();
      }
      throw const AuthException('browser_unavailable', '无法启动系统授权浏览器');
    } on FormatException {
      throw const AuthException('invalid_callback', '授权回调格式无效');
    }
  }
}
