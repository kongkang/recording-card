/// 5 authentic Home / Timeline screen implementations matching `design-demos/dir-1.html`–`dir-5.html`:
/// - Braun Field: Hardware OLED oscilloscope panel + tactile 3D keys + hairline flat rows
/// - Chronos: Day segment switcher + duration-proportional vertical time axis + dashed silence gaps
/// - Folio: Broadsheet serif pull-quote masthead + horizontal rule editorial index
/// - Nocturne: OLED studio telemetry strip + hairline acoustic spectrum rows
/// - Air: Living coral/teal state pill + airy floating glass/card stack
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import '../../core/store/app_store.dart';
import '../../core/store/device_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/audio/recording_status.dart';
import '../../widgets/photo_thumbnail.dart';
import '../../widgets/quota_soft_banner.dart';
import '../../widgets/recording_status_block.dart';
import 'styled_chrome.dart';

/// Deterministic acoustic energy bar heights (`0.22..1.0`) derived from event data.
List<double> deriveEventEnergyBars(RecordEvent e, {int count = 16}) {
  var seed = e.id.hashCode ^ e.title.hashCode ^ e.dur.hashCode;
  final speechLen = e.dialog.length * 19 + e.raw.length * 7;
  final bars = <double>[];
  for (var i = 0; i < count; i++) {
    seed = (seed * 1103515245 + 12345 + i * 97 + speechLen) & 0x7fffffff;
    final norm = ((seed >> 8) % 72 + 24) / 100.0;
    bars.add(norm.clamp(0.24, 0.98));
  }
  if (e.mark.isNotEmpty && bars.length > 4) {
    bars[bars.length ~/ 2] = 1.0;
  }
  return bars;
}

double eventDurationMinutes(RecordEvent e) {
  final sec = parseDurationSeconds(e.dur);
  if (sec != null && sec > 0) return sec / 60.0;
  return 5.0;
}

class StyledTimelineView extends StatefulWidget {
  const StyledTimelineView({
    super.key,
    required this.store,
    required this.recordingStatus,
    required this.device,
    required this.onRefresh,
    required this.onOpenTrivialCluster,
  });

  final AppStore store;
  final RecordingStatusController? recordingStatus;
  final DeviceStore? device;
  final Future<void> Function() onRefresh;
  final Future<void> Function(TrivialClusterCard card) onOpenTrivialCluster;

  @override
  State<StyledTimelineView> createState() => _StyledTimelineViewState();
}

class _StyledTimelineViewState extends State<StyledTimelineView> {
  String _chronosDay = 'today'; // 'today' | 'yesterday' | 'all'
  bool _chronosDayInitialized = false;
  int _sessionMarks = 0;
  bool _wasRecording = false;

  @override
  void initState() {
    super.initState();
    widget.device?.retainClock();
    _wasRecording = isAnyRecording(widget.device);
    widget.device?.addListener(_onDeviceChanged);
  }

  @override
  void didUpdateWidget(covariant StyledTimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device != widget.device) {
      oldWidget.device?.removeListener(_onDeviceChanged);
      oldWidget.device?.releaseClock();
      widget.device?.retainClock();
      widget.device?.addListener(_onDeviceChanged);
      _wasRecording = isAnyRecording(widget.device);
    }
  }

  void _onDeviceChanged() {
    final nowRec = isAnyRecording(widget.device);
    if (nowRec && !_wasRecording && mounted) {
      setState(() => _sessionMarks = 0);
    }
    _wasRecording = nowRec;
  }

  @override
  void dispose() {
    widget.device?.removeListener(_onDeviceChanged);
    widget.device?.releaseClock();
    super.dispose();
  }

  Future<void> _toggleRecord(BuildContext context) async {
    final device = widget.device;
    if (device == null) return;
    String? err;
    if (device.isConnected) {
      err = await device.toggleRecording();
    } else {
      final ok = await device.togglePhoneRecording();
      if (!ok) {
        err = device.phoneRecordingError;
      }
    }
    if (err != null && err.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _tapMark(BuildContext context) async {
    final device = widget.device;
    if (device == null) return;
    final messenger = ScaffoldMessenger.of(context);
    String msg = '已打重点标记';
    if (device.isConnected && device.isRecording) {
      final err = await device.markNow();
      msg = err ?? '已打重点标记';
    } else if (device.isPhoneRecording) {
      device.recordPhoneMark();
    } else {
      msg = '请先开始录音再打重点';
    }
    if (!mounted) return;
    if (msg == '已打重点标记') {
      setState(() => _sessionMarks += 1);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(duration: const Duration(seconds: 1), content: Text(msg)),
      );
  }

  Widget _buildListenables(
    Widget Function(BuildContext context, DeviceStore? dev) builder,
  ) {
    final dev = widget.device;
    if (dev == null) {
      return Builder(builder: (ctx) => builder(ctx, null));
    }
    return ListenableBuilder(
      listenable: dev,
      builder: (ctx, _) => builder(ctx, dev),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final styleId = context.rcStyle.styleId;
    final entries = store.feedEntries;
    if (!_chronosDayInitialized && entries.isNotEmpty) {
      _chronosDayInitialized = true;
      final hasToday = entries.any(
        (e) => e is FeedDayHeaderEntry && e.dayOffset == 0,
      );
      _chronosDay = hasToday ? 'today' : 'all';
    }

    return _buildListenables((context, dev) {
      return switch (styleId) {
        RCUIStyleId.braunField => _BraunFieldHome(
          store: store,
          device: dev,
          recordingStatus: widget.recordingStatus,
          sessionMarks: _sessionMarks,
          onRefresh: widget.onRefresh,
          onToggleRec: () => _toggleRecord(context),
          onTapMark: () => _tapMark(context),
          onOpenTrivial: widget.onOpenTrivialCluster,
        ),
        RCUIStyleId.chronos => _ChronosHome(
          store: store,
          device: dev,
          recordingStatus: widget.recordingStatus,
          dayFilter: _chronosDay,
          onDayChanged: (v) => setState(() => _chronosDay = v),
          onRefresh: widget.onRefresh,
          onOpenTrivial: widget.onOpenTrivialCluster,
        ),
        RCUIStyleId.folio => _FolioHome(
          store: store,
          device: dev,
          recordingStatus: widget.recordingStatus,
          onRefresh: widget.onRefresh,
          onOpenTrivial: widget.onOpenTrivialCluster,
        ),
        RCUIStyleId.nocturne => _NocturneHome(
          store: store,
          device: dev,
          recordingStatus: widget.recordingStatus,
          onRefresh: widget.onRefresh,
          onToggleRec: () => _toggleRecord(context),
          onOpenTrivial: widget.onOpenTrivialCluster,
        ),
        RCUIStyleId.air => _AirHome(
          store: store,
          device: dev,
          recordingStatus: widget.recordingStatus,
          onRefresh: widget.onRefresh,
          onToggleRec: () => _toggleRecord(context),
          onOpenTrivial: widget.onOpenTrivialCluster,
        ),
        RCUIStyleId.warmPaper => const SizedBox.shrink(),
      };
    });
  }
}

// ── Shared Helpers ─────────────────────────────────────────────────────────────

Widget _styledStatusHeader(
  AppStore store,
  RecordingStatusController? recordingStatus,
) {
  final show = !store.selMode && store.filter != FeedFilter.summary;
  if (!show) return const SizedBox.shrink();
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RecordingStatusBlock(
        key: const Key('tl-status-block'),
        controller: recordingStatus,
        syncActive: store.syncStage != null,
        loadingActive: store.loading,
        syncText: store.syncText,
        syncProgress: store.syncStage != null ? store.syncProgress : null,
      ),
      QuotaSoftBanner(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        onOpenMembership: () => store.openSettingSub('membership'),
      ),
    ],
  );
}

