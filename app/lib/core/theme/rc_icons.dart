/// Recording Card 统一矢量图标库与硬件产品代际徽章。
///
/// 统一采用 1.6px 圆角描边几何风格（与原型设计一致），避免不同模块混用各异的
/// Material 图标导致线宽与视觉语言不统一。
library;

import 'package:flutter/material.dart';

import '../device/card_gateway.dart';

enum RCIconKind {
  disconnect,
  bluetooth,
  bolt,
  sync,
  check,
  chevronRight,
  chevronLeft,
  trash,
  mic,
  lock,
  cloud,
  shield,
}

/// 标准化 1.6px 圆角描边图标。
class RCIcon extends StatelessWidget {
  const RCIcon(
    this.kind, {
    super.key,
    this.size = 16,
    this.color,
    this.strokeWidth = 1.6,
  });

  final RCIconKind kind;
  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ?? IconTheme.of(context).color ?? const Color(0xFF1D1D1F);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RCIconPainter(
          kind: kind,
          color: resolved,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _RCIconPainter extends CustomPainter {
  const _RCIconPainter({
    required this.kind,
    required this.color,
    required this.strokeWidth,
  });

  final RCIconKind kind;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final scaledStroke = (strokeWidth * (w / 18.0)).clamp(1.1, 2.6);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = scaledStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (kind) {
      case RCIconKind.disconnect:
        // 简洁断链图标（对角线打断的两个扣环，无外框）
        final p1 = Path()
          ..moveTo(w * 0.42, h * 0.28)
          ..lineTo(w * 0.56, h * 0.14)
          ..arcToPoint(
            Offset(w * 0.86, h * 0.44),
            radius: Radius.circular(w * 0.21),
          )
          ..lineTo(w * 0.72, h * 0.58);
        final p2 = Path()
          ..moveTo(w * 0.28, h * 0.42)
          ..lineTo(w * 0.14, h * 0.56)
          ..arcToPoint(
            Offset(w * 0.44, h * 0.86),
            radius: Radius.circular(w * 0.21),
            clockwise: false,
          )
          ..lineTo(w * 0.58, h * 0.72);
        canvas.drawPath(p1, paint);
        canvas.drawPath(p2, paint);
        canvas.drawLine(
          Offset(w * 0.16, h * 0.16),
          Offset(w * 0.84, h * 0.84),
          paint,
        );
      case RCIconKind.bluetooth:
        final bt = Path()
          ..moveTo(w * 0.28, h * 0.30)
          ..lineTo(w * 0.74, h * 0.68)
          ..lineTo(w * 0.48, h * 0.88)
          ..lineTo(w * 0.48, h * 0.12)
          ..lineTo(w * 0.74, h * 0.32)
          ..lineTo(w * 0.28, h * 0.70);
        canvas.drawPath(bt, paint);
      case RCIconKind.bolt:
        final bolt = Path()
          ..moveTo(w * 0.56, h * 0.08)
          ..lineTo(w * 0.22, h * 0.54)
          ..lineTo(w * 0.48, h * 0.54)
          ..lineTo(w * 0.42, h * 0.92)
          ..lineTo(w * 0.78, h * 0.46)
          ..lineTo(w * 0.52, h * 0.46)
          ..close();
        canvas.drawPath(
          bolt,
          Paint()
            ..color = color
            ..style = PaintingStyle.fill,
        );
      case RCIconKind.sync:
        final rect = Rect.fromLTWH(w * 0.14, h * 0.14, w * 0.72, h * 0.72);
        canvas.drawArc(rect, -2.55, 2.25, false, paint);
        canvas.drawArc(rect, 0.58, 2.25, false, paint);
        // 右上角箭头
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.69, h * 0.16)
            ..lineTo(w * 0.85, h * 0.28)
            ..lineTo(w * 0.68, h * 0.36),
          paint,
        );
        // 左下角箭头
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.31, h * 0.84)
            ..lineTo(w * 0.15, h * 0.72)
            ..lineTo(w * 0.32, h * 0.64),
          paint,
        );
      case RCIconKind.check:
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.20, h * 0.54)
            ..lineTo(w * 0.42, h * 0.76)
            ..lineTo(w * 0.82, h * 0.28),
          paint,
        );
      case RCIconKind.chevronRight:
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.36, h * 0.22)
            ..lineTo(w * 0.66, h * 0.50)
            ..lineTo(w * 0.36, h * 0.78),
          paint,
        );
      case RCIconKind.chevronLeft:
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.64, h * 0.22)
            ..lineTo(w * 0.34, h * 0.50)
            ..lineTo(w * 0.64, h * 0.78),
          paint,
        );
      case RCIconKind.trash:
        canvas.drawLine(
          Offset(w * 0.18, h * 0.28),
          Offset(w * 0.82, h * 0.28),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.36, h * 0.28)
            ..lineTo(w * 0.36, h * 0.18)
            ..lineTo(w * 0.64, h * 0.18)
            ..lineTo(w * 0.64, h * 0.28),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.28, h * 0.28)
            ..lineTo(w * 0.32, h * 0.82)
            ..lineTo(w * 0.68, h * 0.82)
            ..lineTo(w * 0.72, h * 0.28),
          paint,
        );
      case RCIconKind.mic:
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.35, h * 0.14, w * 0.30, h * 0.44),
          Radius.circular(w * 0.15),
        );
        canvas.drawRRect(body, paint);
        canvas.drawArc(
          Rect.fromLTWH(w * 0.24, h * 0.30, w * 0.52, h * 0.40),
          0.15,
          2.84,
          false,
          paint,
        );
        canvas.drawLine(
          Offset(w * 0.50, h * 0.70),
          Offset(w * 0.50, h * 0.86),
          paint,
        );
        canvas.drawLine(
          Offset(w * 0.34, h * 0.86),
          Offset(w * 0.66, h * 0.86),
          paint,
        );
      case RCIconKind.lock:
        canvas.drawArc(
          Rect.fromLTWH(w * 0.30, h * 0.16, w * 0.40, h * 0.42),
          3.14159,
          3.14159,
          false,
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.22, h * 0.44, w * 0.56, h * 0.40),
            Radius.circular(w * 0.10),
          ),
          paint,
        );
      case RCIconKind.cloud:
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.28, h * 0.74)
            ..lineTo(w * 0.74, h * 0.74)
            ..arcToPoint(
              Offset(w * 0.72, h * 0.44),
              radius: Radius.circular(w * 0.16),
              clockwise: false,
            )
            ..arcToPoint(
              Offset(w * 0.32, h * 0.38),
              radius: Radius.circular(w * 0.24),
              clockwise: false,
            )
            ..arcToPoint(
              Offset(w * 0.28, h * 0.74),
              radius: Radius.circular(w * 0.18),
              clockwise: false,
            ),
          paint,
        );
      case RCIconKind.shield:
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.50, h * 0.14)
            ..lineTo(w * 0.80, h * 0.26)
            ..lineTo(w * 0.76, h * 0.58)
            ..quadraticBezierTo(w * 0.50, h * 0.84, w * 0.50, h * 0.86)
            ..quadraticBezierTo(w * 0.50, h * 0.84, w * 0.24, h * 0.58)
            ..lineTo(w * 0.20, h * 0.26)
            ..close(),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _RCIconPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 录音卡 App Logo 标记（用于灵动岛/本机录音运行标识，非麦克风图标）。
