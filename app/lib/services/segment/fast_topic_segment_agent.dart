/// 独立快速主题分段 Agent —— 连续发言片段遇 `≥ 1 分钟` 空白后，按语义话题逻辑切分，
/// 并持久化幂等水位锁（watermark + runKey），避免历史已切分片段重复触发云端推理。
///
/// 约束（AGENTS.md）：
/// - 本地转写文本已先按 `< 30s` 停顿在投影层无时长上限合并；
/// - 仅在网关可用且配置模型时上行纯文本做主题边界切分，绝不上传音频；
/// - 离线 / 未登录 / 模型失败时保留物理声学合并结果，不编造 AI 主题文本，也不锁死重试机会。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/recording.dart';
import '../analysis/chat_completion.dart';
import 'section_copy.dart';

class TopicParagraph {
  const TopicParagraph({
    required this.speaker,
    required this.text,
    required this.startAtMs,
    required this.endAtMs,
    this.srcUtteranceIds = const [],
  });

  final String speaker;
  final String text;
  final int startAtMs;
  final int endAtMs;
  final List<String> srcUtteranceIds;

  TopicParagraph copyWith({
    String? speaker,
    String? text,
    int? startAtMs,
    int? endAtMs,
    List<String>? srcUtteranceIds,
  }) => TopicParagraph(
    speaker: speaker ?? this.speaker,
    text: text ?? this.text,
    startAtMs: startAtMs ?? this.startAtMs,
    endAtMs: endAtMs ?? this.endAtMs,
    srcUtteranceIds: srcUtteranceIds ?? this.srcUtteranceIds,
  );

  Map<String, dynamic> toJson() => {
    'sp': speaker,
    'tx': text,
    's': startAtMs,
    'e': endAtMs,
    if (srcUtteranceIds.isNotEmpty) 'u': srcUtteranceIds,
  };

  factory TopicParagraph.fromJson(Map<String, dynamic> j) => TopicParagraph(
    speaker: '${j['sp'] ?? ''}',
    text: '${j['tx'] ?? ''}',
    startAtMs: (j['s'] as num?)?.toInt() ?? 0,
    endAtMs: (j['e'] as num?)?.toInt() ?? 0,
    srcUtteranceIds: [for (final u in (j['u'] as List? ?? const [])) '$u'],
  );
}

class TopicSectionOverride {
  const TopicSectionOverride({
    required this.title,
    required this.brief,
    required this.startTurnIndex,
    required this.endTurnIndex,
    this.tags = const [],
    this.overview = '',
    this.summary = '',
    this.paragraphs = const [],
    this.cleanedByCloud = false,
    this.startAtMs = 0,
    this.endAtMs = 0,
    this.evidenceSliceIds = const [],
  });

  final String title;
  final String brief;
  final int startTurnIndex;
  final int endTurnIndex;
  final List<String> tags;
  final String overview;
  final String summary;
  final List<TopicParagraph> paragraphs;
  final bool cleanedByCloud;
  final int startAtMs;
  final int endAtMs;
  final List<String> evidenceSliceIds;

  TopicSectionOverride copyWith({
    String? title,
    String? brief,
    int? startTurnIndex,
    int? endTurnIndex,
    List<String>? tags,
    String? overview,
    String? summary,
    List<TopicParagraph>? paragraphs,
    bool? cleanedByCloud,
    int? startAtMs,
    int? endAtMs,
    List<String>? evidenceSliceIds,
  }) => TopicSectionOverride(
    title: title ?? this.title,
    brief: brief ?? this.brief,
    startTurnIndex: startTurnIndex ?? this.startTurnIndex,
    endTurnIndex: endTurnIndex ?? this.endTurnIndex,
    tags: tags ?? this.tags,
    overview: overview ?? this.overview,
    summary: summary ?? this.summary,
    paragraphs: paragraphs ?? this.paragraphs,
    cleanedByCloud: cleanedByCloud ?? this.cleanedByCloud,
    startAtMs: startAtMs ?? this.startAtMs,
    endAtMs: endAtMs ?? this.endAtMs,
    evidenceSliceIds: evidenceSliceIds ?? this.evidenceSliceIds,
  );