Widget _styledThumbTile(
  EventPhoto photo, {
  required double size,
  required double radius,
  Border? border,
  int? totalCount,
}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: border,
    ),
    clipBehavior: Clip.antiAlias,
    child: Stack(
      fit: StackFit.expand,
      children: [
        PhotoThumbnail(
          path: photo.path,
          logicalWidth: size,
          source: photo.source,
          placeholderIconSize: size * 0.36,
        ),
        if (totalCount != null && totalCount > 1)
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xAA000000),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$totalCount',
                style: const TextStyle(
                  fontSize: 9.5,
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

Widget _styledMultiSelectBar(
  BuildContext context,
  AppStore store, {
  required Color bg,
  required Color fg,
  required Color accentBg,
  required Color accentFg,
  required Color chipBorder,
  required double radius,
  bool serif = false,
}) {
  return Container(
    key: const Key('sumbar'),
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (id, lbl) in const [
              ('today', '今日'),
              ('week', '本周'),
              ('month', '本月'),
              ('none', '清除'),
            ])
              InkWell(
                key: Key('chip-$id'),
                borderRadius: BorderRadius.circular(999),
                onTap: () => id == 'none' ? store.selNone() : store.selRange(id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: (id != 'none' && store.activeQuickRange == id)
                        ? accentBg
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: (id != 'none' && store.activeQuickRange == id)
                          ? accentBg
                          : chipBorder,
                    ),
                  ),
                  child: Text(
                    lbl,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: (id != 'none' && store.activeQuickRange == id)
                          ? accentFg
                          : fg,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                '已选 ${store.selCount} 段',
                key: const Key('sel-count'),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  fontFamilyFallback: serif
                      ? rcSerifFontFallback
                      : rcFontFallback,
                ),
              ),
            ),
            TextButton(
              key: const Key('cancel-summary'),
              onPressed: store.cancelSummary,
              style: TextButton.styleFrom(
                foregroundColor: fg.withValues(alpha: 0.78),
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              child: const Text('取消', style: TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 6),
            Material(
              color: store.selCount == 0
                  ? accentBg.withValues(alpha: 0.35)
                  : accentBg,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                key: const Key('generate-summary'),
                borderRadius: BorderRadius.circular(8),
                onTap: store.selCount == 0 ? null : store.genSummary,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Text(
                    '生成总结',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: accentFg,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

Widget _styledSummaryCardBlock(
  BuildContext context,
  AppStore store,
  SummaryCard card, {
  required Color bg,
  required Border border,
  required Color titleColor,
  required Color subColor,
  required Color accentColor,
  required double radius,
  List<BoxShadow>? shadow,
  EdgeInsets margin = const EdgeInsets.fromLTRB(16, 0, 16, 12),
  bool serifTitle = false,
}) {
  final locked = store.selMode && card.state != SummaryState.done;
  if (card.state == SummaryState.pending) {
    return Container(
      key: Key('card-${card.id}'),
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        border: border,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow,
      ),
      child: Row(
        children: [
          Icon(Icons.edit_note_rounded, size: 18, color: accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '多选总结草稿 · 在下方勾选录音片段后点「生成总结」',
              style: TextStyle(fontSize: 12.5, color: subColor),
            ),
          ),
        ],
      ),
    );
  }
  if (card.state == SummaryState.generating) {
    return Container(
      key: Key('card-${card.id}'),
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        border: border,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow,
      ),
      child: InkWell(
        onTap: locked ? null : () => store.tapCard(card.id, isSummary: true),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: accentColor,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '正在整理总结… ${card.progress}%',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  if (card.state == SummaryState.failed) {
    return Container(
      key: Key('card-${card.id}'),
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        border: border,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '总结生成失败 · ${card.error ?? '请重试'}',
              style: TextStyle(fontSize: 13, color: subColor),
            ),
          ),
          TextButton(
            onPressed: () => store.retryGeneration(card.id),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  final picCount = store.activePhotoCountForSummary(card);
  final pendingTodos = card.todos.length;
  return Container(
    key: Key('timeline-item-${card.id}'),
    margin: margin,
    decoration: BoxDecoration(
      color: bg,
      border: border,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: shadow,
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('card-${card.id}'),
        onTap: locked ? null : () => store.tapCard(card.id, isSummary: true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title ?? '会议总结',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                        fontFamilyFallback: serifTitle
                            ? rcSerifFontFallback
                            : rcFontFallback,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '总结 · $pendingTodos 项待办${picCount > 0 ? ' · 含 $picCount 张图片' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: accentColor),
            ],
          ),
        ),
      ),
    ),
  );
}

// ── 1. BRAUN FIELD HOME (`dir-1.html`) ─────────────────────────────────────────

class _BraunFieldHome extends StatelessWidget {
  const _BraunFieldHome({
    required this.store,
    required this.device,
    required this.recordingStatus,
    required this.sessionMarks,
    required this.onRefresh,
    required this.onToggleRec,
    required this.onTapMark,
    required this.onOpenTrivial,
  });

  final AppStore store;
  final DeviceStore? device;
  final RecordingStatusController? recordingStatus;
  final int sessionMarks;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onToggleRec;
  final Future<void> Function() onTapMark;
  final Future<void> Function(TrivialClusterCard card) onOpenTrivial;

  @override
  Widget build(BuildContext context) {
    final rec = isAnyRecording(device);
    final clock = activeRecordingClock(device);
    final entries = store.feedEntries;
    final bottomPad = styledListBottomPadding(
      RCUIStyleId.braunField,
      bottomInset: MediaQuery.paddingOf(context).bottom,
    );

    return RefreshIndicator(
      key: const Key('timeline-refresh'),
      onRefresh: onRefresh,
      child: ListView(
        key: const Key('timeline-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(0, 8, 0, bottomPad),
        children: [
          _styledStatusHeader(store, recordingStatus),
          if (store.filter != FeedFilter.summary)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
              child: Column(
                children: [
                  // Hardware OLED Oscilloscope LCD
                  Container(
                    key: const Key('braun-lcd-panel'),
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131412),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF242420),
                        width: 2,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    clock,
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                      height: 1.05,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                      fontFamilyFallback: rcMonoFontFallback,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              sessionMarks > 0
                                  ? '重点 ×$sessionMarks'
                                  : (rec ? 'REC' : 'STANDBY'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFFF8B5E),
                                fontFamilyFallback: rcMonoFontFallback,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 28,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var i = 0; i < 14; i++) ...[
                                if (i > 0) const SizedBox(width: 5),
                                Expanded(
                                  child: FractionallySizedBox(
                                    heightFactor: rec
                                        ? const [
                                            0.30,
                                            0.56,
                                            0.82,
                                            0.62,
                                            0.42,
                                            0.92,
                                            0.68,
                                            0.48,
                                            0.86,
                                            0.58,
                                            0.76,
                                            0.44,
                                            0.90,
                                            0.54,
                                          ][i]
                                        : 0.16,
                                    alignment: Alignment.bottomCenter,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: (rec && i % 3 == 1)
                                            ? const Color(0xFFFF5514)
                                            : const Color(0xFF464741),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Tactile 3D hardware key pair
                  Row(
                    key: const Key('braun-key-pair'),
                    children: [
                      Expanded(
                        flex: 13,
                        child: _BraunKeyButton(
                          label: rec ? '停止录音' : '开始录音',
                          orange: rec,
                          onTap: onToggleRec,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 10,
                        child: _BraunKeyButton(
                          icon: Icons.flag_outlined,
                          label: '打重点',
                          orange: false,
                          onTap: onTapMark,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

          // Day label + Multi-select toggle bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  store.filter == FeedFilter.summary ? '总结归档' : '今天',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF5C5B53),
                  ),
                ),
                _BraunMiniButton(
                  label: store.selMode ? '取消' : '多选总结',
                  onTap: store.selMode ? store.cancelSummary : store.startSummary,
                ),
              ],
            ),
          ),

          if (store.selMode)
            _styledMultiSelectBar(
              context,
              store,
              bg: const Color(0xFF161614),
              fg: Colors.white,
              accentBg: const Color(0xFFFF5514),
              accentFg: const Color(0xFF121210),
              chipBorder: const Color(0xFF3E3E38),
              radius: 12,
            ),

          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Text(
                  store.filter == FeedFilter.summary
                      ? '暂无总结，点击「多选总结」生成'
                      : '还没有录音记录',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF5C5B53)),
                ),
              ),
            )
          else
            for (var idx = 0; idx < entries.length; idx++)
              _buildEntry(context, entries[idx], idx == 0),
        ],
      ),
    );
  }

  Widget _buildEntry(BuildContext context, FeedListEntry entry, bool isFirst) {
    return switch (entry) {
      final FeedDayHeaderEntry h => (isFirst && h.dayOffset == 0)
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey('tl-day-${h.dayOffset}'),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
              child: Text(
                h.dayLabel,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF5C5B53),
                ),
              ),
            ),
      final FeedItemEntry it => switch (it.item) {
        final SummaryCard s => _styledSummaryCardBlock(
          context,
          store,
          s,
          bg: const Color(0xFFFAFAF5),
          border: Border.all(color: const Color(0xFFD8D7CE)),
          titleColor: const Color(0xFF161614),
          subColor: const Color(0xFF5C5B53),
          accentColor: const Color(0xFFB83200),
          radius: 10,
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        ),
        final UnclassifiedPhotosCard u => InkWell(
          key: Key('card-unc-${u.dayOffset}'),
          onTap: () => store.openUnclassified(u.dayOffset, fresh: true),
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFE5E4DC),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${u.photos.length} 张照片待归类',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF161614),
                  ),
                ),
                const Text(
                  '去归位',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFB83200),
                  ),
                ),
              ],
            ),
          ),
        ),
        final TrivialClusterCard t => InkWell(
          key: Key('trivial-cluster-${t.id}'),
          onTap: () => onOpenTrivial(t),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFD8D7CE))),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  size: 14,
                  color: Color(0xFF5C5B53),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '短片/静音 · ${t.count} 段 (${t.timeRange})',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF5C5B53),
                      fontFamilyFallback: rcMonoFontFallback,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: Color(0xFF5C5B53),
                ),
              ],
            ),
          ),
        ),
        final ForkedEventPair fp => Container(
          key: Key('fork-card-${fp.forkGroupId}'),
          margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAF5),
            border: Border.all(color: const Color(0xFF22221E), width: 1.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.left.id, fresh: true),
                  child: Text(
                    fp.left.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('|', style: TextStyle(color: Color(0xFF5C5B53))),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.right.id, fresh: true),
                  child: Text(
                    fp.right.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        final RecordEvent ev => _buildBraunEventRow(context, ev),
        _ => const SizedBox.shrink(),
      },
    };
  }

  Widget _buildBraunEventRow(BuildContext context, RecordEvent ev) {
    final photos = store.activePhotosForEvent(ev);
    final sel = store.selMode && store.selIds.contains(ev.id);
    return InkWell(
      key: Key('card-${ev.id}'),
      onTap: () {
        if (ev.live) return;
        if (store.selMode) {
          store.toggleSel(ev.id);
        } else {
          store.openDetail(ev.id, fresh: true);
        }
      },
      child: Container(
        margin: sel
            ? const EdgeInsets.fromLTRB(12, 0, 12, 6)
            : const EdgeInsets.symmetric(horizontal: 16),
        padding: sel
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 14)
            : const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
        decoration: sel
            ? BoxDecoration(
                color: const Color(0xFFFFF4EE),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF5514), width: 1.5),
              )
            : const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFD8D7CE))),
              ),
        child: Row(
          children: [
            if (store.selMode && !ev.live) ...[
              Container(
                key: Key('selbox-${ev.id}'),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: sel ? const Color(0xFFFF5514) : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: sel
                        ? const Color(0xFFFF5514)
                        : const Color(0xFF9E9C92),
                    width: 1.5,
                  ),
                ),
                child: sel
                    ? const Icon(Icons.check, size: 13, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ev.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF161614),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      Text(
                        ev.time,
                        key: Key('when-${ev.id}'),
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF5C5B53),
                          fontFamilyFallback: rcMonoFontFallback,
                        ),
                      ),
                      Text(
                        ev.dur,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF5C5B53),
                          fontFamilyFallback: rcMonoFontFallback,
                        ),
                      ),
                      if (ev.live)
                        const Text(
                          '整理中',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFE12D1C),
                          ),
                        ),
                      if (ev.mark.isNotEmpty)
                        Text(
                          ev.mark,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFB83200),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (photos.isNotEmpty) ...[
              const SizedBox(width: 12),
              _styledThumbTile(
                photos.first,
                size: 44,
                radius: 8,
                border: Border.all(color: const Color(0xFF22221E)),
                totalCount: photos.length,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BraunKeyButton extends StatelessWidget {
  const _BraunKeyButton({
    this.icon,
    required this.label,
    required this.orange,
    required this.onTap,
  });

  final IconData? icon;
  final String label;
  final bool orange;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = orange ? const Color(0xFFFF5514) : const Color(0xFFFAFAF5);
    final fg = orange ? const Color(0xFF121210) : const Color(0xFF161614);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFF22221E), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Color(0xFF22221E), offset: Offset(0, 3)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
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
}

class _BraunMiniButton extends StatelessWidget {
  const _BraunMiniButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: const Key('summary-start'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF22221E)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF161614),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 2. CHRONOS PROPORTIONAL AXIS HOME (`dir-2.html`) ──────────────────────────

class _ChronosHome extends StatelessWidget {
  const _ChronosHome({
    required this.store,
    required this.device,
    required this.recordingStatus,
    required this.dayFilter,
    required this.onDayChanged,
    required this.onRefresh,
    required this.onOpenTrivial,
  });

  final AppStore store;
  final DeviceStore? device;
  final RecordingStatusController? recordingStatus;
  final String dayFilter;
  final ValueChanged<String> onDayChanged;
  final Future<void> Function() onRefresh;
  final Future<void> Function(TrivialClusterCard card) onOpenTrivial;

  List<FeedListEntry> _filteredEntries() {
    final all = store.feedEntries;
    if (dayFilter == 'all' || store.filter == FeedFilter.summary) return all;
    final targetOffset = dayFilter == 'today' ? 0 : 1;
    final out = <FeedListEntry>[];
    var includeGroup = false;
    for (final entry in all) {
      if (entry is FeedDayHeaderEntry) {
        includeGroup = entry.dayOffset == targetOffset;
      } else if (includeGroup) {
        out.add(entry);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filteredEntries();
    final bottomPad = styledListBottomPadding(
      RCUIStyleId.chronos,
      bottomInset: MediaQuery.paddingOf(context).bottom,
    );

    final widgets = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is FeedDayHeaderEntry) {
        widgets.add(
          Padding(
            key: ValueKey('tl-day-${entry.dayOffset}'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              entry.dayLabel,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF525968),
              ),
            ),
          ),
        );
      } else if (entry is FeedItemEntry) {
        final item = entry.item;
        final next = (i + 1 < entries.length) ? entries[i + 1] : null;
        final nextIsEvent =
            next is FeedItemEntry && next.item is RecordEvent;
        if (item is RecordEvent) {
          widgets.add(_buildAxisEventRow(context, item));
          if (nextIsEvent) {
            widgets.add(
              Padding(
                padding: const EdgeInsets.only(left: 71),
                child: CustomPaint(
                  size: const Size(2, 24),
                  painter: _DashedConnectorPainter(const Color(0xFFDCE2EC)),
                ),
              ),
            );
          } else {
            widgets.add(const SizedBox(height: 10));
          }
        } else if (item is SummaryCard) {
          widgets.add(
            _styledSummaryCardBlock(
              context,
              store,
              item,
              bg: const Color(0xFFEFF4FF),
              border: Border.all(color: const Color(0xFFD5E1FA)),
              titleColor: const Color(0xFF111318),
              subColor: const Color(0xFF1D4ED8),
              accentColor: const Color(0xFF1D4ED8),
              radius: 12,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            ),
          );
        } else if (item is UnclassifiedPhotosCard) {
          widgets.add(
            InkWell(
              key: Key('card-unc-${item.dayOffset}'),
              onTap: () => store.openUnclassified(item.dayOffset, fresh: true),
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF2F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${item.photos.length} 张照片待归类',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111318),
                      ),
                    ),
                    const Text(
                      '去归位',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1D4ED8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        } else if (item is TrivialClusterCard) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: InkWell(
                key: Key('trivial-cluster-${item.id}'),
                onTap: () => onOpenTrivial(item),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFE2E6EE)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '低语音/静音片段 · ${item.count} 段 (${item.timeRange})',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF525968),
                    ),
                  ),
                ),
              ),
            ),
          );
        } else if (item is ForkedEventPair) {
          widgets.add(
            Container(
              key: Key('fork-card-${item.forkGroupId}'),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFE2E6EE)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => store.openDetail(item.left.id, fresh: true),
                      child: Text(item.left.title, maxLines: 1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () => store.openDetail(item.right.id, fresh: true),
                      child: Text(item.right.title, maxLines: 1),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      }
    }

    return Column(
      children: [
        // Day switcher + 框选总结
        Padding(
          key: const Key('chronos-day-bar'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAEEF5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (k, lbl) in const [
                      ('today', '今天'),
                      ('yesterday', '昨天'),
                      ('all', '全部'),
                    ])
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => onDayChanged(k),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: dayFilter == k
                                ? Colors.white
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            lbl,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: dayFilter == k
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: dayFilter == k
                                  ? const Color(0xFF111318)
                                  : const Color(0xFF525968),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Material(
                color: store.selMode ? const Color(0xFF1D4ED8) : Colors.white,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  key: const Key('summary-start'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: store.selMode
                      ? store.cancelSummary
                      : store.startSummary,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: store.selMode
                            ? const Color(0xFF1D4ED8)
                            : const Color(0xFFD0D7E3),
                      ),
                    ),
                    child: Text(
                      store.selMode ? '取消' : '框选总结',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: store.selMode
                            ? Colors.white
                            : const Color(0xFF111318),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            key: const Key('timeline-refresh'),
            onRefresh: onRefresh,
            child: ListView(
              key: const Key('chronos-axis-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(0, 4, 0, bottomPad),
              children: [
                _styledStatusHeader(store, recordingStatus),
                if (store.selMode)
                  _styledMultiSelectBar(
                    context,
                    store,
                    bg: const Color(0xFFEFF4FF),
                    fg: const Color(0xFF111318),
                    accentBg: const Color(0xFF1D4ED8),
                    accentFg: Colors.white,
                    chipBorder: const Color(0xFFC8D7F4),
                    radius: 12,
                  ),
                if (widgets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: Center(
                      child: Text(
                        '该时段暂无录音记录',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF525968),
                        ),
                      ),
                    ),
                  )
                else
                  ...widgets,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAxisEventRow(BuildContext context, RecordEvent ev) {
    final photos = store.activePhotosForEvent(ev);
    final sel = store.selMode && store.selIds.contains(ev.id);
    final durMin = eventDurationMinutes(ev);
    final double boxHeight = durMin >= 15
        ? 132.0
        : (durMin >= 7 ? 96.0 : 68.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left proportional time ruler column
            SizedBox(
              width: 56,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(0, 4, 10, 4),
                      decoration: const BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: Color(0xFFCBD5E1),
                            width: 1.5,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            ev.time,
                            key: Key('when-${ev.id}'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF525968),
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            ev.dur,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF525968),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 8,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Color(0xFF111318),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Right proportional ribbon card
            Expanded(
              child: Material(
                color: sel ? const Color(0xFFEFF4FF) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: Key('card-${ev.id}'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    if (ev.live) return;
                    if (store.selMode) {
                      store.toggleSel(ev.id);
                    } else {
                      store.openDetail(ev.id, fresh: true);
                    }
                  },
                  child: Container(
                    constraints: BoxConstraints(minHeight: boxHeight),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: sel
                            ? const Color(0xFF1D4ED8)
                            : const Color(0xFFE2E6EE),
                        width: sel ? 1.5 : 1.0,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      if (store.selMode && !ev.live) ...[
                                        Icon(
                                          sel
                                              ? Icons.check_circle
                                              : Icons.radio_button_unchecked,
                                          key: Key('selbox-${ev.id}'),
                                          size: 16,
                                          color: sel
                                              ? const Color(0xFF1D4ED8)
                                              : const Color(0xFF94A3B8),
                                        ),
                                        const SizedBox(width: 6),
                                      ],
                                      Expanded(
                                        child: Text(
                                          ev.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF111318),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (ev.brief.trim().isNotEmpty) ...[
                                    const SizedBox(height: 5),
                                    Text(
                                      ev.brief.trim(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFF525968),
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (photos.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              _styledThumbTile(
                                photos.first,
                                size: 42,
                                radius: 8,
                                totalCount: photos.length,
                              ),
                            ],
                          ],
                        ),
                        if (ev.mark.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.only(left: 8),
                            decoration: const BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: Color(0xFFB91C1C),
                                  width: 2.5,
                                ),
                              ),
                            ),
                            child: Text(
                              ev.mark,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFB91C1C),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashedConnectorPainter extends CustomPainter {
  const _DashedConnectorPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (double y = 0; y < size.height; y += 6) {
      canvas.drawLine(
        Offset(0, y),
        Offset(0, math.min(y + 3, size.height)),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedConnectorPainter oldDelegate) =>
      oldDelegate.color != color;
}

// ── 3. ARCHIVAL FOLIO HOME (`dir-3.html`) ──────────────────────────────────────

class _FolioHome extends StatelessWidget {
  const _FolioHome({
    required this.store,
    required this.device,
    required this.recordingStatus,
    required this.onRefresh,
    required this.onOpenTrivial,
  });

  final AppStore store;
  final DeviceStore? device;
  final RecordingStatusController? recordingStatus;
  final Future<void> Function() onRefresh;
  final Future<void> Function(TrivialClusterCard card) onOpenTrivial;

  @override
  Widget build(BuildContext context) {
    final entries = store.feedEntries;
    final bottomPad = styledListBottomPadding(
      RCUIStyleId.folio,
      bottomInset: MediaQuery.paddingOf(context).bottom,
    );

    RecordEvent? leadEv;
    for (final e in store.events) {
      if (!e.live && e.brief.trim().isNotEmpty) {
        leadEv = e;
        break;
      }
    }
    leadEv ??= store.events.isNotEmpty ? store.events.first : null;
    final leadText = (leadEv != null && leadEv.brief.trim().isNotEmpty)
        ? leadEv.brief.trim()
        : (leadEv?.title ?? '今日录音内容将自动整理成头版纪要');

    return RefreshIndicator(
      key: const Key('timeline-refresh'),
      onRefresh: onRefresh,
      child: ListView(
        key: const Key('timeline-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(0, 6, 0, bottomPad),
        children: [
          _styledStatusHeader(store, recordingStatus),
          // Broadsheet lead pull-quote
          if (store.filter != FeedFilter.summary)
            InkWell(
              key: const Key('folio-lead-quote'),
              onTap: leadEv == null
                  ? null
                  : () => store.openDetail(leadEv!.id, fresh: true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '今日头版结论',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFA62B21),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '「$leadText」',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        height: 1.42,
                        color: Color(0xFF1C1917),
                        fontFamilyFallback: rcSerifFontFallback,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Broadsheet 1px ink section rule + compile summary trigger
          Container(
            margin: const EdgeInsets.fromLTRB(18, 4, 18, 4),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFF1C1917))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  store.filter == FeedFilter.summary ? '总结归档' : '今日目录',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF57534E),
                  ),
                ),
                Material(
                  color: store.selMode ? const Color(0xFFA62B21) : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    key: const Key('summary-start'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: store.selMode
                        ? store.cancelSummary
                        : store.startSummary,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: store.selMode
                              ? const Color(0xFFA62B21)
                              : const Color(0xFFC8BDA8),
                        ),
                      ),
                      child: Text(
                        store.selMode ? '取消' : '编纂总结',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: store.selMode
                              ? const Color(0xFFF7F2E8)
                              : const Color(0xFF1C1917),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (store.selMode)
            _styledMultiSelectBar(
              context,
              store,
              bg: const Color(0xFF1C1917),
              fg: const Color(0xFFF7F2E8),
              accentBg: const Color(0xFFA62B21),
              accentFg: const Color(0xFFF7F2E8),
              chipBorder: const Color(0xFF57534E),
              radius: 8,
              serif: true,
            ),

          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Text(
                  store.filter == FeedFilter.summary
                      ? '暂无总结，点击「编纂总结」生成'
                      : '还没有录音记录',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF57534E)),
                ),
              ),
            )
          else
            for (var i = 0; i < entries.length; i++)
              _buildEntry(context, entries[i], i == 0),
        ],
      ),
    );
  }

  Widget _buildEntry(BuildContext context, FeedListEntry entry, bool isFirst) {
    return switch (entry) {
      final FeedDayHeaderEntry h => (isFirst && h.dayOffset == 0)
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey('tl-day-${h.dayOffset}'),
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 4),
              child: Text(
                h.dayLabel,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF57534E),
                ),
              ),
            ),
      final FeedItemEntry it => switch (it.item) {
        final SummaryCard s => _styledSummaryCardBlock(
          context,
          store,
          s,
          bg: const Color(0xFFFCF9F2),
          border: Border.all(color: const Color(0xFFDDD4C3)),
          titleColor: const Color(0xFF1C1917),
          subColor: const Color(0xFF57534E),
          accentColor: const Color(0xFFA62B21),
          radius: 6,
          margin: const EdgeInsets.fromLTRB(18, 6, 18, 10),
          serifTitle: true,
        ),
        final UnclassifiedPhotosCard u => InkWell(
          key: Key('card-unc-${u.dayOffset}'),
          onTap: () => store.openUnclassified(u.dayOffset, fresh: true),
          child: Container(
            margin: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D8),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${u.photos.length} 张照片待归卷',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1C1917),
                  ),
                ),
                const Text(
                  '去归位',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFA62B21),
                  ),
                ),
              ],
            ),
          ),
        ),
        final TrivialClusterCard t => InkWell(
          key: Key('trivial-cluster-${t.id}'),
          onTap: () => onOpenTrivial(t),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 18),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFDDD4C3))),
            ),
            child: Text(
              '零碎短片 · ${t.count} 段 (${t.timeRange})',
              style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF57534E),
                fontFamilyFallback: rcSerifFontFallback,
              ),
            ),
          ),
        ),
        final ForkedEventPair fp => Container(
          key: Key('fork-card-${fp.forkGroupId}'),
          margin: const EdgeInsets.fromLTRB(18, 6, 18, 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFCF9F2),
            border: Border.all(color: const Color(0xFFDDD4C3)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.left.id, fresh: true),
                  child: Text(fp.left.title, maxLines: 1),
                ),
              ),
              const Text(' / '),
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.right.id, fresh: true),
                  child: Text(fp.right.title, maxLines: 1),
                ),
              ),
            ],
          ),
        ),
        final RecordEvent ev => _buildFolioRow(context, ev),
        _ => const SizedBox.shrink(),
      },
    };
  }

  Widget _buildFolioRow(BuildContext context, RecordEvent ev) {
    final photos = store.activePhotosForEvent(ev);
    final sel = store.selMode && store.selIds.contains(ev.id);
    return InkWell(
      key: Key('card-${ev.id}'),
      onTap: () {
        if (ev.live) return;
        if (store.selMode) {
          store.toggleSel(ev.id);
        } else {
          store.openDetail(ev.id, fresh: true);
        }
      },
      child: Container(
        margin: sel
            ? const EdgeInsets.fromLTRB(14, 0, 14, 6)
            : const EdgeInsets.symmetric(horizontal: 18),
        padding: sel
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 14)
            : const EdgeInsets.symmetric(vertical: 15),
        decoration: sel
            ? BoxDecoration(
                color: const Color(0xFFFCF2EF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFA62B21), width: 1.5),
              )
            : const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFDDD4C3))),
              ),
        child: Row(
          children: [
            if (store.selMode && !ev.live) ...[
              Container(
                key: Key('selbox-${ev.id}'),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: sel ? const Color(0xFFA62B21) : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: sel
                        ? const Color(0xFFA62B21)
                        : const Color(0xFFC8BDA8),
                    width: 1.5,
                  ),
                ),
                child: sel
                    ? const Icon(Icons.check, size: 12, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ev.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                      color: Color(0xFF1C1917),
                      fontFamilyFallback: rcSerifFontFallback,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      Text(
                        ev.time,
                        key: Key('when-${ev.id}'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF57534E),
                        ),
                      ),
                      Text(
                        ev.dur,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF57534E),
                        ),
                      ),
                      if (ev.mark.isNotEmpty)
                        Text(
                          '朱批 ${ev.mark}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFA62B21),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (photos.isNotEmpty) ...[
              const SizedBox(width: 12),
              _styledThumbTile(
                photos.first,
                size: 42,
                radius: 5,
                totalCount: photos.length,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 4. NOCTURNE STUDIO HOME (`dir-4.html`) ─────────────────────────────────────

class _NocturneHome extends StatelessWidget {
  const _NocturneHome({
    required this.store,
    required this.device,
    required this.recordingStatus,
    required this.onRefresh,
    required this.onToggleRec,
    required this.onOpenTrivial,
  });

  final AppStore store;
  final DeviceStore? device;
  final RecordingStatusController? recordingStatus;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onToggleRec;
  final Future<void> Function(TrivialClusterCard card) onOpenTrivial;

  @override
  Widget build(BuildContext context) {
    final rec = isAnyRecording(device);
    final clock = rec ? activeRecordingClock(device) : '待机中';
    final subLine = device != null && device!.isConnected
        ? '${device!.batteryLevelText} · ${device!.batteryEtaText}'
        : '点击「开录」即时本机采音';
    final entries = store.feedEntries;
    final bottomPad = styledListBottomPadding(
      RCUIStyleId.nocturne,
      bottomInset: MediaQuery.paddingOf(context).bottom,
    );

    return RefreshIndicator(
      key: const Key('timeline-refresh'),
      onRefresh: onRefresh,
      child: ListView(
        key: const Key('timeline-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(0, 0, 0, bottomPad),
        children: [
          _styledStatusHeader(store, recordingStatus),
          // OLED Studio Telemetry Bar
          Container(
            key: const Key('nocturne-telemetry-strip'),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E222B))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        clock,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          color: rec
                              ? const Color(0xFFFBBF24)
                              : const Color(0xFFF3F4F6),
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontFamilyFallback: rcMonoFontFallback,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF8B92A1),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Row(
                  children: [
                    Material(
                      color: const Color(0xFF12141A),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        key: const Key('summary-start'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: store.selMode
                            ? store.cancelSummary
                            : store.startSummary,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFF282D38),
                            ),
                          ),
                          child: Text(
                            store.selMode ? '取消' : '多选',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF3F4F6),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: const Color(0xFFF5A623),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: onToggleRec,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6.5,
                          ),
                          child: Text(
                            rec ? '停录' : '开录',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111214),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (store.selMode)
            _styledMultiSelectBar(
              context,
              store,
              bg: const Color(0xFF12141A),
              fg: const Color(0xFFF3F4F6),
              accentBg: const Color(0xFFF5A623),
              accentFg: const Color(0xFF111214),
              chipBorder: const Color(0xFF282D38),
              radius: 10,
            ),

          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Text(
                  store.filter == FeedFilter.summary
                      ? '暂无总结，点击「多选」生成'
                      : '还没有录音记录',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF8B92A1)),
                ),
              ),
            )
          else
            for (final entry in entries) _buildEntry(context, entry),
        ],
      ),
    );
  }

  Widget _buildEntry(BuildContext context, FeedListEntry entry) {
    return switch (entry) {
      final FeedDayHeaderEntry h => Padding(
        key: ValueKey('tl-day-${h.dayOffset}'),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
        child: Text(
          h.dayLabel,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF8B92A1),
          ),
        ),
      ),
      final FeedItemEntry it => switch (it.item) {
        final SummaryCard s => _styledSummaryCardBlock(
          context,
          store,
          s,
          bg: const Color(0xFF12141A),
          border: Border.all(color: const Color(0xFF1E222B)),
          titleColor: Colors.white,
          subColor: const Color(0xFF8B92A1),
          accentColor: const Color(0xFFFBBF24),
          radius: 10,
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        ),
        final UnclassifiedPhotosCard u => InkWell(
          key: Key('card-unc-${u.dayOffset}'),
          onTap: () => store.openUnclassified(u.dayOffset, fresh: true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E222B))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${u.photos.length} 张照片待归类',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFBBF24),
                  ),
                ),
                const Text(
                  '去归位',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8B92A1)),
                ),
              ],
            ),
          ),
        ),
        final TrivialClusterCard t => InkWell(
          key: Key('trivial-cluster-${t.id}'),
          onTap: () => onOpenTrivial(t),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E222B))),
            ),
            child: Text(
              '低噪片段 · ${t.count} 段 (${t.timeRange})',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8B92A1)),
            ),
          ),
        ),
        final ForkedEventPair fp => Container(
          key: Key('fork-card-${fp.forkGroupId}'),
          margin: const EdgeInsets.fromLTRB(18, 8, 18, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF12141A),
            border: Border.all(color: const Color(0xFF1E222B)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.left.id, fresh: true),
                  child: Text(
                    fp.left.title,
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.right.id, fresh: true),
                  child: Text(
                    fp.right.title,
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
        final RecordEvent ev => _buildNocturneRow(context, ev),
        _ => const SizedBox.shrink(),
      },
    };
  }

  Widget _buildNocturneRow(BuildContext context, RecordEvent ev) {
    final photos = store.activePhotosForEvent(ev);
    final sel = store.selMode && store.selIds.contains(ev.id);
    final bars = deriveEventEnergyBars(ev, count: 14);
    final peakIdx = ev.mark.isNotEmpty ? (bars.length ~/ 2) : -1;

    return InkWell(
      key: Key('card-${ev.id}'),
      onTap: () {
        if (ev.live) return;
        if (store.selMode) {
          store.toggleSel(ev.id);
        } else {
          store.openDetail(ev.id, fresh: true);
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 15, 18, 15),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF1B1914) : Colors.transparent,
          border: const Border(bottom: BorderSide(color: Color(0xFF1E222B))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (store.selMode && !ev.live) ...[
                  Container(
                    key: Key('selbox-${ev.id}'),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: sel
                          ? const Color(0xFFF5A623)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: sel
                            ? const Color(0xFFF5A623)
                            : const Color(0xFF474C59),
                        width: 1.5,
                      ),
                    ),
                    child: sel
                        ? const Icon(
                            Icons.check,
                            size: 12,
                            color: Color(0xFF111214),
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ev.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 10,
                        children: [
                          Text(
                            ev.time,
                            key: Key('when-${ev.id}'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8B92A1),
                              fontFamilyFallback: rcMonoFontFallback,
                            ),
                          ),
                          Text(
                            ev.dur,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8B92A1),
                              fontFamilyFallback: rcMonoFontFallback,
                            ),
                          ),
                          if (ev.mark.isNotEmpty)
                            Text(
                              '${ev.mark} 重点',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFFBBF24),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (photos.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  _styledThumbTile(
                    photos.first,
                    size: 42,
                    radius: 7,
                    totalCount: photos.length,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              key: Key('nocturne-spectrum-${ev.id}'),
              height: 18,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < bars.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Expanded(
                      child: FractionallySizedBox(
                        heightFactor: bars[i],
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          decoration: BoxDecoration(
                            color: i == peakIdx
                                ? const Color(0xFFF5A623)
                                : const Color(0xFF2A303D),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 5. LIQUID FOLIO / AIR HOME (`dir-5.html`) ──────────────────────────────────

class _AirHome extends StatelessWidget {
  const _AirHome({
    required this.store,
    required this.device,
    required this.recordingStatus,
    required this.onRefresh,
    required this.onToggleRec,
    required this.onOpenTrivial,
  });

  final AppStore store;
  final DeviceStore? device;
  final RecordingStatusController? recordingStatus;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onToggleRec;
  final Future<void> Function(TrivialClusterCard card) onOpenTrivial;

  @override
  Widget build(BuildContext context) {
    final rec = isAnyRecording(device);
    final devLabel = device != null && device!.isConnected
        ? capsuleStatusLabel(device!, RCUIStyleId.air)
        : (device?.isPhoneRecording == true
            ? '本机录音'
            : (device?.isWatchFallbackRecording == true ? 'Apple Watch' : '未连接'));
    final clock = rec ? activeRecordingClock(device) : '待机';
    final entries = store.feedEntries;
    final bottomPad = styledListBottomPadding(
      RCUIStyleId.air,
      bottomInset: MediaQuery.paddingOf(context).bottom,
    );

    return RefreshIndicator(
      key: const Key('timeline-refresh'),
      onRefresh: onRefresh,
      child: ListView(
        key: const Key('timeline-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(0, 6, 0, bottomPad),
        children: [
          _styledStatusHeader(store, recordingStatus),
          // Living State Gradient Hero Pill
          Container(
            key: const Key('air-state-pill'),
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: rec
                    ? const [Color(0xFFE85D3F), Color(0xFFD9462B)]
                    : const [Color(0xFF1D6F72), Color(0xFF2F6F62)],
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1E0F172A),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: InkWell(
                    key: const Key('hw-capsule'),
                    onTap: device?.openSheet,
                    child: Row(
                      children: [
                        Text(
                          devLabel,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            clock,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()],
                              fontFamilyFallback: rcMonoFontFallback,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Material(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onToggleRec,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 6,
                      ),
                      child: Text(
                        rec ? '停录' : '开录',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (store.selMode)
            _styledMultiSelectBar(
              context,
              store,
              bg: const Color(0xFF0F172A),
              fg: Colors.white,
              accentBg: const Color(0xFF115E63),
              accentFg: Colors.white,
              chipBorder: const Color(0xFF475569),
              radius: 16,
            ),

          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Text(
                  store.filter == FeedFilter.summary
                      ? '暂无总结，点击右上角「多选总结」生成'
                      : '还没有录音记录',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF475569)),
                ),
              ),
            )
          else
            for (final entry in entries) _buildEntry(context, entry),
        ],
      ),
    );
  }

  Widget _buildEntry(BuildContext context, FeedListEntry entry) {
    const airShadow = [
      BoxShadow(color: Color(0x0D0F172A), blurRadius: 20, offset: Offset(0, 6)),
    ];
    return switch (entry) {
      final FeedDayHeaderEntry h => Padding(
        key: ValueKey('tl-day-${h.dayOffset}'),
        padding: EdgeInsets.fromLTRB(20, h.dayOffset == 0 ? 4 : 16, 20, 8),
        child: Text(
          h.dayLabel,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF475569),
          ),
        ),
      ),
      final FeedItemEntry it => switch (it.item) {
        final SummaryCard s => _styledSummaryCardBlock(
          context,
          store,
          s,
          bg: Colors.white,
          border: Border.all(color: Colors.transparent, width: 0),
          titleColor: const Color(0xFF0F172A),
          subColor: const Color(0xFF475569),
          accentColor: const Color(0xFF115E63),
          radius: 20,
          shadow: airShadow,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        ),
        final UnclassifiedPhotosCard u => Container(
          key: Key('card-unc-${u.dayOffset}'),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: airShadow,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => store.openUnclassified(u.dayOffset, fresh: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${u.photos.length} 张照片待归类',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFC9412C),
                      ),
                    ),
                    const Text(
                      '去归位',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        final TrivialClusterCard t => Container(
          key: Key('trivial-cluster-${t.id}'),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: airShadow,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onOpenTrivial(t),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                '零碎短片 · ${t.count} 段 (${t.timeRange})',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569)),
              ),
            ),
          ),
        ),
        final ForkedEventPair fp => Container(
          key: Key('fork-card-${fp.forkGroupId}'),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: airShadow,
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.left.id, fresh: true),
                  child: Text(fp.left.title, maxLines: 1),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => store.openDetail(fp.right.id, fresh: true),
                  child: Text(fp.right.title, maxLines: 1),
                ),
              ),
            ],
          ),
        ),
        final RecordEvent ev => _buildAirCard(context, ev, airShadow),
        _ => const SizedBox.shrink(),
      },
    };
  }

  Widget _buildAirCard(
    BuildContext context,
    RecordEvent ev,
    List<BoxShadow> shadow,
  ) {
    final photos = store.activePhotosForEvent(ev);
    final sel = store.selMode && store.selIds.contains(ev.id);
    return Container(
      key: Key('timeline-item-${ev.id}'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: sel ? const Color(0xFFF0F9FF) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: sel
            ? Border.all(color: const Color(0xFF115E63), width: 1.5)
            : null,
        boxShadow: shadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('card-${ev.id}'),
          onTap: () {
            if (ev.live) return;
            if (store.selMode) {
              store.toggleSel(ev.id);
            } else {
              store.openDetail(ev.id, fresh: true);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (store.selMode && !ev.live) ...[
                  Container(
                    key: Key('selbox-${ev.id}'),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: sel
                          ? const Color(0xFF115E63)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: sel
                            ? const Color(0xFF115E63)
                            : const Color(0xFFB4C8C5),
                        width: 1.5,
                      ),
                    ),
                    child: sel
                        ? const Icon(Icons.check, size: 13, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ev.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 10,
                        children: [
                          Text(
                            ev.time,
                            key: Key('when-${ev.id}'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF475569),
                            ),
                          ),
                          Text(
                            ev.dur,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF475569),
                            ),
                          ),
                          if (ev.mark.isNotEmpty)
                            Text(
                              '${ev.mark} 重点',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFC9412C),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (photos.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  _styledThumbTile(
                    photos.first,
                    size: 46,
                    radius: 11,
                    totalCount: photos.length,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