class RCAppLogoMark extends StatelessWidget {
  const RCAppLogoMark({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1F),
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      alignment: Alignment.center,
      child: Container(
        width: size * 0.52,
        height: size * 0.64,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: size * 0.09),
          borderRadius: BorderRadius.circular(size * 0.12),
        ),
        alignment: Alignment.topCenter,
        padding: EdgeInsets.only(top: size * 0.10),
        child: Container(
          width: size * 0.16,
          height: size * 0.16,
          decoration: const BoxDecoration(
            color: Color(0xFFFF3B30),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 分硬件代际着色的产品标签（位于蓝牙设备编码左侧，避免小屏截断有效编码）。
///
/// - 点一机 V1（[DeviceKind.dyjV1]）：白底 `#FFFFFF` + 浅灰框 + 深色字
/// - 录音卡 V2（[DeviceKind.cardV2]）：深色 `#1D1D1F` + 白字
/// - 语音 AI 键盘 V2.1（[DeviceKind.boardV21]）：淡蓝色 `#E8F2FF` + 蓝框 + 深蓝字
class DeviceKindBadge extends StatelessWidget {
  const DeviceKindBadge({
    super.key,
    required this.kind,
    this.label,
  });

  final DeviceKind kind;
  final String? label;

  static (Color bg, Color border, Color fg) colorsFor(DeviceKind kind) =>
      switch (kind) {
        DeviceKind.dyjV1 => (
          const Color(0xFFFFFFFF),
          const Color(0xFFD2D2CE),
          const Color(0xFF1D1D1F),
        ),
        DeviceKind.cardV2 => (
          const Color(0xFF1D1D1F),
          const Color(0xFF1D1D1F),
          const Color(0xFFFFFFFF),
        ),
        DeviceKind.boardV21 => (
          const Color(0xFFE8F2FF),
          const Color(0xFFBBD8FF),
          const Color(0xFF1456B8),
        ),
        DeviceKind.getSeedGsc10 => (
          const Color(0xFFFFF7E6),
          const Color(0xFFFFD591),
          const Color(0xFFAD6800),
        ),
        DeviceKind.omiCv1 => (
          const Color(0xFFF3EEFF),
          const Color(0xFFD3ADF7),
          const Color(0xFF531DAB),
        ),
        DeviceKind.appleWatch => (
          const Color(0xFFEAF7EE),
          const Color(0xFFB7E1C4),
          const Color(0xFF186A3B),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = colorsFor(kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label ?? kind.displayModel,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          height: 1.15,
          color: fg,
        ),
      ),
    );
  }
}
