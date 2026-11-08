/// 设计 token —— 取自 prototype/index.html `:root` 与关键布局尺寸（设计真源）。
library;

import 'package:flutter/material.dart';

abstract final class RCColors {
  static const bg = Color(0xFFFAFAF8);
  static const card = Color(0xFFFFFFFF);
  static const label = Color(0xFF1D1D1F);
  static const ink = Color(0xFF3C3C43);
  static const sec = Color(0xFF8A8A8E);
  static const sep = Color(0xFFE4E4E0);
  static const ax = Color(0xFFC9C9C4);
  static const ok = Color(0xFF34C759);
  static const okInk = Color(0xFF1F7A34);
  static const danger = Color(0xFFFF3B30);
}

abstract final class RCDims {
  static const narrowHeader = 52.0;
  static const wideChrome = 56.0;
  static const wideBreakpoint = 720.0;
}

ThemeData buildRCTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: RCColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: RCColors.label,
      secondary: RCColors.ok,
      surface: RCColors.card,
    ),
    dividerColor: RCColors.sep,
    splashFactory: NoSplash.splashFactory,
    // iOS/macOS 系统字体，Android 回退 Roboto
    textTheme: base.textTheme.apply(fontFamily: '.SF Pro Text'),
  );
}