  Map<String, dynamic> toJson() => {
    't': title,
    'b': brief,
    's': startTurnIndex,
    'e': endTurnIndex,
    if (tags.isNotEmpty) 'tg': tags,
    if (overview.isNotEmpty) 'ov': overview,
    if (summary.isNotEmpty) 'su': summary,
    if (paragraphs.isNotEmpty) 'p': [for (final p in paragraphs) p.toJson()],
    if (cleanedByCloud) 'cl': true,
    if (startAtMs > 0) 'sa': startAtMs,
    if (endAtMs > 0) 'ea': endAtMs,
    if (evidenceSliceIds.isNotEmpty) 'ev': evidenceSliceIds,
  };

  factory TopicSectionOverride.fromJson(Map<String, dynamic> j) =>
      TopicSectionOverride(
        title: '${j['t'] ?? ''}',
        brief: '${j['b'] ?? ''}',
        startTurnIndex: (j['s'] as num?)?.toInt() ?? 0,
        endTurnIndex: (j['e'] as num?)?.toInt() ?? 0,
        tags: [for (final t in (j['tg'] as List? ?? const [])) '$t'],
        overview: '${j['ov'] ?? ''}',
        summary: '${j['su'] ?? j['summary'] ?? ''}',
        paragraphs: [
          for (final p in (j['p'] as List? ?? const []))
            if (p is Map<String, dynamic>) TopicParagraph.fromJson(p),
        ],
        cleanedByCloud: j['cl'] == true,
        startAtMs: (j['sa'] as num?)?.toInt() ?? 0,
        endAtMs: (j['ea'] as num?)?.toInt() ?? 0,
        evidenceSliceIds: [
          for (final s in (j['ev'] as List? ?? const [])) '$s',
        ],
      );
}

class TopicRunSegmentation {
  const TopicRunSegmentation({
    required this.runKey,
    required this.startAtMs,
    required this.endAtMs,
    required this.sections,
    required this.evaluatedAtMs,
    this.coveredUtteranceEndMs = 0,
    this.coveredUtteranceIds = const {},
  });

  final String runKey;
  final int startAtMs;
  final int endAtMs;
  final List<TopicSectionOverride> sections;
  final int evaluatedAtMs;
  final int coveredUtteranceEndMs;
  final Set<String> coveredUtteranceIds;

  Map<String, dynamic> toJson() => {
    'k': runKey,
    's': startAtMs,
    'e': endAtMs,
    'sec': [for (final sec in sections) sec.toJson()],
    'at': evaluatedAtMs,
    if (coveredUtteranceEndMs > 0) 'cue': coveredUtteranceEndMs,
    if (coveredUtteranceIds.isNotEmpty) 'cui': coveredUtteranceIds.toList(),
  };

  factory TopicRunSegmentation.fromJson(Map<String, dynamic> j) =>
      TopicRunSegmentation(
        runKey: '${j['k'] ?? ''}',
        startAtMs: (j['s'] as num?)?.toInt() ?? 0,
        endAtMs: (j['e'] as num?)?.toInt() ?? 0,
        sections: [
          for (final s in (j['sec'] as List? ?? const []))
            if (s is Map<String, dynamic>) TopicSectionOverride.fromJson(s),
        ],
        evaluatedAtMs: (j['at'] as num?)?.toInt() ?? 0,
        coveredUtteranceEndMs: (j['cue'] as num?)?.toInt() ?? 0,
        coveredUtteranceIds: {
          for (final id in (j['cui'] as List? ?? const [])) '$id',
        },
      );
}

class TopicSegmentationState {
  const TopicSegmentationState({
    this.watermarkEndAtMs = 0,
    this.lockedRunKeys = const {},
    this.runsByKey = const {},
    this.rollingByAnchor = const {},
    this.stageByTask = const {},
  });

  const TopicSegmentationState.empty()
    : watermarkEndAtMs = 0,
      lockedRunKeys = const {},
      runsByKey = const {},
      rollingByAnchor = const {},
      stageByTask = const {};

  /// 更高轮次覆盖短轮的顺序。只在该轮时间不早于短轮时，时间轴才改用它。
  static const List<String> higherStageOrder = ['clean.long', 'clean.medium'];

  /// 单调水位：endAtMs <= watermarkEndAtMs 的历史连续说话簇已结算锁定，不重跑。
  final int watermarkEndAtMs;
  final Set<String> lockedRunKeys;
  final Map<String, TopicRunSegmentation> runsByKey;

  /// 滚动语义+声纹联合清洗分段结果（key 为连续说话组 anchorSegmentId）。
  final Map<String, TopicRunSegmentation> rollingByAnchor;

