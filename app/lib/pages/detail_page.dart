/// 详情页 —— 「对话详情 / 原始数据 / 被引用总结 N」平级 tab（refs 仅 N>0 显示）。
///
/// 有 v2 分段视图时（本地转写链路）：
/// - 对话详情：润色 turn；润色未完成时回退本地原始句并提示；
/// - 原始数据：按切片分组，展示时间、情绪、说话人推测与静音；
/// 没有视图时（旧数据/设计样例）回退 [RecordEvent] 的 dialog/raw。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/models/record.dart';
import '../core/models/recording.dart';
import '../core/models/segment_view.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../services/recordings/cleaned_dialogue.dart';
import '../services/transcribe/utterance_builder.dart';
import '../widgets/photo_preview_sheet.dart';
import '../widgets/photo_thumbnail.dart';
import '../widgets/quick_speaker_sheet.dart';
import '../widgets/raw_audio_player.dart';
import '../widgets/speaker_suggestion_banner.dart';
import '../widgets/store_scope.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.eventId,
    this.showPaneBack = false,
    this.backLabel,
  });

  final String eventId;

  /// 宽屏双栏：面板内返回按钮（窄屏走顶栏面包屑）
  final bool showPaneBack;
  final String? backLabel;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

sealed class _DetailListEntry {
  const _DetailListEntry();
}

class _DetailForkCompareEntry extends _DetailListEntry {
  const _DetailForkCompareEntry(this.sibling);
  final RecordEvent sibling;
}

class _DetailSilentEmptyEntry extends _DetailListEntry {
  const _DetailSilentEmptyEntry();
}

class _DetailOverviewEntry extends _DetailListEntry {
  const _DetailOverviewEntry(this.text);
  final String text;
}

class _DetailSpeakerSuggestBannerEntry extends _DetailListEntry {
  const _DetailSpeakerSuggestBannerEntry(this.eventId);
  final String eventId;
}

class _DetailDialogueBubbleEntry extends _DetailListEntry {
  const _DetailDialogueBubbleEntry({
    required this.firstTurnIndex,
    required this.turnIndices,
    required this.rawSpk,
    required this.displaySpk,
    required this.avatarSpk,
    required this.canQuickName,
    required this.paragraphs,
    required this.startClock,
  });

  final int firstTurnIndex;
  final List<int> turnIndices;
  final String rawSpk;
  final String displaySpk;
  final String avatarSpk;
  final bool canQuickName;
  final List<String> paragraphs;
  final String startClock;
}

class _DetailInlinePhotoEntry extends _DetailListEntry {
  const _DetailInlinePhotoEntry({
    required this.photo,
    required this.index,
    required this.quoteText,
  });

  final EventPhoto photo;
  final int index;
  final String? quoteText;
}

class _DetailRefSummaryEntry extends _DetailListEntry {
  const _DetailRefSummaryEntry({
    required this.summary,
    required this.picCount,
  });

  final SummaryCard summary;
  final int picCount;
}

class _DetailRawNoteEntry extends _DetailListEntry {
  const _DetailRawNoteEntry({
    required this.text,
    required this.bottomPad,
    this.muted = false,
  });

  final String text;
  final double bottomPad;
  final bool muted;
}

class _DetailRawSliceHeaderEntry extends _DetailListEntry {
  const _DetailRawSliceHeaderEntry({
    required this.sliceId,
    required this.label,
    required this.seekMs,
  });

  final String sliceId;
  final String label;
  final int seekMs;
}

class _DetailRawBubbleEntry extends _DetailListEntry {
  const _DetailRawBubbleEntry({
    required this.meta,
    required this.text,
    this.bubbleKey,
    this.staticActive = false,
    this.trackPlaybackPos = false,
    this.startMs = 0,
    this.endMs = 0,
    this.onTap,
  });

  final String meta;
  final String text;
  final Key? bubbleKey;
  final bool staticActive;
  final bool trackPlaybackPos;
  final int startMs;
  final int endMs;
  final VoidCallback? onTap;
}

class _DetailHeaderMemo {
  const _DetailHeaderMemo({
    required this.key,
    required this.refs,
    required this.speakerText,
    required this.hasAnyTurns,
    required this.hasMarkedSpeaker,
  });

  final Object key;
  final List<SummaryCard> refs;
  final String speakerText;
  final bool hasAnyTurns;
  final bool hasMarkedSpeaker;
}

class _DetailEntriesMemo {
  const _DetailEntriesMemo({required this.key, required this.entries});

  final Object key;
  final List<_DetailListEntry> entries;
}

class _DetailPageState extends State<DetailPage> {
  String _tab = 'dlg'; // dlg | raw | refs
  final GlobalKey<RawAudioPlayerState> _playerKey =
      GlobalKey<RawAudioPlayerState>();
  final ValueNotifier<int?> _activeFilePosMs = ValueNotifier<int?>(null);
  int _selectedMergedSliceIdx = 0;
  bool _showForkCompare = false;
  _DetailHeaderMemo? _headerMemo;
  _DetailEntriesMemo? _entriesMemo;

