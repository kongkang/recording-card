/// 录音卡 V2（CardV2）72×40 单色 OLED 位图渲染器。
///
/// 对齐 `reai-card-sdk` `DISPLAY_SHOW` 协议：
/// - 屏幕可见区域固定为 72×40 像素（5 页 × 72 列 = 360 字节）；
/// - 每字节对应同一列连续 8 行像素，其中 `bit 0` 为该 8 行页的顶行；
/// - 真机环境使用 Flutter `TextPainter` + `Canvas` 将中文/ASCII 文本栅格化为 72×40 位图，
///   在 `FLUTTER_TEST` 环境下走零等待的同步点阵降级渲染，避免 `FakeAsync` 挂起。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

const int oledWidth = 72;
const int oledHeight = 40;
const int oledBitmapBytes = 360;

/// 将 72×40 RGBA8888 像素缓冲按 SSD1306 页列顺序打包为 360 字节单色位图。
///
/// 布局：`bytes[page * 72 + col]` 中 `bit line` 对应像素 `(x = col, y = page * 8 + line)`，
/// 即 `bit 0` 为每页顶行；RGB 均值大于 [threshold] 即点亮。
Uint8List packRgbaToOledBitmap360(
  Uint8List rgba, {
  int width = oledWidth,
  int height = oledHeight,
  int threshold = 100,
}) {
  if (width != oledWidth || height != oledHeight) {
    throw ArgumentError('OLED dimensions must be ${oledWidth}x$oledHeight');
  }
  final requiredBytes = width * height * 4;
  if (rgba.length < requiredBytes) {
    throw ArgumentError(
      'RGBA buffer too short: expected >= $requiredBytes bytes, got ${rgba.length}',
    );
  }
  final out = Uint8List(oledBitmapBytes);
  for (var page = 0; page < 5; page++) {
    for (var col = 0; col < oledWidth; col++) {
      var bits = 0;
      for (var line = 0; line < 8; line++) {
        final y = page * 8 + line;
        final idx = (y * oledWidth + col) * 4;
        final luma = (rgba[idx] + rgba[idx + 1] + rgba[idx + 2]) / 3.0;
        if (luma > threshold) {
          bits |= (1 << line);
        }
      }
      out[page * oledWidth + col] = bits;
    }
  }
  return out;
}

abstract class OledBitmapRenderer {
  Future<Uint8List> renderText({required String line1, String? line2});
}

class FlutterOledBitmapRenderer implements OledBitmapRenderer {
  const FlutterOledBitmapRenderer({this.forceSoftwareFallback});

  final bool? forceSoftwareFallback;

  static bool get _isRunningInFlutterTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  @override
  Future<Uint8List> renderText({required String line1, String? line2}) async {
    final clean1 = line1.trim();
    final clean2 = line2?.trim() ?? '';
    if (forceSoftwareFallback ?? _isRunningInFlutterTest) {
      return renderFallbackBitmap360(
        line1: clean1,
        line2: clean2.isEmpty ? null : clean2,
      );
    }
    try {
      return await _renderWithCanvas(
        clean1,
        clean2.isEmpty ? null : clean2,
      ).timeout(const Duration(milliseconds: 800));
    } on Object {
      return renderFallbackBitmap360(
        line1: clean1,
        line2: clean2.isEmpty ? null : clean2,
      );
    }
  }

