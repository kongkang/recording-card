/// Timeline 页 —— 按日分组倒序；两行折叠卡；勾选模式（全选今日/本周/本月 + 底部操作栏）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/models/record.dart';
import '../core/models/recording.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../services/audio/recording_status.dart';
import '../widgets/photo_thumbnail.dart';
import '../widgets/recording_status_block.dart';
import '../widgets/selection_marker.dart';
import '../widgets/store_scope.dart';

enum _StickyRangeEdge { none, top, bottom }

class TimelinePage extends StatefulWidget {
  const TimelinePage({
    super.key,
    this.asLeftPane = false,
    this.recordingStatus,
  });

  /// 宽屏双栏时作为常显左栏
  final bool asLeftPane;

  /// 设备录音态状态块；null 时不展示（旧调用/测试兼容）
  final RecordingStatusController? recordingStatus;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};

  _StickyRangeEdge _stickyEdge = _StickyRangeEdge.none;
  String? _stickyTargetId;
  int _stickyCount = 0;
  bool _rangeCheckScheduled = false;

  GlobalKey _itemKeyFor(String id) =>
      _itemKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'range-item-$id'));

  void _scheduleRangeCheck(AppStore store) {
    if (_rangeCheckScheduled) return;
    _rangeCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rangeCheckScheduled = false;
      _recomputeStickyRange(store);
    });
  }

  void _setStickyState(_StickyRangeEdge edge, String? targetId, int count) {
    if (_stickyEdge == edge &&
        _stickyTargetId == targetId &&
        _stickyCount == count) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _stickyEdge = edge;
      _stickyTargetId = targetId;
      _stickyCount = count;
    });
  }

  void _recomputeStickyRange(AppStore store) {
    final anchorId = store.selAnchorId;
    if (!mounted || !store.selMode || anchorId == null) {
      _setStickyState(_StickyRangeEdge.none, null, 0);
      return;
    }
    final viewportCtx = _viewportKey.currentContext;
    final viewportObj = viewportCtx?.findRenderObject();
    if (viewportObj is! RenderBox ||
        !viewportObj.attached ||
        !viewportObj.hasSize) {
      return;
    }
    final vh = viewportObj.size.height;
    if (vh <= 0) return;

    final ordered = store.selectableEventIds;
    final anchorIdx = ordered.indexOf(anchorId);
    if (anchorIdx < 0) {
      _setStickyState(_StickyRangeEdge.none, null, 0);
      return;
    }

    int? minVisibleIdx;
    int? maxVisibleIdx;
    String? firstVisibleId;
    String? lastVisibleId;
    bool? anchorAbove;
    bool? anchorBelow;

    for (var i = 0; i < ordered.length; i++) {
      final id = ordered[i];
      final itemObj = _itemKeys[id]?.currentContext?.findRenderObject();
      if (itemObj is! RenderBox || !itemObj.attached || !itemObj.hasSize) {
        continue;
      }
      final top = itemObj.localToGlobal(Offset.zero, ancestor: viewportObj).dy;
      final bottom = top + itemObj.size.height;

      if (id == anchorId) {
        if (bottom <= 8) {
          anchorAbove = true;
          anchorBelow = false;
        } else if (top >= vh - 8) {
          anchorAbove = false;
          anchorBelow = true;
        } else {
          anchorAbove = false;
          anchorBelow = false;
        }
      }

      if (bottom > 16 && top < vh - 16) {
        if (minVisibleIdx == null || i < minVisibleIdx) {
          minVisibleIdx = i;
          firstVisibleId = id;
        }
        if (maxVisibleIdx == null || i > maxVisibleIdx) {
          maxVisibleIdx = i;
          lastVisibleId = id;
        }
      }
    }

    // 若锚点卡片已被 Sliver 回收，利用列表顺序与可见下标反推方向
    if (anchorAbove == null && minVisibleIdx != null && maxVisibleIdx != null) {
      if (anchorIdx < minVisibleIdx) {
        anchorAbove = true;
        anchorBelow = false;
      } else if (anchorIdx > maxVisibleIdx) {
        anchorAbove = false;
        anchorBelow = true;
      }
    }

    if (anchorAbove == true &&
        lastVisibleId != null &&
        ordered.indexOf(lastVisibleId) > anchorIdx) {
      final preview = store.previewRangeTo(lastVisibleId);
      if (preview != null) {
        _setStickyState(_StickyRangeEdge.bottom, lastVisibleId, preview.count);
        return;
      }
    }
    if (anchorBelow == true &&
        firstVisibleId != null &&
        ordered.indexOf(firstVisibleId) < anchorIdx) {
      final preview = store.previewRangeTo(firstVisibleId);
      if (preview != null) {
        _setStickyState(_StickyRangeEdge.top, firstVisibleId, preview.count);
        return;
      }
    }
    _setStickyState(_StickyRangeEdge.none, null, 0);
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final recordingStatus = widget.recordingStatus;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = context.rc;
        final entries = store.feedEntries;
        // 录音/同步状态块只出现在「全部/记录」的内容顶部：
        // 勾选总结时收起（总结源列表保持干净），切到「总结」Tab 也不显示。
        final showStatus =
            recordingStatus != null &&
            !store.selMode &&
            store.filter != FeedFilter.summary;
        final showPendingCandidate =
            !store.selMode &&
            store.filter != FeedFilter.summary &&
            store.pendingLocalAudioCount > 0 &&
            store.syncStage == null;
        if (!store.selMode && _itemKeys.isNotEmpty) {
          _itemKeys.clear();
        }
        if (store.selMode && store.selAnchorId != null) {
          _scheduleRangeCheck(store);
        } else if (_stickyEdge != _StickyRangeEdge.none) {
          _scheduleRangeCheck(store);
        }

        final showTopSticky =
            store.selMode &&
            store.selAnchorId != null &&
            _stickyEdge == _StickyRangeEdge.top &&
            _stickyTargetId != null;
        final showBottomSticky =
            store.selMode &&
            store.selAnchorId != null &&
            _stickyEdge == _StickyRangeEdge.bottom &&
            _stickyTargetId != null;

        final headerCount =
            (showStatus ? 1 : 0) + (showPendingCandidate ? 1 : 0);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TabsBar(store: store),
            if (store.selMode) _RangeBar(store: store),
            _SyncBannerHost(
              store: store,
              showStatus: showStatus,
              recordingStatus: recordingStatus,
            ),
            Expanded(
              child: Stack(
                key: _viewportKey,
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (store.selMode &&
                          store.selAnchorId != null &&
                          (n is ScrollUpdateNotification ||
                              n is ScrollEndNotification ||
                              n is ScrollMetricsNotification)) {
                        _scheduleRangeCheck(store);
                      }
                      return false;
                    },
                    // 下拉刷新：全部/记录 Tab 从设备补传新录音并触发积压转写；总结 Tab 仅刷新本机总结列表
                    child: RefreshIndicator(
                      key: const Key('timeline-refresh'),
                      onRefresh: () async {
                        if (store.filter == FeedFilter.summary) {
                          await store.refreshSummariesOnly();
                          return;
                        }
                        final message = await store.syncRecordings();
                        if (message != null &&
                            message.isNotEmpty &&
                            context.mounted) {
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              SnackBar(
                                duration: const Duration(seconds: 2),
                                content: Text(message),
                              ),
                            );
                        }
                      },
                      child: entries.isEmpty
                          ? ListView(
                              key: const Key('timeline-empty'),
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.only(
                                top: 16,
                                bottom: RCDims.pageBottomPad,
                              ),
                              children: [
                                if (showStatus)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 22,
                                    ),
                                    child: RecordingStatusBlock(
                                      controller: recordingStatus,
                                    ),
                                  ),
                                if (showPendingCandidate)
                                  _PendingAudioBannerHost(
                                    store: store,
                                    showStatus: showStatus,
                                    recordingStatus: recordingStatus,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 22,
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 60),
                                  child: Center(
                                    child: Column(
                                      children: [
                                        Icon(
                                          store.filter == FeedFilter.summary
                                              ? Icons.summarize_outlined
                                              : Icons.mic_none,
                                          size: 36,
                                          color: c.ax,
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          store.filter == FeedFilter.summary
                                              ? '还没有总结\n点击右上角「总结」选择记录生成'
                                              : (store.loadError ??
                                                    (store.syncError ??
                                                        _emptyText(
                                                          store,
                                                          deviceReady:
                                                              store.deviceConnected
                                                                  ?.call() ??
                                                              true,
                                                        ))),
                                          key: store.filter ==
                                                  FeedFilter.summary
                                              ? const Key('summary-empty-text')
                                              : null,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: c.sec,
                                            fontSize: 14,
                                            height: 1.6,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              key: const Key('timeline-list'),
                              physics: const AlwaysScrollableScrollPhysics(),
                              scrollCacheExtent: const ScrollCacheExtent.pixels(
                                320,
                              ),
                              addAutomaticKeepAlives: false,
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                4,
                                22,
                                RCDims.pageBottomPad,
                              ),
                              itemCount: headerCount + entries.length,
                              itemBuilder: (context, index) {
                                if (showStatus && index == 0) {
                                  return RecordingStatusBlock(
                                    key: const ValueKey('tl-status-block'),
                                    controller: recordingStatus,
                                  );
                                }
                                final pendingIdx = showStatus ? 1 : 0;
                                if (showPendingCandidate &&
                                    index == pendingIdx) {
                                  return _PendingAudioBannerHost(
                                    key: const ValueKey('tl-pending-banner'),
                                    store: store,
                                    showStatus: showStatus,
                                    recordingStatus: recordingStatus,
                                  );
                                }
                                final entry = entries[index - headerCount];
                                return switch (entry) {
                                  final FeedDayHeaderEntry h => Padding(
                                    key: ValueKey('tl-day-${h.dayOffset}'),
                                    padding: const EdgeInsets.only(
                                      top: 4,
                                      bottom: 14,
                                    ),
                                    child: Text(
                                      h.dayLabel,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: c.label,
                                      ),
                                    ),
                                  ),
                                  final FeedItemEntry it => _TimelineRail(
                                    key: ValueKey(
                                      'tl-rail-${_entryKeyId(it.item)}',
                                    ),
                                    first: it.first,
                                    last: it.last,
                                    child: switch (it.item) {
                                      final SummaryCard s => _SummaryCardView(
                                        card: s,
                                        store: store,
                                      ),
                                      final UnclassifiedPhotosCard u =>
                                        _UnclassifiedPhotosCardView(card: u),
                                      final ForkedEventPair fp =>
                                        _ForkedEventCardView(
                                          pair: fp,
                                          store: store,
                                        ),
                                      final TrivialClusterCard t =>
                                        _TrivialClusterView(
                                          card: t,
                                          onTap: () => _showTrivialClusterSheet(
                                            context,
                                            store,
                                            t,
                                          ),
                                        ),
                                      final RecordEvent e => _EventCardView(
                                        event: e,
                                        store: store,
                                        cardKey: (!e.live && store.selMode)
                                            ? _itemKeyFor(e.id)
                                            : null,
                                      ),
                                      _ => const SizedBox.shrink(),
                                    },
                                  ),
                                };
                              },
                            ),
                    ),
                  ),
                  if (showTopSticky)
                    Positioned(
                      top: 10,
                      left: 22,
                      right: 22,
                      child: Center(
                        child: _StickyRangeButton(
                          key: const Key('sticky-select-top'),
                          icon: Icons.vertical_align_top_rounded,
                          label: '选择到这儿 · 共 $_stickyCount 项',
                          onTap: () => store.selectRangeTo(_stickyTargetId!),
                        ),
                      ),
                    ),
                  if (showBottomSticky)
                    Positioned(
                      bottom: 12,
                      left: 22,
                      right: 22,
                      child: Center(
                        child: _StickyRangeButton(
                          key: const Key('sticky-select-bottom'),
                          icon: Icons.vertical_align_bottom_rounded,
                          label: '选到此处 · 共 $_stickyCount 项',
                          onTap: () => store.selectRangeTo(_stickyTargetId!),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (store.selMode) _SelBar(store: store),
          ],
        );
      },
    );
  }

  static String _entryKeyId(Object item) => switch (item) {
    final SummaryCard s => 'sum-${s.id}',
    final UnclassifiedPhotosCard u => 'unc-${u.dayOffset}',
    final ForkedEventPair fp => 'fork-${fp.forkGroupId}',
    final TrivialClusterCard t => 'triv-${t.id}',
    final RecordEvent e => 'ev-${e.id}',
    _ => '${identityHashCode(item)}',
  };
}

