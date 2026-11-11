/// 详情页 —— 「对话详情 / 原始数据 / 被引用总结 N」平级 tab（refs 仅 N>0 显示）。
///
/// 有 v2 分段视图时（本地转写链路）：
/// - 对话详情：润色 turn；润色未完成时回退本地原始句并提示；
/// - 原始数据：按切片分组，展示时间、情绪、说话人推测与静音；
/// 没有视图时（旧数据/设计样例）回退 [RecordEvent] 的 dialog/raw。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/models/segment_view.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
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

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _activeFilePosMs = null;
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
    final refs = store.doneSummariesReferencing(widget.eventId);
    final view = store.segmentViewFor(widget.eventId);
    final speakerText = view != null && view.segment.speakerCount > 0
        ? '${view.segment.speakerLabels.join(' / ')}（推测）'
        : '说话人 ${e.speakers}';

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
                runSpacing: 4,
                children: [
                  Text(
                    '${_dayLabel(e)} ${e.time} · ${e.dur}',
                    key: const Key('dt-meta'),
                    style: const TextStyle(fontSize: 12, color: RCColors.sec),
                  ),
                  Text(
                    speakerText,
                    style: const TextStyle(fontSize: 12, color: RCColors.sec),
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
              final clip = _audioClipFor(view);
              return Container(
                key: const Key('raw-sticky-player'),
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
                decoration: const BoxDecoration(
                  color: RCColors.bg,
                  border: Border(bottom: BorderSide(color: RCColors.sep)),
                ),
                child: RawAudioPlayer(
                  key: _playerKey,
                  fileKey: view?.file.deviceName ?? e.id,
                  wavPath: view?.file.wavPath,
                  durationHintMs: view?.file.durationMs,
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
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 32),
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
                                  ? '实时切片本地转写（保留原始文本，暂未接入云端润色）。'
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
        return _dialogWidgets(e, view);
      case 'raw':
        return _rawWidgets(e, view);
      case 'refs':
        return [
          for (final r in refs)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton(
                key: Key('ref-${r.id}'),
                onPressed: () => store.openSum(r.id),
                style: OutlinedButton.styleFrom(
                  foregroundColor: RCColors.label,
                  side: const BorderSide(color: RCColors.sep),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(14),
                  alignment: Alignment.centerLeft,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        r.title ?? '',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${r.time} · 已选 ${r.srcIds.length} 片段',
                      style: const TextStyle(
                        fontSize: 12,
                        color: RCColors.sec,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ];
      default:
        return const [];
    }
  }

  List<Widget> _dialogWidgets(RecordEvent e, SegmentView? view) {
    final lines = <({String spk, String text, String meta})>[];
    if (view != null && view.turns.isNotEmpty) {
      for (final t in view.turns) {
        lines.add((
          spk: t.speakerLabel,
          text: t.text,
          meta:
              '${_speakerText(t.speakerLabel)} · '
              '${_hms(view.file.startAtMs + t.startMs)}—'
              '${_hms(view.file.startAtMs + t.endMs)}',
        ));
      }
    } else if (view != null && view.utterances.isNotEmpty) {
      for (final u in view.utterances) {
        final label = u.speakerLabel ?? '未区分';
        lines.add((
          spk: label,
          text: u.text,
          meta:
              '${_speakerText(label)} · '
              '${_hms(view.file.startAtMs + u.startMs)}—'
              '${_hms(view.file.startAtMs + u.endMs)}',
        ));
      }
    } else {
      for (final l in e.dialog) {
        lines.add((
          spk: l.spk,
          text: l.text,
          meta: '说话人 ${l.spk} · ${l.src.replaceFirst('来源 ', '')}',
        ));
      }
    }

    return [
      for (final l in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _speakerColor(l.spk),
                ),
                child: Text(
                  _avatar(l.spk),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.meta,
                      style: const TextStyle(
                        fontSize: 11,
                        color: RCColors.sec,
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
                        l.text,
                        style: const TextStyle(fontSize: 14, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _rawWidgets(RecordEvent e, SegmentView? view) {
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
            '${l.spk} · ${l.src}',
            l.text,
            bubbleKey: Key('raw-utt-$i'),
            onTap: parsedMs != null ? () => _seekRawAudio(parsedMs) : null,
          ),
        );
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
              '${_speakerText(u.speakerLabel ?? '未区分')} · '
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
            '${_speakerText(u.speakerLabel ?? '未区分')} · '
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
