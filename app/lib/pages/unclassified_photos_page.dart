/// 未归类图片相册子页 —— 双列 1:1 正方形相册网格，支持大图预览、按当日记录归位与标记「不归类」。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../data/seed.dart';
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
        final items = store.unclassifiedPhotosForDay(dayOffset);
        final title = dayOffset == 0
            ? '今日未归类图片'
            : '${dayLabel(dayOffset)}未归类图片';
        return ColoredBox(
          key: const Key('p-unc'),
          color: RCColors.bg,
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
                      foregroundColor: RCColors.sec,
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
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '共 ${items.length} 张 · 点击图片预览，可归入当日记录或标记不归类',
                            style: const TextStyle(
                              fontSize: 12,
                              color: RCColors.sec,
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
                          foregroundColor: RCColors.sec,
                          backgroundColor: RCColors.card,
                          side: const BorderSide(color: RCColors.sep),
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
                    ? const Center(
                        key: Key('unc-empty'),
                        child: Text(
                          '暂无待归类图片',
                          style: TextStyle(fontSize: 13, color: RCColors.sec),
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
    final hasFile = photo.path.isNotEmpty && File(photo.path).existsSync();
    final srcLabel = photo.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
    final best = candidates.isNotEmpty ? candidates.first : null;
    return Container(
      key: Key('unc-item-${event.id}-${photo.id}'),
      decoration: BoxDecoration(
        color: RCColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RCColors.sep),
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
                      color: const Color(0xFFEAEAE4),
                      child: Center(
                        child: Icon(
                          photo.source == 'dyj_camera'
                              ? Icons.photo_camera_outlined
                              : Icons.photo_outlined,
                          size: 28,
                          color: RCColors.sec,
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
                    style: const TextStyle(fontSize: 11, color: RCColors.sec),
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
                                      color: const Color(0xFFEAF3EA),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: const Color(0xFFB8D9B8),
                                      ),
                                    ),
                                    child: Text(
                                      '归入·${best.title}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: RCColors.okInk,
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
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 3,
                                    ),
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 14,
                                      color: RCColors.sec,
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
                            color: RCColors.bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: RCColors.sep),
                          ),
                          child: const Text(
                            '不归类',
                            style: TextStyle(fontSize: 11, color: RCColors.sec),
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RCColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '归入当日记录',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                for (final c in candidates)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${c.time} · ${c.dur}',
                      style: const TextStyle(fontSize: 12, color: RCColors.sec),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: RCColors.ax,
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      store.reassignExcludedPhoto(
                        fromEventId: event.id,
                        photoId: photo.id,
                        toEventId: c.id,
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
    final hasFile = photo.path.isNotEmpty && File(photo.path).existsSync();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: RCColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: hasFile
                    ? Image.file(File(photo.path), fit: BoxFit.cover)
                    : const ColoredBox(
                        color: Color(0xFFEAEAE4),
                        child: Center(
                          child: Icon(
                            Icons.photo_outlined,
                            size: 44,
                            color: RCColors.sec,
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$srcLabel · ${photo.time}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '原属记录：${event.title}',
                      style: const TextStyle(fontSize: 12, color: RCColors.sec),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            store.dismissPhoto(event.id, photo.id);
                          },
                          child: const Text('不归类'),
                        ),
                        if (best != null)
                          FilledButton.tonal(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              store.reassignExcludedPhoto(
                                fromEventId: event.id,
                                photoId: photo.id,
                                toEventId: best.id,
                              );
                            },
                            child: Text('归入「${best.title}」'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
