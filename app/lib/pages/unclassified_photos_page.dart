/// 未归类图片相册子页 —— 双列 1:1 正方形相册网格，支持大图预览、按当日记录归位与标记「不归类」。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../data/seed.dart';
import '../widgets/photo_preview_sheet.dart';
import '../widgets/store_scope.dart';

class UnclassifiedPhotosPage extends StatelessWidget {
  const UnclassifiedPhotosPage({
    super.key,
    required this.dayOffset,
    this.showPaneBack = false,
  });

  final int dayOffset;
  final bool showPaneBack;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = context.rc;
        final items = store.unclassifiedPhotosForDay(dayOffset);
        final title = dayOffset == 0
            ? '今日未归类图片'
            : '${dayLabel(dayOffset)}未归类图片';
        return ColoredBox(
          key: const Key('p-unc'),
          color: c.bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showPaneBack)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('pb-unc'),
                    onPressed: store.goBack,
                    icon: const Icon(Icons.chevron_left, size: 18),
                    label: Text(
                      '返回${AppStore.pageLabels[store.stackPrev?.type] ?? 'Timeline'}',
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: c.sec,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            key: const Key('uncp-title'),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: c.label,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '共 ${items.length} 张 · 点击图片预览，可归入当日记录或标记不归类',
                            style: TextStyle(
                              fontSize: 12,
                              color: c.sec,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (items.isNotEmpty)
                      TextButton(
                        key: const Key('unc-dismiss-all'),
                        onPressed: () => store.dismissUnclassifiedDay(dayOffset),
                        style: TextButton.styleFrom(
                          foregroundColor: c.sec,
                          backgroundColor: c.card,
                          side: BorderSide(color: c.sep),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('全部不归类'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        key: const Key('unc-empty'),
                        child: Text(
                          '暂无待归类图片',
                          style: TextStyle(fontSize: 13, color: c.sec),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          const hPad = 20.0;
                          const spacing = 12.0;
                          final gridWidth =
                              (constraints.maxWidth - hPad * 2 - spacing)
                                  .clamp(120.0, 2000.0);
                          final tileSide = gridWidth / 2;
                          return GridView.builder(
                            key: const Key('unc-album-grid'),
                            padding: const EdgeInsets.fromLTRB(
                              hPad,
                              4,
                              hPad,
                              RCDims.pageBottomPad,
                            ),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: spacing,
                                  mainAxisSpacing: spacing,
                                  mainAxisExtent: (tileSide - 2) + 68,
                                ),
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final item = items[i];
                              final cands = store.candidateEventsForPhoto(
                                dayOffset,
                                item.photo,
                              );
                              return _AlbumTile(
                                store: store,
                                event: item.event,
                                photo: item.photo,
                                candidates: cands,
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.store,
    required this.event,
    required this.photo,
    required this.candidates,
  });

  final AppStore store;
  final RecordEvent event;
  final EventPhoto photo;
  final List<RecordEvent> candidates;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final hasFile = photo.path.isNotEmpty && File(photo.path).existsSync();
    final srcLabel = photo.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
    final best = candidates.isNotEmpty ? candidates.first : null;
    final okBg = c.isDark ? const Color(0xFF1A2E1E) : const Color(0xFFEAF3EA);
    final okBorder = c.isDark
        ? const Color(0xFF2D5434)
        : const Color(0xFFB8D9B8);
    return Container(
      key: Key('unc-item-${event.id}-${photo.id}'),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.sep),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: Key('unc-photo-${event.id}-${photo.id}'),
            onTap: () => _showPreview(context, srcLabel, best),
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasFile)
                    Image.file(File(photo.path), fit: BoxFit.cover)
                  else
                    ColoredBox(
                      color: c.isDark
                          ? const Color(0xFF242428)
                          : const Color(0xFFEAEAE4),
                      child: Center(
                        child: Icon(
                          photo.source == 'dyj_camera'
                              ? Icons.photo_camera_outlined
                              : Icons.photo_outlined,
                          size: 28,
                          color: c.sec,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x9E000000),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        photo.time,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$srcLabel · 原属 ${event.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.sec),
                  ),
                  Row(
                    children: [
                      if (best != null)
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: InkWell(
                                  key: Key(
                                    'unc-reassign-${event.id}-${photo.id}-${best.id}',
                                  ),
                                  onTap: () => store.reassignExcludedPhoto(
                                    fromEventId: event.id,
                                    photoId: photo.id,
                                    toEventId: best.id,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: okBg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: okBorder),
                                    ),
                                    child: Text(
                                      '归入·${best.title}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: c.okInk,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (candidates.length > 1) ...[
                                const SizedBox(width: 3),
                                InkWell(
                                  key: Key('unc-pick-${event.id}-${photo.id}'),
                                  onTap: () => _showCandidatePicker(context),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 3,
                                    ),
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 14,
                                      color: c.sec,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        )
                      else
                        const Spacer(),
                      const SizedBox(width: 4),
                      InkWell(
                        key: Key('unc-dismiss-${event.id}-${photo.id}'),
                        onTap: () => store.dismissPhoto(event.id, photo.id),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: c.bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: c.sep),
                          ),
                          child: Text(
                            '不归类',
                            style: TextStyle(fontSize: 11, color: c.sec),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showCandidatePicker(BuildContext context) {
    final rc = context.rc;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: rc.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final sc = ctx.rc;
        final okBg = sc.isDark
            ? const Color(0xFF1A2E1E)
            : const Color(0xFFEAF3EA);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '归入当日记录',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: sc.label,
                  ),
                ),
                const SizedBox(height: 8),
                for (var ci = 0; ci < candidates.length; ci++)
                  Builder(
                    builder: (context) {
                      final c = candidates[ci];
                      return ListTile(
                        key: Key('unc-cand-${c.id}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: sc.label,
                                ),
                              ),
                            ),
                            if (ci == 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: okBg,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  '时间最接近',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: sc.okInk,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${c.time} · ${c.dur}',
                          style: TextStyle(
                            fontSize: 12,
                            color: sc.sec,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: sc.ax,
                        ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          store.reassignExcludedPhoto(
                            fromEventId: event.id,
                            photoId: photo.id,
                            toEventId: c.id,
                          );
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPreview(
    BuildContext context,
    String srcLabel,
    RecordEvent? best,
  ) {
    showPhotoPreviewSheet(
      context,
      photo: photo,
      title: '$srcLabel · ${photo.time}',
      subtitle: '原属记录：${event.title}',
      onSecondaryAction: () => store.dismissPhoto(event.id, photo.id),
      secondaryActionLabel: '不归类',
      onPrimaryAction: best != null
          ? () => store.reassignExcludedPhoto(
                fromEventId: event.id,
                photoId: photo.id,
                toEventId: best.id,
              )
          : null,
      primaryActionLabel: best != null ? '归入「${best.title}」' : null,
    );
  }
}
