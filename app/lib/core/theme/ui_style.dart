/// 可选界面风格注册表与样式语义扩展（手机 + Apple Watch 同一套 6 种风格真源）。
///
/// ID 线协议（Dart / iOS WatchHardwareBridge / watchOS / WatchWidgets 全端一致）：
/// - `default`     ：静纸声录（Warm Paper，默认内置、跟随系统深浅色）
/// - `braun_field` ：声波仪（Braun Field）
/// - `chronos`     ：昼夜声轴（Chronos）
/// - `folio`       ：卷宗（Folio）
/// - `nocturne`    ：暗房（Nocturne，纯黑 OLED 深色）
/// - `air`         ：灵动卡片（Air）
library;

import 'package:flutter/material.dart';

/// 手机与 Apple Watch 共享的界面风格枚举。
enum RCUIStyleId {
  warmPaper('default'),
  braunField('braun_field'),
  chronos('chronos'),
  folio('folio'),
  nocturne('nocturne'),
  air('air');

  const RCUIStyleId(this.wireId);

  final String wireId;

  static RCUIStyleId fromWireId(String? raw) {
    final trimmed = raw?.trim();
    for (final v in values) {
      if (v.wireId == trimmed) return v;
    }
    return RCUIStyleId.warmPaper;
  }
}

/// 风格模板授权档位（现阶段全部为 `free`，后续新增付费档位时可直接把指定模板改为 `pro`）。
enum UIStyleTier { free, pro }

/// 供设置页模板库与 Apple-Hosted Background Assets 使用的风格元数据。
@immutable
class UIStyleDescriptor {
  const UIStyleDescriptor({
    required this.id,
    required this.name,
    required this.enName,
    required this.tagline,
    required this.watchNote,
    required this.swatchColors,
    required this.builtin,
    required this.assetPackId,
    this.tier = UIStyleTier.free,
  });

  final RCUIStyleId id;
  final String name;
  final String enName;
  final String tagline;
  final String watchNote;
  final List<Color> swatchColors;
  final bool builtin;
  final String assetPackId;
  final UIStyleTier tier;

  static const List<UIStyleDescriptor> catalog = <UIStyleDescriptor>[
    UIStyleDescriptor(
      id: RCUIStyleId.warmPaper,
      name: '静纸声录',
      enName: 'Warm Paper',
      tagline: '暖白纸感与朱红点缀，轻量无边框时间轴',
      watchNote: '表盘配哑光朱红滑停与琥珀打点',
      swatchColors: <Color>[
        Color(0xFFFAFAF8),
        Color(0xFFFFFFFF),
        Color(0xFF1D1D1F),
        Color(0xFFD94124),
      ],
      builtin: true,
      assetPackId: 'com.reai.recordingcard.style.default',
      tier: UIStyleTier.free,
    ),
    UIStyleDescriptor(
      id: RCUIStyleId.braunField,
      name: '声波仪',
      enName: 'Braun Field',
      tagline: '几何削角仪表卡、等宽刻度与信号橙物理控件',
      watchNote: '表盘配 12 格 LED 单圈计拍与橙色滑块',
      swatchColors: <Color>[
        Color(0xFFECEAE4),
        Color(0xFFF8F7F3),
        Color(0xFFFF5514),
        Color(0xFF5D7A3B),
      ],
      builtin: false,
      assetPackId: 'com.reai.recordingcard.style.braun_field',
      tier: UIStyleTier.free,
    ),
    UIStyleDescriptor(
      id: RCUIStyleId.chronos,
      name: '昼夜声轴',
      enName: 'Chronos',
      tagline: '日间极净高对比版式、精密时间轴与钴蓝标注',
      watchNote: '表盘左侧带精密分时标尺与钴蓝环',
      swatchColors: <Color>[
        Color(0xFFF5F7FB),
        Color(0xFFFFFFFF),
        Color(0xFF1D4ED8),
        Color(0xFF60A5FA),
      ],
      builtin: false,
      assetPackId: 'com.reai.recordingcard.style.chronos',
      tier: UIStyleTier.free,
    ),
    UIStyleDescriptor(
      id: RCUIStyleId.folio,
      name: '卷宗',
      enName: 'Folio',
      tagline: '宣纸米黄档案卡片、书卷衬线标题与朱砂印章',
      watchNote: '表盘为暖纸细线框与衬线读时',
      swatchColors: <Color>[
        Color(0xFFF4EFE6),
        Color(0xFFFBF8F2),
        Color(0xFFA63426),
        Color(0xFF3F3830),
      ],
      builtin: false,
      assetPackId: 'com.reai.recordingcard.style.folio',
      tier: UIStyleTier.free,
    ),
    UIStyleDescriptor(
      id: RCUIStyleId.nocturne,
      name: '暗房',
      enName: 'Nocturne',
      tagline: '纯黑零眩光暗房界面、低刺激琥珀金重点标记',
      watchNote: '表盘带实时声学频谱柱与琥珀重点峰',
      swatchColors: <Color>[
        Color(0xFF0A0B0D),
        Color(0xFF15171B),
        Color(0xFFF5A623),
        Color(0xFF30D158),
      ],
      builtin: false,
      assetPackId: 'com.reai.recordingcard.style.nocturne',
      tier: UIStyleTier.free,
    ),
    UIStyleDescriptor(
      id: RCUIStyleId.air,
      name: '灵动卡片',
      enName: 'Air',
      tagline: '鼠尾草薄荷柔和层叠圆角、呼吸留白与珊瑚点亮',
      watchNote: '表盘顶部带随状态流转的柔和微光',
      swatchColors: <Color>[
        Color(0xFFF1F6F5),
        Color(0xFFFFFFFF),
        Color(0xFF1B7A6B),
        Color(0xFFE85C42),
      ],
      builtin: false,
      assetPackId: 'com.reai.recordingcard.style.air',
      tier: UIStyleTier.free,
    ),
  ];

