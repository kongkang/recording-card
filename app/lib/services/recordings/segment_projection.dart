/// 把本地录音文件投影成 Timeline 的 [RecordEvent] 与详情页的 [SegmentView]。
///
/// 时间：`SegmentRecord.startAtMs` 是绝对时间；`PolishedTurn.startMs` 是相对
/// 录音起点。投影时统一换算，详情页再按需展示相对时间。
library;

import '../../core/models/record.dart';
import '../../core/models/recording.dart';
import '../../core/models/segment_view.dart';

class ProjectionResult {
  const ProjectionResult({required this.events, required this.views});

  final List<RecordEvent> events;
  final Map<String, SegmentView> views;
}

class SegmentProjection {
  const SegmentProjection._();

  static ProjectionResult build(List<RecordingFile> files) {
    final events = <RecordEvent>[];
    final views = <String, SegmentView>{};
    for (final file in files) {
      for (final segment in file.segments) {
        final view = _viewFor(file, segment);
        views[segment.id] = view;
        events.add(_eventFor(view));
      }
    }
    events.sort((a, b) {
      if (a.dayOffset != b.dayOffset) return a.dayOffset.compareTo(b.dayOffset);
      return b.time.compareTo(a.time);
    });
    return ProjectionResult(events: events, views: views);
  }

  static SegmentView _viewFor(RecordingFile file, SegmentRecord segment) {
    final turnById = {for (final t in file.turns) t.id: t};
    var turns = <PolishedTurn>[
      for (final id in segment.turnIds)
        if (turnById[id] != null) turnById[id]!,
    ];
    if (turns.isEmpty) {
      turns = file.turns
          .where(
            (t) =>
                file.startAtMs + t.startMs >= segment.startAtMs &&
                file.startAtMs + t.startMs <=
                    (segment.endAtMs ?? segment.startAtMs),
          )
          .toList();
    }
    turns.sort((a, b) => a.startMs.compareTo(b.startMs));

    final sliceIds = segment.sliceIds.toSet();
    final slices = <AudioSlice>[
      for (final s in file.slices)
        if (sliceIds.isEmpty ||
            sliceIds.contains(s.id) ||
            file.startAtMs + s.startMs <= (segment.endAtMs ?? 0) &&
                file.startAtMs + s.endMs >= segment.startAtMs)
          s,
    ];
    final sliceSet = {for (final s in slices) s.id};
    var utterances = <RawUtterance>[
      for (final u in file.utterances)
        if (sliceSet.contains(u.sliceId) ||
            (sliceSet.isEmpty &&
                file.startAtMs + u.startMs >= segment.startAtMs &&
                file.startAtMs + u.startMs <=
                    (segment.endAtMs ?? segment.startAtMs)))
          u,
    ];
    utterances.sort((a, b) => a.startMs.compareTo(b.startMs));

    return SegmentView(
      segment: segment,
      file: file,
      turns: turns,
      utterances: utterances,
      slices: slices,
    );
  }

  static RecordEvent _eventFor(SegmentView view) {
    final segment = view.segment;
    final file = view.file;
    final startMs = segment.startAtMs;
    final endMs = segment.endAtMs ??
        (view.turns.isNotEmpty
            ? file.startAtMs + view.turns.last.endMs
            : startMs + (file.durationMs > 0 ? file.durationMs : 1000));
    final dayOffset = _dayOffset(startMs);

    final dialog = <TurnLine>[
      for (final t in view.turns)
        TurnLine(
          t.speakerLabel,
          t.text,
          '${_hm(file.startAtMs + t.startMs)}—${_hm(file.startAtMs + t.endMs)}',
        ),
    ];
    if (dialog.isEmpty) {
      // 润色未就绪：详情页展示本地原文，时间轴仍能看到内容
      for (final u in view.utterances) {
        dialog.add(
          TurnLine(
            u.speakerLabel ?? '未区分',
            u.text,
            '${_hm(file.startAtMs + u.startMs)}—${_hm(file.startAtMs + u.endMs)}',
          ),
        );
      }
    }

    final raw = <TurnLine>[
      for (final u in view.utterances)
        TurnLine(
          _rawSpeaker(u),
          u.text,
          '${_hm(file.startAtMs + u.startMs)} · 原始转写',
        ),
    ];

    final speakers = segment.speakerCount > 0 && segment.speakerLabels.isNotEmpty
        ? '${segment.speakerLabels.join(' / ')}（推测）'
        : '未区分';

    final note = segment.status == SegmentStatus.live
        ? '正在整理这段录音'
        : (segment.polishStale || file.polishStale)
            ? '部分内容未润色'
            : segment.fallback
                ? '总结未完成'
                : !file.timeSynced
                    ? '时间未校准'
                    : null;

    final brief = segment.brief.trim().isNotEmpty
        ? segment.brief
        : segment.status == SegmentStatus.live
            ? '正在整理这段对话…'
            : '尚无摘要';
    final longText = segment.longText.trim().isNotEmpty
        ? segment.longText
        : dialog.map((t) => t.text).join('\n');

    return RecordEvent(
      id: segment.id,
      dayOffset: dayOffset,
      title: segment.title.trim().isEmpty ? '录音片段' : segment.title,
      brief: brief,
      longText: longText,
      time: _hm(startMs),
      dur: _duration(endMs - startMs),
      speakers: speakers,
      mark: segment.mark ?? '',
      srcMap: '来源 ${_hm(startMs)}—${_hm(endMs)}',
      dialog: dialog,
      raw: raw,
      live: segment.status == SegmentStatus.live,
      note: note,
    );
  }

  static String _rawSpeaker(RawUtterance u) {
    final speaker = u.speakerLabel ?? '未区分';
    final emotion = (u.emotion ?? '').trim();
    return emotion.isEmpty ? speaker : '$speaker · 情绪 $emotion';
  }

  static int _dayOffset(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    return today.difference(day).inDays.clamp(0, 3650);
  }

  static String _hm(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  static String _duration(int ms) {
    if (ms <= 0) return '—';
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) return '$h小时$m分';
    if (m == 0) return '$s秒';
    return s == 0 ? '$m分' : '$m分$s秒';
  }
}