class _SyncBannerHost extends StatelessWidget {
  const _SyncBannerHost({
    required this.store,
    required this.showStatus,
    required this.recordingStatus,
  });

  final AppStore store;
  final bool showStatus;
  final RecordingStatusController? recordingStatus;

  @override
  Widget build(BuildContext context) {
    // 设计稿只有一处顶部实时状态块（#live-status）：状态块已经在展示「正在录音 / 正在同步 / 正在转写」时，
    // 不再叠出第二条 _SyncBanner（「正在取回…」进度条），避免两块同步提示同时出现冲突。
    final active = store.loading || store.syncStage != null;
    if (!active) return const SizedBox.shrink();
    final ctrl = recordingStatus;
    if (!showStatus || ctrl == null) {
      return _SyncBanner(store: store);
    }
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (ctrl.phase != RecordingPhase.idle) {
          return const SizedBox.shrink();
        }
        return _SyncBanner(store: store);
      },
    );
  }
}

class _PendingAudioBannerHost extends StatelessWidget {
  const _PendingAudioBannerHost({
    super.key,
    required this.store,
    required this.showStatus,
    required this.recordingStatus,
    this.padding,
  });

  final AppStore store;
  final bool showStatus;
  final RecordingStatusController? recordingStatus;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    Widget content() {
      final banner = _PendingAudioBanner(store: store);
      return padding != null ? Padding(padding: padding!, child: banner) : banner;
    }