  static UIStyleDescriptor byId(RCUIStyleId id) {
    for (final d in catalog) {
      if (d.id == id) return d;
    }
    return catalog.first;
  }
}

/// 风格化的形状、强调色、字排与双端签名参数，随 `ThemeData.extensions` 注入整棵界面树。
@immutable
class RCStyleSpec extends ThemeExtension<RCStyleSpec> {
  const RCStyleSpec({
    required this.styleId,
    required this.accent,
    required this.accentFg,
    required this.accentSoft,
    required this.surfaceSubtle,
    required this.cardRadius,
    required this.pillRadius,
    required this.eventAsCard,
    required this.cardShadow,
    required this.serifTitles,
    required this.monoMeta,
    required this.railColor,
    required this.railNodeColor,
    required this.railNodeSquare,
    required this.os1OrbColors,
    required this.os1OrbLabelColor,
    required this.os1HerGradient,
    required this.os1ChatBg,
    required this.watchBg,
    required this.watchAccent,
    required this.watchStartBg,
    required this.watchStopBg,
    required this.watchBattColor,
  });

  final RCUIStyleId styleId;
  final Color accent;
  final Color accentFg;
  final Color accentSoft;
  final Color surfaceSubtle;
  final double cardRadius;
  final double pillRadius;

  /// 普通时间轴事件行是否独立成卡：
  /// `warmPaper` 与 `chronos` 为 `false`（严格无底板行，保留默认验收基线），
  /// `braunField` / `folio` / `nocturne` / `air` 为 `true`。
  final bool eventAsCard;
  final List<BoxShadow>? cardShadow;
  final bool serifTitles;
  final bool monoMeta;
  final Color railColor;
  final Color railNodeColor;
  final bool railNodeSquare;
  final List<Color> os1OrbColors;
  final Color os1OrbLabelColor;
  final List<Color> os1HerGradient;
  final Color os1ChatBg;

  // Watch 迷你预览真源颜色
  final Color watchBg;
  final Color watchAccent;
  final Color watchStartBg;
  final Color watchStopBg;
  final Color watchBattColor;

  static const warmPaper = RCStyleSpec(
    styleId: RCUIStyleId.warmPaper,
    accent: Color(0xFF1D1D1F),
    accentFg: Color(0xFFFFFFFF),
    accentSoft: Color(0x141D1D1F),
    surfaceSubtle: Color(0xFFF3F3EF),
    cardRadius: 12,
    pillRadius: 999,
    eventAsCard: false,
    cardShadow: null,
    serifTitles: false,
    monoMeta: false,
    railColor: Color(0xFFE4E4E0),
    railNodeColor: Color(0xFFC9C9C4),
    railNodeSquare: false,
    os1OrbColors: <Color>[
      Color(0xFFFFB57A),
      Color(0xFFEF653F),
      Color(0xFFC5361B),
    ],
    os1OrbLabelColor: Color(0xFFC5361B),
    os1HerGradient: <Color>[
      Color(0xFFEE6F4C),
      Color(0xFFD44A32),
      Color(0xFFB02E1C),
    ],
    os1ChatBg: Color(0xFFF5F4F0),
    watchBg: Color(0xFF090908),
    watchAccent: Color(0xFFF2A23C),
    watchStartBg: Color(0xFF2DC653),
    watchStopBg: Color(0xFFE85035),
    watchBattColor: Color(0xFF2DC653),
  );

