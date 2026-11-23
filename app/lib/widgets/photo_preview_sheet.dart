/// 照片大图预览半屏弹层 —— 详情页、总结结果页与未归类相册页共用。
///
/// 展示高清预览（本地无图时诚实退化占位图标）、来源与拍摄时间、可选邻近对话原句摘录，
/// 以及「定位到原始对话流 ›」（`Key('pm-jump-dlg')`）或「不属于本段 / 不归类 / 归入」操作。
library;

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/theme/tokens.dart';
import 'photo_thumbnail.dart';

Future<void> showPhotoPreviewSheet(
  BuildContext context, {
  required EventPhoto photo,
  required String title,
  String? subtitle,
  String? quoteText,
  VoidCallback? onJumpToDialog,
  String jumpLabel = '定位到原始对话流 ›',
  VoidCallback? onSecondaryAction,
  String? secondaryActionLabel,
  VoidCallback? onPrimaryAction,
  String? primaryActionLabel,
}) {
  final outerColors = context.rc;
  final outerStyle = context.rcStyle;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: outerColors.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(outerStyle.cardRadius + 6),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (ctx) {
      final c = ctx.rc;
      final s = ctx.rcStyle;
      return SafeArea(
        key: const Key('photo-preview-sheet'),
        child: SingleChildScrollView(
          primary: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: c.sep,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(s.cardRadius),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: PhotoThumbnail(
                        path: photo.path,
                        logicalWidth: 420,
                        source: photo.source,
                        placeholderIconSize: 44,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: c.label,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.sec,
                        ),
                      ),
                    ],
                    if (quoteText != null && quoteText.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: c.bg,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: c.sep),
                        ),
                        child: Text(
                          quoteText.trim(),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: c.ink,
                          ),
                        ),
                      ),
                    ],
                    if (onJumpToDialog != null ||
                        onSecondaryAction != null ||
                        onPrimaryAction != null) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          if (onSecondaryAction != null &&
                              secondaryActionLabel != null)
                            TextButton(
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                onSecondaryAction();
                              },
                              child: Text(secondaryActionLabel),
                            ),
                          if (onJumpToDialog != null)
                            FilledButton.tonal(
                              key: const Key('pm-jump-dlg'),
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                onJumpToDialog();
                              },
                              child: Text(jumpLabel),
                            ),
                          if (onPrimaryAction != null &&
                              primaryActionLabel != null)
                            FilledButton.tonal(
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                onPrimaryAction();
                              },
                              child: Text(primaryActionLabel),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
