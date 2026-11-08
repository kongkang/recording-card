import 'package:flutter/material.dart';

/// 测试用无动画页面转场：Navigator pages 推入/弹出立即到位，
/// finder/drag 不必等 300ms 转场（真机仍是 Cupertino 转场 + 边缘返回手势）。
class NoAnimPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoAnimPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

ThemeData testTheme() => ThemeData(
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values) p: const NoAnimPageTransitionsBuilder(),
      }),
    );