  /// 中轮 / 长轮再合并结果。外层 key 是任务 id，内层 key 是 anchorSegmentId。
  final Map<String, Map<String, TopicRunSegmentation>> stageByTask;

  /// 时间轴采用的整理结果：更高轮次只有不旧于短轮时才盖住短轮。
  TopicRunSegmentation? displayRunForAnchor(String anchorId) {
    final rolling = rollingByAnchor[anchorId];
    TopicRunSegmentation? best;
    var bestAt = -1;
    if (rolling != null && rolling.sections.isNotEmpty) {
      best = rolling;
      bestAt = rolling.evaluatedAtMs;
    }
    for (final taskId in higherStageOrder) {
      final run = stageByTask[taskId]?[anchorId];
      if (run == null || run.sections.isEmpty) continue;
      if (best == null || run.evaluatedAtMs >= bestAt) {
        best = run;
        bestAt = run.evaluatedAtMs;
      }
    }
    return best;
  }

  bool isLocked(String runKey, int endAtMs) =>
      lockedRunKeys.contains(runKey) ||
      (watermarkEndAtMs > 0 && endAtMs <= watermarkEndAtMs);

  TopicSegmentationState withRun(TopicRunSegmentation run) {
    final nextWatermark = run.endAtMs > watermarkEndAtMs
        ? run.endAtMs
        : watermarkEndAtMs;
    return TopicSegmentationState(
      watermarkEndAtMs: nextWatermark,
      lockedRunKeys: {...lockedRunKeys, run.runKey},
      runsByKey: {...runsByKey, run.runKey: run},
      rollingByAnchor: rollingByAnchor,
      stageByTask: stageByTask,
    );
  }

  TopicSegmentationState withRollingRun(TopicRunSegmentation run) =>
      TopicSegmentationState(
        watermarkEndAtMs: watermarkEndAtMs,
        lockedRunKeys: lockedRunKeys,
        runsByKey: runsByKey,
        rollingByAnchor: {...rollingByAnchor, run.runKey: run},
        stageByTask: stageByTask,
      );

  TopicSegmentationState withStageRun(String taskId, TopicRunSegmentation run) {
    final current =
        stageByTask[taskId] ?? const <String, TopicRunSegmentation>{};
    return TopicSegmentationState(
      watermarkEndAtMs: watermarkEndAtMs,
      lockedRunKeys: lockedRunKeys,
      runsByKey: runsByKey,
      rollingByAnchor: rollingByAnchor,
      stageByTask: {
        ...stageByTask,
        taskId: {...current, run.runKey: run},
      },
    );
  }

  TopicSegmentationState withoutRollingRuns() => const TopicSegmentationState();

  Map<String, dynamic> toJson() => {
    'v': 2,
    'wm': watermarkEndAtMs,
    'lk': lockedRunKeys.toList(),
    'runs': {for (final e in runsByKey.entries) e.key: e.value.toJson()},
    if (rollingByAnchor.isNotEmpty)
      'rolling': {
        for (final e in rollingByAnchor.entries) e.key: e.value.toJson(),
      },
    if (stageByTask.isNotEmpty)
      'stages': {
        for (final task in stageByTask.entries)
          task.key: {
            for (final run in task.value.entries) run.key: run.value.toJson(),
          },
      },
  };

