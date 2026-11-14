/// 把本地录音文件投影成 Timeline 的 [RecordEvent] 与详情页的 [SegmentView]。
///
/// 时间：`SegmentRecord.startAtMs` 是绝对时间；`PolishedTurn.startMs` 是相对
/// 录音起点。投影时统一换算，详情页再按需展示相对时间。
library;

import '../../core/models/record.dart';
import '../../core/models/recording.dart';
import '../../core/models/segment_view.dart';

class ProjectionResult {
  const ProjectionResult({
    required this.events,
    required this.views,
    this.mergedIdRedirects = const {},
  });

  final List<RecordEvent> events;
  final Map<String, SegmentView> views;

  /// 被折叠进连续无语音合并块的非锚点子分段 ID → 锚点分段 ID（供照片等归属重定向聚合）。
  final Map<String, String> mergedIdRedirects;
}

class SegmentProjection {
  const SegmentProjection._();

  static final RegExp _gapMarkPattern = RegExp(r'^流中断\s*(\d+)\s*次$');
  static final RegExp _legacySilentTitlePattern = RegExp(
    r'^实时切片\s*#\d+（未识别到人声）$',
  );

  /// 同会话内允许连续无语音切片合并的最大间隔（10 分钟）；跨会话按相邻切片窗口（5 分钟）容差。
  static const int _sameSessionGapLimitMs = 10 * 60 * 1000;
  static const int _adjacentGapLimitMs = 5 * 60 * 1000;

  static ProjectionResult build(List<RecordingFile> files) {
    final rawViews = <SegmentView>[];
    for (final file in files) {
      for (final segment in file.segments) {
        rawViews.add(_viewFor(file, segment));
      }
    }

    // 先按真实起点时间升序排列，再做同日连续无语音切片无损聚合（不修改磁盘原始 WAV 与 JSON）。
    rawViews.sort((a, b) {
      final cmpStart = a.segment.startAtMs.compareTo(b.segment.startAtMs);
      if (cmpStart != 0) return cmpStart;
      final cmpEnd = _endMsOf(a).compareTo(_endMsOf(b));
      if (cmpEnd != 0) return cmpEnd;
      return a.segment.id.compareTo(b.segment.id);
    });

    final events = <RecordEvent>[];
    final views = <String, SegmentView>{};
    final redirects = <String, String>{};
    final startMsByEventId = <String, int>{};

    var i = 0;
    while (i < rawViews.length) {
      final head = rawViews[i];
      if (!_isMergeableSilent(head)) {
        views[head.segment.id] = head;
        final event = _eventFor(head);
        events.add(event);
        startMsByEventId[event.id] = head.segment.startAtMs;
        i++;
        continue;
      }

      final group = <SegmentView>[head];
      var j = i + 1;
      while (j < rawViews.length) {
        final prev = group.last;
        final next = rawViews[j];
        if (!_canMergeConsecutiveSilent(prev, next)) break;
        group.add(next);
        j++;
      }

      if (group.length == 1) {
        views[head.segment.id] = head;
        final event = _eventFor(head);
        events.add(event);
        startMsByEventId[event.id] = head.segment.startAtMs;
      } else {
        // 锚定最早第一片的 segment.id：随着后续新静音片不断追加，主键保持稳定不跳变
        final anchor = group.first;
        final mergedView = SegmentView(
          segment: anchor.segment,
          file: anchor.file,
          turns: const [],
          utterances: const [],
          slices: [for (final c in group) ...c.slices],
          mergedChildren: List<SegmentView>.unmodifiable(group),
        );
        views[anchor.segment.id] = mergedView;
        for (var k = 1; k < group.length; k++) {
          redirects[group[k].segment.id] = anchor.segment.id;
        }
        final event = _mergedSilentEventFor(mergedView);
        events.add(event);
        startMsByEventId[event.id] = anchor.segment.startAtMs;
      }
      i = j;
    }

    events.sort((a, b) {
      if (a.dayOffset != b.dayOffset) return a.dayOffset.compareTo(b.dayOffset);
      final cmpTime = b.time.compareTo(a.time);
      if (cmpTime != 0) return cmpTime;
      final aMs = startMsByEventId[a.id] ?? 0;
      final bMs = startMsByEventId[b.id] ?? 0;
      return bMs.compareTo(aMs);
    });
    return ProjectionResult(
      events: events,
      views: views,
      mergedIdRedirects: redirects,
    );
  }

