/// 把本地录音文件投影成 Timeline 的 [RecordEvent] 与详情页的 [SegmentView]。
///
/// 时间：`SegmentRecord.startAtMs` 是绝对时间；`PolishedTurn.startMs` 是相对
/// 录音起点。投影时统一换算，详情页再按需展示相对时间。
library;

import '../../core/models/record.dart';
import '../../core/models/recording.dart';
import '../../core/models/segment_view.dart';
import '../../core/models/summary.dart';
import '../segment/fast_topic_segment_agent.dart';
import '../transcribe/utterance_builder.dart';

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

/// 连续语音段组（与 Timeline / 滚动清洗引擎共用同源分组边界）。
class ProjectedSpeechGroup {
  const ProjectedSpeechGroup({
    required this.anchorSegmentId,
    required this.views,
    required this.startAtMs,
    required this.endAtMs,
  });

  final String anchorSegmentId;
  final List<SegmentView> views;
  final int startAtMs;
  final int endAtMs;
}

class SegmentProjection {
  const SegmentProjection._();

  static final RegExp _gapMarkPattern = RegExp(r'^流中断\s*(\d+)\s*次$');
  static final RegExp _legacyRawTitlePattern = RegExp(
    r'^实时切片\s*#\d+(?:（未识别到人声）)?$',
  );

  /// 同会话内允许连续无语音切片合并的最大间隔（10 分钟）；跨会话按相邻切片窗口（5 分钟）容差。
  static const int _sameSessionGapLimitMs = 10 * 60 * 1000;
  static const int _adjacentGapLimitMs = 5 * 60 * 1000;

  /// `< 30s` 连续语音物理停顿合并阈值（不设总时长上限）。
  static const int _speechMergeGapLimitMs = 30 * 1000;

  /// 提取当前全部「连续有声说话簇」，供滚动清洗分段服务与投影共源对齐 `anchorSegmentId`。
  static List<ProjectedSpeechGroup> collectSpeechGroups(
    List<RecordingFile> files,
  ) {
    final rawViews = _sortedRawViews(files);
    final groups = <ProjectedSpeechGroup>[];
    var i = 0;
    while (i < rawViews.length) {
      final head = rawViews[i];
      if (_isMergeableSilent(head)) {
        var j = i + 1;
        while (j < rawViews.length &&
            _canMergeConsecutiveSilent(rawViews[j - 1], rawViews[j])) {
          j++;
        }
        i = j;
        continue;
      }
      if (!_isMergeableSpeech(head)) {
        if (head.turns.isNotEmpty || head.utterances.isNotEmpty) {
          groups.add(
            ProjectedSpeechGroup(
              anchorSegmentId: head.segment.id,
              views: [head],
              startAtMs: head.segment.startAtMs,
              endAtMs: _endMsOf(head),
            ),
          );
        }
        i++;
        continue;
      }
      final speechGroup = <SegmentView>[head];
      var j = i + 1;
      while (j < rawViews.length &&
          _canMergeConsecutiveSpeech(speechGroup.last, rawViews[j])) {
        speechGroup.add(rawViews[j]);
        j++;
      }
      groups.add(
        ProjectedSpeechGroup(
          anchorSegmentId: speechGroup.first.segment.id,
          views: speechGroup,
          startAtMs: speechGroup.first.segment.startAtMs,
          endAtMs: _endMsOf(speechGroup.last),
        ),
      );
      i = j;
    }
    return groups;
  }

  static List<SegmentView> _sortedRawViews(List<RecordingFile> files) {
    final rawViews = <SegmentView>[];
    for (final file in files) {
      for (final segment in file.segments) {
        rawViews.add(_viewFor(file, segment));
      }
    }

    // 先按真实起点时间升序排列，再做同日连续切片无损聚合（不修改磁盘原始 WAV 与 JSON）。
    rawViews.sort((a, b) {
      final cmpStart = a.segment.startAtMs.compareTo(b.segment.startAtMs);
      if (cmpStart != 0) return cmpStart;
      final cmpEnd = _endMsOf(a).compareTo(_endMsOf(b));
      if (cmpEnd != 0) return cmpEnd;
      return a.segment.id.compareTo(b.segment.id);
    });
    return rawViews;
  }

