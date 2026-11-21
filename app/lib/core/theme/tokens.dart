/// 设计 token —— 取自 prototype/index.html `:root` 与关键布局尺寸（设计真源）。
///
/// 颜色分两层：
/// - [RCColorScheme]：**主题感知的语义色**，挂在 `ThemeData.extensions` 上，
///   深/浅两套；页面里用 `context.rc.bg` 取当前亮度的值。
/// - [RCColors]：浅色常量，保留给既有 100+ 处 `RCColors.xxx` 引用继续编译，
///   在浅色主题下与 `context.rc.xxx` 完全等价；**新代码请用 `context.rc`**
///   （否则深色模式下会拿到浅色值，出现白底黑字的问题）。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 语义色（浅色常量，等同 `RCColorScheme.light`）。
///
/// 只保证浅色主题下正确；需要跟随深色模式的地方改用 `context.rc`。
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

  /// 已连接但未录音（待机）的胶囊圆点：橙=没在运行，绿=正在录音。
  static const warn = Color(0xFFFF9500);
  static const danger = Color(0xFFFF3B30);

  /// 看门狗判定掉线后自动重连中：蓝点。重连一次失败即回灰（无设备）。
  static const info = Color(0xFF007AFF);
}

abstract final class RCDims {
  static const narrowHeader = 52.0;
  static const wideChrome = 56.0;
  static const wideBreakpoint = 720.0;

  /// 设置页开关行最小高度（iOS 44pt / Android 48dp 触控下限之上留余量）。
  static const settingRow = 52.0;

  /// 全页面底部统一呼吸留白（无论内容是否铺满一屏，滚动到底部均保留空间）。
  static const pageBottomPad = 48.0;
}

/// 主题感知的语义色表。
///
/// 用法：`context.rc.bg` / `context.rc.label` / `context.rc.sep` …
/// 通过 `ThemeData.extensions` 挂载，由 [buildRCTheme] / [buildRCDarkTheme]
/// 分别注入浅色与深色取值；不依赖任何全局状态。
@immutable
class RCColorScheme extends ThemeExtension<RCColorScheme> {
  const RCColorScheme({
    required this.brightness,
    required this.bg,
    required this.card,
    required this.label,
    required this.ink,
    required this.sec,
    required this.sep,
    required this.ax,
    required this.ok,
    required this.okInk,
    required this.danger,
    this.warn = RCColors.warn,
    this.info = RCColors.info,
  });

  /// 浅色：与 [RCColors] 常量一一对应（值相同，便于老代码平滑迁移）。
  static const light = RCColorScheme(
    brightness: Brightness.light,
    bg: RCColors.bg,
    card: RCColors.card,
    label: RCColors.label,
    ink: RCColors.ink,
    sec: RCColors.sec,
    sep: RCColors.sep,
    ax: RCColors.ax,
    ok: RCColors.ok,
    okInk: RCColors.okInk,
    danger: RCColors.danger,
    warn: RCColors.warn,
    info: RCColors.info,
  );

  /// 深色：背景近黑、正文高对比、分隔线弱化。
  ///
  /// 对比度（相对 `bg`）：`label` ≈ 17:1、`ink` ≈ 13:1、`sec` ≈ 7.2:1，
  /// 均高于 WCAG AA 正文 4.5:1 的要求。
  static const dark = RCColorScheme(
    brightness: Brightness.dark,
    bg: Color(0xFF0E0E10),
    card: Color(0xFF1A1A1D),
    label: Color(0xFFF5F5F7),
    ink: Color(0xFFD4D4D8),
    sec: Color(0xFFA0A0A6),
    sep: Color(0xFF2C2C2F),
    ax: Color(0xFF4B4B50),
    ok: Color(0xFF30D158),
    okInk: Color(0xFF6FDD8B),
    danger: Color(0xFFFF453A),
    warn: Color(0xFFFF9F0A),
    info: Color(0xFF0A84FF),
  );

  /// 当前亮度（供需要按亮/暗做微调的组件判断）。
  final Brightness brightness;

  /// 页面底色。
  final Color bg;

  /// 卡片/分组容器底色。
  final Color card;

  /// 标题与高强调文字。
  final Color label;

  /// 正文。
  final Color ink;

  /// 次要说明文字。
  final Color sec;

  /// 分隔线。
  final Color sep;

  /// 禁用/弱化元素（关闭态开关轨道等）。
  final Color ax;

  /// 强调色（成功/在线）。
  final Color ok;

  /// 强调色上的文字（深色底上的绿字）。
  final Color okInk;

  /// 警示色。
  final Color danger;

  /// 待机/提醒橙色。
  final Color warn;

  /// 状态信息蓝色。
  final Color info;

  bool get isDark => brightness == Brightness.dark;

  /// 开关轨道颜色：开 = 墨色（原型 `.sw.on{background:var(--label)}`），关 = 弱化灰。
  Color get switchTrackOn => label;