  static const warmPaperDark = RCStyleSpec(
    styleId: RCUIStyleId.warmPaper,
    accent: Color(0xFFF5F5F7),
    accentFg: Color(0xFF0E0E10),
    accentSoft: Color(0x22F5F5F7),
    surfaceSubtle: Color(0xFF1F1F23),
    cardRadius: 12,
    pillRadius: 999,
    eventAsCard: false,
    cardShadow: null,
    serifTitles: false,
    monoMeta: false,
    railColor: Color(0xFF2C2C2F),
    railNodeColor: Color(0xFF4B4B50),
    railNodeSquare: false,
    os1OrbColors: <Color>[
      Color(0xFFFFB57A),
      Color(0xFFEF653F),
      Color(0xFFC5361B),
    ],
    os1OrbLabelColor: Color(0xFFFF8F73),
    os1HerGradient: <Color>[
      Color(0xFFEE6F4C),
      Color(0xFFD44A32),
      Color(0xFFB02E1C),
    ],
    os1ChatBg: Color(0xFF0E0E10),
    watchBg: Color(0xFF090908),
    watchAccent: Color(0xFFF2A23C),
    watchStartBg: Color(0xFF2DC653),
    watchStopBg: Color(0xFFE85035),
    watchBattColor: Color(0xFF2DC653),
  );

  static const braunField = RCStyleSpec(
    styleId: RCUIStyleId.braunField,
    accent: Color(0xFFFF5514),
    accentFg: Color(0xFFFFFFFF),
    accentSoft: Color(0x1AFF5514),
    surfaceSubtle: Color(0xFFE3E0D8),
    cardRadius: 8,
    pillRadius: 6,
    eventAsCard: true,
    cardShadow: null,
    serifTitles: false,
    monoMeta: true,
    railColor: Color(0xFFD4D1C8),
    railNodeColor: Color(0xFFFF5514),
    railNodeSquare: true,
    os1OrbColors: <Color>[
      Color(0xFFFF8B5C),
      Color(0xFFFF5514),
      Color(0xFFB83505),
    ],
    os1OrbLabelColor: Color(0xFFFF5514),
    os1HerGradient: <Color>[
      Color(0xFF1C1D1B),
      Color(0xFF141513),
      Color(0xFF0D0E0C),
    ],
    os1ChatBg: Color(0xFF141513),
    watchBg: Color(0xFF0D0E0D),
    watchAccent: Color(0xFFFF5514),
    watchStartBg: Color(0xFFFF5514),
    watchStopBg: Color(0xFFFF5514),
    watchBattColor: Color(0xFFA3B86C),
  );

  static const chronos = RCStyleSpec(
    styleId: RCUIStyleId.chronos,
    accent: Color(0xFF1D4ED8),
    accentFg: Color(0xFFFFFFFF),
    accentSoft: Color(0x141D4ED8),
    surfaceSubtle: Color(0xFFE9EFF8),
    cardRadius: 14,
    pillRadius: 999,
    eventAsCard: false,
    cardShadow: <BoxShadow>[
      BoxShadow(color: Color(0x0A0F172A), blurRadius: 10, offset: Offset(0, 3)),
    ],
    serifTitles: true,
    monoMeta: false,
    railColor: Color(0xFFCBD5E1),
    railNodeColor: Color(0xFF1D4ED8),
    railNodeSquare: false,
    os1OrbColors: <Color>[
      Color(0xFF60A5FA),
      Color(0xFF2563EB),
      Color(0xFF1E3A8A),
    ],
    os1OrbLabelColor: Color(0xFF1D4ED8),
    os1HerGradient: <Color>[
      Color(0xFF1E4FD8),
      Color(0xFF173A9C),
      Color(0xFF0F266A),
    ],
    os1ChatBg: Color(0xFFFAFAFC),
    watchBg: Color(0xFF050811),
    watchAccent: Color(0xFF60A5FA),
    watchStartBg: Color(0xFF2563EB),
    watchStopBg: Color(0xFFEF4444),
    watchBattColor: Color(0xFF60A5FA),
  );