  @override
  void dispose() {
    _activeFilePosMs.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _activeFilePosMs.value = null;
      _selectedMergedSliceIdx = 0;
      _showForkCompare = false;
      _headerMemo = null;
      _entriesMemo = null;
    }
  }

  void _seekRawAudio(int fileMs) {
    final player = _playerKey.currentState;
    if (player == null) return;
    unawaited(player.seekToFileMs(fileMs, autoPlay: true));
  }

  ({int? clipStartMs, int? clipEndMs, int? gapCountOverride}) _audioClipFor(
    SegmentView? view,
  ) {
    if (view == null) {
      return (clipStartMs: null, clipEndMs: null, gapCountOverride: null);
    }
    int? gapCount;
    if (view.file.deviceName.startsWith('LIVE_')) {
      final mark = view.segment.mark ?? '';
      final m = RegExp(r'流中断\s*(\d+)\s*次').firstMatch(mark);
      gapCount = m != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
    }
    if (view.file.segments.length > 1) {
      final start = (view.segment.startAtMs - view.file.startAtMs).clamp(
        0,
        1 << 30,
      );
      final segEndMs =
          view.segment.endAtMs ??
          (view.file.startAtMs + view.file.durationMs);
      final end = (segEndMs - view.file.startAtMs).clamp(
        start,
        1 << 30,
      );
      if (end > start) {
        return (
          clipStartMs: start,
          clipEndMs: end,
          gapCountOverride: gapCount,
        );
      }
    }
    return (
      clipStartMs: 0,
      clipEndMs: view.file.durationMs > 0 ? view.file.durationMs : null,
      gapCountOverride: gapCount,
    );
  }

  _DetailHeaderMemo _ensureHeaderMemo(
    AppStore store,
    RecordEvent e,
    RecordEvent? sibling,
  ) {
    final key = (e.id, sibling?.id, store.dataRevision);
    final cached = _headerMemo;
    if (cached != null && cached.key == key) return cached;

    final refs = store.doneSummariesReferencing(e.id);
    final speakerText = lifeSpeakerLabel(store.displaySpeakersSummary(e));
    final dialogOrRaw = e.dialog.isNotEmpty ? e.dialog : e.raw;
    final hasAnyTurns = dialogOrRaw.any((t) => t.spk.trim() != '无语音');
    final markableSpeakers = store.speakerEntriesForEvents([e]);
    final hasMarkedSpeaker =
        markableSpeakers.any((s) => s.currentAlias.isNotEmpty) ||
        store.hasTurnOverridesFor([e]);
    final built = _DetailHeaderMemo(
      key: key,
      refs: refs,
      speakerText: speakerText,
      hasAnyTurns: hasAnyTurns,
      hasMarkedSpeaker: hasMarkedSpeaker,
    );
    _headerMemo = built;
    return built;
  }

  List<_DetailListEntry> _ensureEntries(
    AppStore store,
    RecordEvent e,
    List<SummaryCard> refs,
    SegmentView? view,
    RecordEvent? sibling,
  ) {
    final key = (
      e.id,
      _tab,
      _selectedMergedSliceIdx,
      _showForkCompare,
      sibling?.id,
      store.dataRevision,
    );
    final cached = _entriesMemo;
    if (cached != null && cached.key == key) return cached.entries;

    final tabEntries = switch (_tab) {
      'dlg' => _dialogEntries(store, e, view),
      'raw' => _rawEntries(store, e, view),
      'refs' => [
        for (final r in refs)
          _DetailRefSummaryEntry(
            summary: r,
            picCount: store.activePhotoCountForSummary(r),
          ),
      ],
      _ => const <_DetailListEntry>[],
    };
    final entries = (sibling != null && _showForkCompare)
        ? <_DetailListEntry>[_DetailForkCompareEntry(sibling), ...tabEntries]
        : tabEntries;
    _entriesMemo = _DetailEntriesMemo(key: key, entries: entries);
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final store = StoreScope.of(context);
    final RecordEvent? e = store.eventByIdOrNull(widget.eventId);
    if (e == null) {
      // 记录已被删除 / 历史栈里的失效 id：明确空态，不留红屏
      return Center(
        key: const Key('detail-missing'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                size: 36,
                color: c.ax,
              ),
              const SizedBox(height: 10),
              Text(
                '这条记录已不在本机',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '可能已被删除，或录音卡上的原文件已清理。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: c.sec),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                key: const Key('detail-missing-back'),
                onPressed: store.goBack,
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    final sibling = store.siblingForkEventFor(e.id);
    final header = _ensureHeaderMemo(store, e, sibling);
    final refs = header.refs;
    final view = store.segmentViewFor(e.id);
    final speakerText = header.speakerText;
    final dialogOrRaw = e.dialog.isNotEmpty ? e.dialog : e.raw;
    final hasAnyTurns = header.hasAnyTurns;
    final hasMarkedSpeaker = header.hasMarkedSpeaker;
    final entries = _ensureEntries(store, e, refs, view, sibling);

    return ColoredBox(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showPaneBack)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('pb-detail'),
                onPressed: store.goBack,
                icon: const Icon(Icons.chevron_left, size: 18),
                label: Text(widget.backLabel ?? '‹ 返回'),
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
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.title,
                  key: const Key('dt-h3'),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: c.label,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${_dayLabel(e)} ${e.time} · ${e.dur}',
                      key: const Key('dt-meta'),
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                    Text(
                      speakerText,
                      key: const Key('dt-speakers'),
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                    if (e.sourceDeviceLabel != null &&
                        e.sourceDeviceLabel!.trim().isNotEmpty)
                      Container(
                        key: const Key('dt-device-label'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: c.isDark
                              ? const Color(0xFF1D2838)
                              : const Color(0xFFEEF4FF),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: c.isDark
                                ? const Color(0xFF2D4363)
                                : const Color(0xFFC8DCFF),
                          ),
                        ),
                        child: Text(
                          e.sourceDeviceLabel!.trim(),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: c.isDark
                                ? const Color(0xFF93C5FD)
                                : const Color(0xFF1D4ED8),
                          ),
                        ),
                      ),
                    if (hasAnyTurns)
                      InkWell(
                        key: const Key('mark-speaker-btn'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          final firstTurn = dialogOrRaw.firstWhere(
                            (t) => t.spk.trim() != '无语音',
                            orElse: () => dialogOrRaw.first,
                          );
                          final firstIdx = dialogOrRaw.indexOf(firstTurn);
                          final safeIdx = firstIdx < 0 ? 0 : firstIdx;
                          showQuickSpeakerSheet(
                            context,
                            store: store,
                            event: e,
                            turnIndex: safeIdx,
                            rawSpeaker: firstTurn.spk,
                            sampleQuote: firstTurn.text,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: c.card,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: c.sep),
                          ),
                          child: Text(
                            hasMarkedSpeaker ? '编辑说话人' : '标记说话人',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: c.label,
                            ),
                          ),
                        ),
                      ),
                    if (e.mark.isNotEmpty)
                      Text(
                        e.mark,
                        style: TextStyle(fontSize: 12, color: c.ink),
                      ),
                  ],
                ),
                if (sibling != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    key: const Key('detail-fork-banner'),
                    padding: const EdgeInsets.fromLTRB(12, 9, 12, 6),
                    decoration: BoxDecoration(
                      color: c.isDark
                          ? const Color(0xFF1B2433)
                          : const Color(0xFFF3F6FC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.sep),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '同时间段检测到来自「${sibling.sourceDeviceLabel ?? '另一设备'}」的不同内容记录',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            fontWeight: FontWeight.w500,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              key: const Key('detail-fork-compare-toggle'),
                              onPressed: () => setState(
                                () => _showForkCompare = !_showForkCompare,
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              child: Text(
                                _showForkCompare ? '收起对照' : '展开双列对照',
                              ),
                            ),
                            TextButton(
                              key: const Key('detail-fork-switch'),
                              onPressed: () => store.openDetail(sibling.id),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              child: const Text('查看另一路 ›'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.sep)),
            ),
            child: Row(
              children: [
                _tabBtn(c, '对话详情', 'dlg'),
                _tabBtn(c, '原始数据', 'raw'),
                if (refs.isNotEmpty) _tabBtn(c, '被引用总结 ${refs.length}', 'refs'),
              ],
            ),
          ),
          if (_tab == 'raw')
            Builder(
              builder: (context) {
                final activeAudioView = (view != null && view.isMerged)
                    ? view.mergedChildren[_selectedMergedSliceIdx.clamp(
                        0,
                        view.mergedChildren.length - 1,
                      )]
                    : view;
                final currentWavPath = activeAudioView?.file.wavPath;
                if (activeAudioView?.file.isExternalImported == true &&
                    (currentWavPath == null || currentWavPath.isEmpty)) {
                  return const SizedBox.shrink();
                }
                final clip = _audioClipFor(activeAudioView);
                return Container(
                  key: const Key('raw-sticky-player'),
                  padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
                  decoration: BoxDecoration(
                    color: c.bg,
                    border: Border(bottom: BorderSide(color: c.sep)),
                  ),
                  child: RawAudioPlayer(
                    key: _playerKey,
                    fileKey: activeAudioView?.file.deviceName ?? e.id,
                    wavPath: currentWavPath,
                    durationHintMs: activeAudioView?.file.durationMs,
                    clipStartMs: clip.clipStartMs,
                    clipEndMs: clip.clipEndMs,
                    gapCountOverride: clip.gapCountOverride,
                    padding: EdgeInsets.zero,
                    onAudioDeleted: () => store.markRawAudioDeleted(
                      fileId: activeAudioView?.file.id,
                      deviceName: activeAudioView?.file.deviceName,
                      wavPath: currentWavPath,
                    ),
                    onFilePositionChanged: (ms) {
                      if (mounted && _activeFilePosMs.value != ms) {
                        _activeFilePosMs.value = ms;
                      }
                    },
                  ),
                );
              },
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                22,
                14,
                22,
                RCDims.pageBottomPad,
              ),
              scrollCacheExtent: const ScrollCacheExtent.pixels(320),
              addAutomaticKeepAlives: false,
              itemCount: entries.length,
              itemBuilder: (context, index) =>
                  _buildDetailEntry(context, c, store, e, entries[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForkComparePanel(
    RCColorScheme c,
    RecordEvent current,
    RecordEvent sibling,
  ) {
    Widget column(RecordEvent item, {required bool withLeftBorder}) {
      final turns = item.dialog.isNotEmpty ? item.dialog : item.raw;
      final preview = turns.take(6).toList();
      final devLabel = (item.sourceDeviceLabel ?? '').trim().isNotEmpty
          ? item.sourceDeviceLabel!.trim()
          : (item.sourceLane == 'ble' ? '蓝牙硬件' : '伴随设备');
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: withLeftBorder
            ? BoxDecoration(border: Border(left: BorderSide(color: c.sep)))
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.isDark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFEEF5FF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                devLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (preview.isEmpty)
              Text(
                item.brief.trim().isNotEmpty ? item.brief.trim() : '暂无转写内容',
                style: TextStyle(fontSize: 12, color: c.sec, height: 1.4),
              )
            else
              for (final t in preview) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    t.text,
                    style: TextStyle(fontSize: 12, color: c.ink, height: 1.4),
                  ),
                ),
              ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        key: const Key('detail-fork-compare-panel'),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.sep),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: column(current, withLeftBorder: false)),
            Expanded(child: column(sibling, withLeftBorder: true)),
          ],
        ),
      ),
    );
  }

  String _dayLabel(RecordEvent e) {
    if (e.dayOffset == 0) return '今天';
    if (e.dayOffset == 1) return '昨天';
    final d = DateTime.now().subtract(Duration(days: e.dayOffset));
    const dow = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${d.month}月${d.day}日 ${dow[d.weekday - 1]}';
  }

  Widget _tabBtn(RCColorScheme c, String label, String id) => Padding(
    padding: const EdgeInsets.only(right: 18),
    child: TextButton(
      key: Key('det-tab-$id'),
      onPressed: () => setState(() => _tab = id),
      style: TextButton.styleFrom(
        foregroundColor: _tab == id ? c.label : c.sec,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: _tab == id ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    ),
  );

  Widget _buildDetailEntry(
    BuildContext context,
    RCColorScheme c,
    AppStore store,
    RecordEvent e,
    _DetailListEntry entry,
  ) {
    switch (entry) {
      case _DetailForkCompareEntry(:final sibling):
        return _buildForkComparePanel(c, e, sibling);
      case _DetailSilentEmptyEntry():
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            key: const Key('detail-silent-empty'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Text(
              '这段时间没有识别到人声，可在「原始数据」回听原始录音。',
              style: TextStyle(
                fontSize: 13,
                height: 1.55,
                color: c.sec,
              ),
            ),
          ),
        );
      case _DetailSpeakerSuggestBannerEntry(:final eventId):
        return SpeakerSuggestionBanner(
          store: store,
          eventIds: [eventId],
          margin: const EdgeInsets.only(bottom: 14),
        );
      case _DetailOverviewEntry(:final text):
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            key: const Key('detail-overview-card'),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '阶段概述',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: c.sec,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: c.ink,
                  ),
                ),
              ],
            ),
          ),
        );
      case _DetailDialogueBubbleEntry():
        void openQuickSheet() {
          store.setPendingMergedBubbleTurns(
            e.id,
            entry.firstTurnIndex,
            entry.turnIndices,
          );
          unawaited(
            showQuickSpeakerSheet(
              context,
              store: store,
              event: e,
              turnIndex: entry.firstTurnIndex,
              rawSpeaker: entry.rawSpk,
              sampleQuote: entry.paragraphs.join('\n'),
            ).whenComplete(store.clearPendingMergedBubbleTurns),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                key: Key('turn-spk-${entry.firstTurnIndex}'),
                borderRadius: BorderRadius.circular(14),
                onTap: entry.canQuickName ? openQuickSheet : null,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _speakerColor(entry.displaySpk, isDark: c.isDark),
                  ),
                  child: Text(
                    _avatar(entry.avatarSpk),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: c.label,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      key: Key('turn-who-${e.id}-${entry.firstTurnIndex}'),
                      onTap: entry.canQuickName ? openQuickSheet : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '${entry.displaySpk} · ${entry.startClock}',
                              style: TextStyle(
                                fontSize: 11,
                                color: entry.canQuickName ? c.ink : c.sec,
                                fontWeight: entry.canQuickName
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (entry.canQuickName) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.edit_outlined,
                              size: 11,
                              color: c.sec,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      key: Key('turn-para-${e.id}-${entry.firstTurnIndex}'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.sep),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < entry.paragraphs.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            Text(
                              entry.paragraphs[i],
                              key: Key(
                                'turn-para-body-${e.id}-${entry.firstTurnIndex}-$i',
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.5,
                                color: c.label,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      case _DetailInlinePhotoEntry():
        return _inlinePhotoCard(
          c,
          store,
          e,
          entry.photo,
          entry.index,
          quoteText: entry.quoteText,
        );
      case _DetailRefSummaryEntry(:final summary, :final picCount):
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: c.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: c.sep),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: Key('ref-${summary.id}'),
              onTap: () => store.openSum(summary.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            summary.title ?? '',
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
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${summary.time} · 已选 ${summary.srcIds.length} 片段',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.sec,
                            ),
                          ),
                        ),
                        if (picCount > 0) ...[
                          Text(
                            ' · ',
                            style: TextStyle(
                              fontSize: 12,
                              color: c.sec,
                            ),
                          ),
                          Text(
                            '含 $picCount 张图片',
                            style: TextStyle(
                              fontSize: 12,
                              color: c.sec,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      case _DetailRawNoteEntry(:final text, :final bottomPad, :final muted):
        return Padding(
          padding: EdgeInsets.only(bottom: bottomPad),
          child: Text(
            text,
            style: TextStyle(
              fontSize: muted ? 12 : 12.5,
              color: muted ? c.ax : c.sec,
              height: 1.5,
            ),
          ),
        );
      case _DetailRawSliceHeaderEntry(:final sliceId, :final label, :final seekMs):
        return Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: InkWell(
            onTap: () => _seekRawAudio(seekMs),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                label,
                key: Key('raw-slice-$sliceId'),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.sec,
                ),
              ),
            ),
          ),
        );
      case _DetailRawBubbleEntry():
        return _buildRawBubble(c, entry);
    }
  }

  Widget _buildRawBubble(RCColorScheme c, _DetailRawBubbleEntry entry) {
    if (!entry.trackPlaybackPos) {
      return _rawBubble(
        c,
        entry.meta,
        entry.text,
        bubbleKey: entry.bubbleKey,
        active: entry.staticActive,
        onTap: entry.onTap,
      );
    }
    return ValueListenableBuilder<int?>(
      valueListenable: _activeFilePosMs,
      builder: (context, pos, _) {
        final active =
            pos != null && pos >= entry.startMs && pos <= entry.endMs;
        return _rawBubble(
          c,
          entry.meta,
          entry.text,
          bubbleKey: entry.bubbleKey,
          active: active,
          onTap: entry.onTap,
        );
      },
    );
  }

  List<_DetailListEntry> _dialogEntries(
    AppStore store,
    RecordEvent e,
    SegmentView? view,
  ) {
    final eventAnchorSec = _secOfDayFromClock(e.time) ?? 0;
    final hasEpochBase = view != null && view.file.startAtMs > 0;
    final baseMidnightMs = hasEpochBase
        ? _startOfDayEpochMs(view.file.startAtMs)
        : 0;

    final lines =
        <({String spk, String text, String clock, int startSec, int endSec})>[];
    if (hasEpochBase && view.turns.isNotEmpty) {
      for (final t in view.turns) {
        final ts = view.file.startAtMs + t.startMs;
        final te = view.file.startAtMs + t.endMs;
        lines.add((
          spk: t.speakerLabel,
          text: t.text,
          clock: '${_hms(ts)}—${_hms(te)}',
          startSec: _monotonicSecFromEpoch(ts, baseMidnightMs),
          endSec: _monotonicSecFromEpoch(te, baseMidnightMs),
        ));
      }
    } else if (hasEpochBase && view.utterances.isNotEmpty) {
      for (final u in view.utterances) {
        final label = u.speakerLabel ?? '未区分';
        final ts = view.file.startAtMs + u.startMs;
        final te = view.file.startAtMs + u.endMs;
        lines.add((
          spk: label,
          text: u.text,
          clock: '${_hms(ts)}—${_hms(te)}',
          startSec: _monotonicSecFromEpoch(ts, baseMidnightMs),
          endSec: _monotonicSecFromEpoch(te, baseMidnightMs),
        ));
      }
    } else {
      var runningSec = eventAnchorSec;
      for (final l in e.dialog) {
        final rawClock = l.src.replaceFirst('来源 ', '');
        var startSec = _unwrapClockSec(
          _secOfDayFromClock(rawClock) ?? runningSec,
          eventAnchorSec,
        );
        while (startSec < runningSec - 6 * 3600) {
          startSec += 86400;
        }
        final tail = rawClock.contains('—')
            ? rawClock.split('—').last.trim()
            : rawClock;
        var endSec = _unwrapClockSec(
          _secOfDayFromClock(tail) ?? startSec,
          eventAnchorSec,
        );
        while (endSec < startSec) {
          endSec += 86400;
        }
        if (endSec > runningSec) {
          runningSec = endSec;
        }
        lines.add((
          spk: l.spk,
          text: l.text,
          clock: rawClock,
          startSec: startSec,
          endSec: endSec,
        ));
      }
    }

    final activePhotos = store.activePhotosForEvent(e);
    final photoSecs = <int>[
      for (final p in activePhotos)
        if (hasEpochBase && p.capturedAtMs != null)
          _monotonicSecFromEpoch(p.capturedAtMs!, baseMidnightMs)
        else
          _unwrapClockSec(
            p.capturedAtMs != null
                ? (_secOfDayFromClock(_hms(p.capturedAtMs!)) ?? eventAnchorSec)
                : (_secOfDayFromClock(p.time) ?? eventAnchorSec),
            eventAnchorSec,
          ),
    ];

    String extractClockHead(String clock) {
      final parts = clock.split('—');
      return parts.first.trim();
    }

    // 同一说话人连续发言留在同一个气泡；短间隔拼成一段，停顿 >= 30 秒只在气泡内换段。
    final meaningful =
        <({
          String spk,
          String text,
          String clock,
          int startSec,
          int endSec,
          int turnIndex,
        })>[];
    for (var turnIdx = 0; turnIdx < lines.length; turnIdx++) {
      final l = lines[turnIdx];
      if (!isMeaningfulSpeechText(l.text)) continue;
      meaningful.add((
        spk: l.spk,
        text: l.text,
        clock: l.clock,
        startSec: l.startSec,
        endSec: l.endSec,
        turnIndex: turnIdx,
      ));
    }
    final bubbles = mergedDlgParagraphs(
      [
        for (final l in meaningful)
          CleanDialogueLine(
            speakerKey: store.displayTurnSpeaker(
              e,
              l.turnIndex,
              l.spk,
              includeGuessSuffix: false,
            ),
            text: l.text,
            startSec: l.startSec,
            endSec: l.endSec,
            turnIndex: l.turnIndex,
          ),
      ],
      photoSecs: photoSecs,
    );
    final lineByIndex = {for (final l in meaningful) l.turnIndex: l};

    final groups = <({
      int firstTurnIndex,
      List<int> turnIndices,
      String rawSpk,
      String displaySpk,
      String avatarSpk,
      bool canQuickName,
      List<String> paragraphs,
      String startClock,
      int sortSec,
    })>[];
    for (var bi = 0; bi < bubbles.length; bi++) {
      final bubble = bubbles[bi];
      final nextFirstIdx = bi + 1 < bubbles.length
          ? bubbles[bi + 1].firstTurnIndex
          : (1 << 30);
      final src = lineByIndex[bubble.firstTurnIndex];
      if (src == null) continue;
      final turnIndices = <int>[
        for (final m in meaningful)
          if (m.turnIndex >= bubble.firstTurnIndex &&
              m.turnIndex < nextFirstIdx)
            m.turnIndex,
      ];
      final baseDisplaySpk = lifeSpeakerLabel(
        store.displayTurnSpeaker(
          e,
          bubble.firstTurnIndex,
          src.spk,
          includeGuessSuffix: false,
        ),
      );
      final hintCandidate = store.pendingCandidateNameForEventSlot(
        e,
        src.spk,
        turnIndex: bubble.firstTurnIndex,
      );
      final displaySpk = (hintCandidate != null && hintCandidate.isNotEmpty)
          ? '$baseDisplaySpk · 疑似$hintCandidate?'
          : baseDisplaySpk;
      groups.add((
        firstTurnIndex: bubble.firstTurnIndex,
        turnIndices: turnIndices.isEmpty
            ? <int>[bubble.firstTurnIndex]
            : turnIndices,
        rawSpk: src.spk,
        displaySpk: displaySpk,
        avatarSpk: baseDisplaySpk,
        canQuickName: src.spk.trim() != '无语音',
        paragraphs: bubble.paragraphs,
        startClock: extractClockHead(src.clock),
        sortSec: bubble.startSec,
      ));
    }

    final entries = <({int sortSec, int order, _DetailListEntry entry})>[];
    var order = 0;
    for (final g in groups) {
      entries.add((
        sortSec: g.sortSec,
        order: order++,
        entry: _DetailDialogueBubbleEntry(
          firstTurnIndex: g.firstTurnIndex,
          turnIndices: g.turnIndices,
          rawSpk: g.rawSpk,
          displaySpk: g.displaySpk,
          avatarSpk: g.avatarSpk,
          canQuickName: g.canQuickName,
          paragraphs: g.paragraphs,
          startClock: g.startClock,
        ),
      ));
    }

    for (var i = 0; i < activePhotos.length; i++) {
      final p = activePhotos[i];
      final sortSec = photoSecs[i];
      String? nearestQuote;
      int? bestDelta;
      for (final l in lines) {
        final d = (l.startSec - sortSec).abs();
        if (bestDelta == null || d < bestDelta) {
          bestDelta = d;
          nearestQuote =
              '${lifeSpeakerLabel(store.displaySpeaker(e, l.spk, includeGuessSuffix: false))}：${l.text}';
        }
      }
      entries.add((
        sortSec: sortSec,
        order: order++,
        entry: _DetailInlinePhotoEntry(
          photo: p,
          index: i,
          quoteText: nearestQuote,
        ),
      ));
    }

    entries.sort((a, b) {
      final cmp = a.sortSec.compareTo(b.sortSec);
      return cmp != 0 ? cmp : a.order.compareTo(b.order);
    });

    final overviewText = e.longText.trim();
    final joinedFirst =
        groups.isNotEmpty ? groups.first.paragraphs.join('\n') : '';
    final showOverviewCard =
        groups.isNotEmpty &&
        isMeaningfulSpeechText(overviewText) &&
        !overviewText.contains('未检测到有效人声') &&
        !overviewText.contains('没有识别到人声') &&
        !overviewText.startsWith('已保存本地原始转写') &&
        !(groups.length == 1 && overviewText == joinedFirst.trim());

    return [
      if (groups.isEmpty) const _DetailSilentEmptyEntry(),
      if (showOverviewCard) _DetailOverviewEntry(overviewText),
      if (groups.isNotEmpty &&
          store.pendingSpeakerSuggestionsFor([e.id]).isNotEmpty)
        _DetailSpeakerSuggestBannerEntry(e.id),
      for (final item in entries) item.entry,
    ];
  }

  Widget _inlinePhotoCard(
    RCColorScheme c,
    AppStore store,
    RecordEvent e,
    EventPhoto p,
    int index, {
    String? quoteText,
  }) {
    final srcLabel = p.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
    return Padding(
      key: Key('dphoto-${e.id}-$index'),
      padding: const EdgeInsets.only(left: 38, bottom: 14),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 296),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.sep),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  key: Key('dphoto-thumb-${e.id}-$index'),
                  onTap: () => _showDetailPhotoPreview(
                    context,
                    store,
                    e,
                    p,
                    srcLabel,
                    quoteText: quoteText,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 72,
                      height: 72,
                      child: PhotoThumbnail(
                        path: p.path,
                        logicalWidth: 72,
                        source: p.source,
                        placeholderIconSize: 24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$srcLabel · ${p.time}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.sec,
                        ),
                      ),
                      const SizedBox(height: 8),
                      InkWell(
                        key: Key('dphoto-exclude-${e.id}-$index'),
                        onTap: () => store.excludePhoto(e.id, p.id),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: c.bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: c.sep),
                          ),
                          child: Text(
                            '不属于本段',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: c.sec,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetailPhotoPreview(
    BuildContext context,
    AppStore store,
    RecordEvent e,
    EventPhoto p,
    String srcLabel, {
    String? quoteText,
  }) {
    unawaited(
      showPhotoPreviewSheet(
        context,
        photo: p,
        title: '$srcLabel · ${p.time}',
        subtitle: e.title,
        quoteText: quoteText,
        onSecondaryAction: () => store.excludePhoto(e.id, p.id),
        secondaryActionLabel: '不属于本段',
      ),
    );
  }

  static int _startOfDayEpochMs(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  /// 以录音起点当日零点为锚点计算单调递增秒数（跨午夜 `00:xx` 自动大于 `23:5x`）。
  static int _monotonicSecFromEpoch(int epochMs, int baseMidnightMs) {
    return ((epochMs - baseMidnightMs) / 1000).round();
  }

  /// 纯时钟字符串场景下处理跨午夜（例如起点 `23:50`，后续 `00:05` 自动 `+86400`）。
  static int _unwrapClockSec(int rawSec, int anchorSec) {
    if (anchorSec >= 18 * 3600 && rawSec < 12 * 3600) {
      return rawSec + 86400;
    }
    return rawSec;
  }

  static int? _secOfDayFromClock(String raw) {
    final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    final sec = m.group(3) != null ? (int.tryParse(m.group(3)!) ?? 0) : 0;
    return h * 3600 + min * 60 + sec;
  }

  List<_DetailListEntry> _rawEntries(
    AppStore store,
    RecordEvent e,
    SegmentView? view,
  ) {
    // 播放器已置顶吸顶在「原始数据」tab 顶部（raw-sticky-player），此处只滚句子流。
    final entries = <_DetailListEntry>[];

    if (view == null) {
      for (var i = 0; i < e.raw.length; i++) {
        final l = e.raw[i];
        final parsedMs = _parseRelativeClockMs(l.src);
        entries.add(
          _DetailRawBubbleEntry(
            meta: '${_rawSpeakerLabel(store, e, l.spk)} · ${l.src}',
            text: l.text,
            bubbleKey: Key('raw-utt-$i'),
            onTap: parsedMs != null ? () => _seekRawAudio(parsedMs) : null,
          ),
        );
      }
      return entries;
    }

    if (view.isMergedSilent) {
      final selectedIdx = _selectedMergedSliceIdx.clamp(
        0,
        view.mergedChildren.length - 1,
      );
      entries.add(
        _DetailRawNoteEntry(
          text:
              '连续 ${view.mergedChildren.length} 个无语音切片已合并展示，点选任一切片可在上方播放器回听对应原始音频：',
          bottomPad: 10,
        ),
      );
      for (var i = 0; i < view.mergedChildren.length; i++) {
        final child = view.mergedChildren[i];
        final cStart = child.segment.startAtMs;
        final cEnd =
            child.segment.endAtMs ??
            (cStart +
                (child.file.durationMs > 0 ? child.file.durationMs : 1000));
        final durSec = ((cEnd - cStart) / 1000).round().clamp(1, 86400);
        final active = i == selectedIdx;
        entries.add(
          _DetailRawBubbleEntry(
            meta: '切片 ${i + 1} · ${_hms(cStart)}—${_hms(cEnd)} · $durSec 秒',
            text: child.file.deviceName,
            bubbleKey: Key('raw-merged-slice-$i'),
            staticActive: active,
            onTap: () {
              _activeFilePosMs.value = null;
              setState(() => _selectedMergedSliceIdx = i);
            },
          ),
        );
      }
      return entries;
    }

    if (view.isMergedSpeech) {
      final selectedIdx = _selectedMergedSliceIdx.clamp(
        0,
        view.mergedChildren.length - 1,
      );
      entries.add(
        _DetailRawNoteEntry(
          text:
              '连续 ${view.mergedChildren.length} 个分片已按 <30s 停顿自动合并，点击任一分片切换上方播放器回听对应原始 WAV：',
          bottomPad: 10,
        ),
      );
      for (var i = 0; i < view.mergedChildren.length; i++) {
        final child = view.mergedChildren[i];
        final cStart = child.segment.startAtMs;
        final cEnd =
            child.segment.endAtMs ??
            (cStart +
                (child.file.durationMs > 0 ? child.file.durationMs : 1000));
        final durSec = ((cEnd - cStart) / 1000).round().clamp(1, 86400);
        final active = i == selectedIdx;
        entries.add(
          _DetailRawBubbleEntry(
            meta: '分片 ${i + 1} · ${_hms(cStart)}—${_hms(cEnd)} · $durSec 秒',
            text: child.file.deviceName,
            bubbleKey: Key('raw-merged-slice-$i'),
            staticActive: active,
            onTap: () {
              _activeFilePosMs.value = null;
              setState(() => _selectedMergedSliceIdx = i);
            },
          ),
        );
        for (final u in child.utterances) {
          entries.add(
            _DetailRawBubbleEntry(
              meta:
                  '${_rawSpeakerLabel(store, e, u.speakerLabel ?? '未区分')} · '
                  '${_hms(child.file.startAtMs + u.startMs)} · ${_emotion(u.emotion)}',
              text: u.text,
              bubbleKey: Key('raw-utt-${u.id}'),
              trackPlaybackPos: active,
              startMs: u.startMs,
              endMs: u.endMs,
              onTap: () {
                final switched = _selectedMergedSliceIdx != i;
                if (switched) {
                  setState(() => _selectedMergedSliceIdx = i);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _seekRawAudio(u.startMs);
                  });
                } else {
                  _seekRawAudio(u.startMs);
                }
              },
            ),
          );
        }
      }
      return entries;
    }

    if (view.slices.isEmpty) {
      if (view.utterances.isEmpty) {
        entries.add(
          const _DetailRawNoteEntry(
            text: '暂无原始转写（静音或模型未识别到语音）。',
            bottomPad: 0,
          ),
        );
      } else {
        final hasAudioFile =
            view.file.wavPath != null && view.file.wavPath!.isNotEmpty;
        for (final u in view.utterances) {
          entries.add(
            _DetailRawBubbleEntry(
              meta:
                  '${_rawSpeakerLabel(store, e, u.speakerLabel ?? '未区分')} · '
                  '${_hms(view.file.startAtMs + u.startMs)} · ${_emotion(u.emotion)}',
              text: u.text,
              bubbleKey: Key('raw-utt-${u.id}'),
              trackPlaybackPos: true,
              startMs: u.startMs,
              endMs: u.endMs,
              onTap: hasAudioFile ? () => _seekRawAudio(u.startMs) : null,
            ),
          );
        }
      }
      return entries;
    }

    final utterancesBySlice = <String, List<RawUtterance>>{};
    for (final u in view.utterances) {
      (utterancesBySlice[u.sliceId] ??= []).add(u);
    }
    for (final slice in view.slices) {
      final sliceUtterances =
          utterancesBySlice[slice.id] ?? const <RawUtterance>[];
      entries.add(
        _DetailRawSliceHeaderEntry(
          sliceId: slice.id,
          label:
              '[${_hms(view.file.startAtMs + slice.startMs)}—'
              '${_hms(view.file.startAtMs + slice.endMs)}]',
          seekMs: slice.startMs,
        ),
      );
      for (final u in sliceUtterances) {
        entries.add(
          _DetailRawBubbleEntry(
            meta:
                '${_rawSpeakerLabel(store, e, u.speakerLabel ?? '未区分')} · '
                '${_hms(view.file.startAtMs + u.startMs)} · ${_emotion(u.emotion)}',
            text: u.text,
            bubbleKey: Key('raw-utt-${u.id}'),
            trackPlaybackPos: true,
            startMs: u.startMs,
            endMs: u.endMs,
            onTap: () => _seekRawAudio(u.startMs),
          ),
        );
      }
      if (slice.silenceAfterMs >= 2000) {
        final seconds = (slice.silenceAfterMs / 1000).round();
        entries.add(
          _DetailRawNoteEntry(
            text: '（静音约 $seconds 秒）',
            bottomPad: 12,
            muted: true,
          ),
        );
      }
    }
    return entries;
  }

  Widget _rawBubble(
    RCColorScheme c,
    String meta,
    String text, {
    Key? bubbleKey,
    bool active = false,
    VoidCallback? onTap,
  }) {
    final idleBg = c.isDark
        ? const Color(0xFF161619)
        : const Color(0xFFF6F6F2);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: active ? c.card : idleBg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: bubbleKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? c.label : (c.isDark ? c.sep : Colors.transparent),
                width: 1.2,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        meta,
                        style: TextStyle(
                          fontSize: 11,
                          color: active ? c.ink : c.sec,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (onTap != null)
                      Icon(
                        active
                            ? Icons.graphic_eq_rounded
                            : Icons.play_circle_outline_rounded,
                        size: 14,
                        color: active ? c.label : c.ax,
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: c.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static int? _parseRelativeClockMs(String raw) {
    final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
    if (m == null) return null;
    final a = int.tryParse(m.group(1)!) ?? 0;
    final b = int.tryParse(m.group(2)!) ?? 0;
    final c = m.group(3) != null ? int.tryParse(m.group(3)!) : null;
    if (c != null) return null; // HH:mm:ss 绝对墙钟无法单独推算文件相对毫秒
    return (a * 60 + b) * 1000;
  }

  static String _speakerText(String label) {
    final v = label.trim();
    if (v.isEmpty) return '说话人 未区分';
    if (v.startsWith('说话人')) return v;
    return '说话人 $v';
  }

  /// 「原始数据」tab 始终保留原始簇名，已标记时附括号备注，保留原始映射关系。
  static String _rawSpeakerLabel(
    AppStore store,
    RecordEvent event,
    String rawSpk,
  ) {
    final base = _speakerText(rawSpk);
    final alias = store.speakerAliasFor(event, rawSpk);
    if (alias == null || alias.isEmpty) return base;
    return '$base（已标：$alias）';
  }

  static String _emotion(String? emotion) {
    final v = (emotion ?? '').trim();
    return v.isEmpty ? '情绪 —' : '情绪 $v';
  }

  static String _avatar(String speaker) {
    final match = RegExp(r'\d+').firstMatch(speaker);
    if (match != null) return match.group(0)!;
    final cleaned = speaker.replaceAll('说话人', '').trim();
    if (cleaned.isEmpty || cleaned.startsWith('未')) return '未';
    return String.fromCharCode(cleaned.runes.first);
  }

  static Color _speakerColor(String speaker, {required bool isDark}) {
    const lightColors = [
      Color(0xFFDDE9DD),
      Color(0xFFE8E8E4),
      Color(0xFFE3E6F0),
      Color(0xFFF0E6DD),
    ];
    const darkColors = [
      Color(0xFF1F3324),
      Color(0xFF2B2B30),
      Color(0xFF22293A),
      Color(0xFF362A20),
    ];
    final colors = isDark ? darkColors : lightColors;
    final match = RegExp(r'\d+').firstMatch(speaker);
    final n = match != null
        ? int.tryParse(match.group(0)!) ?? 0
        : (speaker.isEmpty ? 0 : speaker.codeUnitAt(0));
    return colors[n % colors.length];
  }

  static String _hms(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}:'
        '${d.second.toString().padLeft(2, '0')}';
  }
}