  /// 判断单段是否为可参与连续折叠的「已完成无语音切片」。
  ///
  /// 保护条件：
  /// 1. 必须是 `RecordingStage.ready` 且非 `live`；
  /// 2. `turns` 与 `utterances` 均为空；
  /// 3. 若带有非「流中断 N 次」的物理打点 `mark`（例如用户单击物理键标记），绝不吞并。
  static bool _isMergeableSilent(SegmentView v) {
    if (v.file.stage != RecordingStage.ready) return false;
    if (v.segment.status == SegmentStatus.live) return false;
    if (v.turns.isNotEmpty || v.utterances.isNotEmpty) return false;
    final mark = (v.segment.mark ?? '').trim();
    if (mark.isNotEmpty && !_gapMarkPattern.hasMatch(mark)) {
      return false;
    }
    return true;
  }

  static bool _canMergeConsecutiveSilent(SegmentView prev, SegmentView next) {
    if (!_isMergeableSilent(next)) return false;
    final prevStart = prev.segment.startAtMs;
    final nextStart = next.segment.startAtMs;
    if (_dayOffset(prevStart) != _dayOffset(nextStart)) return false;

    final prevEnd = _endMsOf(prev);
    final gapMs = nextStart - prevEnd;
    final sameSession =
        prev.segment.sessionId.trim().isNotEmpty &&
        prev.segment.sessionId == next.segment.sessionId;
    if (sameSession) {
      return gapMs <= _sameSessionGapLimitMs;
    }
    return gapMs.abs() <= _adjacentGapLimitMs;
  }

  static int _endMsOf(SegmentView view) {
    final segment = view.segment;
    final file = view.file;
    final startMs = segment.startAtMs;
    return segment.endAtMs ??
        (view.turns.isNotEmpty
            ? file.startAtMs + view.turns.last.endMs
            : startMs + (file.durationMs > 0 ? file.durationMs : 1000));
  }

  static RecordEvent _mergedSilentEventFor(SegmentView mergedView) {
    final children = mergedView.mergedChildren;
    final count = children.length;
    final earliestStartMs = children.first.segment.startAtMs;
    final latestEndMs = _endMsOf(children.last);

    var sumDurationMs = 0;
    var totalGaps = 0;
    var allTimeSynced = true;
    for (final c in children) {
      final s = c.segment.startAtMs;
      final e = _endMsOf(c);
      if (e > s) sumDurationMs += (e - s);
      if (!c.file.timeSynced) allTimeSynced = false;
      final mk = (c.segment.mark ?? '').trim();
      final m = _gapMarkPattern.firstMatch(mk);
      if (m != null) {
        totalGaps += int.tryParse(m.group(1) ?? '0') ?? 0;
      }
    }
    if (sumDurationMs <= 0) {
      sumDurationMs = (latestEndMs - earliestStartMs).clamp(1000, 1 << 30);
    }

    final startHm = _hm(earliestStartMs);
    final endHm = _hm(latestEndMs);
    final durStr = _duration(sumDurationMs);

    return RecordEvent(
      id: mergedView.segment.id,
      dayOffset: _dayOffset(earliestStartMs),
      title: '未识别到语音（已合并 $count 段）',
      brief: '连续 $count 个切片未检测到有效人声，已自动折叠合并。',
      longText:
          '$startHm—$endHm 连续 $count 个录音切片（共 $durStr）均未检测到有效人声，已自动折叠合并；全部原始音频均完整保留，可在详情「原始数据」逐片回听或清理。',
      time: startHm,
      dur: durStr,
      speakers: '无语音',
      mark: totalGaps > 0 ? '流中断 $totalGaps 次' : '',
      srcMap: '来源 $startHm—$endHm · $count 个切片',
      dialog: const [],
      raw: const [],
      live: false,
      note: allTimeSynced ? null : '时间未校准',
    );
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

    final isReadySilent = _isMergeableSilent(view);
    final speakers = segment.speakerCount > 0 && segment.speakerLabels.isNotEmpty
        ? '${segment.speakerLabels.join(' / ')}（推测）'
        : (isReadySilent ? '无语音' : '未区分');

    final note = segment.status == SegmentStatus.live
        ? '正在整理这段录音'
        : (segment.polishStale || file.polishStale)
            ? '部分内容未润色'
            : segment.fallback
                ? '总结未完成'
                : !file.timeSynced
                    ? '时间未校准'
                    : null;

    final normalizedSilent =
        isReadySilent && _legacySilentTitlePattern.hasMatch(segment.title.trim());
    final resolvedTitle = normalizedSilent
        ? '未识别到语音'
        : (segment.title.trim().isEmpty ? '录音片段' : segment.title);
    final brief = normalizedSilent
        ? '本段未检测到有效人声，原始录音已保存在本机。'
        : segment.brief.trim().isNotEmpty
            ? segment.brief
            : segment.status == SegmentStatus.live
                ? '正在整理这段对话…'
                : '尚无摘要';
    final longText = normalizedSilent
        ? '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。'
        : segment.longText.trim().isNotEmpty
            ? segment.longText
            : dialog.map((t) => t.text).join('\n');

    return RecordEvent(
      id: segment.id,
      dayOffset: dayOffset,
      title: resolvedTitle,
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