  static const folio = RCStyleSpec(
    styleId: RCUIStyleId.folio,
    accent: Color(0xFFA62B21),
    accentFg: Color(0xFFF7F2E8),
    accentSoft: Color(0x14A62B21),
    surfaceSubtle: Color(0xFFEFE8D8),
    cardRadius: 6,
    pillRadius: 6,
    eventAsCard: true,
    cardShadow: null,
    serifTitles: true,
    monoMeta: false,
    railColor: Color(0xFFDDD4C3),
    railNodeColor: Color(0xFFA62B21),
    railNodeSquare: true,
    os1OrbColors: <Color>[
      Color(0xFFE07A68),
      Color(0xFFB83A2A),
      Color(0xFF7A2016),
    ],
    os1OrbLabelColor: Color(0xFFA62B21),
    os1HerGradient: <Color>[
      Color(0xFF381C18),
      Color(0xFF231210),
      Color(0xFF160B09),
    ],
    os1ChatBg: Color(0xFFF5F0E6),
    watchBg: Color(0xFF0D0B09),
    watchAccent: Color(0xFFD96552),
    watchStartBg: Color(0xFF2DC653),
    watchStopBg: Color(0xFFC83E2B),
    watchBattColor: Color(0xFFD9C7AE),
  );

  static const nocturne = RCStyleSpec(
    styleId: RCUIStyleId.nocturne,
    accent: Color(0xFFF5A623),
    accentFg: Color(0xFF111214),
    accentSoft: Color(0x24F5A623),
    surfaceSubtle: Color(0xFF1D2026),
    cardRadius: 12,
    pillRadius: 999,
    eventAsCard: true,
    cardShadow: null,
    serifTitles: false,
    monoMeta: true,
    railColor: Color(0xFF1E222B),
    railNodeColor: Color(0xFFF5A623),
    railNodeSquare: false,
    os1OrbColors: <Color>[
      Color(0xFFFFD07A),
      Color(0xFFF5A623),
      Color(0xFFB56E08),
    ],
    os1OrbLabelColor: Color(0xFFF5A623),
    os1HerGradient: <Color>[
      Color(0xFF14161D),
      Color(0xFF07080A),
      Color(0xFF030405),
    ],
    os1ChatBg: Color(0xFF07080A),
    watchBg: Color(0xFF000000),
    watchAccent: Color(0xFFF5A623),
    watchStartBg: Color(0xFF2DC653),
    watchStopBg: Color(0xFFFF453A),
    watchBattColor: Color(0xFFF5A623),
  );

  static const air = RCStyleSpec(
    styleId: RCUIStyleId.air,
    accent: Color(0xFF115E63),
    accentFg: Color(0xFFFFFFFF),
    accentSoft: Color(0x16115E63),
    surfaceSubtle: Color(0xFFE5EFED),
    cardRadius: 20,
    pillRadius: 999,
    eventAsCard: true,
    cardShadow: <BoxShadow>[
      BoxShadow(color: Color(0x0D0F172A), blurRadius: 20, offset: Offset(0, 6)),
    ],
    serifTitles: false,
    monoMeta: false,
    railColor: Color(0xFFDCE5EC),
    railNodeColor: Color(0xFF115E63),
    railNodeSquare: false,
    os1OrbColors: <Color>[
      Color(0xFFFFA994),
      Color(0xFFE85D3F),
      Color(0xFFA93026),
    ],
    os1OrbLabelColor: Color(0xFFE85D3F),
    os1HerGradient: <Color>[
      Color(0xFFE85D3F),
      Color(0xFFC9412C),
      Color(0xFFA93026),
    ],
    os1ChatBg: Color(0xFFC9412C),
    watchBg: Color(0xFF060A09),
    watchAccent: Color(0xFF6CD4B9),
    watchStartBg: Color(0xFF115E63),
    watchStopBg: Color(0xFFE85C42),
    watchBattColor: Color(0xFF6CD4B9),
  );

  static RCStyleSpec of(
    RCUIStyleId id, {
    Brightness brightness = Brightness.light,
  }) => switch (id) {
    RCUIStyleId.warmPaper =>
      brightness == Brightness.dark ? warmPaperDark : warmPaper,
    RCUIStyleId.braunField => braunField,
    RCUIStyleId.chronos => chronos,
    RCUIStyleId.folio => folio,
    RCUIStyleId.nocturne => nocturne,
    RCUIStyleId.air => air,
  };

