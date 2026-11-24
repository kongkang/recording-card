/// Non-default style app headers, brand icon mark, and 4-slot bottom/floating navigation chrome
/// matching `design-demos/dir-1.html` through `design-demos/dir-5.html`.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/store/app_store.dart';
import '../../core/store/device_store.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/store_scope.dart';

/// Whether [styleId] uses a floating bottom dock that overlays scrolling content.
bool isFloatingDockStyle(RCUIStyleId styleId) => switch (styleId) {
  RCUIStyleId.braunField || RCUIStyleId.nocturne || RCUIStyleId.air => true,
  RCUIStyleId.warmPaper || RCUIStyleId.chronos || RCUIStyleId.folio => false,
};

/// Extra bottom padding inside scrollable views so items scroll cleanly above floating docks.
double styledListBottomPadding(
  RCUIStyleId styleId, {
  double bottomInset = 0,
}) => isFloatingDockStyle(styleId)
    ? 110.0 + bottomInset
    : RCDims.pageBottomPad + bottomInset;

/// Active clock string matching `DeviceStore` real recording timers.
String activeRecordingClock(DeviceStore? device) {
  if (device == null) return '0:00:00';
  if (device.isRecording) return device.recClockText;
  if (device.isWatchFallbackRecording) return device.watchFailoverClockText;
  if (device.isPhoneRecording) {
    final s = device.phoneRecSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  return '00:00:00';
}

bool isAnyRecording(DeviceStore? device) =>
    device != null &&
    (device.isRecording ||
        device.isPhoneRecording ||
        device.isWatchFallbackRecording);

String capsuleStatusLabel(DeviceStore device, RCUIStyleId styleId) {
  if (device.linkState == LinkState.reconnecting) return '连接中…';
  if (!device.isConnected) {
    if (device.isWatchFallbackRecording) return '手表录音中';
    if (device.isPhoneRecording) return '本机录音中';
    return switch (styleId) {
      RCUIStyleId.braunField => '连接录音卡',
      RCUIStyleId.folio => '连接硬件',
      _ => '连接设备',
    };
  }
  if (device.isRecording) return '录音中';
  final devName = device.connectedName?.trim() ?? '';
  if (devName.isNotEmpty) return devName;
  return '已连接';
}

/// Vector rendition of `app/assets/icon/app_icon.svg`.
class RCAppIconMark extends StatelessWidget {
  const RCAppIconMark({super.key, this.size = 22, this.radius = 6});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _RCAppIconPainter()),
      ),
    );
  }
}

class _RCAppIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFDFDFB), Color(0xFFEFEFE8)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    final cardRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.158, h * 0.26, w * 0.684, h * 0.478),
      Radius.circular(w * 0.094),
    );
    canvas.drawRRect(cardRect, Paint()..color = const Color(0xFF1D1D1F));

    final wavePaint = Paint()..color = const Color(0xFFFAFAF8);
    const bars = [
      (0.252, 0.441, 0.117),
      (0.361, 0.389, 0.223),
      (0.471, 0.351, 0.299),
      (0.580, 0.389, 0.223),
      (0.689, 0.441, 0.117),
    ];
    for (final (x, y, bh) in bars) {
      final bw = w * 0.059;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * x, h * y, bw, h * bh),
          Radius.circular(bw / 2),
        ),
        wavePaint,
      );
    }
    canvas.drawCircle(
      Offset(w * 0.76, h * 0.322),
      w * 0.039,
      Paint()..color = const Color(0xFFFF3B30),
    );
  }

  @override
  bool shouldRepaint(_RCAppIconPainter oldDelegate) => false;
}

/// Per-style top header for all 5 non-default styles.
class StyledAppHeader extends StatelessWidget {
  const StyledAppHeader({
    super.key,
    required this.height,
    required this.topInset,
    required this.wide,
    required this.device,
    required this.onTapTop,
  });

  final double height;
  final double topInset;
  final bool wide;
  final DeviceStore device;
  final VoidCallback onTapTop;

