/// 本地照片缩略图组件 —— 异步非阻塞加载 + 按展示宽度降采样解码。
///
/// 避免在 `build()` 中同步调用 `File.existsSync()` 阻塞 UI 线程，
/// 并通过 `cacheWidth` 按设备像素密度降采样至 32px 档位，降低大图解码与内存开销。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';

class PhotoThumbnail extends StatelessWidget {
  const PhotoThumbnail({
    super.key,
    required this.path,
    required this.logicalWidth,
    this.source = 'system_album',
    this.placeholderIconSize = 16,
    this.placeholderColor,
    this.fit = BoxFit.cover,
  });

  final String path;
  final double logicalWidth;
  final String source;
  final double placeholderIconSize;
  final Color? placeholderColor;
  final BoxFit fit;

  Widget _placeholder(Color bg, Color iconColor) {
    return ColoredBox(
      color: bg,
      child: Center(
        child: Icon(
          source == 'dyj_camera'
              ? Icons.photo_camera_outlined
              : Icons.photo_outlined,
          size: placeholderIconSize,
          color: iconColor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final bg =
        placeholderColor ??
        (c.isDark ? const Color(0xFF242428) : const Color(0xFFEAEAE4));
    if (path.isEmpty) return _placeholder(bg, c.sec);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rawPx = (logicalWidth * dpr).ceil();
    final cacheWidth = ((rawPx + 31) ~/ 32 * 32).clamp(64, 1280);
    return Image.file(
      File(path),
      fit: fit,
      cacheWidth: cacheWidth,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return ColoredBox(color: bg);
      },
      errorBuilder: (_, _, _) => _placeholder(bg, c.sec),
    );
  }
}
