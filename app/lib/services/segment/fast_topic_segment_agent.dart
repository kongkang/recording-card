/// 独立快速主题分段 Agent —— 连续发言片段遇 `≥ 1 分钟` 空白后，按语义话题逻辑切分，
/// 并持久化幂等水位锁（watermark + runKey），避免历史已切分片段重复触发云端推理。
///
/// 约束（AGENTS.md）：
/// - 本地转写文本已先按 `< 30s` 停顿在投影层无时长上限合并；
/// - 仅在网关可用且配置模型时上行纯文本做主题边界切分，绝不上传音频；
/// - 离线 / 未登录 / 模型失败时保留物理声学合并结果，不编造 AI 主题文本，也不锁死重试机会。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/models/recording.dart';
import '../analysis/chat_completion.dart';

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
    this.paragraphs = const [],
    this.cleanedByCloud = false,
    this.startAtMs = 0,
    this.endAtMs = 0,
  });

  final String title;
  final String brief;
  final int startTurnIndex;
  final int endTurnIndex;
  final List<String> tags;
  final String overview;
  final List<TopicParagraph> paragraphs;
  final bool cleanedByCloud;
  final int startAtMs;
  final int endAtMs;

  TopicSectionOverride copyWith({
    String? title,
    String? brief,
    int? startTurnIndex,
    int? endTurnIndex,
    List<String>? tags,
    String? overview,
    List<TopicParagraph>? paragraphs,
    bool? cleanedByCloud,
    int? startAtMs,
    int? endAtMs,
  }) => TopicSectionOverride(
    title: title ?? this.title,
    brief: brief ?? this.brief,
    startTurnIndex: startTurnIndex ?? this.startTurnIndex,
    endTurnIndex: endTurnIndex ?? this.endTurnIndex,
    tags: tags ?? this.tags,
    overview: overview ?? this.overview,
    paragraphs: paragraphs ?? this.paragraphs,
    cleanedByCloud: cleanedByCloud ?? this.cleanedByCloud,
    startAtMs: startAtMs ?? this.startAtMs,
    endAtMs: endAtMs ?? this.endAtMs,
  );

  Map<String, dynamic> toJson() => {
    't': title,
    'b': brief,
    's': startTurnIndex,
    'e': endTurnIndex,
    if (tags.isNotEmpty) 'tg': tags,
    if (overview.isNotEmpty) 'ov': overview,
    if (paragraphs.isNotEmpty) 'p': [for (final p in paragraphs) p.toJson()],
    if (cleanedByCloud) 'cl': true,
    if (startAtMs > 0) 'sa': startAtMs,
    if (endAtMs > 0) 'ea': endAtMs,
  };

  factory TopicSectionOverride.fromJson(Map<String, dynamic> j) =>
      TopicSectionOverride(
        title: '${j['t'] ?? ''}',
        brief: '${j['b'] ?? ''}',
        startTurnIndex: (j['s'] as num?)?.toInt() ?? 0,
        endTurnIndex: (j['e'] as num?)?.toInt() ?? 0,
        tags: [for (final t in (j['tg'] as List? ?? const [])) '$t'],
        overview: '${j['ov'] ?? ''}',
        paragraphs: [
          for (final p in (j['p'] as List? ?? const []))
            if (p is Map<String, dynamic>) TopicParagraph.fromJson(p),
        ],
        cleanedByCloud: j['cl'] == true,
        startAtMs: (j['sa'] as num?)?.toInt() ?? 0,
        endAtMs: (j['ea'] as num?)?.toInt() ?? 0,
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
  });

  const TopicSegmentationState.empty()
    : watermarkEndAtMs = 0,
      lockedRunKeys = const {},
      runsByKey = const {},
      rollingByAnchor = const {};

  /// 单调水位：endAtMs <= watermarkEndAtMs 的历史连续说话簇已结算锁定，不重跑。
  final int watermarkEndAtMs;
  final Set<String> lockedRunKeys;
  final Map<String, TopicRunSegmentation> runsByKey;

  /// 滚动语义+声纹联合清洗分段结果（key 为连续说话组 anchorSegmentId）。
  final Map<String, TopicRunSegmentation> rollingByAnchor;

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
    );
  }

  TopicSegmentationState withRollingRun(TopicRunSegmentation run) =>
      TopicSegmentationState(
        watermarkEndAtMs: watermarkEndAtMs,
        lockedRunKeys: lockedRunKeys,
        runsByKey: runsByKey,
        rollingByAnchor: {...rollingByAnchor, run.runKey: run},
      );

  TopicSegmentationState withoutRollingRuns() => TopicSegmentationState(
    watermarkEndAtMs: 0,
    lockedRunKeys: const {},
    runsByKey: const {},
    rollingByAnchor: const {},
  );

  Map<String, dynamic> toJson() => {
    'v': 2,
    'wm': watermarkEndAtMs,
    'lk': lockedRunKeys.toList(),
    'runs': {for (final e in runsByKey.entries) e.key: e.value.toJson()},
    if (rollingByAnchor.isNotEmpty)
      'rolling': {
        for (final e in rollingByAnchor.entries) e.key: e.value.toJson(),
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
    );
  }
}

/// 原子持久化 `_topic_segmentation.json`，存放在录音根目录，不被 `RecordingStore.loadAll` 当作录音目录。
class TopicSegmentationStore {
  TopicSegmentationStore({required Future<Directory> Function() resolveRoot})
    : _resolveRoot = resolveRoot;

  final Future<Directory> Function() _resolveRoot;
  TopicSegmentationState? _cache;

  Future<File> _file() async {
    final root = await _resolveRoot();
    if (!await root.exists()) await root.create(recursive: true);
    return File('${root.path}/_topic_segmentation.json');
  }

  Future<TopicSegmentationState> load({bool refresh = false}) async {
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

  Future<void> save(TopicSegmentationState state) async {
    _cache = state;
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> clear() async {
    _cache = const TopicSegmentationState.empty();
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
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
  static String buildRunKey(String anchorSegmentId, int startAtMs, int endAtMs) =>
      '$anchorSegmentId@$startAtMs..$endAtMs';

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
          state = state.withRun(
            TopicRunSegmentation(
              runKey: run.runKey,
              startAtMs: run.startAtMs,
              endAtMs: run.endAtMs,
              sections: sections,
              evaluatedAtMs: _now().millisecondsSinceEpoch,
            ),
          );
          await store.save(state);
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
      final closedSegs = f.segments
          .where((s) => s.status == SegmentStatus.closed)
          .toList()
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
              '严格输出 JSON：{"sections":[{"title":"简短标题","brief":"一两句概述",'
              '"startTurn":0,"endTurn":2,"tags":["关键词"]}]}。'
              '所有下标必须连续覆盖 0 到最后一条，不遗漏也不越界，不编造对话中不存在的事实。',
        ),
        ChatMessage(
          role: 'user',
          content:
              '对话条数：${run.turns.length}\n\n${buf.toString()}',
        ),
      ],
      model: effectiveModel,
      temperature: 0.1,
      maxTokens: 1024,
    );
    return _parseSections(raw, run.turns.length);
  }

  static List<TopicSectionOverride> _parseSections(
    String raw,
    int turnCount,
  ) {
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
      final title = '${item['title'] ?? ''}'.trim();
      final brief = '${item['brief'] ?? ''}'.trim();
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
          startTurnIndex: start,
          endTurnIndex: end,
          tags: cur.tags,
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
