/// 详情页 —— 「对话详情 / 原始数据 / 被引用总结 N」平级 tab（refs 仅 N>0 显示）。
///
/// 有 v2 分段视图时（本地转写链路）：
/// - 对话详情：润色 turn；润色未完成时回退本地原始句并提示；
/// - 原始数据：按切片分组，展示时间、情绪、说话人推测与静音；
/// 没有视图时（旧数据/设计样例）回退 [RecordEvent] 的 dialog/raw。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/models/segment_view.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../services/transcribe/utterance_builder.dart';
import '../widgets/photo_preview_sheet.dart';
import '../widgets/quick_speaker_sheet.dart';
import '../widgets/raw_audio_player.dart';
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

class _DetailPageState extends State<DetailPage> {
  String _tab = 'dlg'; // dlg | raw | refs
  final GlobalKey<RawAudioPlayerState> _playerKey =
      GlobalKey<RawAudioPlayerState>();
  int? _activeFilePosMs;
  int _selectedMergedSliceIdx = 0;

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _activeFilePosMs = null;
      _selectedMergedSliceIdx = 0;
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

  @override
  Widget build(BuildContext context) {
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
              const Icon(
                Icons.description_outlined,
                size: 36,
                color: RCColors.ax,
              ),
              const SizedBox(height: 10),
              const Text(
                '这条记录已不在本机',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                '可能已被删除，或录音卡上的原文件已清理。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: RCColors.sec),
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
    final refs = store.doneSummariesReferencing(e.id);
    final view = store.segmentViewFor(e.id);
    final speakerText = store.displaySpeakersSummary(e);
    final dialogOrRaw = e.dialog.isNotEmpty ? e.dialog : e.raw;
    final hasAnyTurns =
        dialogOrRaw.any((t) => t.spk.trim() != '无语音');
    final markableSpeakers = store.speakerEntriesForEvents([e]);
    final hasMarkedSpeaker =
        markableSpeakers.any((s) => s.currentAlias.isNotEmpty) ||
        store.hasTurnOverridesFor([e]);

    return Column(
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
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.title,
                key: const Key('dt-h3'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
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
                    style: const TextStyle(fontSize: 12, color: RCColors.sec),
                  ),
                  Text(
                    speakerText,
                    key: const Key('dt-speakers'),
                    style: const TextStyle(fontSize: 12, color: RCColors.sec),
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
                        showQuickSpeakerSheet(
                          context,
                          store: store,
                          event: e,
                          turnIndex: firstIdx < 0 ? 0 : firstIdx,
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
                          color: RCColors.card,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: RCColors.sep),
                        ),
                        child: Text(
                          hasMarkedSpeaker ? '编辑说话人' : '标记说话人',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: RCColors.label,
                          ),
                        ),
                      ),
                    ),
                  if (e.mark.isNotEmpty)
                    Text(
                      e.mark,
                      style: const TextStyle(fontSize: 12, color: RCColors.ink),
                    ),
                ],
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: RCColors.sep)),
          ),
          child: Row(
            children: [
              _tabBtn('对话详情', 'dlg'),
              _tabBtn('原始数据', 'raw'),
              if (refs.isNotEmpty) _tabBtn('被引用总结 ${refs.length}', 'refs'),
            ],
          ),
        ),
        // 诚实边界：说话人来自推测归类，不能当成已验证身份展示
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
          child: Text(
            '说话人为推测归类，非已验证身份；长静音已在清洗版中省略。',
            key: const Key('detail-pnote'),
            style: TextStyle(fontSize: 11.5, height: 1.5, color: context.rc.sec),
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
              final clip = _audioClipFor(activeAudioView);
              return Container(
                key: const Key('raw-sticky-player'),
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
                decoration: const BoxDecoration(
                  color: RCColors.bg,
                  border: Border(bottom: BorderSide(color: RCColors.sep)),
                ),
                child: RawAudioPlayer(
                  key: _playerKey,
                  fileKey: activeAudioView?.file.deviceName ?? e.id,
                  wavPath: activeAudioView?.file.wavPath,
                  durationHintMs: activeAudioView?.file.durationMs,
                  clipStartMs: clip.clipStartMs,
                  clipEndMs: clip.clipEndMs,
                  gapCountOverride: clip.gapCountOverride,
                  padding: EdgeInsets.zero,
                  onFilePositionChanged: (ms) {
                    if (mounted && _activeFilePosMs != ms) {
                      setState(() => _activeFilePosMs = ms);
                    }
                  },
                ),
              );
            },
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              22,
              14,
              22,
              RCDims.pageBottomPad,
            ),
            children: [
              if (view != null &&
                  ((e.note != null && e.note!.isNotEmpty) ||
                      (view.turns.isEmpty && view.utterances.isNotEmpty)))
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(
                    e.note ??
                        (view.file.polishStale
                            ? '部分内容未润色，以下为本地原始转写。'
                            : (view.file.deviceName.startsWith('LIVE_')
                                  ? '本地实时转写已完成，将在当前清洗周期或停录后自动由云端整理。'
                                  : '云端润色未完成，以下为本地原始转写。')),
                    key: const Key('detail-note'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: RCColors.sec,
                      height: 1.5,
                    ),
                  ),
                ),
              ..._buildTab(store, e, refs, view),
            ],
          ),
        ),
      ],
    );
  }

  String _dayLabel(RecordEvent e) {
    if (e.dayOffset == 0) return '今天';
    if (e.dayOffset == 1) return '昨天';
    final d = DateTime.now().subtract(Duration(days: e.dayOffset));
    const dow = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${d.month}月${d.day}日 ${dow[d.weekday - 1]}';
  }

  Widget _tabBtn(String label, String id) => Padding(
    padding: const EdgeInsets.only(right: 18),
    child: TextButton(
      key: Key('det-tab-$id'),
      onPressed: () => setState(() => _tab = id),
      style: TextButton.styleFrom(
        foregroundColor: _tab == id ? RCColors.label : RCColors.sec,
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

  List<Widget> _buildTab(
    AppStore store,
    RecordEvent e,
    List refs,
    SegmentView? view,
  ) {
    switch (_tab) {
      case 'dlg':
        return _dialogWidgets(store, e, view);
      case 'raw':
        return _rawWidgets(store, e, view);
      case 'refs':
        return [
          for (final r in refs)
            Builder(
              builder: (context) {
                final picCount = store.activePhotoCountForSummary(r);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: RCColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: RCColors.sep),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: Key('ref-${r.id}'),
                      onTap: () => store.openSum(r.id),
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
                                    r.title ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: RCColors.ax,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${r.time} · 已选 ${r.srcIds.length} 片段',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RCColors.sec,
                                    ),
                                  ),
                                ),
                                if (picCount > 0) ...[
                                  const Text(
                                    ' · ',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: RCColors.sec,
                                    ),
                                  ),
                                  Text(
                                    '含 $picCount 张图片',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RCColors.sec,
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
              },
            ),
        ];
      default:
        return const [];
    }
  }

  List<Widget> _dialogWidgets(
    AppStore store,
    RecordEvent e,
    SegmentView? view,
  ) {
    final lines = <({String spk, String text, String clock, int sortSec})>[];
    if (view != null && view.turns.isNotEmpty) {
      for (final t in view.turns) {
        final ts = view.file.startAtMs + t.startMs;
        lines.add((
          spk: t.speakerLabel,
          text: t.text,
          clock: '${_hms(ts)}—${_hms(view.file.startAtMs + t.endMs)}',
          sortSec: _secOfDayFromEpoch(ts),
        ));
      }
    } else if (view != null && view.utterances.isNotEmpty) {
      for (final u in view.utterances) {
        final label = u.speakerLabel ?? '未区分';
        final ts = view.file.startAtMs + u.startMs;
        lines.add((
          spk: label,
          text: u.text,
          clock: '${_hms(ts)}—${_hms(view.file.startAtMs + u.endMs)}',
          sortSec: _secOfDayFromEpoch(ts),
        ));
      }
    } else {
      for (final l in e.dialog) {
        final rawClock = l.src.replaceFirst('来源 ', '');
        lines.add((
          spk: l.spk,
          text: l.text,
          clock: rawClock,
          sortSec: _secOfDayFromClock(rawClock) ?? _secOfDayFromClock(e.time) ?? 0,
        ));
      }
    }

    final activePhotos = store.activePhotosForEvent(e);
    final photoSecs = <int>[
      for (final p in activePhotos)
        p.capturedAtMs != null
            ? _secOfDayFromEpoch(p.capturedAtMs!)
            : (_secOfDayFromClock(p.time) ?? _secOfDayFromClock(e.time) ?? 0),
    ];

    bool hasPhotoBetween(int prevSec, int nextSec) {
      if (nextSec <= prevSec) return false;
      for (final pSec in photoSecs) {
        if (pSec > prevSec && pSec < nextSec) return true;
      }
      return false;
    }

    String extractClockHead(String clock) {
      final parts = clock.split('—');
      return parts.first.trim();
    }

    String extractClockTail(String clock) {
      final parts = clock.split('—');
      return parts.length > 1 ? parts.last.trim() : parts.first.trim();
    }

    // 同一说话人相邻发言在语义展示层自动合并成连贯自然段（不因短切片时间戳切碎），
    // 若两句之间穿插了现场照片则按时间先后保留分隔。
    final groups = <({
      int firstTurnIndex,
      String rawSpk,
      String displaySpk,
      String avatarSpk,
      bool canQuickName,
      String text,
      String startClock,
      String endClock,
      int sortSec,
      int lastSortSec,
    })>[];

    for (var turnIdx = 0; turnIdx < lines.length; turnIdx++) {
      final l = lines[turnIdx];
      if (!isMeaningfulSpeechText(l.text)) continue;
      final displaySpk = store.displayTurnSpeaker(e, turnIdx, l.spk);
      final avatarSpk = store.displayTurnSpeaker(
        e,
        turnIdx,
        l.spk,
        includeGuessSuffix: false,
      );
      final canQuickName = l.spk.trim() != '无语音';
      final startClock = extractClockHead(l.clock);
      final endClock = extractClockTail(l.clock);
      final prev = groups.isNotEmpty ? groups.last : null;
      final canMerge =
          prev != null &&
          prev.displaySpk == displaySpk &&
          !hasPhotoBetween(prev.lastSortSec, l.sortSec);
      if (canMerge) {
        groups[groups.length - 1] = (
          firstTurnIndex: prev.firstTurnIndex,
          rawSpk: prev.rawSpk,
          displaySpk: prev.displaySpk,
          avatarSpk: prev.avatarSpk,
          canQuickName: prev.canQuickName,
          text: joinPolishedUtterances(prev.text, l.text.trim()),
          startClock: prev.startClock,
          endClock: endClock.isNotEmpty ? endClock : prev.endClock,
          sortSec: prev.sortSec,
          lastSortSec: l.sortSec > prev.lastSortSec
              ? l.sortSec
              : prev.lastSortSec,
        );
      } else {
        groups.add((
          firstTurnIndex: turnIdx,
          rawSpk: l.spk,
          displaySpk: displaySpk,
          avatarSpk: avatarSpk,
          canQuickName: canQuickName,
          text: l.text.trim(),
          startClock: startClock,
          endClock: endClock,
          sortSec: l.sortSec,
          lastSortSec: l.sortSec,
        ));
      }
    }

    final entries = <({int sortSec, int order, Widget widget})>[];
    var order = 0;
    for (final g in groups) {
      final clockRange =
          (g.endClock.isNotEmpty && g.endClock != g.startClock)
              ? '${g.startClock}—${g.endClock}'
              : g.startClock;
      void openQuickSheet() => showQuickSpeakerSheet(
        context,
        store: store,
        event: e,
        turnIndex: g.firstTurnIndex,
        rawSpeaker: g.rawSpk,
        sampleQuote: g.text,
      );
      entries.add((
        sortSec: g.sortSec,
        order: order++,
        widget: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                key: Key('turn-spk-${g.firstTurnIndex}'),
                borderRadius: BorderRadius.circular(14),
                onTap: g.canQuickName ? openQuickSheet : null,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _speakerColor(g.displaySpk),
                  ),
                  child: Text(
                    _avatar(g.avatarSpk),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
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
                      key: Key('turn-who-${e.id}-${g.firstTurnIndex}'),
                      onTap: g.canQuickName ? openQuickSheet : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '${g.displaySpk} · $clockRange',
                              style: TextStyle(
                                fontSize: 11,
                                color: g.canQuickName
                                    ? RCColors.ink
                                    : RCColors.sec,
                                fontWeight: g.canQuickName
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (g.canQuickName) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.edit_outlined,
                              size: 11,
                              color: RCColors.sec,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: RCColors.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: RCColors.sep),
                      ),
                      child: Text(
                        g.text,
                        style: const TextStyle(fontSize: 14, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    }

    for (var i = 0; i < activePhotos.length; i++) {
      final p = activePhotos[i];
      final sortSec = photoSecs[i];
      String? nearestQuote;
      int? bestDelta;
      for (final l in lines) {
        final d = (l.sortSec - sortSec).abs();
        if (bestDelta == null || d < bestDelta) {
          bestDelta = d;
          nearestQuote = '${store.displaySpeaker(e, l.spk)}：${l.text}';
        }
      }
      entries.add((
        sortSec: sortSec,
        order: order++,
        widget: _inlinePhotoCard(store, e, p, i, quoteText: nearestQuote),
      ));
    }

    entries.sort((a, b) {
      final cmp = a.sortSec.compareTo(b.sortSec);
      return cmp != 0 ? cmp : a.order.compareTo(b.order);
    });

    final overviewText = e.longText.trim();
    final showOverviewCard =
        groups.isNotEmpty &&
        isMeaningfulSpeechText(overviewText) &&
        !overviewText.contains('未检测到有效人声') &&
        !overviewText.startsWith('已保存本地原始转写') &&
        !(groups.length == 1 && overviewText == groups.single.text.trim());

    return [
      if (groups.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            key: const Key('detail-silent-empty'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: RCColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: RCColors.sep),
            ),
            child: Text(
              view != null && view.isMergedSilent
                  ? '本时段连续 ${view.mergedChildren.length} 个切片未检测到有效人声，原始音频均已保留，可在「原始数据」逐片回听。'
                  : '本段未检测到有效人声，可在「原始数据」回听原始录音。',
              style: const TextStyle(
                fontSize: 13,
                height: 1.55,
                color: RCColors.sec,
              ),
            ),
          ),
        ),
      if (showOverviewCard)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            key: const Key('detail-overview-card'),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: RCColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: RCColors.sep),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '阶段概述',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: RCColors.sec,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  overviewText,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: RCColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      for (final item in entries) item.widget,
    ];
  }

  Widget _inlinePhotoCard(
    AppStore store,
    RecordEvent e,
    EventPhoto p,
    int index, {
    String? quoteText,
  }) {
    final hasFile = p.path.isNotEmpty && File(p.path).existsSync();
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
              color: RCColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: RCColors.sep),
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
                      child: hasFile
                          ? Image.file(File(p.path), fit: BoxFit.cover)
                          : ColoredBox(
                              color: const Color(0xFFEAEAE4),
                              child: Center(
                                child: Icon(
                                  p.source == 'dyj_camera'
                                      ? Icons.photo_camera_outlined
                                      : Icons.photo_outlined,
                                  size: 24,
                                  color: RCColors.sec,
                                ),
                              ),
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
                        style: const TextStyle(
                          fontSize: 12,
                          color: RCColors.sec,
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
                            color: RCColors.bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: RCColors.sep),
                          ),
                          child: const Text(
                            '不属于本段',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: RCColors.sec,
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

  static int _secOfDayFromEpoch(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return d.hour * 3600 + d.minute * 60 + d.second;
  }

  static int? _secOfDayFromClock(String raw) {
    final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    final sec = m.group(3) != null ? (int.tryParse(m.group(3)!) ?? 0) : 0;
    return h * 3600 + min * 60 + sec;
  }

  List<Widget> _rawWidgets(AppStore store, RecordEvent e, SegmentView? view) {
    // 播放器已置顶吸顶在「原始数据」tab 顶部（raw-sticky-player），此处只滚句子流。
    final widgets = <Widget>[
      if (view != null && !view.file.timeSynced)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            '时间未校准：录音时设备时钟未同步，时间为推算值。',
            key: Key('raw-time-unsynced'),
            style: TextStyle(fontSize: 12, color: RCColors.danger),
          ),
        ),
    ];

    if (view == null) {
      for (var i = 0; i < e.raw.length; i++) {
        final l = e.raw[i];
        final parsedMs = _parseRelativeClockMs(l.src);
        widgets.add(
          _rawBubble(
            '${_rawSpeakerLabel(store, e, l.spk)} · ${l.src}',
            l.text,
            bubbleKey: Key('raw-utt-$i'),
            onTap: parsedMs != null ? () => _seekRawAudio(parsedMs) : null,
          ),
        );
      }
      return widgets;
    }

    if (view.isMergedSilent) {
      final selectedIdx = _selectedMergedSliceIdx.clamp(
        0,
        view.mergedChildren.length - 1,
      );
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '连续 ${view.mergedChildren.length} 个无语音切片已合并展示，点选任一切片可在上方播放器回听对应原始音频：',
            style: const TextStyle(fontSize: 12, color: RCColors.sec, height: 1.5),
          ),
        ),
      );
      for (var i = 0; i < view.mergedChildren.length; i++) {
        final child = view.mergedChildren[i];
        final cStart = child.segment.startAtMs;
        final cEnd =
            child.segment.endAtMs ??
            (cStart + (child.file.durationMs > 0 ? child.file.durationMs : 1000));
        final durSec = ((cEnd - cStart) / 1000).round().clamp(1, 86400);
        final active = i == selectedIdx;
        widgets.add(
          _rawBubble(
            '切片 ${i + 1} · ${_hms(cStart)}—${_hms(cEnd)} · $durSec 秒',
            child.file.deviceName,
            bubbleKey: Key('raw-merged-slice-$i'),
            active: active,
            onTap: () {
              setState(() {
                _selectedMergedSliceIdx = i;
                _activeFilePosMs = null;
              });
            },
          ),
        );
      }
      return widgets;
    }

    if (view.isMergedSpeech) {
      final selectedIdx = _selectedMergedSliceIdx.clamp(
        0,
        view.mergedChildren.length - 1,
      );
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '连续 ${view.mergedChildren.length} 个分片已按 <30s 停顿自动合并，点击任一分片切换上方播放器回听对应原始 WAV：',
            style: const TextStyle(fontSize: 12, color: RCColors.sec, height: 1.5),
          ),
        ),
      );
      for (var i = 0; i < view.mergedChildren.length; i++) {
        final child = view.mergedChildren[i];
        final cStart = child.segment.startAtMs;
        final cEnd =
            child.segment.endAtMs ??
            (cStart + (child.file.durationMs > 0 ? child.file.durationMs : 1000));
        final durSec = ((cEnd - cStart) / 1000).round().clamp(1, 86400);
        final active = i == selectedIdx;
        widgets.add(
          _rawBubble(
            '分片 ${i + 1} · ${_hms(cStart)}—${_hms(cEnd)} · $durSec 秒',
            child.file.deviceName,
            bubbleKey: Key('raw-merged-slice-$i'),
            active: active,
            onTap: () {
              setState(() {
                _selectedMergedSliceIdx = i;
                _activeFilePosMs = null;
              });
            },
          ),
        );
        for (final u in child.utterances) {
          final pos = _activeFilePosMs;
          final uActive = active && pos != null && pos >= u.startMs && pos <= u.endMs;
          widgets.add(
            _rawBubble(
              '${_rawSpeakerLabel(store, e, u.speakerLabel ?? '未区分')} · '
              '${_hms(child.file.startAtMs + u.startMs)} · ${_emotion(u.emotion)}',
              u.text,
              bubbleKey: Key('raw-utt-${u.id}'),
              active: uActive,
              onTap: () {
                final switched = _selectedMergedSliceIdx != i;
                setState(() {
                  _selectedMergedSliceIdx = i;
                });
                if (switched) {
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
      return widgets;
    }

    if (view.slices.isEmpty) {
      if (view.utterances.isEmpty) {
        widgets.add(
          const Text(
            '暂无原始转写（静音或模型未识别到语音）。',
            style: TextStyle(fontSize: 13, color: RCColors.sec),
          ),
        );
      } else {
        for (final u in view.utterances) {
          final pos = _activeFilePosMs;
          final active = pos != null && pos >= u.startMs && pos <= u.endMs;
          widgets.add(
            _rawBubble(
              '${_rawSpeakerLabel(store, e, u.speakerLabel ?? '未区分')} · '
              '${_hms(view.file.startAtMs + u.startMs)} · ${_emotion(u.emotion)}',
              u.text,
              bubbleKey: Key('raw-utt-${u.id}'),
              active: active,
              onTap: () => _seekRawAudio(u.startMs),
            ),
          );
        }
      }
      return widgets;
    }

    for (final slice in view.slices) {
      final sliceUtterances = view.utterances
          .where((u) => u.sliceId == slice.id)
          .toList();
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: InkWell(
            onTap: () => _seekRawAudio(slice.startMs),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '[${_hms(view.file.startAtMs + slice.startMs)}—'
                '${_hms(view.file.startAtMs + slice.endMs)}]',
                key: Key('raw-slice-${slice.id}'),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: RCColors.sec,
                ),
              ),
            ),
          ),
        ),
      );
      for (final u in sliceUtterances) {
        final pos = _activeFilePosMs;
        final active = pos != null && pos >= u.startMs && pos <= u.endMs;
        widgets.add(
          _rawBubble(
            '${_rawSpeakerLabel(store, e, u.speakerLabel ?? '未区分')} · '
            '${_hms(view.file.startAtMs + u.startMs)} · ${_emotion(u.emotion)}',
            u.text,
            bubbleKey: Key('raw-utt-${u.id}'),
            active: active,
            onTap: () => _seekRawAudio(u.startMs),
          ),
        );
      }
      if (slice.silenceAfterMs >= 2000) {
        final seconds = (slice.silenceAfterMs / 1000).round();
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '（静音约 $seconds 秒）',
              style: const TextStyle(fontSize: 12, color: RCColors.ax),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _rawBubble(
    String meta,
    String text, {
    Key? bubbleKey,
    bool active = false,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: active ? RCColors.card : const Color(0xFFF6F6F2),
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
                color: active ? RCColors.label : Colors.transparent,
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
                          color: active ? RCColors.ink : RCColors.sec,
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
                        color: active ? RCColors.label : RCColors.ax,
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(text, style: const TextStyle(fontSize: 14, height: 1.55)),
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

  static Color _speakerColor(String speaker) {
    const colors = [
      Color(0xFFDDE9DD),
      Color(0xFFE8E8E4),
      Color(0xFFE3E6F0),
      Color(0xFFF0E6DD),
    ];
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