    final ctrl = recordingStatus;
    if (!showStatus || ctrl == null) {
      return content();
    }
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (ctrl.phase != RecordingPhase.idle) {
          return const SizedBox.shrink();
        }
        return content();
      },
    );
  }
}

class _TabsBar extends StatelessWidget {
  const _TabsBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    Widget tab(String label, FeedFilter f, String keyName) {
      final locked = store.tabsLocked && f != FeedFilter.event;
      final on = store.filter == f;
      return TextButton(
        key: Key('tab-$keyName'),
        onPressed: locked ? null : () => store.setFilter(f),
        style: TextButton.styleFrom(
          foregroundColor: on ? c.label : c.sec,
          disabledForegroundColor: c.ax,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 2, 22, 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.sep)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                tab('全部', FeedFilter.all, 'all'),
                const SizedBox(width: 18),
                tab('记录', FeedFilter.event, 'event'),
                const SizedBox(width: 18),
                tab('总结', FeedFilter.summary, 'summary'),
              ],
            ),
          ),
          // 原型 .btn-sum：透明底 + 深色描边胶囊
          OutlinedButton(
            key: const Key('summary-start'),
            onPressed: store.selMode ? null : store.startSummary,
            style: OutlinedButton.styleFrom(
              foregroundColor: c.label,
              disabledForegroundColor: c.ax,
              side: BorderSide(color: store.selMode ? c.ax : c.label),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13),
            ),
            child: const Text('总结'),
          ),
        ],
      ),
    );
  }
}