  /// 开关滑块颜色：浅色轨道上用白，深色模式的开态轨道是近白，滑块反过来用底色。
  Color get switchThumb => isDark ? bg : Colors.white;

  /// 主操作实心按钮（背景为 `label`）上的前景文字色。
  Color get onLabel => isDark ? bg : Colors.white;

  @override
  RCColorScheme copyWith({
    Brightness? brightness,
    Color? bg,
    Color? card,
    Color? label,
    Color? ink,
    Color? sec,
    Color? sep,
    Color? ax,
    Color? ok,
    Color? okInk,
    Color? danger,
    Color? warn,
    Color? info,
  }) {
    return RCColorScheme(
      brightness: brightness ?? this.brightness,
      bg: bg ?? this.bg,
      card: card ?? this.card,
      label: label ?? this.label,
      ink: ink ?? this.ink,
      sec: sec ?? this.sec,
      sep: sep ?? this.sep,
      ax: ax ?? this.ax,
      ok: ok ?? this.ok,
      okInk: okInk ?? this.okInk,
      danger: danger ?? this.danger,
      warn: warn ?? this.warn,
      info: info ?? this.info,
    );
  }

  @override
  RCColorScheme lerp(ThemeExtension<RCColorScheme>? other, double t) {
    if (other is! RCColorScheme) return this;
    return RCColorScheme(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      label: Color.lerp(label, other.label, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      sec: Color.lerp(sec, other.sec, t)!,
      sep: Color.lerp(sep, other.sep, t)!,
      ax: Color.lerp(ax, other.ax, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      okInk: Color.lerp(okInk, other.okInk, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      info: Color.lerp(info, other.info, t)!,
    );
  }
}

/// 取当前主题的语义色：`context.rc.label`。
///
/// 主题里没挂 [RCColorScheme] 时（例如测试里直接 `MaterialApp(home: ...)`
/// 用默认主题），回退到浅色常量而不是抛异常——样式降级但页面不崩。
extension RCContext on BuildContext {
  RCColorScheme get rc =>
      Theme.of(this).extension<RCColorScheme>() ?? RCColorScheme.light;
}

/// 字体回退链。
///
/// 不再写死 `fontFamily: '.SF Pro Text'`：Android 没有该字体，写死会让整棵
/// 文本树回退到不存在的字体族（字体渲染异常/告警）。改成「不指定 fontFamily，
/// 由各平台系统字体接管（iOS = SF Pro，Android = Roboto / 思源）+ 中文回退链」。
const List<String> rcFontFallback = <String>[
  'SF Pro Text', // iOS/macOS 系统字体（存在则优先，纯字体匹配，不影响别的平台）
  'PingFang SC', // iOS/macOS 中文
  'Noto Sans CJK SC', // Android 中文常见名
  'Source Han Sans SC',
  'Roboto', // Android 拉丁
  'sans-serif', // 通用兜底
];

ThemeData buildRCTheme() => _buildTheme(RCColorScheme.light);

/// 深色主题：同一套语义色，深色取值。
///
/// 接线方式（`lib/main.dart` 不在本任务改动范围，需另行接）：
/// `MaterialApp(theme: buildRCTheme(), darkTheme: buildRCDarkTheme())`；
/// 不设 `themeMode` 时默认跟随系统。
ThemeData buildRCDarkTheme() => _buildTheme(RCColorScheme.dark);

ThemeData _buildTheme(RCColorScheme scheme) {
  final dark = scheme.isDark;
  final base = dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: scheme.label,
      onPrimary: scheme.onLabel,
      secondary: scheme.ok,
      surface: scheme.card,
      onSurface: scheme.label,
    ),
    dividerColor: scheme.sep,
    splashFactory: NoSplash.splashFactory,
    extensions: <ThemeExtension<dynamic>>[scheme],
    textTheme: base.textTheme.apply(fontFamilyFallback: rcFontFallback),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamilyFallback: rcFontFallback,
    ),
    // 系统组件（AppBar / Dialog / SnackBar 等）跟随语义色，避免深色下白块
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.bg,
      foregroundColor: scheme.label,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dialogTheme: base.dialogTheme.copyWith(backgroundColor: scheme.card),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: dark ? scheme.card : const Color(0xFF2C2C2E),
      contentTextStyle: TextStyle(color: dark ? scheme.label : Colors.white),
    ),
  );
}

/// 应用级滚动行为：纵向列表在滚动时显示系统滚动条、静止后自动隐藏；横向滚动区不显示滚动条。
class RCScrollBehavior extends MaterialScrollBehavior {
  const RCScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) != Axis.vertical) {
      return child;
    }
    switch (getPlatform(context)) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return CupertinoScrollbar(
          controller: details.controller,
          thumbVisibility: false,
          child: child,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return Scrollbar(
          controller: details.controller,
          thumbVisibility: false,
          interactive: false,
          child: child,
        );
    }
  }
}