  factory TopicSegmentationState.fromJson(Map<String, dynamic> j) {
    final rawRuns = j['runs'] as Map<String, dynamic>? ?? const {};
    final rawRolling = j['rolling'] as Map<String, dynamic>? ?? const {};
    return TopicSegmentationState(
      watermarkEndAtMs: (j['wm'] as num?)?.toInt() ?? 0,
      lockedRunKeys: {for (final k in (j['lk'] as List? ?? const [])) '$k'},
      runsByKey: {
        for (final entry in rawRuns.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key: TopicRunSegmentation.fromJson(
              entry.value as Map<String, dynamic>,
            ),
      },
      rollingByAnchor: {
        for (final entry in rawRolling.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key: TopicRunSegmentation.fromJson(
              entry.value as Map<String, dynamic>,
            ),
      },
      stageByTask: _parseStageMap(j['stages']),
    );
  }

  static Map<String, Map<String, TopicRunSegmentation>> _parseStageMap(
    Object? raw,
  ) {
    if (raw is! Map) return const {};
    final stages = <String, Map<String, TopicRunSegmentation>>{};
    for (final taskEntry in raw.entries) {
      if (taskEntry.value is! Map) continue;
      final runs = <String, TopicRunSegmentation>{};
      for (final runEntry in (taskEntry.value as Map).entries) {
        final value = runEntry.value;
        if (value is! Map) continue;
        runs['${runEntry.key}'] = TopicRunSegmentation.fromJson(
          value is Map<String, dynamic>
              ? value
              : Map<String, dynamic>.from(value),
        );
      }
      stages['${taskEntry.key}'] = runs;
    }
    return stages;
  }
}

/// 原子持久化 `_topic_segmentation.json`，存放在录音根目录，不被 `RecordingStore.loadAll` 当作录音目录。
///
/// 内置异步串行化互斥队列与 `readModifyWrite` 原子读-改-写：
/// 确保 `clean.short` 与 `clean.medium` / `clean.long` 并发落盘时绝不互相覆盖或触发 `.tmp` 竞态。
class TopicSegmentationStore {
  TopicSegmentationStore({required Future<Directory> Function() resolveRoot})
    : _resolveRoot = resolveRoot;

  final Future<Directory> Function() _resolveRoot;
  TopicSegmentationState? _cache;
  Future<void> _mutex = Future<void>.value();
  int _tmpSeq = 0;

  Future<T> _withLock<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutex = _mutex.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<File> _file() async {
    final root = await _resolveRoot();
    if (!await root.exists()) await root.create(recursive: true);
    return File('${root.path}/_topic_segmentation.json');
  }

  Future<TopicSegmentationState> _loadUnlocked({required bool refresh}) async {
    final cached = _cache;
    if (!refresh && cached != null) return cached;
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cache = const TopicSegmentationState.empty();
        return _cache!;
      }
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map<String, dynamic>) {
        _cache = TopicSegmentationState.fromJson(decoded);
        return _cache!;
      }
    } catch (_) {}
    _cache = const TopicSegmentationState.empty();
    return _cache!;
  }

  Future<void> _saveUnlocked(TopicSegmentationState state) async {
    _cache = state;
    final f = await _file();
    final tmp = File('${f.path}.tmp.${++_tmpSeq}');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  Future<TopicSegmentationState> load({bool refresh = false}) =>
      _withLock(() => _loadUnlocked(refresh: refresh));

  Future<void> save(TopicSegmentationState state) =>
      _withLock(() => _saveUnlocked(state));

  Future<void> clear() => _withLock(() async {
    _cache = const TopicSegmentationState.empty();
    final f = await _file();
    if (await f.exists()) await f.delete();
  });

  /// 原子读-改-写：在同一互斥锁临界区内读取最新状态、应用变更并持久化落盘。
  Future<TopicSegmentationState> readModifyWrite(
    FutureOr<TopicSegmentationState> Function(TopicSegmentationState current)
    updater, {
    bool refresh = false,
  }) => _withLock(() async {
    final current = await _loadUnlocked(refresh: refresh);
    final next = await updater(current);
    await _saveUnlocked(next);
    return next;
  });
}

class TopicSegmentEvaluationResult {
  const TopicSegmentEvaluationResult({
    required this.state,
    this.evaluatedCount = 0,
    this.skippedLocked = 0,
    this.error,
  });

  final TopicSegmentationState state;
  final int evaluatedCount;
  final int skippedLocked;
  final Object? error;
}

class _TurnItem {
  const _TurnItem({
    required this.absStartMs,
    required this.absEndMs,
    required this.speaker,
    required this.text,
  });

  final int absStartMs;
  final int absEndMs;
  final String speaker;
  final String text;
}

class _SpeechUnit {
  const _SpeechUnit({
    required this.anchorId,
    required this.startAtMs,
    required this.endAtMs,
    required this.speechStartAtMs,
    required this.speechEndAtMs,
    required this.trailingSilenceMs,
    required this.turns,
  });

  final String anchorId;
  final int startAtMs;
  final int endAtMs;
  final int speechStartAtMs;
  final int speechEndAtMs;
  final int trailingSilenceMs;
  final List<_TurnItem> turns;
}

class _SpeechRun {
  const _SpeechRun({
    required this.runKey,
    required this.units,
    required this.turns,
    required this.startAtMs,
    required this.endAtMs,
    required this.speechEndAtMs,
  });

  final String runKey;
  final List<_SpeechUnit> units;
  final List<_TurnItem> turns;
  final int startAtMs;
  final int endAtMs;
  final int speechEndAtMs;
}