class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    Widget chip(String label, String r) {
      final active = r != 'none' && store.activeQuickRange == r;
      return KeyedSubtree(
        key: Key('chip-$r'),
        child: OutlinedButton(
          onPressed: () => r == 'none' ? store.selNone() : store.selRange(r),
          style: OutlinedButton.styleFrom(
            backgroundColor: active ? c.label : Colors.transparent,
            foregroundColor: active ? c.onLabel : c.ink,
            side: BorderSide(color: active ? c.label : c.sep),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          child: Text(label),
        ),
      );
    }

    return Container(
      key: const Key('rangebar'),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Text(
              '全选',
              style: TextStyle(fontSize: 13, color: c.sec),
            ),
          ),
          chip('今日', 'today'),
          chip('本周', 'week'),
          chip('本月', 'month'),
          chip('清除', 'none'),
        ],
      ),
    );
  }
}

class _SelBar extends StatelessWidget {
  const _SelBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      key: const Key('sumbar'),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.sep)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '已选 ${store.selCount} 项',
                key: const Key('sel-count'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  store.selAnchorId == null
                      ? '点击标记起点，上下滑动可区间连选'
                      : '已定起点，上下滑动可区间全选',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('cancel-summary'),
                  onPressed: store.cancelSummary,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.ink,
                    side: BorderSide(color: c.ax),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('generate-summary'),
                  onPressed: store.selCount == 0 ? null : store.genSummary,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.label,
                    disabledBackgroundColor: c.ax,
                    foregroundColor: c.onLabel,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  child: const Text('生成总结'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 时间轴轨道：左侧 1px 竖线 + 10×10 轴点（原型 .tl-item/.tl-node）。
/// 首项线从点下方起、末项线到点上方止、单项无线，跨项距连续成轨。
class _TimelineRail extends StatelessWidget {
  const _TimelineRail({
    super.key,
    required this.first,
    required this.last,
    required this.child,
  });
  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return CustomPaint(
      painter: _TimelineRailPainter(
        first: first,
        last: last,
        lineColor: c.sep,
        dotFillColor: c.bg,
        dotBorderColor: c.ax,
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 26),
        child: child,
      ),
    );
  }
}

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({
    required this.first,
    required this.last,
    required this.lineColor,
    required this.dotFillColor,
    required this.dotBorderColor,
  });

  final bool first;
  final bool last;
  final Color lineColor;
  final Color dotFillColor;
  final Color dotBorderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final only = first && last;
    if (!only) {
      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      final top = first ? 9.0 : 0.0;
      final bottom = last ? 9.0 : size.height;
      if (bottom > top) {
        canvas.drawLine(Offset(5.0, top), Offset(5.0, bottom), linePaint);
      }
    }
    const dotCenter = Offset(5.0, 13.0);
    canvas.drawCircle(
      dotCenter,
      4.25,
      Paint()
        ..color = dotFillColor
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      dotCenter,
      4.25,
      Paint()
        ..color = dotBorderColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_TimelineRailPainter oldDelegate) =>
      oldDelegate.first != first ||
      oldDelegate.last != last ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.dotFillColor != dotFillColor ||
      oldDelegate.dotBorderColor != dotBorderColor;
}

