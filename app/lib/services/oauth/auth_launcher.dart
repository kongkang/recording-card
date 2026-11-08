/// 系统授权页启动器接缝 —— 生产用 ASWebAuthenticationSession/Chrome Custom Tabs，
/// 测试注入 Fake，不拉起真实浏览器。
library;

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

abstract class AuthLauncher {
  Future<String> launch(Uri url, String callbackScheme);
}

class WebAuthLauncher implements AuthLauncher {
  const WebAuthLauncher();

  @override
  Future<String> launch(Uri url, String callbackScheme) =>
      FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackScheme,
      );
}