  @override
  RCStyleSpec copyWith({
    RCUIStyleId? styleId,
    Color? accent,
    Color? accentFg,
    Color? accentSoft,
    Color? surfaceSubtle,
    double? cardRadius,
    double? pillRadius,
    bool? eventAsCard,
    List<BoxShadow>? cardShadow,
    bool? serifTitles,
    bool? monoMeta,
    Color? railColor,
    Color? railNodeColor,
    bool? railNodeSquare,
    List<Color>? os1OrbColors,
    Color? os1OrbLabelColor,
    List<Color>? os1HerGradient,
    Color? os1ChatBg,
    Color? watchBg,
    Color? watchAccent,
    Color? watchStartBg,
    Color? watchStopBg,
    Color? watchBattColor,
  }) {
    return RCStyleSpec(
      styleId: styleId ?? this.styleId,
      accent: accent ?? this.accent,
      accentFg: accentFg ?? this.accentFg,
      accentSoft: accentSoft ?? this.accentSoft,
      surfaceSubtle: surfaceSubtle ?? this.surfaceSubtle,
      cardRadius: cardRadius ?? this.cardRadius,
      pillRadius: pillRadius ?? this.pillRadius,
      eventAsCard: eventAsCard ?? this.eventAsCard,
      cardShadow: cardShadow ?? this.cardShadow,
      serifTitles: serifTitles ?? this.serifTitles,
      monoMeta: monoMeta ?? this.monoMeta,
      railColor: railColor ?? this.railColor,
      railNodeColor: railNodeColor ?? this.railNodeColor,
      railNodeSquare: railNodeSquare ?? this.railNodeSquare,
      os1OrbColors: os1OrbColors ?? this.os1OrbColors,
      os1OrbLabelColor: os1OrbLabelColor ?? this.os1OrbLabelColor,
      os1HerGradient: os1HerGradient ?? this.os1HerGradient,
      os1ChatBg: os1ChatBg ?? this.os1ChatBg,
      watchBg: watchBg ?? this.watchBg,
      watchAccent: watchAccent ?? this.watchAccent,
      watchStartBg: watchStartBg ?? this.watchStartBg,
      watchStopBg: watchStopBg ?? this.watchStopBg,
      watchBattColor: watchBattColor ?? this.watchBattColor,
    );
  }

  @override
  RCStyleSpec lerp(ThemeExtension<RCStyleSpec>? other, double t) {
    if (other is! RCStyleSpec) return this;
    final pickOther = t >= 0.5;
    return RCStyleSpec(
      styleId: pickOther ? other.styleId : styleId,
      accent: Color.lerp(accent, other.accent, t)!,
      accentFg: Color.lerp(accentFg, other.accentFg, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      surfaceSubtle: Color.lerp(surfaceSubtle, other.surfaceSubtle, t)!,
      cardRadius: lerpDouble(cardRadius, other.cardRadius, t),
      pillRadius: lerpDouble(pillRadius, other.pillRadius, t),
      eventAsCard: pickOther ? other.eventAsCard : eventAsCard,
      cardShadow: pickOther ? other.cardShadow : cardShadow,
      serifTitles: pickOther ? other.serifTitles : serifTitles,
      monoMeta: pickOther ? other.monoMeta : monoMeta,
      railColor: Color.lerp(railColor, other.railColor, t)!,
      railNodeColor: Color.lerp(railNodeColor, other.railNodeColor, t)!,
      railNodeSquare: pickOther ? other.railNodeSquare : railNodeSquare,
      os1OrbColors: _lerpColors(os1OrbColors, other.os1OrbColors, t),
      os1OrbLabelColor:
          Color.lerp(os1OrbLabelColor, other.os1OrbLabelColor, t)!,
      os1HerGradient: _lerpColors(os1HerGradient, other.os1HerGradient, t),
      os1ChatBg: Color.lerp(os1ChatBg, other.os1ChatBg, t)!,
      watchBg: Color.lerp(watchBg, other.watchBg, t)!,
      watchAccent: Color.lerp(watchAccent, other.watchAccent, t)!,
      watchStartBg: Color.lerp(watchStartBg, other.watchStartBg, t)!,
      watchStopBg: Color.lerp(watchStopBg, other.watchStopBg, t)!,
      watchBattColor: Color.lerp(watchBattColor, other.watchBattColor, t)!,
    );
  }

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;

  static List<Color> _lerpColors(List<Color> a, List<Color> b, double t) {
    final len = a.length < b.length ? a.length : b.length;
    return <Color>[for (var i = 0; i < len; i++) Color.lerp(a[i], b[i], t)!];
  }
}

/// 从 BuildContext 读取当前界面风格的拓展参数：`context.rcStyle`。
extension RCStyleContext on BuildContext {
  RCStyleSpec get rcStyle =>
      Theme.of(this).extension<RCStyleSpec>() ?? RCStyleSpec.warmPaper;
}