/// 事件卡：标题、时间、2–3 行生活摘要；点开显示更完整概述与详情按钮。
class _EventCardView extends StatelessWidget {
  const _EventCardView({
    required this.event,
    required this.store,
    this.cardKey,
  });
  final RecordEvent event;
  final AppStore store;
  final GlobalKey? cardKey;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final open = store.openCardId == event.id;
    final picked = store.selMode && store.selIds.contains(event.id);
    final isAnchor =
        store.selMode && !event.live && store.selAnchorId == event.id;
    final activePhotos = store.activePhotosForEvent(event);
    final mergeBg = c.isDark
        ? const Color(0xFF172738)
        : const Color(0xFFEEF5FF);
    final mergeBorder = c.isDark
        ? const Color(0xFF28486B)
        : const Color(0xFFC2DBFF);
    final mergeFg = c.isDark
        ? const Color(0xFF8CC4FF)
        : const Color(0xFF0F4C81);
    return Padding(
      key: Key('timeline-item-${event.id}'),
      padding: const EdgeInsets.only(bottom: 36),
      child: Align(
        alignment: Alignment.centerLeft,
        child: KeyedSubtree(
          key: cardKey,
          child: SelectionMarker(
            checked: picked,
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (store.selMode && !event.live)
                GestureDetector(
                  key: Key('selbox-${event.id}'),
                  onTap: () => store.toggleSel(event.id),
                  child: Container(
                    margin: const EdgeInsets.only(top: 2, right: 10),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: picked ? c.ok : c.ax,
                        width: 1.6,
                      ),
                      color: picked ? c.ok : Colors.transparent,
                    ),
                    child: picked
                        ? const Icon(Icons.check, size: 15, color: Colors.white)
                        : null,
                  ),
                ),
              Expanded(
                child: InkWell(
                  key: Key('card-${event.id}'),
                  onTap: () => store.tapCard(event.id, isSummary: false),
                  borderRadius: BorderRadius.circular(12),
                  // 设计稿 .card 只有 margin-bottom，没有底板/边框/阴影：
                  // 事件是时间轴上的列表行，卡片形态只属于总结（.sumcard）。
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  event.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.1,
                                    color: c.label,
                                  ),
                                ),
                                if (event.live) ...[
                                  const SizedBox(height: 6),
                                  const _EventNoteBadge(
                                    text: '整理中',
                                    live: true,
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      '${event.time} · ${event.dur}',
                                      key: Key('when-${event.id}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: c.sec,
                                      ),
                                    ),
                                    if (event.mergedSliceCount > 1 &&
                                        event.speakers != '无语音')
                                      Container(
                                        key: Key('ev-merge-badge-${event.id}'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          // 对齐 prototype `.merge-chip`：浅蓝底 + 蓝字（深色下深海蓝底 + 亮蓝字）
                                          color: mergeBg,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: mergeBorder,
                                          ),
                                        ),
                                          child: Text(
                                          '已合并 ${event.mergedSliceCount} 分片',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                            color: mergeFg,
                                          ),
                                        ),
                                      ),
                                    if (isAnchor)
                                      Container(
                                        key: Key('sel-anchor-badge-${event.id}'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: RCColors.ink,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: const Text(
                                          '起点',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (event.brief.trim().isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    event.brief.trim(),
                                    key: Key('card-summary-${event.id}'),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.6,
                                      color: c.ink,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (activePhotos.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            _PhotoStackThumb(
                              key: Key('pics-${event.id}'),
                              photos: activePhotos,
                            ),
                          ],
                        ],
                      ),
                      if (open) ...[
                        if (event.longText.trim().isNotEmpty &&
                            event.longText.trim() != event.brief.trim()) ...[
                          const SizedBox(height: 10),
                          Text(
                            event.longText,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.55,
                              color: c.ink,
                            ),
                          ),
                        ],
                        if (!event.live) ...[
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton(
                              key: Key('detail-${event.id}'),
                              onPressed: () =>
                                  store.openDetail(event.id, fresh: true),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: c.label,
                                side: BorderSide(color: c.ax),
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(fontSize: 13),
                              ),
                              child: const Text('详情'),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// 同一时段多路并发但语义不同（如手表/手机在会议室 + 蓝牙外出通话）的双列分叉卡。
class _ForkedEventCardView extends StatelessWidget {
  const _ForkedEventCardView({required this.pair, required this.store});

  final ForkedEventPair pair;
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final headerBg = c.isDark
        ? const Color(0xFF1D2430)
        : const Color(0xFFF3F6FC);
    return Padding(
      key: Key('timeline-item-${pair.forkGroupId}'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Container(
        key: Key('fork-card-${pair.forkGroupId}'),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.sep),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: Key('fork-header-${pair.forkGroupId}'),
              color: headerBg,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(Icons.call_split_rounded, size: 14, color: c.info),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '双路并发 · 内容不同已保留',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    pair.time,
                    style: TextStyle(fontSize: 11.5, color: c.sec),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: c.sep),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ForkBranchColumn(
                    key: Key('fork-col-left-${pair.left.id}'),
                    event: pair.left,
                    store: store,
                    isLeft: true,
                    withLeftBorder: false,
                  ),
                ),
                Expanded(
                  child: _ForkBranchColumn(
                    key: Key('fork-col-right-${pair.right.id}'),
                    event: pair.right,
                    store: store,
                    isLeft: false,
                    withLeftBorder: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ForkBranchColumn extends StatelessWidget {
  const _ForkBranchColumn({
    super.key,
    required this.event,
    required this.store,
    required this.isLeft,
    required this.withLeftBorder,
  });

  final RecordEvent event;
  final AppStore store;
  final bool isLeft;
  final bool withLeftBorder;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final picked = store.selMode && store.selIds.contains(event.id);
    final devLabel = (event.sourceDeviceLabel ?? '').trim().isNotEmpty
        ? event.sourceDeviceLabel!.trim()
        : (isLeft ? '蓝牙硬件' : '手机本机');
    final badgeBg = isLeft
        ? (c.isDark ? const Color(0xFF172738) : const Color(0xFFEEF5FF))
        : (c.isDark ? const Color(0xFF1B2B23) : const Color(0xFFECF9F2));
    final badgeFg = isLeft
        ? (c.isDark ? const Color(0xFF8CC4FF) : const Color(0xFF0F4C81))
        : (c.isDark ? const Color(0xFF7BE0AD) : const Color(0xFF126B3F));

    return InkWell(
      onTap: () {
        if (store.selMode && !event.live) {
          store.toggleSel(event.id);
        } else if (!event.live) {
          store.openDetail(event.id, fresh: true);
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: withLeftBorder
            ? BoxDecoration(border: Border(left: BorderSide(color: c.sep)))
            : null,
        child: SelectionMarker(
          checked: picked,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Container(
                      key: Key('fork-dev-${event.id}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        devLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: badgeFg,
                        ),
                      ),
                    ),
                  ),
                  if (store.selMode && !event.live) ...[
                    const SizedBox(width: 4),
                    GestureDetector(
                      key: Key('chk-${event.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => store.toggleSel(event.id),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: picked ? c.ok : c.ax,
                            width: 1.5,
                          ),
                          color: picked ? c.ok : Colors.transparent,
                        ),
                        child: picked
                            ? const Icon(
                                Icons.check,
                                size: 12,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                event.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: c.label,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${event.time} · ${event.dur}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: c.sec),
              ),
              if (event.brief.trim().isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  event.brief.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 1.4, color: c.ink),
                ),
              ],
              if (!event.live) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    key: Key('fork-detail-${event.id}'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => store.openDetail(event.id, fresh: true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        '详情 ›',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.label,
                        ),
                      ),
                    ),
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

/// 总结 Action Card：pending / generating（进度）/ done（查看结果入口）。
class _SummaryCardView extends StatelessWidget {
  const _SummaryCardView({required this.card, required this.store});
  final SummaryCard card;
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final locked = card.state != SummaryState.done;
    Widget inner;
    switch (card.state) {
      case SummaryState.pending:
        inner = Column(
          key: const Key('sumcard-pending'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '手动总结',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.label,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${card.time} · 选择来源切片中',
              style: TextStyle(fontSize: 12, color: c.sec),
            ),
          ],
        );
      case SummaryState.generating:
        inner = Column(
          key: const Key('sumcard-generating'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '正在生成总结',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                ),
                TextButton(
                  key: Key('sumcard-cancel-${card.id}'),
                  onPressed: () => store.cancelGeneratingSummary(card.id),
                  style: TextButton.styleFrom(
                    foregroundColor: c.sec,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${card.time} · 分析检查中',
              style: TextStyle(fontSize: 12, color: c.sec),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  key: const Key('sumcard-prog'),
                  value: card.progress / 100,
                  minHeight: 4,
                  backgroundColor: c.sep,
                  valueColor: AlwaysStoppedAnimation(c.ok),
                ),
              ),
            ),
          ],
        );
      case SummaryState.failed:
        inner = Column(
          key: const Key('sumcard-failed'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '总结生成失败',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.label,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              card.error ?? '请稍后重试',
              style: TextStyle(fontSize: 12, color: c.sec),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('sumcard-retry'),
                  onPressed: () => store.retryGeneration(card.id),
                  child: const Text('重试'),
                ),
                TextButton(
                  key: const Key('sumcard-dismiss'),
                  onPressed: () => store.dismissFailed(card.id),
                  child: const Text('放弃'),
                ),
              ],
            ),
          ],
        );
      case SummaryState.done:
        final picCount = store.activePhotoCountForSummary(card);
        final rangeText =
            (card.rangeLabel != null && card.rangeLabel!.isNotEmpty)
            ? card.rangeLabel!
            : card.time;
        inner = Column(
          key: const Key('sumcard-done'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    card.title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                ),
                // 总结没有详情页：整张卡片可点，箭头只做「会进下一页」的提示
                Icon(Icons.chevron_right, size: 16, color: c.ax),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Flexible(
                  child: Text(
                    '$rangeText · 已选 ${card.srcIds.length} 片段',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                ),
                if (picCount > 0) ...[
                  Text(
                    ' · ',
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                  Text(
                    '含 $picCount 张图片',
                    key: Key('sumpics-${card.id}'),
                    style: TextStyle(fontSize: 12, color: c.sec),
                  ),
                ],
              ],
            ),
          ],
        );
    }
    return Padding(
      key: Key('timeline-item-${card.id}'),
      padding: const EdgeInsets.only(bottom: 36),
      child: InkWell(
        key: Key('card-${card.id}'),
        onTap: locked ? null : () => store.tapCard(card.id, isSummary: true),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          key: Key('sumcard-${card.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          // 设计稿 .sumcard：只有总结才是卡片（底板 + 1px 分隔线边框 + 12 圆角）
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.sep),
          ),
          child: inner,
        ),
      ),
    );
  }
}

