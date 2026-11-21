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
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../services/recordings/cleaned_dialogue.dart';
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
  bool _showForkCompare = false;

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _activeFilePosMs = null;
      _selectedMergedSliceIdx = 0;
      _showForkCompare = false;
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
    final refs = store.doneSummariesReferencing(e.id);
    final view = store.segmentViewFor(e.id);
    final sibling = store.siblingForkEventFor(e.id);
    final speakerText = lifeSpeakerLabel(store.displaySpeakersSummary(e));
    final dialogOrRaw = e.dialog.isNotEmpty ? e.dialog : e.raw;
    final hasAnyTurns =
        dialogOrRaw.any((t) => t.spk.trim() != '无语音');
    final markableSpeakers = store.speakerEntriesForEvents([e]);
    final hasMarkedSpeaker =
        markableSpeakers.any((s) => s.currentAlias.isNotEmpty) ||
        store.hasTurnOverridesFor([e]);

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
                final clip = _audioClipFor(activeAudioView);
                final currentWavPath = activeAudioView?.file.wavPath;
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
                if (sibling != null && _showForkCompare)
                  _buildForkComparePanel(c, e, sibling),
                ..._buildTab(c, store, e, refs, view),
              ],
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

  List<Widget> _buildTab(
    RCColorScheme c,
    AppStore store,
    RecordEvent e,
    List refs,
    SegmentView? view,
  ) {
    switch (_tab) {
      case 'dlg':
        return _dialogWidgets(c, store, e, view);
      case 'raw':
        return _rawWidgets(c, store, e, view);
      case 'refs':
        return [
          for (final r in refs)
            Builder(
              builder: (context) {
                final picCount = store.activePhotoCountForSummary(r);
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
                                    '${r.time} · 已选 ${r.srcIds.length} 片段',
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
              },
            ),
        ];
      default:
        return const [];
    }
  }

  List<Widget> _dialogWidgets(
    RCColorScheme c,
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
      final displaySpk = lifeSpeakerLabel(
        store.displayTurnSpeaker(
          e,
          bubble.firstTurnIndex,
          src.spk,
          includeGuessSuffix: false,
        ),
      );
      groups.add((
        firstTurnIndex: bubble.firstTurnIndex,
        turnIndices: turnIndices.isEmpty
            ? <int>[bubble.firstTurnIndex]
            : turnIndices,
        rawSpk: src.spk,
        displaySpk: displaySpk,
        avatarSpk: displaySpk,
        canQuickName: src.spk.trim() != '无语音',
        paragraphs: bubble.paragraphs,
        startClock: extractClockHead(src.clock),
        sortSec: bubble.startSec,
      ));
    }

    final entries = <({int sortSec, int order, Widget widget})>[];
    var order = 0;
    for (final g in groups) {
      void openQuickSheet() {
        store.setPendingMergedBubbleTurns(
          e.id,
          g.firstTurnIndex,
          g.turnIndices,
        );
        unawaited(
          showQuickSpeakerSheet(
            context,
            store: store,
            event: e,
            turnIndex: g.firstTurnIndex,
            rawSpeaker: g.rawSpk,
            sampleQuote: g.paragraphs.join('\n'),
          ).whenComplete(store.clearPendingMergedBubbleTurns),
        );
      }

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
                    color: _speakerColor(g.displaySpk, isDark: c.isDark),
                  ),
                  child: Text(
                    _avatar(g.avatarSpk),
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
                      key: Key('turn-who-${e.id}-${g.firstTurnIndex}'),
                      onTap: g.canQuickName ? openQuickSheet : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '${g.displaySpk} · ${g.startClock}',
                              style: TextStyle(
                                fontSize: 11,
                                color: g.canQuickName ? c.ink : c.sec,
                                fontWeight: g.canQuickName
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (g.canQuickName) ...[
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
                      key: Key('turn-para-${e.id}-${g.firstTurnIndex}'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.sep),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < g.paragraphs.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            Text(
                              g.paragraphs[i],
                              key: Key(
                                'turn-para-body-${e.id}-${g.firstTurnIndex}-$i',
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
        widget: _inlinePhotoCard(c, store, e, p, i, quoteText: nearestQuote),
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
      if (groups.isEmpty)
        Padding(
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
        ),
      if (showOverviewCard)
        Padding(
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
                  overviewText,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: c.ink,
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
    RCColorScheme c,
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
                      child: hasFile
                          ? Image.file(File(p.path), fit: BoxFit.cover)
                          : ColoredBox(
                              color: c.isDark
                                  ? const Color(0xFF242428)
                                  : const Color(0xFFEAEAE4),
                              child: Center(
                                child: Icon(
                                  p.source == 'dyj_camera'
                                      ? Icons.photo_camera_outlined
                                      : Icons.photo_outlined,
                                  size: 24,
                                  color: c.sec,
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

  List<Widget> _rawWidgets(
    RCColorScheme c,
    AppStore store,
    RecordEvent e,
    SegmentView? view,
  ) {
    // 播放器已置顶吸顶在「原始数据」tab 顶部（raw-sticky-player），此处只滚句子流。
    final widgets = <Widget>[];

    if (view == null) {
      for (var i = 0; i < e.raw.length; i++) {
        final l = e.raw[i];
        final parsedMs = _parseRelativeClockMs(l.src);
        widgets.add(
          _rawBubble(
            c,
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
            style: TextStyle(fontSize: 12, color: c.sec, height: 1.5),
          ),
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
        widgets.add(
          _rawBubble(
            c,
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
            style: TextStyle(fontSize: 12, color: c.sec, height: 1.5),
          ),
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
        widgets.add(
          _rawBubble(
            c,
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
          final uActive =
              active && pos != null && pos >= u.startMs && pos <= u.endMs;
          widgets.add(
            _rawBubble(
              c,
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
          Text(
            '暂无原始转写（静音或模型未识别到语音）。',
            style: TextStyle(fontSize: 13, color: c.sec),
          ),
        );
      } else {
        for (final u in view.utterances) {
          final pos = _activeFilePosMs;
          final active = pos != null && pos >= u.startMs && pos <= u.endMs;
          widgets.add(
            _rawBubble(
              c,
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
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.sec,
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
            c,
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
              style: TextStyle(fontSize: 12, color: c.ax),
            ),
          ),
        );
      }
    }
    return widgets;
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
