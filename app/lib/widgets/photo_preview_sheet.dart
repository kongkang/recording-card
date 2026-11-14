/// 照片大图预览半屏弹层 —— 详情页、总结结果页与未归类相册页共用。
///
/// 展示高清预览（本地无图时诚实退化占位图标）、来源与拍摄时间、可选邻近对话原句摘录，
/// 以及「定位到原始对话流 ›」（`Key('pm-jump-dlg')`）或「不属于本段 / 不归类 / 归入」操作。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/theme/tokens.dart';

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
  final hasFile = photo.path.isNotEmpty && File(photo.path).existsSync();
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: RCColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (ctx) {
      return SafeArea(
        key: const Key('photo-preview-sheet'),
        child: SingleChildScrollView(
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
                    color: RCColors.sep,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: hasFile
                          ? Image.file(File(photo.path), fit: BoxFit.cover)
                          : ColoredBox(
                              color: const Color(0xFFEAEAE4),
                              child: Center(
                                child: Icon(
                                  photo.source == 'dyj_camera'
                                      ? Icons.photo_camera_outlined
                                      : Icons.photo_outlined,
                                  size: 44,
                                  color: RCColors.sec,
                                ),
                              ),
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
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: RCColors.sec,
                        ),
                      ),
                    ],
                    if (quoteText != null && quoteText.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: RCColors.bg,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: RCColors.sep),
                        ),
                        child: Text(
                          quoteText.trim(),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: RCColors.ink,
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