  static ProjectionResult build(
    List<RecordingFile> files, {
    TopicSegmentationState? topicState,
  }) {
    final rawViews = _sortedRawViews(files);

    final events = <RecordEvent>[];
    final views = <String, SegmentView>{};
    final redirects = <String, String>{};
    final startMsByEventId = <String, int>{};

    var i = 0;
    while (i < rawViews.length) {
      final head = rawViews[i];
      if (_isMergeableSilent(head)) {
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
        continue;
      }

      if (!_isMergeableSpeech(head)) {
        views[head.segment.id] = head;
        final event = _eventFor(head);
        events.add(event);
        startMsByEventId[event.id] = head.segment.startAtMs;
        i++;
        continue;
      }

      final speechGroup = <SegmentView>[head];
      var j = i + 1;
      while (j < rawViews.length) {
        final prev = speechGroup.last;
        final next = rawViews[j];
        if (!_canMergeConsecutiveSpeech(prev, next)) break;
        speechGroup.add(next);
        j++;
      }

      _projectSpeechGroup(
        group: speechGroup,
        topicState: topicState,
        events: events,
        views: views,
        redirects: redirects,
        startMsByEventId: startMsByEventId,
      );
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

  static bool _isMergeableSpeech(SegmentView v) {
    if (_isMergeableSilent(v)) return false;
    if (v.segment.status != SegmentStatus.closed) return false;
    return v.turns.isNotEmpty || v.utterances.isNotEmpty;
  }

  static int _speechStartMsOf(SegmentView v) {
    if (v.turns.isNotEmpty) return v.file.startAtMs + v.turns.first.startMs;
    if (v.utterances.isNotEmpty) {
      return v.file.startAtMs + v.utterances.first.startMs;
    }
    return v.segment.startAtMs;
  }

  static int _speechEndMsOf(SegmentView v) {
    if (v.turns.isNotEmpty) return v.file.startAtMs + v.turns.last.endMs;
    if (v.utterances.isNotEmpty) {
      return v.file.startAtMs + v.utterances.last.endMs;
    }
    return _endMsOf(v);
  }

  static bool _canMergeConsecutiveSpeech(SegmentView prev, SegmentView next) {
    if (!_isMergeableSpeech(next)) return false;
    final prevStart = prev.segment.startAtMs;
    final nextStart = next.segment.startAtMs;
    if (_dayOffset(prevStart) != _dayOffset(nextStart)) return false;
    final prevSpeechEnd = _speechEndMsOf(prev);
    final nextSpeechStart = _speechStartMsOf(next);
    final gapMs = nextSpeechStart - prevSpeechEnd;
    return gapMs >= -60 * 1000 && gapMs < _speechMergeGapLimitMs;
  }

  static void _projectSpeechGroup({
    required List<SegmentView> group,
    required TopicSegmentationState? topicState,
    required List<RecordEvent> events,
    required Map<String, SegmentView> views,
    required Map<String, String> redirects,
    required Map<String, int> startMsByEventId,
  }) {
    final anchor = group.first;
    final startAtMs = anchor.segment.startAtMs;
    final endAtMs = _endMsOf(group.last);
    final rollingRun = topicState?.displayRunForAnchor(anchor.segment.id);
    final runKey = FastTopicSegmentAgent.buildRunKey(
      anchor.segment.id,
      startAtMs,
      endAtMs,
    );
    final topicRun = topicState?.runsByKey[runKey];

    // 单个未拆分且无滚动清洗结果的片段直接走原始投影（无合并徽标）
    if (group.length == 1 &&
        (rollingRun == null || rollingRun.sections.isEmpty) &&
        (topicRun == null || topicRun.sections.isEmpty)) {
      views[anchor.segment.id] = anchor;
      final event = _eventFor(anchor);
      events.add(event);
      startMsByEventId[event.id] = anchor.segment.startAtMs;
      return;
    }

    // 把多片中的相对时间统一换算到 anchor.file.startAtMs 坐标系
    final combinedTurns = <PolishedTurn>[];
    final combinedUtterances = <RawUtterance>[];
    final utteranceCompositeKey = <int, String>{};
    final combinedSlices = <AudioSlice>[];
    for (final child in group) {
      final delta = child.file.startAtMs - anchor.file.startAtMs;
      for (final t in child.turns) {
        combinedTurns.add(
          PolishedTurn(
            id: t.id,
            startMs: t.startMs + delta,
            endMs: t.endMs + delta,
            speakerLabel: t.speakerLabel,
            text: t.text,
            srcUtteranceIds: t.srcUtteranceIds,
            revision: t.revision,
          ),
        );
      }
      for (final u in child.utterances) {
        final shifted = RawUtterance(
          id: u.id,
          sliceId: u.sliceId,
          startMs: u.startMs + delta,
          endMs: u.endMs + delta,
          text: u.text,
          lang: u.lang,
          emotion: u.emotion,
          speakerCluster: u.speakerCluster,
          speakerLabel: u.speakerLabel,
          spkConfidence: u.spkConfidence,
        );
        combinedUtterances.add(shifted);
        utteranceCompositeKey[identityHashCode(shifted)] =
            '${child.file.id}::${u.id}';
      }
      for (final s in child.slices) {
        combinedSlices.add(
          AudioSlice(
            id: s.id,
            index: s.index,
            startMs: s.startMs + delta,
            endMs: s.endMs + delta,
            wavPath: s.wavPath,
            stage: s.stage,
            silenceAfterMs: s.silenceAfterMs,
            error: s.error,
          ),
        );
      }
    }
    combinedTurns.sort((a, b) => a.startMs.compareTo(b.startMs));
    combinedUtterances.sort((a, b) => a.startMs.compareTo(b.startMs));

    if (rollingRun != null && rollingRun.sections.isNotEmpty) {
      _projectRollingSections(
        anchor: anchor,
        group: group,
        rollingRun: rollingRun,
        combinedUtterances: combinedUtterances,
        utteranceCompositeKey: utteranceCompositeKey,
        combinedSlices: combinedSlices,
        events: events,
        views: views,
        redirects: redirects,
        startMsByEventId: startMsByEventId,
      );
      return;
    }

    if (topicRun != null &&
        topicRun.sections.length >= 2 &&
        (combinedTurns.isNotEmpty || combinedUtterances.isNotEmpty)) {
      final emittedTopics = <({String id, int startMs, int endMs})>[];
      final itemCount = combinedTurns.isNotEmpty
          ? combinedTurns.length
          : combinedUtterances.length;
      for (var si = 0; si < topicRun.sections.length; si++) {
        final sec = topicRun.sections[si];
        final sIdx = sec.startTurnIndex.clamp(0, itemCount - 1);
        final eIdx = sec.endTurnIndex.clamp(sIdx, itemCount - 1);
        final subTurns = combinedTurns.isNotEmpty
            ? combinedTurns.sublist(sIdx, eIdx + 1)
            : const <PolishedTurn>[];
        final List<RawUtterance> subUtterances;
        final int secStartMs;
        final int secEndMs;
        if (subTurns.isNotEmpty) {
          secStartMs = anchor.file.startAtMs + subTurns.first.startMs;
          secEndMs = anchor.file.startAtMs + subTurns.last.endMs;
          final srcUtteranceSet = {
            for (final t in subTurns) ...t.srcUtteranceIds,
          };
          subUtterances = combinedUtterances.where((u) {
            if (srcUtteranceSet.isNotEmpty) {
              return srcUtteranceSet.contains(u.id);
            }
            final abs = anchor.file.startAtMs + u.startMs;
            return abs >= secStartMs && abs <= secEndMs;
          }).toList();
        } else {
          subUtterances = combinedUtterances.sublist(sIdx, eIdx + 1);
          secStartMs = anchor.file.startAtMs + subUtterances.first.startMs;
          secEndMs = anchor.file.startAtMs + subUtterances.last.endMs;
        }
        final subChildren = [
          for (final c in group)
            if (_endMsOf(c) > secStartMs && c.segment.startAtMs < secEndMs) c,
        ];
        final effectiveChildren = subChildren.isEmpty ? [anchor] : subChildren;
        final speakers = <String>{
          for (final t in subTurns)
            if (t.speakerLabel.trim().isNotEmpty && t.speakerLabel != '未区分')
              t.speakerLabel,
          if (subTurns.isEmpty)
            for (final u in subUtterances)
              if ((u.speakerLabel ?? '').trim().isNotEmpty &&
                  u.speakerLabel != '未区分')
                u.speakerLabel!,
        }.toList();
        final previewTexts = subTurns.isNotEmpty
            ? subTurns.map((t) => '${t.speakerLabel}: ${t.text}')
            : subUtterances.map(
                (u) => '${u.speakerLabel ?? '未区分'}: ${u.text}',
              );
        final briefSource = subTurns.isNotEmpty
            ? subTurns.map((t) => t.text).take(2).join('；')
            : subUtterances.map((u) => u.text).take(2).join('；');
        final eventId = si == 0
            ? anchor.segment.id
            : '${anchor.segment.id}#t$si';
        final secSeg = SegmentRecord(
          id: eventId,
          sessionId: anchor.segment.sessionId,
          index: anchor.segment.index + si,
          startAtMs: secStartMs,
          endAtMs: secEndMs,
          title: sec.title.trim().isNotEmpty
              ? sec.title.trim()
              : (si == 0 && anchor.segment.title.trim().isNotEmpty
                    ? anchor.segment.title
                    : '话题 ${si + 1}'),
          brief: sec.brief.trim().isNotEmpty ? sec.brief.trim() : briefSource,
          longText: previewTexts.join('\n'),
          speakerLabels: speakers,
          speakerCount: speakers.length,
          tags: sec.tags.isNotEmpty ? sec.tags : anchor.segment.tags,
          status: anchor.segment.status,
          sliceIds: {for (final u in subUtterances) u.sliceId}.toList(),
          turnIds: [for (final t in subTurns) t.id],
          mark: si == 0 ? anchor.segment.mark : null,
          polishStale: effectiveChildren.any(
            (c) => c.segment.polishStale || c.file.polishStale,
          ),
          fallback: effectiveChildren.any((c) => c.segment.fallback),
        );
        final secView = SegmentView(
          segment: secSeg,
          file: anchor.file,
          turns: subTurns,
          utterances: subUtterances,
          slices: combinedSlices,
          mergedChildren: effectiveChildren.length > 1
              ? List<SegmentView>.unmodifiable(effectiveChildren)
              : const [],
        );
        views[eventId] = secView;
        final ev = _eventFor(
          secView,
          mergedSliceCount: secView.mergedSliceCount,
        );
        events.add(ev);
        startMsByEventId[eventId] = secStartMs;
        emittedTopics.add((
          id: eventId,
          startMs: secStartMs,
          endMs: secEndMs,
        ));
      }

      for (var k = 1; k < group.length; k++) {
        final child = group[k];
        final childMid =
            (child.segment.startAtMs + _endMsOf(child)) ~/ 2;
        var targetId = emittedTopics.first.id;
        for (final t in emittedTopics) {
          if (childMid >= t.startMs && childMid <= t.endMs) {
            targetId = t.id;
            break;
          }
        }
        redirects[child.segment.id] = targetId;
      }
      return;
    }

    // 单主题 override（若有）或纯声学 `< 30s` 多片合并
    final singleTopic =
        (topicRun != null && topicRun.sections.isNotEmpty)
        ? topicRun.sections.first
        : null;
    final speakers = <String>{
      for (final c in group) ...c.segment.speakerLabels,
      for (final t in combinedTurns)
        if (t.speakerLabel.trim().isNotEmpty && t.speakerLabel != '未区分')
          t.speakerLabel,
    }.toList();
    final marks = <String>{
      for (final c in group)
        if ((c.segment.mark ?? '').trim().isNotEmpty) c.segment.mark!.trim(),
    }.toList();
    final resolvedTitle = singleTopic != null && singleTopic.title.trim().isNotEmpty
        ? singleTopic.title.trim()
        : _resolveCleanTitle(
            group
                .map((c) => c.segment.title.trim())
                .firstWhere(
                  (t) =>
                      t.isNotEmpty &&
                      !_legacyRawTitlePattern.hasMatch(t) &&
                      isMeaningfulSpeechText(t),
                  orElse: () => '',
                ),
            combinedTurns: combinedTurns,
            combinedUtterances: combinedUtterances,
          );
    final distinctBriefs = group
        .map((c) => c.segment.brief.trim())
        .where(
          (b) =>
              b.isNotEmpty &&
              isMeaningfulSpeechText(b) &&
              !_legacyRawTitlePattern.hasMatch(b),
        )
        .toSet()
        .toList();
    final resolvedBrief =
        singleTopic != null && singleTopic.brief.trim().isNotEmpty
        ? singleTopic.brief.trim()
        : (distinctBriefs.isEmpty
              ? _fallbackBrief(combinedTurns, combinedUtterances)
              : distinctBriefs.take(2).join('；'));
    final distinctLongs = group
        .map((c) => c.segment.longText.trim())
        .where((l) => l.isNotEmpty)
        .toSet()
        .toList();
    final mergedSeg = SegmentRecord(
      id: anchor.segment.id,
      sessionId: anchor.segment.sessionId,
      index: anchor.segment.index,
      startAtMs: startAtMs,
      endAtMs: endAtMs,
      title: resolvedTitle,
      brief: resolvedBrief,
      longText: distinctLongs.join('\n'),
      speakerLabels: speakers,
      speakerCount: speakers.length,
      tags: singleTopic != null && singleTopic.tags.isNotEmpty
          ? singleTopic.tags
          : {for (final c in group) ...c.segment.tags}.toList(),
      status: anchor.segment.status,
      sliceIds: {for (final c in group) ...c.segment.sliceIds}.toList(),
      turnIds: [for (final t in combinedTurns) t.id],
      mark: marks.isEmpty ? null : marks.join(' · '),
      polishStale: group.any(
        (c) => c.segment.polishStale || c.file.polishStale,
      ),
      fallback: group.any((c) => c.segment.fallback),
    );
    final mergedView = SegmentView(
      segment: mergedSeg,
      file: anchor.file,
      turns: combinedTurns,
      utterances: combinedUtterances,
      slices: combinedSlices,
      mergedChildren: group.length > 1
          ? List<SegmentView>.unmodifiable(group)
          : const [],
    );
    views[anchor.segment.id] = mergedView;
    for (var k = 1; k < group.length; k++) {
      redirects[group[k].segment.id] = anchor.segment.id;
    }
    final ev = _eventFor(
      mergedView,
      mergedSliceCount: group.length,
    );
    events.add(ev);
    startMsByEventId[ev.id] = startAtMs;
  }

  static void _projectRollingSections({
    required SegmentView anchor,
    required List<SegmentView> group,
    required TopicRunSegmentation rollingRun,
    required List<RawUtterance> combinedUtterances,
    required Map<int, String> utteranceCompositeKey,
    required List<AudioSlice> combinedSlices,
    required List<RecordEvent> events,
    required Map<String, SegmentView> views,
    required Map<String, String> redirects,
    required Map<String, int> startMsByEventId,
  }) {
    final emittedTopics = <({String id, int startMs, int endMs})>[];
    final anchorStartMs = anchor.file.startAtMs;

    void emitSection({
      required int sectionIndex,
      required String title,
      required String brief,
      required String overview,
      required List<String> tags,
      required List<PolishedTurn> turns,
      required List<RawUtterance> utterances,
      required int secStartMs,
      required int secEndMs,
      required bool cleanedByCloud,
      String? explicitId,
    }) {
      if (turns.isEmpty && utterances.isEmpty) return;
      final subChildren = [
        for (final c in group)
          if (_endMsOf(c) > secStartMs && c.segment.startAtMs < secEndMs) c,
      ];
      final effectiveChildren = subChildren.isEmpty ? [anchor] : subChildren;
      final speakers = <String>{
        for (final t in turns)
          if (t.speakerLabel.trim().isNotEmpty && t.speakerLabel != '未区分')
            t.speakerLabel.trim(),
        if (turns.isEmpty)
          for (final u in utterances)
            if ((u.speakerLabel ?? '').trim().isNotEmpty &&
                u.speakerLabel != '未区分')
              u.speakerLabel!.trim(),
      }.toList();

      final seedText = turns.isNotEmpty
          ? turns.map((t) => t.text).join(' ')
          : utterances.map((u) => u.text).join(' ');
      final resolvedTitle =
          (title.trim().isNotEmpty &&
              !_legacyRawTitlePattern.hasMatch(title.trim()) &&
              isMeaningfulSpeechText(title))
          ? title.trim()
          : buildReadableFallbackTitle(seedText, fallback: '阶段话题');
      final resolvedBrief =
          (brief.trim().isNotEmpty &&
              isMeaningfulSpeechText(brief) &&
              !_legacyRawTitlePattern.hasMatch(brief.trim()))
          ? brief.trim()
          : _truncateClean(seedText, 68);
      final resolvedLong =
          (overview.trim().isNotEmpty && isMeaningfulSpeechText(overview))
          ? overview.trim()
          : resolvedBrief;

      final eventId =
          explicitId ??
          (emittedTopics.isEmpty
              ? anchor.segment.id
              : '${anchor.segment.id}#t$sectionIndex');
      final secSeg = SegmentRecord(
        id: eventId,
        sessionId: anchor.segment.sessionId,
        index: anchor.segment.index + sectionIndex,
        startAtMs: secStartMs,
        endAtMs: secEndMs > secStartMs ? secEndMs : secStartMs + 1000,
        title: resolvedTitle,
        brief: resolvedBrief,
        longText: resolvedLong,
        speakerLabels: speakers,
        speakerCount: speakers.length,
        tags: tags.isNotEmpty ? tags : anchor.segment.tags,
        status: anchor.segment.status,
        sliceIds: {for (final u in utterances) u.sliceId}.toList(),
        turnIds: [for (final t in turns) t.id],
        mark: emittedTopics.isEmpty ? anchor.segment.mark : null,
        polishStale: cleanedByCloud
            ? false
            : effectiveChildren.any(
                (c) => c.segment.polishStale || c.file.polishStale,
              ),
        fallback: cleanedByCloud
            ? false
            : effectiveChildren.any((c) => c.segment.fallback),
      );
      final secView = SegmentView(
        segment: secSeg,
        file: anchor.file,
        turns: turns,
        utterances: utterances,
        slices: combinedSlices,
        mergedChildren: effectiveChildren.length > 1
            ? List<SegmentView>.unmodifiable(effectiveChildren)
            : const [],
      );
      views[eventId] = secView;
      final ev = _eventFor(
        secView,
        mergedSliceCount: secView.mergedSliceCount,
      );
      events.add(ev);
      startMsByEventId[eventId] = secStartMs;
      emittedTopics.add((id: eventId, startMs: secStartMs, endMs: secEndMs));
    }

    for (var si = 0; si < rollingRun.sections.length; si++) {
      final sec = rollingRun.sections[si];
      final paragraphs = sec.paragraphs
          .where((p) => isMeaningfulSpeechText(p.text))
          .toList();
      final subTurns = <PolishedTurn>[
        for (var pi = 0; pi < paragraphs.length; pi++)
          () {
            final p = paragraphs[pi];
            final relStart = (p.startAtMs - anchorStartMs).clamp(0, 1 << 30);
            final relEnd = (p.endAtMs - anchorStartMs).clamp(
              relStart + 500,
              1 << 30,
            );
            return PolishedTurn(
              id: 'rc-$si-$pi',
              startMs: relStart,
              endMs: relEnd,
              speakerLabel: p.speaker.trim().isEmpty
                  ? '未区分'
                  : p.speaker.trim(),
              text: p.text.trim(),
              srcUtteranceIds: p.srcUtteranceIds,
            );
          }(),
      ];
      final srcSet = {for (final p in paragraphs) ...p.srcUtteranceIds};
      final rawSecStart = sec.startAtMs > 0
          ? sec.startAtMs
          : (subTurns.isNotEmpty
                ? anchorStartMs + subTurns.first.startMs
                : anchor.segment.startAtMs);
      final rawSecEnd = sec.endAtMs > rawSecStart
          ? sec.endAtMs
          : (subTurns.isNotEmpty
                ? anchorStartMs + subTurns.last.endMs
                : rawSecStart + 1000);
      final subUtterances = combinedUtterances.where((u) {
        final cKey = utteranceCompositeKey[identityHashCode(u)];
        if (srcSet.isNotEmpty) {
          if (cKey != null && srcSet.contains(cKey)) return true;
          if (srcSet.contains(u.id)) return true;
        }
        final absMs = anchorStartMs + u.startMs;
        return srcSet.isEmpty &&
            absMs >= rawSecStart - 500 &&
            absMs <= rawSecEnd + 500;
      }).toList();
      emitSection(
        sectionIndex: si,
        title: sec.title,
        brief: sec.brief,
        overview: sec.overview,
        tags: sec.tags,
        turns: subTurns,
        utterances: subUtterances,
        secStartMs: rawSecStart,
        secEndMs: rawSecEnd,
        cleanedByCloud: sec.cleanedByCloud,
      );
    }

    // 保留处于当前清洗周期末尾、尚未到达下次清洗点的最新语音片段，避免新讲话暂不可见
    final coveredIds = rollingRun.coveredUtteranceIds;
    final trailingUtterances = <RawUtterance>[
      for (final u in combinedUtterances)
        if (!coveredIds.contains(utteranceCompositeKey[identityHashCode(u)]) &&
            !coveredIds.contains(u.id) &&
            (anchorStartMs + u.endMs) > rollingRun.coveredUtteranceEndMs)
          u,
    ];
    if (trailingUtterances.isNotEmpty) {
      final tailTurns = _consolidateUtterancesLocally(trailingUtterances);
      if (tailTurns.isNotEmpty) {
        final tStart = anchorStartMs + tailTurns.first.startMs;
        final tEnd = anchorStartMs + tailTurns.last.endMs;
        final combined = tailTurns.map((t) => t.text).join(' ');
        emitSection(
          sectionIndex: rollingRun.sections.length,
          title: buildReadableFallbackTitle(combined, fallback: '最新片段'),
          brief: _truncateClean(combined, 68),
          overview: '本地实时转写已完成，将在当前清洗周期或停录后与上文一并由云端整理。',
          tags: const [],
          turns: tailTurns,
          utterances: trailingUtterances,
          secStartMs: tStart,
          secEndMs: tEnd,
          cleanedByCloud: false,
          explicitId: emittedTopics.isEmpty
              ? anchor.segment.id
              : '${anchor.segment.id}#tail',
        );
      }
    }

    if (emittedTopics.isEmpty) {
      views[anchor.segment.id] = anchor;
      final ev = _eventFor(anchor);
      events.add(ev);
      startMsByEventId[ev.id] = anchor.segment.startAtMs;
      return;
    }

    for (var k = 1; k < group.length; k++) {
      final child = group[k];
      final childMid = (child.segment.startAtMs + _endMsOf(child)) ~/ 2;
      var targetId = emittedTopics.first.id;
      for (final t in emittedTopics) {
        if (childMid >= t.startMs && childMid <= t.endMs) {
          targetId = t.id;
          break;
        }
      }
      redirects[child.segment.id] = targetId;
    }
  }

  static List<PolishedTurn> _consolidateUtterancesLocally(
    List<RawUtterance> utterances,
  ) {
    final sorted = utterances
        .where((u) => isMeaningfulSpeechText(u.text))
        .toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final turns = <PolishedTurn>[];
    for (var i = 0; i < sorted.length; i++) {
      final u = sorted[i];
      final clean = cleanSpokenFillers(u.text);
      if (clean.isEmpty || !isMeaningfulSpeechText(clean)) continue;
      final spk = (u.speakerLabel ?? '').trim().isEmpty
          ? '未区分'
          : u.speakerLabel!.trim();
      if (turns.isNotEmpty && turns.last.speakerLabel == spk) {
        final prev = turns.last;
        turns[turns.length - 1] = PolishedTurn(
          id: prev.id,
          startMs: prev.startMs,
          endMs: u.endMs > prev.endMs ? u.endMs : prev.endMs,
          speakerLabel: spk,
          text: joinPolishedUtterances(prev.text, clean),
          srcUtteranceIds: [...prev.srcUtteranceIds, u.id],
        );
      } else {
        turns.add(
          PolishedTurn(
            id: 'loc-$i',
            startMs: u.startMs,
            endMs: u.endMs,
            speakerLabel: spk,
            text: clean,
            srcUtteranceIds: [u.id],
          ),
        );
      }
    }
    return turns;
  }

  static String _resolveCleanTitle(
    String candidate, {
    required List<PolishedTurn> combinedTurns,
    required List<RawUtterance> combinedUtterances,
  }) {
    final t = candidate.trim();
    if (t.isNotEmpty &&
        !_legacyRawTitlePattern.hasMatch(t) &&
        isMeaningfulSpeechText(t)) {
      return t;
    }
    final seed = combinedTurns.isNotEmpty
        ? combinedTurns.map((e) => e.text).join(' ')
        : combinedUtterances.map((e) => e.text).join(' ');
    return buildReadableFallbackTitle(seed, fallback: '录音片段');
  }

  static String _fallbackBrief(
    List<PolishedTurn> turns,
    List<RawUtterance> utterances,
  ) {
    final seed = turns.isNotEmpty
        ? turns.map((t) => t.text).join('；')
        : utterances.map((u) => u.text).join('；');
    return seed.trim().isEmpty ? '尚无摘要' : _truncateClean(seed, 68);
  }

  static String _truncateClean(String text, int maxLen) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}…';
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
    turns = turns
        .where((t) => isMeaningfulSpeechText(t.text))
        .toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

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
        if (isMeaningfulSpeechText(u.text) &&
            (sliceSet.contains(u.sliceId) ||
                (sliceSet.isEmpty &&
                    file.startAtMs + u.startMs >= segment.startAtMs &&
                    file.startAtMs + u.startMs <=
                        (segment.endAtMs ?? segment.startAtMs))))
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

  static RecordEvent _eventFor(
    SegmentView view, {
    int mergedSliceCount = 1,
  }) {
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

    final rawTitle = segment.title.trim();
    final isSilentOrLegacyTitle =
        isReadySilent &&
        (rawTitle.isEmpty || _legacyRawTitlePattern.hasMatch(rawTitle));
    final isNonSilentLegacyTitle =
        !isReadySilent &&
        (rawTitle.isEmpty ||
            _legacyRawTitlePattern.hasMatch(rawTitle) ||
            !isMeaningfulSpeechText(rawTitle));
    final fallbackSeedText = dialog.isNotEmpty
        ? dialog.map((t) => t.text).join(' ')
        : raw.map((t) => t.text).join(' ');
    final resolvedTitle = isSilentOrLegacyTitle
        ? '未识别到语音'
        : (isNonSilentLegacyTitle
              ? buildReadableFallbackTitle(
                  fallbackSeedText,
                  fallback: '录音片段',
                )
              : rawTitle);
    final rawBrief = segment.brief.trim();
    final brief = isReadySilent
        ? '本段未检测到有效人声，原始录音已保存在本机。'
        : (rawBrief.isNotEmpty &&
                  isMeaningfulSpeechText(rawBrief) &&
                  !_legacyRawTitlePattern.hasMatch(rawBrief))
            ? rawBrief
            : segment.status == SegmentStatus.live
                ? '正在整理这段对话…'
                : (fallbackSeedText.trim().isNotEmpty
                      ? _truncateClean(fallbackSeedText, 68)
                      : '尚无摘要');
    final rawLong = segment.longText.trim();
    final longText = isReadySilent
        ? '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。'
        : (rawLong.isNotEmpty &&
                  isMeaningfulSpeechText(rawLong) &&
                  !_legacyRawTitlePattern.hasMatch(rawLong))
            ? rawLong
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
      srcMap: mergedSliceCount > 1
          ? '来源 ${_hm(startMs)}—${_hm(endMs)} · $mergedSliceCount 个分片'
          : '来源 ${_hm(startMs)}—${_hm(endMs)}',
      dialog: dialog,
      raw: raw,
      live: segment.status == SegmentStatus.live,
      note: note,
      mergedSliceCount: mergedSliceCount,
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