  Future<Uint8List> _renderWithCanvas(String line1, String? line2) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, oledWidth.toDouble(), oledHeight.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, oledWidth.toDouble(), oledHeight.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );

    if (line2 == null || line2.isEmpty) {
      final painter = _fitPainter(
        line1,
        maxFontSize: 15.0,
        minFontSize: 9.0,
        maxWidth: oledWidth - 2.0,
        fontWeight: FontWeight.w600,
      );
      final dx = ((oledWidth - painter.width) / 2).clamp(0.0, oledWidth - 1.0);
      final dy = ((oledHeight - painter.height) / 2).clamp(
        0.0,
        oledHeight - 1.0,
      );
      painter.paint(canvas, Offset(dx, dy));
    } else {
      final topPainter = _fitPainter(
        line1,
        maxFontSize: 13.0,
        minFontSize: 9.0,
        maxWidth: oledWidth - 2.0,
        fontWeight: FontWeight.w600,
      );
      final bottomPainter = _fitPainter(
        line2,
        maxFontSize: 11.5,
        minFontSize: 8.0,
        maxWidth: oledWidth - 2.0,
        fontWeight: FontWeight.w500,
      );
      final totalHeight = topPainter.height + 2.0 + bottomPainter.height;
      final startY = ((oledHeight - totalHeight) / 2).clamp(
        0.0,
        oledHeight - 1.0,
      );
      final topDx = ((oledWidth - topPainter.width) / 2).clamp(
        0.0,
        oledWidth - 1.0,
      );
      final botDx = ((oledWidth - bottomPainter.width) / 2).clamp(
        0.0,
        oledWidth - 1.0,
      );
      topPainter.paint(canvas, Offset(topDx, startY));
      bottomPainter.paint(
        canvas,
        Offset(botDx, startY + topPainter.height + 2.0),
      );
    }

    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(oledWidth, oledHeight);
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        return renderFallbackBitmap360(line1: line1, line2: line2);
      }
      return packRgbaToOledBitmap360(byteData.buffer.asUint8List());
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }

  TextPainter _fitPainter(
    String text, {
    required double maxFontSize,
    required double minFontSize,
    required double maxWidth,
    required FontWeight fontWeight,
  }) {
    var size = maxFontSize;
    late TextPainter painter;
    while (true) {
      painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: const Color(0xFFFFFFFF),
            fontSize: size,
            fontWeight: fontWeight,
            height: 1.08,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: double.infinity);
      if (painter.width <= maxWidth || size <= minFontSize) {
        if (painter.width > maxWidth) {
          painter.layout(maxWidth: maxWidth);
        }
        return painter;
      }
      size -= 0.5;
    }
  }

  /// 纯 Dart 同步点阵回退：支持 5×7 ASCII 字符与紧凑中文占位，用于测试或底层光栅化异常兜底。
  @visibleForTesting
  static Uint8List renderFallbackBitmap360({
    required String line1,
    String? line2,
  }) {
    final pixels = Uint8List(oledWidth * oledHeight);
    void setPixel(int x, int y) {
      if (x >= 0 && x < oledWidth && y >= 0 && y < oledHeight) {
        pixels[y * oledWidth + x] = 1;
      }
    }

    void drawLine(String text, int topY) {
      final runes = text.runes.take(12).toList();
      final totalW = runes.length * 6 - (runes.isEmpty ? 0 : 1);
      var x0 = ((oledWidth - totalW) ~/ 2).clamp(0, oledWidth - 1);
      for (final rune in runes) {
        final glyph = _ascii5x7[rune];
        if (glyph != null) {
          for (var col = 0; col < 5; col++) {
            final bits = glyph[col];
            for (var row = 0; row < 7; row++) {
              if ((bits & (1 << row)) != 0) {
                setPixel(x0 + col, topY + row);
              }
            }
          }
        } else if (rune != 0x20) {
          // 非 ASCII 字符（如中文）在回退路径下绘制外框 + 特征斜线，保证测试断言可区分内容
          for (var col = 0; col < 5; col++) {
            for (var row = 0; row < 7; row++) {
              final border =
                  col == 0 || col == 4 || row == 0 || row == 6 || col == row;
              if (border) {
                setPixel(x0 + col, topY + row);
              }
            }
          }
        }
        x0 += 6;
      }
    }

    final clean2 = line2?.trim() ?? '';
    if (clean2.isEmpty) {
      drawLine(line1, 16);
    } else {
      drawLine(line1, 8);
      drawLine(clean2, 24);
    }

    final out = Uint8List(oledBitmapBytes);
    for (var page = 0; page < 5; page++) {
      for (var col = 0; col < oledWidth; col++) {
        var bits = 0;
        for (var line = 0; line < 8; line++) {
          final y = page * 8 + line;
          if (pixels[y * oledWidth + col] != 0) {
            bits |= (1 << line);
          }
        }
        out[page * oledWidth + col] = bits;
      }
    }
    return out;
  }

  static const Map<int, List<int>> _ascii5x7 = {
    0x30: [0x3E, 0x51, 0x49, 0x45, 0x3E], // 0
    0x31: [0x00, 0x42, 0x7F, 0x40, 0x00], // 1
    0x32: [0x42, 0x61, 0x51, 0x49, 0x46], // 2
    0x33: [0x21, 0x41, 0x45, 0x4B, 0x31], // 3
    0x34: [0x18, 0x14, 0x12, 0x7F, 0x10], // 4
    0x35: [0x27, 0x45, 0x45, 0x45, 0x39], // 5
    0x36: [0x3C, 0x4A, 0x49, 0x49, 0x30], // 6
    0x37: [0x01, 0x71, 0x09, 0x05, 0x03], // 7
    0x38: [0x36, 0x49, 0x49, 0x49, 0x36], // 8
    0x39: [0x06, 0x49, 0x49, 0x29, 0x1E], // 9
    0x41: [0x7E, 0x11, 0x11, 0x11, 0x7E], // A
    0x42: [0x7F, 0x49, 0x49, 0x49, 0x36], // B
    0x43: [0x3E, 0x41, 0x41, 0x41, 0x22], // C
    0x44: [0x7F, 0x41, 0x41, 0x22, 0x1C], // D
    0x45: [0x7F, 0x49, 0x49, 0x49, 0x41], // E
    0x46: [0x7F, 0x09, 0x09, 0x09, 0x01], // F
    0x47: [0x3E, 0x41, 0x49, 0x49, 0x7A], // G
    0x48: [0x7F, 0x08, 0x08, 0x08, 0x7F], // H
    0x49: [0x00, 0x41, 0x7F, 0x41, 0x00], // I
    0x4A: [0x20, 0x40, 0x41, 0x3F, 0x01], // J
    0x4B: [0x7F, 0x08, 0x14, 0x22, 0x41], // K
    0x4C: [0x7F, 0x40, 0x40, 0x40, 0x40], // L
    0x4D: [0x7F, 0x02, 0x0C, 0x02, 0x7F], // M
    0x4E: [0x7F, 0x04, 0x08, 0x10, 0x7F], // N
    0x4F: [0x3E, 0x41, 0x41, 0x41, 0x3E], // O
    0x50: [0x7F, 0x09, 0x09, 0x09, 0x06], // P
    0x51: [0x3E, 0x41, 0x51, 0x21, 0x5E], // Q
    0x52: [0x7F, 0x09, 0x19, 0x29, 0x46], // R
    0x53: [0x46, 0x49, 0x49, 0x49, 0x31], // S
    0x54: [0x01, 0x01, 0x7F, 0x01, 0x01], // T
    0x55: [0x3F, 0x40, 0x40, 0x40, 0x3F], // U
    0x56: [0x1F, 0x20, 0x40, 0x20, 0x1F], // V
    0x57: [0x3F, 0x40, 0x38, 0x40, 0x3F], // W
    0x58: [0x63, 0x14, 0x08, 0x14, 0x63], // X
    0x59: [0x07, 0x08, 0x70, 0x08, 0x07], // Y
    0x5A: [0x61, 0x51, 0x49, 0x45, 0x43], // Z
    0x2D: [0x08, 0x08, 0x08, 0x08, 0x08], // -
    0x5F: [0x40, 0x40, 0x40, 0x40, 0x40], // _
  };
}