class FastTopicSegmentAgent {
  FastTopicSegmentAgent({
    required ChatCompletion chat,
    String model = '',
    String Function()? modelResolver,
    bool Function()? ready,
    this.speechMergeGap = const Duration(seconds: 30),
    this.blankThreshold = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _chat = chat,
       _model = model,
       _modelResolver = modelResolver,
       _ready = ready,
       _now = now ?? DateTime.now;

  final ChatCompletion _chat;
  final String _model;
  final String Function()? _modelResolver;
  final bool Function()? _ready;
  final Duration speechMergeGap;
  final Duration blankThreshold;
  final DateTime Function() _now;

  String get effectiveModel {
    final resolved = _modelResolver?.call().trim() ?? '';
    return resolved.isNotEmpty ? resolved : _model.trim();
  }

  bool get isReady => effectiveModel.isNotEmpty && (_ready?.call() ?? true);

  /// 提取全局连续说话簇（同一天内相邻语音间隔 `< speechMergeGap` 合并）。
  static String buildRunKey(
    String anchorSegmentId,
    int startAtMs,
    int endAtMs,
  ) => '$anchorSegmentId@$startAtMs..$endAtMs';

  /// 检查是否有连续说话簇在之后出现了 `>= blankThreshold`（默认 1 分钟）空白；
  /// 若有且未落入幂等水位锁，则调用快速云端模型做话题切片并持久化锁定。
  Future<TopicSegmentEvaluationResult> evaluateRuns(
    List<RecordingFile> files, {
    required TopicSegmentationStore store,
    bool sessionJustEnded = false,
    int? wallClockNowMs,
  }) async {
    var state = await store.load();
    if (!isReady || files.isEmpty) {
      return TopicSegmentEvaluationResult(state: state);
    }

    final timeline = _collectTimeline(files);
    if (timeline.speechUnits.isEmpty) {
      return TopicSegmentEvaluationResult(state: state);
    }

    final runs = _groupIntoRuns(timeline.speechUnits);
    var evaluated = 0;
    var skipped = 0;
    Object? lastError;

    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      if (run.turns.isEmpty) continue;

      final isLastRun = i == runs.length - 1;
      final hasBlankAfter = _hasBlankAfter(
        run: run,
        nextRun: isLastRun ? null : runs[i + 1],
        silentIntervals: timeline.silentIntervals,
        sessionJustEnded: isLastRun && sessionJustEnded,
        wallClockNowMs: wallClockNowMs,
      );
      if (!hasBlankAfter) continue;

      if (state.isLocked(run.runKey, run.endAtMs)) {
        skipped++;
        continue;
      }

      try {
        final sections = await _segmentByTopic(run);
        if (sections.isNotEmpty) {
          final evaluatedRun = TopicRunSegmentation(
            runKey: run.runKey,
            startAtMs: run.startAtMs,
            endAtMs: run.endAtMs,
            sections: sections,
            evaluatedAtMs: _now().millisecondsSinceEpoch,
          );
          state = await store.readModifyWrite(
            (latest) => latest.withRun(evaluatedRun),
          );
          evaluated++;
        }
      } catch (e) {
        lastError ??= e;
      }
    }

    return TopicSegmentEvaluationResult(
      state: state,
      evaluatedCount: evaluated,
      skippedLocked: skipped,
      error: lastError,
    );
  }

  ({
    List<_SpeechUnit> speechUnits,
    List<({int startAtMs, int endAtMs})> silentIntervals,
  })
  _collectTimeline(List<RecordingFile> files) {
    final sortedFiles = [...files]
      ..sort((a, b) => a.startAtMs.compareTo(b.startAtMs));
    final units = <_SpeechUnit>[];
    final silences = <({int startAtMs, int endAtMs})>[];

    for (final f in sortedFiles) {
      final closedSegs =
          f.segments.where((s) => s.status == SegmentStatus.closed).toList()
            ..sort((a, b) => a.startAtMs.compareTo(b.startAtMs));

      if (closedSegs.isEmpty) {
        final hasSpeech = f.turns.isNotEmpty || f.utterances.isNotEmpty;
        if (!hasSpeech) {
          final endAt = f.startAtMs + (f.durationMs > 0 ? f.durationMs : 0);
          if (endAt > f.startAtMs) {
            silences.add((startAtMs: f.startAtMs, endAtMs: endAt));
          }
        }
        continue;
      }

      final turnById = {for (final t in f.turns) t.id: t};
      for (final seg in closedSegs) {
        final segTurns = <_TurnItem>[];
        if (seg.turnIds.isNotEmpty) {
          for (final id in seg.turnIds) {
            final t = turnById[id];
            if (t == null) continue;
            segTurns.add(
              _TurnItem(
                absStartMs: f.startAtMs + t.startMs,
                absEndMs: f.startAtMs + t.endMs,
                speaker: t.speakerLabel,
                text: t.text,
              ),
            );
          }
        } else {
          for (final u in f.utterances) {
            segTurns.add(
              _TurnItem(
                absStartMs: f.startAtMs + u.startMs,
                absEndMs: f.startAtMs + u.endMs,
                speaker: u.speakerLabel ?? '未区分',
                text: u.text,
              ),
            );
          }
        }

        final endAtMs =
            seg.endAtMs ??
            (segTurns.isNotEmpty
                ? segTurns.last.absEndMs
                : f.startAtMs + f.durationMs);
        if (segTurns.isEmpty && seg.speakerCount == 0) {
          if (endAtMs > seg.startAtMs) {
            silences.add((startAtMs: seg.startAtMs, endAtMs: endAtMs));
          }
          continue;
        }
        final trailingSliceSil = f.slices.isNotEmpty
            ? f.slices.last.silenceAfterMs
            : 0;
        final speechStartAtMs = segTurns.isNotEmpty
            ? segTurns.first.absStartMs
            : seg.startAtMs;
        final speechEndAtMs = segTurns.isNotEmpty
            ? segTurns.last.absEndMs
            : endAtMs;
        units.add(
          _SpeechUnit(
            anchorId: seg.id,
            startAtMs: seg.startAtMs,
            endAtMs: endAtMs,
            speechStartAtMs: speechStartAtMs,
            speechEndAtMs: speechEndAtMs,
            trailingSilenceMs: trailingSliceSil,
            turns: segTurns,
          ),
        );
      }
    }

    units.sort((a, b) => a.startAtMs.compareTo(b.startAtMs));
    return (speechUnits: units, silentIntervals: silences);
  }

  List<_SpeechRun> _groupIntoRuns(List<_SpeechUnit> units) {
    final runs = <_SpeechRun>[];
    if (units.isEmpty) return runs;

    final gapLimit = speechMergeGap.inMilliseconds;
    var bucket = <_SpeechUnit>[units.first];

    void flushBucket() {
      final first = bucket.first;
      final last = bucket.last;
      final turns = <_TurnItem>[for (final u in bucket) ...u.turns]
        ..sort((a, b) => a.absStartMs.compareTo(b.absStartMs));
      runs.add(
        _SpeechRun(
          runKey: buildRunKey(first.anchorId, first.startAtMs, last.endAtMs),
          units: List.unmodifiable(bucket),
          turns: turns,
          startAtMs: first.startAtMs,
          endAtMs: last.endAtMs,
          speechEndAtMs: last.speechEndAtMs,
        ),
      );
    }

    for (var i = 1; i < units.length; i++) {
      final prev = bucket.last;
      final curr = units[i];
      final gapMs = curr.speechStartAtMs - prev.speechEndAtMs;
      final sameDay = _sameLocalDay(prev.startAtMs, curr.startAtMs);
      if (sameDay && gapMs >= -60 * 1000 && gapMs < gapLimit) {
        bucket.add(curr);
      } else {
        flushBucket();
        bucket = [curr];
      }
    }
    flushBucket();
    return runs;
  }

  bool _hasBlankAfter({
    required _SpeechRun run,
    required _SpeechRun? nextRun,
    required List<({int startAtMs, int endAtMs})> silentIntervals,
    required bool sessionJustEnded,
    required int? wallClockNowMs,
  }) {
    final thresholdMs = blankThreshold.inMilliseconds;
    if (sessionJustEnded) return true;
    if (run.units.last.trailingSilenceMs >= thresholdMs) return true;
    if (nextRun != null) {
      return nextRun.units.first.speechStartAtMs - run.speechEndAtMs >=
          thresholdMs;
    }
    var trailingSilentMs = 0;
    for (final s in silentIntervals) {
      if (s.endAtMs > run.speechEndAtMs) {
        final effectiveStart = s.startAtMs < run.speechEndAtMs
            ? run.speechEndAtMs
            : s.startAtMs;
        trailingSilentMs += s.endAtMs - effectiveStart;
      }
    }
    if (trailingSilentMs >= thresholdMs) return true;
    if (wallClockNowMs != null &&
        wallClockNowMs - run.speechEndAtMs >= thresholdMs) {
      return true;
    }
    return false;
  }

  Future<List<TopicSectionOverride>> _segmentByTopic(_SpeechRun run) async {
    final buf = StringBuffer();
    for (var i = 0; i < run.turns.length; i++) {
      final t = run.turns[i];
      final offsetSec = ((t.absStartMs - run.startAtMs) / 1000).round();
      buf.writeln('[$i +${offsetSec}s] ${t.speaker}: ${t.text}');
    }
    final raw = await _chat.complete(
      [
        const ChatMessage(
          role: 'system',
          content:
              '你是录音话题分段助手。给定一段按时间编号 [0..N-1] 的连续对话，'
              '按语义话题切分成 1 到多个连续不重叠的话题段。'
              '按内容或时间事件切段，不要按逐词逐句或原始短切片切碎。'
              '严格输出 JSON：{"sections":[{"title":"简短标题","brief":"一两句概述",'
              '"summary":"卡片摘要","startTurn":0,"endTurn":2,"tags":["关键词"]}]}。'
              'summary 可与 brief 相同；若只给 summary，将用作 brief。'
              '所有下标必须连续覆盖 0 到最后一条，不遗漏也不越界，不编造对话中不存在的事实。',
        ),
        ChatMessage(
          role: 'user',
          content: '对话条数：${run.turns.length}\n\n${buf.toString()}',
        ),
      ],
      model: effectiveModel,
      temperature: 0.1,
      maxTokens: 1024,
    );
    return _parseSections(raw, run.turns.length);
  }

  static List<TopicSectionOverride> _parseSections(String raw, int turnCount) {
    if (turnCount <= 0) return const [];
    final jsonText = _extractJsonObject(raw);
    if (jsonText == null) return const [];
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) return const [];
    final list = decoded['sections'];
    if (list is! List || list.isEmpty) return const [];

    final parsed = <TopicSectionOverride>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final copy = SectionCopy.fromModel(item);
      final title = copy.title;
      final brief = copy.brief;
      final s = ((item['startTurn'] as num?)?.toInt() ?? 0).clamp(
        0,
        turnCount - 1,
      );
      final e = ((item['endTurn'] as num?)?.toInt() ?? s).clamp(
        s,
        turnCount - 1,
      );
      final tags = [
        for (final tg in (item['tags'] as List? ?? const []))
          if ('$tg'.trim().isNotEmpty) '$tg'.trim(),
      ];
      parsed.add(
        TopicSectionOverride(
          title: title.isEmpty ? '话题 ${parsed.length + 1}' : title,
          brief: brief,
          overview: copy.overview,
          summary: copy.summary,
          startTurnIndex: s,
          endTurnIndex: e,
          tags: tags,
        ),
      );
    }
    if (parsed.isEmpty) return const [];
    parsed.sort((a, b) => a.startTurnIndex.compareTo(b.startTurnIndex));

    // 规范化为严格连续覆盖 [0 .. turnCount - 1]
    final normalized = <TopicSectionOverride>[];
    var cursor = 0;
    for (var i = 0; i < parsed.length; i++) {
      if (cursor >= turnCount) break;
      final cur = parsed[i];
      final start = cursor;
      final isLast = i == parsed.length - 1;
      var end = isLast ? turnCount - 1 : cur.endTurnIndex;
      if (end < start) end = start;
      if (end >= turnCount) end = turnCount - 1;
      normalized.add(
        TopicSectionOverride(
          title: cur.title,
          brief: cur.brief,
          overview: cur.overview,
          summary: cur.summary,
          startTurnIndex: start,
          endTurnIndex: end,
          tags: cur.tags,
          evidenceSliceIds: cur.evidenceSliceIds,
        ),
      );
      cursor = end + 1;
    }
    return normalized;
  }

  static String? _extractJsonObject(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return trimmed.substring(start, end + 1);
  }

  static bool _sameLocalDay(int aMs, int bMs) {
    final a = DateTime.fromMillisecondsSinceEpoch(aMs).toLocal();
    final b = DateTime.fromMillisecondsSinceEpoch(bMs).toLocal();
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