  @override
  Widget build(BuildContext context) {
    final s = context.rcStyle;
    final store = StoreScope.of(context);
    final sub = !wide && store.subStack.isNotEmpty;

    final Color bg;
    final Border? bottomBorder;
    switch (s.styleId) {
      case RCUIStyleId.braunField:
        bg = const Color(0xFFEFEFE9);
        bottomBorder = null;
      case RCUIStyleId.chronos:
        bg = const Color(0xFFFAFAFC);
        bottomBorder = null;
      case RCUIStyleId.folio:
        bg = const Color(0xFFF5F0E6);
        bottomBorder = const Border(
          bottom: BorderSide(color: Color(0xFF1C1917), width: 1.0),
        );
      case RCUIStyleId.nocturne:
        bg = const Color(0xFF07080A);
        bottomBorder = const Border(
          bottom: BorderSide(color: Color(0xFF1E222B), width: 1.0),
        );
      case RCUIStyleId.air:
        bg = const Color(0xFFF2F5F8);
        bottomBorder = null;
      case RCUIStyleId.warmPaper:
        bg = context.rc.bg;
        bottomBorder = Border(bottom: BorderSide(color: context.rc.sep));
    }

    return Container(
      key: s.styleId == RCUIStyleId.folio
          ? const Key('folio-masthead')
          : const Key('app-header'),
      height: height,
      padding: EdgeInsets.fromLTRB(18, topInset, 18, 0),
      decoration: BoxDecoration(color: bg, border: bottomBorder),
      child: Row(
        children: [
          if (sub) ...[
            _buildBackButton(s, store),
            Expanded(
              child: GestureDetector(
                key: const Key('header-tap-top'),
                behavior: HitTestBehavior.opaque,
                onTap: onTapTop,
                child: const SizedBox.expand(),
              ),
            ),
          ] else
            Expanded(
              child: GestureDetector(
                key: const Key('header-tap-top'),
                behavior: HitTestBehavior.opaque,
                onTap: onTapTop,
                child: _buildBrandTitle(s, store),
              ),
            ),
          _buildRightAction(context, s, store, sub),
        ],
      ),
    );
  }