/// 同步/装载提示条：阶段文案 + 真实进度（不做假动画）。
class _SyncBanner extends StatelessWidget {
  const _SyncBanner({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final text = store.syncStage != null ? store.syncText : '正在读取本地录音…';
    final progress = store.syncStage != null ? store.syncProgress : null;
    return Container(
      key: const Key('sync-banner'),
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  key: const Key('sync-text'),
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                key: const Key('sync-progress'),
                value: progress.clamp(0, 1),
                minHeight: 3,
                backgroundColor: c.sep,
                valueColor: AlwaysStoppedAnimation(c.ok),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分段状态小徽标：仅用于正在整理的直播段。
class _EventNoteBadge extends StatelessWidget {
  const _EventNoteBadge({required this.text, required this.live});

  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final bg = live
        ? (c.isDark ? const Color(0xFF321B18) : const Color(0xFFFDF1EC))
        : (c.isDark ? const Color(0xFF242428) : const Color(0xFFF2F2EE));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: c.danger,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: live ? c.danger : c.sec,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态文案：区分「没录音」「正在整理」「整理失败」「录了但没识别到语音」。
///
/// 关键：**失败的录音不能算"正在整理"**。否则一条永远处理不完的录音
/// 会让时间轴永远停在"正在整理"，用户既看不到失败原因，也等不到结果。
String _emptyText(AppStore store, {bool deviceReady = true}) {
  final files = store.recordingFiles;
  if (files.isEmpty) {
    return deviceReady
        ? '还没有录音\n下拉可从录音卡取回'
        : '还没有录音\n连上录音卡后下拉取回';
  }
  final pending = files.where((f) => f.stage != RecordingStage.ready).toList();
  if (pending.isEmpty) return '录音里没有识别到语音';
  // 只剩失败项：如实说失败，并带上第一条可读原因
  if (pending.every((f) => f.stage == RecordingStage.failed)) {
    // 没连卡时，这些只是等人来核对的历史残留，不该一打开就红着脸报错；
    // 连上卡之后才如实说"有 N 条没处理完"。
    if (!deviceReady) {
      return '还没有可显示的录音\n连上录音卡后可核对并重试';
    }
    final reason = pending.first.error;
    return reason == null || reason.isEmpty
        ? '有 ${pending.length} 条录音未能处理\n下拉可重试'
        : '有 ${pending.length} 条录音未能处理\n$reason';
  }
  // 还有真在跑的：才说正在整理
  if (pending.any((f) => f.stage != RecordingStage.failed)) {
    return '正在整理本地录音…\n完成后会出现在时间轴';
  }
  return '录音里没有识别到语音';
}

/// 45px 正方形相册缩略图：1 张单图、2~3 张层叠、超过 3 张第 4 层显示总数遮罩。
class _PhotoStackThumb extends StatelessWidget {
  const _PhotoStackThumb({super.key, required this.photos});

  final List<EventPhoto> photos;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final count = photos.length;
    if (count == 0) return const SizedBox.shrink();
    if (count == 1) {
      return SizedBox(
        width: 45,
        height: 45,
        child: _tile(c, photos.first, size: 45),
      );
    }
    final layers = count > 3 ? 4 : count;
    final tileSize = layers == 2 ? 39.0 : (layers == 3 ? 36.0 : 34.0);
    final step = (45.0 - tileSize) / (layers - 1);
    return SizedBox(
      width: 45,
      height: 45,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < layers; i++)
            Positioned(
              left: i * step,
              top: (layers - 1 - i) * step,
              width: tileSize,
              height: tileSize,
              child: _tile(
                c,
                photos[i],
                size: tileSize,
                overlayCount: (count > 3 && i == layers - 1) ? count : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(
    RCColorScheme c,
    EventPhoto p, {
    required double size,
    int? overlayCount,
  }) {
    final phBg = c.isDark ? const Color(0xFF242428) : const Color(0xFFEAEAE4);
    final phInner = c.isDark
        ? const Color(0xFF2A2A2E)
        : const Color(0xFFE6E6E0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: phBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.card, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PhotoThumbnail(
            path: p.path,
            logicalWidth: size,
            source: p.source,
            placeholderIconSize: 16,
            placeholderColor: phInner,
          ),
          if (overlayCount != null)
            ColoredBox(
              color: const Color(0x88000000),
              child: Center(
                child: Text(
                  '$overlayCount',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 当天分组顶部的「未归类图片」条目（从对话详情标记「不属于本段」后移入）。
class _UnclassifiedPhotosCardView extends StatelessWidget {
  const _UnclassifiedPhotosCardView({required this.card});

  final UnclassifiedPhotosCard card;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final store = StoreScope.of(context);
    final title = card.dayOffset == 0 ? '今日未归类图片' : '${card.dayLabelText}未归类图片';
    return Padding(
      key: Key('card-unc-${card.dayOffset}'),
      padding: const EdgeInsets.only(bottom: 28),
      child: Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.sep),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: store.selMode
              ? null
              : () => store.openUnclassified(card.dayOffset, fresh: true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: c.label,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: c.ax,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _PhotoStackThumb(
                      key: Key('unc-pics-${card.dayOffset}'),
                      photos: card.photos,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '已移出对话流 · 共 ${card.photos.length} 张',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.sec,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      key: Key('unc-dismiss-day-${card.dayOffset}'),
                      onTap: () => store.dismissUnclassifiedDay(card.dayOffset),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.bg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: c.sep),
                        ),
                        child: Text(
                          '不归类',
                          style: TextStyle(fontSize: 11.5, color: c.sec),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 待转写录音缓存横幅：录音阶段静默落盘，查看或满周期时统一批量转写并按活动合并。
class _PendingAudioBanner extends StatelessWidget {
  const _PendingAudioBanner({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final mins = math.max(1, (store.pendingLocalAudioDurationMs / 60000).round());
    return Padding(
      key: const Key('pending-audio-banner'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.sep),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () =>
              unawaited(store.transcribeAndOrganizePending(reason: 'manual')),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 18,
                  color: c.sec,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '待转写录音 · ${store.pendingLocalAudioCount} 段（约 $mins 分钟）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '点击立即转写并按活动整合，或下拉刷新',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.sec),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: c.label,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '立即转写',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: c.onLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 连续无意义口水/静音记录折叠成的轻量胶囊；点击可查看明细并跳入单独详情。
class _TrivialClusterView extends StatelessWidget {
  const _TrivialClusterView({required this.card, required this.onTap});
  final TrivialClusterCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final label = card.count > 1 ? '无意义碎碎念 · ${card.count} 段' : '无意义碎碎念';
    return Padding(
      key: Key('trivial-cluster-${card.id}'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: c.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: c.sep),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 14,
                    color: c.sec,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: label,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: c.sec,
                            ),
                          ),
                          TextSpan(
                            text: '  ${card.timeRange} · ${card.totalDur}',
                            style: TextStyle(fontSize: 11.5, color: c.ax),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right,
                    size: 15,
                    color: c.ax,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showTrivialClusterSheet(
  BuildContext context,
  AppStore store,
  TrivialClusterCard card,
) {
  final c = context.rc;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetCtx) {
      final sc = sheetCtx.rc;
      final maxH = MediaQuery.of(sheetCtx).size.height * 0.65;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          key: const Key('trivial-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '无意义碎碎念（${card.count} 段）',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: sc.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '已自动折迭零碎试麦与静音片段，点任意一条查看详情',
                          style: TextStyle(fontSize: 12, color: sc.sec),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    icon: Icon(Icons.close, size: 20, color: sc.sec),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: sc.sep),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                  16,
                  10,
                  16,
                  RCDims.pageBottomPad,
                ),
                itemCount: card.items.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: sc.sep),
                itemBuilder: (_, index) {
                  final e = card.items[index];
                  final snippet = e.brief.trim().isNotEmpty
                      ? e.brief.trim()
                      : (e.speakers == '无语音' ? '纯环境音或静音片段' : '点击查看原始记录');
                  return InkWell(
                    key: Key('trivial-item-${e.id}'),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      store.openDetail(e.id, fresh: true);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: sc.ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${e.time} · ${e.dur}${e.speakers == '无语音' ? ' · 无语音' : ''}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: sc.sec,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  snippet,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: sc.sec,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: sc.ax,
                          ),
                        ],
                      ),
                    ),
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

class _StickyRangeButton extends StatelessWidget {
  const _StickyRangeButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: c.label,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: c.onLabel),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.onLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