  Widget _buildBackButton(RCStyleSpec s, AppStore store) {
    final fg = switch (s.styleId) {
      RCUIStyleId.braunField => const Color(0xFF161614),
      RCUIStyleId.chronos => const Color(0xFF1D4ED8),
      RCUIStyleId.folio => const Color(0xFF1C1917),
      RCUIStyleId.nocturne => const Color(0xFFFBBF24),
      RCUIStyleId.air => const Color(0xFF0F172A),
      RCUIStyleId.warmPaper => const Color(0xFF1D1D1F),
    };
    if (s.styleId == RCUIStyleId.air) {
      return TextButton(
        key: const Key('crumb-back'),
        onPressed: store.goBack,
        style: TextButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chevron_left, size: 17),
            Text(
              store.crumbDest,
              key: const Key('crumb-dest'),
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }
    return TextButton(
      key: const Key('crumb-back'),
      onPressed: store.goBack,
      style: TextButton.styleFrom(
        foregroundColor: fg,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chevron_left, size: 18),
          Text(
            store.crumbDest,
            key: const Key('crumb-dest'),
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandTitle(RCStyleSpec s, AppStore store) {
    final titleText = switch (s.styleId) {
      RCUIStyleId.braunField => '录音卡',
      RCUIStyleId.chronos => '昼夜声轴',
      RCUIStyleId.folio => '声录日刊',
      RCUIStyleId.nocturne => '录音卡',
      RCUIStyleId.air =>
        store.rootTab == RootTab.setting ? '设备与设置' : '录音卡',
      RCUIStyleId.warmPaper => '录音卡',
    };
    final titleColor = s.styleId == RCUIStyleId.nocturne
        ? const Color(0xFFF3F4F6)
        : const Color(0xFF161614);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!(s.styleId == RCUIStyleId.air && store.rootTab == RootTab.setting)) ...[
          RCAppIconMark(
            size: s.styleId == RCUIStyleId.nocturne ? 21 : 22,
            radius: s.styleId == RCUIStyleId.folio || s.styleId == RCUIStyleId.nocturne
                ? 5
                : 6,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            titleText,
            key: const Key('app-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: s.styleId == RCUIStyleId.air ? 17.5 : 16.5,
              fontWeight: s.styleId == RCUIStyleId.folio
                  ? FontWeight.w900
                  : FontWeight.w800,
              color: titleColor,
              fontFamilyFallback: s.serifTitles
                  ? rcSerifFontFallback
                  : rcFontFallback,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRightAction(
    BuildContext context,
    RCStyleSpec s,
    AppStore store,
    bool sub,
  ) {
    if (s.styleId == RCUIStyleId.air && !sub && store.rootTab == RootTab.timeline) {
      return ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final isSel = store.selMode;
          return Material(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              key: const Key('summary-start'),
              borderRadius: BorderRadius.circular(999),
              onTap: isSel ? store.cancelSummary : store.startSummary,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  isSel ? '取消' : '多选总结',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return ListenableBuilder(
      listenable: device,
      builder: (context, _) => _StyledCapsule(
        styleId: s.styleId,
        device: device,
      ),
    );
  }
}

class _StyledCapsule extends StatelessWidget {
  const _StyledCapsule({required this.styleId, required this.device});

  final RCUIStyleId styleId;
  final DeviceStore device;

  @override
  Widget build(BuildContext context) {
    final rec = isAnyRecording(device);
    final connected = device.isConnected;
    final label = capsuleStatusLabel(device, styleId);
    final clock = rec ? activeRecordingClock(device) : '';

    final Color bg;
    final Color fg;
    final Border? border;
    final Color dotColor;
    final bool squareDot;
    final bool showClock;

    switch (styleId) {
      case RCUIStyleId.braunField:
        bg = Colors.white;
        fg = const Color(0xFF161614);
        border = Border.all(color: const Color(0xFF22221E), width: 1.5);
        dotColor = rec
            ? const Color(0xFFE12D1C)
            : (connected ? const Color(0xFF15803D) : const Color(0xFF8A8980));
        squareDot = false;
        showClock = false;
      case RCUIStyleId.chronos:
        bg = Colors.white;
        fg = const Color(0xFF111318);
        border = Border.all(color: const Color(0xFFE2E6EE), width: 1.0);
        dotColor = rec
            ? const Color(0xFFB91C1C)
            : (connected ? const Color(0xFF15803D) : const Color(0xFF94A3B8));
        squareDot = false;
        showClock = rec;
      case RCUIStyleId.folio:
        bg = rec ? const Color(0xFFA62B21) : Colors.white;
        fg = rec ? const Color(0xFFF7F2E8) : const Color(0xFF1C1917);
        border = Border.all(
          color: rec ? const Color(0xFFA62B21) : const Color(0xFFDDD4C3),
          width: 1.0,
        );
        dotColor = rec
            ? const Color(0xFFF7F2E8)
            : (connected ? const Color(0xFF15803D) : const Color(0xFF8A7F72));
        squareDot = false;
        showClock = rec;
      case RCUIStyleId.nocturne:
        bg = const Color(0xFF12141A);
        fg = const Color(0xFFF3F4F6);
        border = Border.all(color: const Color(0xFF242934), width: 1.0);
        dotColor = rec
            ? const Color(0xFFEF4444)
            : (connected ? const Color(0xFF22C55E) : const Color(0xFF6B7280));
        squareDot = false;
        showClock = rec;
      case RCUIStyleId.air:
        bg = Colors.white;
        fg = const Color(0xFF0F172A);
        border = Border.all(color: const Color(0xFFDCE5EC), width: 1.0);
        dotColor = rec
            ? const Color(0xFFE85D3F)
            : (connected ? const Color(0xFF1D6F72) : const Color(0xFF94A3B8));
        squareDot = false;
        showClock = rec;
      case RCUIStyleId.warmPaper:
        bg = context.rc.card;
        fg = context.rc.label;
        border = Border.all(color: context.rc.sep);
        dotColor = rec ? context.rc.ok : context.rc.warn;
        squareDot = false;
        showClock = false;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('hw-capsule'),
        onTap: device.openSheet,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: border,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: const Key('capsule-dot'),
                width: 7.5,
                height: 7.5,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: squareDot ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: squareDot ? BorderRadius.circular(2) : null,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
              if (showClock && clock.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  clock,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontFamilyFallback: rcMonoFontFallback,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 4-slot styled bottom navigation / floating dock (`记录`, `总结`, `问答`, `设置`).
class StyledBottomNav extends StatelessWidget {
  const StyledBottomNav({
    super.key,
    required this.onOpenOs1,
    this.bottomInset = 0,
    this.height,
  });

  final VoidCallback onOpenOs1;
  final double bottomInset;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final s = context.rcStyle;
    final store = StoreScope.of(context);

    final bool onHome =
        store.rootTab == RootTab.timeline && store.filter != FeedFilter.summary;
    final bool onSummary =
        store.rootTab == RootTab.timeline && store.filter == FeedFilter.summary;
    final bool onSetting = store.rootTab == RootTab.setting;

    void goHome() {
      store.go(RootTab.timeline);
      if (store.filter == FeedFilter.summary) {
        store.setFilter(FeedFilter.all);
      }
    }

    void goSummary() {
      store.go(RootTab.timeline);
      store.setFilter(FeedFilter.summary);
    }

    void goSetting() {
      store.go(RootTab.setting);
    }

    switch (s.styleId) {
      case RCUIStyleId.braunField:
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottomInset),
          child: Container(
            key: const Key('braun-dock'),
            height: 54,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: const Color(0xFF161614),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x38000000),
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                _braunDockBtn(
                  key: const Key('nav-timeline'),
                  icon: Icons.graphic_eq_rounded,
                  label: '记录',
                  active: onHome,
                  onTap: goHome,
                ),
                const SizedBox(width: 4),
                _braunDockBtn(
                  key: const Key('nav-summary'),
                  icon: Icons.description_outlined,
                  label: '总结',
                  active: onSummary,
                  onTap: goSummary,
                ),
                const SizedBox(width: 4),
                _braunDockBtn(
                  key: const Key('nav-ai-sunrise'),
                  icon: Icons.auto_awesome_rounded,
                  label: '问答',
                  active: false,
                  onTap: onOpenOs1,
                ),
                const SizedBox(width: 4),
                _braunDockBtn(
                  key: const Key('nav-setting'),
                  icon: Icons.tune_rounded,
                  label: '设备',
                  active: onSetting,
                  onTap: goSetting,
                ),
              ],
            ),
          ),
        );

      case RCUIStyleId.nocturne:
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottomInset),
          child: Container(
            key: const Key('nocturne-thumb-dock'),
            height: 52,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF12141A),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFF262B36)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                _pillDockBtn(
                  key: const Key('nav-timeline'),
                  icon: Icons.graphic_eq_rounded,
                  label: '声录',
                  active: onHome,
                  activeBg: const Color(0xFFF5A623),
                  activeFg: const Color(0xFF111214),
                  inactiveFg: const Color(0xFF8B92A1),
                  onTap: goHome,
                ),
                const SizedBox(width: 4),
                _pillDockBtn(
                  key: const Key('nav-summary'),
                  icon: Icons.description_outlined,
                  label: '总结',
                  active: onSummary,
                  activeBg: const Color(0xFFF5A623),
                  activeFg: const Color(0xFF111214),
                  inactiveFg: const Color(0xFF8B92A1),
                  onTap: goSummary,
                ),
                const SizedBox(width: 4),
                _pillDockBtn(
                  key: const Key('nav-ai-sunrise'),
                  icon: Icons.auto_awesome_rounded,
                  label: '问答',
                  active: false,
                  activeBg: const Color(0xFFF5A623),
                  activeFg: const Color(0xFF111214),
                  inactiveFg: const Color(0xFF8B92A1),
                  onTap: onOpenOs1,
                ),
                const SizedBox(width: 4),
                _pillDockBtn(
                  key: const Key('nav-setting'),
                  icon: Icons.tune_rounded,
                  label: '设置',
                  active: onSetting,
                  activeBg: const Color(0xFFF5A623),
                  activeFg: const Color(0xFF111214),
                  inactiveFg: const Color(0xFF8B92A1),
                  onTap: goSetting,
                ),
              ],
            ),
          ),
        );

      case RCUIStyleId.air:
        return Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 12 + bottomInset),
          child: Container(
            key: const Key('air-float-nav'),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F0F172A),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.80),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white, width: 1.0),
                  ),
                  child: Row(
                    children: [
                      _pillDockBtn(
                        key: const Key('nav-timeline'),
                        icon: Icons.graphic_eq_rounded,
                        label: '记录',
                        active: onHome,
                        activeBg: const Color(0xFF0F172A),
                        activeFg: Colors.white,
                        inactiveFg: const Color(0xFF475569),
                        onTap: goHome,
                      ),
                      const SizedBox(width: 4),
                      _pillDockBtn(
                        key: const Key('nav-summary'),
                        icon: Icons.description_outlined,
                        label: '总结',
                        active: onSummary,
                        activeBg: const Color(0xFF0F172A),
                        activeFg: Colors.white,
                        inactiveFg: const Color(0xFF475569),
                        onTap: goSummary,
                      ),
                      const SizedBox(width: 4),
                      _pillDockBtn(
                        key: const Key('nav-ai-sunrise'),
                        icon: Icons.auto_awesome_rounded,
                        label: '问答',
                        active: false,
                        activeBg: const Color(0xFF0F172A),
                        activeFg: Colors.white,
                        inactiveFg: const Color(0xFF475569),
                        onTap: onOpenOs1,
                      ),
                      const SizedBox(width: 4),
                      _pillDockBtn(
                        key: const Key('nav-setting'),
                        icon: Icons.tune_rounded,
                        label: '设备',
                        active: onSetting,
                        activeBg: const Color(0xFF0F172A),
                        activeFg: Colors.white,
                        inactiveFg: const Color(0xFF475569),
                        onTap: goSetting,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

      case RCUIStyleId.chronos:
        return Container(
          key: const Key('chronos-bottom-bar'),
          height: height ?? (58 + bottomInset),
          padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset),
          decoration: const BoxDecoration(
            color: Color(0xF5FFFFFF),
            border: Border(top: BorderSide(color: Color(0xFFE2E6EE))),
          ),
          child: Row(
            children: [
              _barTabBtn(
                key: const Key('nav-timeline'),
                icon: Icons.schedule_rounded,
                label: '声轴',
                active: onHome,
                activeColor: const Color(0xFF1D4ED8),
                inactiveColor: const Color(0xFF525968),
                onTap: goHome,
              ),
              _barTabBtn(
                key: const Key('nav-summary'),
                icon: Icons.description_outlined,
                label: '总结',
                active: onSummary,
                activeColor: const Color(0xFF1D4ED8),
                inactiveColor: const Color(0xFF525968),
                onTap: goSummary,
              ),
              _barTabBtn(
                key: const Key('nav-ai-sunrise'),
                icon: Icons.auto_awesome_rounded,
                label: '问答',
                active: false,
                activeColor: const Color(0xFF1D4ED8),
                inactiveColor: const Color(0xFF525968),
                onTap: onOpenOs1,
              ),
              _barTabBtn(
                key: const Key('nav-setting'),
                icon: Icons.tune_rounded,
                label: '设置',
                active: onSetting,
                activeColor: const Color(0xFF1D4ED8),
                inactiveColor: const Color(0xFF525968),
                onTap: goSetting,
              ),
            ],
          ),
        );

      case RCUIStyleId.folio:
        return Container(
          key: const Key('folio-bottom-nav'),
          height: height ?? (58 + bottomInset),
          padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset),
          decoration: const BoxDecoration(
            color: Color(0xFFF7F2E8),
            border: Border(top: BorderSide(color: Color(0xFFDDD4C3))),
          ),
          child: Row(
            children: [
              _barTabBtn(
                key: const Key('nav-timeline'),
                icon: Icons.menu_book_rounded,
                label: '日刊',
                active: onHome,
                activeColor: const Color(0xFFA62B21),
                inactiveColor: const Color(0xFF57534E),
                serif: true,
                onTap: goHome,
              ),
              _barTabBtn(
                key: const Key('nav-summary'),
                icon: Icons.description_outlined,
                label: '总结',
                active: onSummary,
                activeColor: const Color(0xFFA62B21),
                inactiveColor: const Color(0xFF57534E),
                serif: true,
                onTap: goSummary,
              ),
              _barTabBtn(
                key: const Key('nav-ai-sunrise'),
                icon: Icons.auto_awesome_rounded,
                label: '夜话',
                active: false,
                activeColor: const Color(0xFFA62B21),
                inactiveColor: const Color(0xFF57534E),
                serif: true,
                onTap: onOpenOs1,
              ),
              _barTabBtn(
                key: const Key('nav-setting'),
                icon: Icons.tune_rounded,
                label: '设置',
                active: onSetting,
                activeColor: const Color(0xFFA62B21),
                inactiveColor: const Color(0xFF57534E),
                serif: true,
                onTap: goSetting,
              ),
            ],
          ),
        );

      case RCUIStyleId.warmPaper:
        return const SizedBox.shrink();
    }
  }

  static Widget _braunDockBtn({
    required Key key,
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final fg = active ? const Color(0xFF121210) : const Color(0xFFA1A098);
    return Expanded(
      child: Material(
        color: active ? const Color(0xFFFF5514) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w700,
                    color: fg,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _pillDockBtn({
    required Key key,
    required IconData icon,
    required String label,
    required bool active,
    required Color activeBg,
    required Color activeFg,
    required Color inactiveFg,
    required VoidCallback onTap,
  }) {
    final fg = active ? activeFg : inactiveFg;
    return Expanded(
      child: Material(
        color: active ? activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: SizedBox(
            height: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15.5, color: fg),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _barTabBtn({
    required Key key,
    required IconData icon,
    required String label,
    required bool active,
    required Color activeColor,
    required Color inactiveColor,
    bool serif = false,
    required VoidCallback onTap,
  }) {
    final fg = active ? activeColor : inactiveColor;
    return Expanded(
      child: InkWell(
        key: key,
        onTap: onTap,
        child: SizedBox(
          height: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  fontFamilyFallback: serif ? rcSerifFontFallback : rcFontFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
