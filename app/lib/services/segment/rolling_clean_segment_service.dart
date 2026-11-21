/// 滚动全量语意+声纹联合清洗与话题分段引擎。
///
/// 在端侧完成 VAD + ASR + 声纹聚类后，按可配置的清洗周期（`cleanCycleMinutes`）
/// 或 `>= 1 分钟` 停顿 / 停录节点，携带上一轮尾部重叠上下文（最后 N 段或最后 M 分钟
/// 已整理结果）与脱敏声纹相似度矩阵上行云端整理，产出：
/// - 高可读性的阶段标题（禁止 `实时切片 #N`）、一句话摘要与多句「阶段概述」；
/// - 基于语义 + 声纹合并后的同说话人连贯自然段（不再按短切片时间戳碎片化展示）；
/// - 自动修正明显受短句干扰导致声纹漂移/低置信度误标的说话人。
///
/// 隐私边界：仅上行文字与说话人簇标签、置信度及簇间标量余弦相似度，绝不上传原始声纹向量。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../core/models/recording.dart';
import '../../core/models/summary.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/voiceprint_library_store.dart';
import '../analysis/chat_completion.dart';
import '../recordings/segment_projection.dart';
import '../recordings/speaker_profile_store.dart';
import '../transcribe/utterance_builder.dart';
import 'fast_topic_segment_agent.dart';
import 'section_copy.dart';

class RollingCleanResult {
  const RollingCleanResult({
    required this.state,
    this.evaluatedRuns = 0,
    this.evaluatedBatches = 0,
    this.skippedRuns = 0,
    this.error,
  });

  final TopicSegmentationState state;
  final int evaluatedRuns;
  final int evaluatedBatches;
  final int skippedRuns;
  final Object? error;
}

class _TimedUnit {
  const _TimedUnit({
    required this.utterance,
    required this.file,
    required this.compositeId,
    required this.absStartMs,
    required this.absEndMs,
    required this.speaker,
  });

  final RawUtterance utterance;
  final RecordingFile file;
  final String compositeId;
  final int absStartMs;
  final int absEndMs;
  final String speaker;
}

class _ParsedRollingSection {
  const _ParsedRollingSection({
    required this.continuesPrevious,
    required this.mergesPreviousParagraph,
    required this.title,
    required this.brief,
    required this.overview,
    required this.tags,
    required this.paragraphs,
    this.summary = '',
    this.evidenceSliceIds = const [],
    this.lowValue = false,
  });

  final bool continuesPrevious;
  final bool mergesPreviousParagraph;
  final String title;
  final String brief;
  final String overview;
  final String summary;
  final List<String> tags;
  final List<_ParsedParagraph> paragraphs;
  final List<String> evidenceSliceIds;
  final bool lowValue;
}

class _ParsedParagraph {
  const _ParsedParagraph({
    required this.uStart,
    required this.uEnd,
    required this.speaker,
    required this.text,
  });

  final int uStart;
  final int uEnd;
  final String speaker;
  final String text;
}

class RollingCleanSegmentService {
  RollingCleanSegmentService({
    required ChatCompletion chat,
    String model = '',
    String Function()? modelResolver,
    bool Function()? ready,
    required Future<Directory> Function() resolveRoot,
    VoiceprintLibraryStore? voiceprintStore,
    AgentConfigStore? agentConfig,
    DateTime Function()? now,
  }) : _chat = chat,
       _model = model,
       _modelResolver = modelResolver,
       _ready = ready,
       _resolveRoot = resolveRoot,
       _voiceprintStore = voiceprintStore,
       _agentConfig = agentConfig,
       _now = now ?? DateTime.now;

  final ChatCompletion _chat;
  final String _model;
  final String Function()? _modelResolver;
  final bool Function()? _ready;
  final Future<Directory> Function() _resolveRoot;
  final VoiceprintLibraryStore? _voiceprintStore;
  final AgentConfigStore? _agentConfig;
  final DateTime Function() _now;

  static const int _maxUtterancesPerBatch = 120;
  static const int _silenceTriggerMs = 15 * 60 * 1000;

  String get effectiveModel {
    final resolved = _modelResolver?.call().trim() ?? '';
    return resolved.isNotEmpty ? resolved : _model.trim();
  }

  bool get isReady => effectiveModel.isNotEmpty && (_ready?.call() ?? true);

  /// 与短轮定时任务的间隔对齐。上限 7 天，避免开发者把间隔改长后被 180 分钟静默截断。
  int get _cycleMinutes =>
      (_agentConfig?.cleanCycleMinutes ?? 15).clamp(1, 10080);
  bool get _cleanOnSilenceGap => _agentConfig?.cleanOnSilenceGap ?? true;
  String get _overlapMode =>
      _agentConfig?.cleanOverlapMode == 'minutes' ? 'minutes' : 'paragraphs';
  int get _overlapParagraphs =>
      (_agentConfig?.cleanOverlapParagraphs ?? 3).clamp(0, 10);
  int get _overlapMinutes =>
      (_agentConfig?.cleanOverlapMinutes ?? 3).clamp(1, 30);

  /// 快速检查是否存在已到达清洗周期或静音停顿门槛的未整理语料。
  bool hasReadyTrigger(
    List<RecordingFile> files,
    TopicSegmentationState state, {
    int? wallClockNowMs,
  }) {
    if (!isReady || files.isEmpty) return false;
    final rawGroups = SegmentProjection.collectActivityGroups(files);
    if (rawGroups.isEmpty) return false;
    final validGroups = <({ProjectedSpeechGroup group, List<_TimedUnit> units})>[
      for (final g in rawGroups)
        () {
          final u = _extractUnits(g);
          return (group: g, units: u);
        }(),
    ].where((e) => e.units.isNotEmpty).toList();
    if (validGroups.isEmpty) return false;
    final nowMs = wallClockNowMs ?? _now().millisecondsSinceEpoch;
    for (var i = 0; i < validGroups.length; i++) {
      final entry = validGroups[i];
      final units = entry.units;
      final existing = state.rollingByAnchor[entry.group.anchorSegmentId];
      final uncovered = _uncoveredUnits(units, existing);
      if (uncovered.isEmpty) continue;
      final isLastGroup = i == validGroups.length - 1;
      final hasLaterGroup =
          !isLastGroup &&
          (validGroups[i + 1].units.first.absStartMs - units.last.absEndMs) >=
              _silenceTriggerMs;
      if (_shouldProcessGroup(
        groupUnits: units,
        uncovered: uncovered,
        isLastGroup: isLastGroup,
        hasLaterGroup: hasLaterGroup,
        forceRecleanAll: false,
        sessionJustEnded: false,
        nowMs: nowMs,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<RollingCleanResult> run(
    List<RecordingFile> files, {
    required TopicSegmentationStore topicStore,
    bool forceRecleanAll = false,
    bool sessionJustEnded = false,
    int? wallClockNowMs,
    void Function(String status)? onProgress,
  }) async {
    var state = forceRecleanAll
        ? await topicStore.readModifyWrite(
            (current) => current.withoutRollingRuns(),
          )
        : await topicStore.load();
    if (!isReady || files.isEmpty) {
      return RollingCleanResult(state: state);
    }

    final rawGroups = SegmentProjection.collectActivityGroups(files);
    if (rawGroups.isEmpty) {
      return RollingCleanResult(state: state);
    }
    final validGroups = <({ProjectedSpeechGroup group, List<_TimedUnit> units})>[
      for (final g in rawGroups)
        () {
          final u = _extractUnits(g);
          return (group: g, units: u);
        }(),
    ].where((e) => e.units.isNotEmpty).toList();
    if (validGroups.isEmpty) {
      return RollingCleanResult(state: state);
    }

    final nowMs = wallClockNowMs ?? _now().millisecondsSinceEpoch;
    var evaluatedRuns = 0;
    var evaluatedBatches = 0;
    var skippedRuns = 0;
    Object? lastError;

    for (var i = 0; i < validGroups.length; i++) {
      final group = validGroups[i].group;
      final units = validGroups[i].units;

      final existingRun = forceRecleanAll
          ? null
          : state.rollingByAnchor[group.anchorSegmentId];
      final uncovered = _uncoveredUnits(units, existingRun);
      if (uncovered.isEmpty) {
        skippedRuns++;
        continue;
      }

      final isLastGroup = i == validGroups.length - 1;
      final hasLaterGroup =
          !isLastGroup &&
          (validGroups[i + 1].units.first.absStartMs - units.last.absEndMs) >=
              _silenceTriggerMs;
      if (!_shouldProcessGroup(
        groupUnits: units,
        uncovered: uncovered,
        isLastGroup: isLastGroup,
        hasLaterGroup: hasLaterGroup,
        forceRecleanAll: forceRecleanAll,
        sessionJustEnded: sessionJustEnded,
        nowMs: nowMs,
      )) {
        skippedRuns++;
        continue;
      }

      final sessionId = _primarySessionOf(group);
      final speakerContext = await _buildVoiceprintContext(sessionId, units);
      final accumulatedSections = <TopicSectionOverride>[
        ...?existingRun?.sections,
      ];
      final coveredIds = <String>{...?existingRun?.coveredUtteranceIds};
      var coveredEndMs = existingRun?.coveredUtteranceEndMs ?? 0;

      final batches = _splitIntoCycleBatches(uncovered);
      var groupEvaluatedBatches = 0;
      for (var bi = 0; bi < batches.length; bi++) {
        final batch = batches[bi];
        onProgress?.call(
          '正在结合语义与声纹清洗整理（第 ${evaluatedRuns + 1} 组 · ${bi + 1}/${batches.length}）',
        );
        try {
          final result = await _processBatch(
            batch: batch,
            accumulatedSections: accumulatedSections,
            speakerContext: speakerContext,
          );
          _mergeBatchSections(accumulatedSections, result, batch);
          for (final u in batch) {
            coveredIds.add(u.compositeId);
            if (u.absEndMs > coveredEndMs) coveredEndMs = u.absEndMs;
          }
          groupEvaluatedBatches++;
          evaluatedBatches++;
        } on Object catch (e) {
          lastError ??= e;
          break;
        }
      }

      if (groupEvaluatedBatches > 0 && accumulatedSections.isNotEmpty) {
        final updatedRun = TopicRunSegmentation(
          runKey: group.anchorSegmentId,
          startAtMs: group.startAtMs,
          endAtMs: group.endAtMs,
          sections: accumulatedSections,
          evaluatedAtMs: nowMs,
          coveredUtteranceEndMs: coveredEndMs,
          coveredUtteranceIds: coveredIds,
        );
        state = await topicStore.readModifyWrite(
          (latest) => latest.withRollingRun(updatedRun).withOrganizerVersion(2),
        );
        evaluatedRuns++;
      }
    }

    if (evaluatedRuns > 0 || (forceRecleanAll && lastError == null)) {
      if (state.organizerVersion < 2) {
        state = state.withOrganizerVersion(2);
        await topicStore.save(state);
      }
    }

    return RollingCleanResult(
      state: state,
      evaluatedRuns: evaluatedRuns,
      evaluatedBatches: evaluatedBatches,
      skippedRuns: skippedRuns,
      error: lastError,
    );
  }

  bool _shouldProcessGroup({
    required List<_TimedUnit> groupUnits,
    required List<_TimedUnit> uncovered,
    required bool isLastGroup,
    required bool hasLaterGroup,
    required bool forceRecleanAll,
    required bool sessionJustEnded,
    required int nowMs,
  }) {
    if (forceRecleanAll || sessionJustEnded) return true;
    final cycleMs = _cycleMinutes * 60 * 1000;
    final spanMs = uncovered.last.absEndMs - uncovered.first.absStartMs;
    if (spanMs >= cycleMs) return true;
    if (_cleanOnSilenceGap) {
      if (hasLaterGroup) return true;
      // 仅对最后一组在途语音检查距今静默时间；已闭合且后继停顿仅 30s..59s 的历史组
      // 严格维持纯声学分段，不误调云端模型。
      if (isLastGroup) {
        final elapsedSinceLastSpeech = nowMs - groupUnits.last.absEndMs;
        if (elapsedSinceLastSpeech >= _silenceTriggerMs) return true;
      }
    }
    return false;
  }

  List<_TimedUnit> _extractUnits(ProjectedSpeechGroup group) {
    final anchorStartMs = group.views.first.file.startAtMs;
    final units = <_TimedUnit>[];
    final seenComposite = <String>{};
    for (final view in group.views) {
      final file = view.file;
      for (final u in view.utterances) {
        if (!isMeaningfulSpeechText(u.text)) continue;
        final cid = '${file.id}::${u.id}';
        if (!seenComposite.add(cid)) continue;
        final absStart = file.startAtMs + u.startMs;
        final minEnd = u.startMs + 200;
        final absEnd = file.startAtMs + (u.endMs > minEnd ? u.endMs : minEnd);
        final spk = (u.speakerLabel ?? '').trim().isEmpty
            ? '未区分'
            : u.speakerLabel!.trim();
        units.add(
          _TimedUnit(
            utterance: u,
            file: file,
            compositeId: cid,
            absStartMs: absStart >= anchorStartMs ? absStart : anchorStartMs,
            absEndMs: absEnd,
            speaker: spk,
          ),
        );
      }
    }
    units.sort((a, b) => a.absStartMs.compareTo(b.absStartMs));
    return units;
  }

  List<_TimedUnit> _uncoveredUnits(
    List<_TimedUnit> allUnits,
    TopicRunSegmentation? existingRun,
  ) {
    if (existingRun == null || existingRun.sections.isEmpty) {
      return allUnits;
    }
    final coveredIds = existingRun.coveredUtteranceIds;
    final coveredEnd = existingRun.coveredUtteranceEndMs;
    return [
      for (final u in allUnits)
        if (!coveredIds.contains(u.compositeId) && u.absEndMs > coveredEnd) u,
    ];
  }

  List<List<_TimedUnit>> _splitIntoCycleBatches(List<_TimedUnit> units) {
    if (units.isEmpty) return const [];
    final cycleMs = _cycleMinutes * 60 * 1000;
    final batches = <List<_TimedUnit>>[];
    var current = <_TimedUnit>[];
    var batchStartMs = units.first.absStartMs;

    for (final u in units) {
      final exceedsTime =
          current.isNotEmpty &&
          ((u.absStartMs - batchStartMs) >= cycleMs ||
              (u.absEndMs - batchStartMs) >= cycleMs * 2);
      final exceedsCount = current.length >= _maxUtterancesPerBatch;
      if (exceedsTime || exceedsCount) {
        batches.add(current);
        current = <_TimedUnit>[];
        batchStartMs = u.absStartMs;
      }
      current.add(u);
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  String _primarySessionOf(ProjectedSpeechGroup group) {
    for (final v in group.views) {
      if (v.file.session.trim().isNotEmpty) return v.file.session.trim();
    }
    return group.views.first.file.id;
  }

  Future<Map<String, Object?>> _buildVoiceprintContext(
    String sessionId,
    List<_TimedUnit> units,
  ) async {
    final labels = <String>{for (final u in units) u.speaker}.toList()..sort();
    final pairwiseSimilarities = <Map<String, Object?>>[];
    final weakHints = <Map<String, String>>[];

    try {
      final root = await _resolveRoot();
      final profileSet = await SpeakerProfileStore(root: root).load(sessionId);
      final profiles = profileSet.profiles;
      for (var i = 0; i < profiles.length; i++) {
        for (var j = i + 1; j < profiles.length; j++) {
          final a = profiles[i];
          final b = profiles[j];
          final sim = VoiceprintLibraryStore.cosineSimilarity(
            a.centroid,
            b.centroid,
          );
          if (sim >= 0.40) {
            pairwiseSimilarities.add({
              'clusterA': '说话人 ${a.index + 1}',
              'clusterB': '说话人 ${b.index + 1}',
              'cosineSimilarity': double.parse(sim.toStringAsFixed(2)),
            });
          }
        }
      }
    } on Object {
      // 声纹表读取失败不阻塞滚动清洗，降级仅用文本说话人标签与置信度。
    }

    final vp = _voiceprintStore;
    if (vp != null) {
      for (final slot in labels) {
        final hint = vp.fuzzyHintFor(session: sessionId, speakerSlot: slot);
        if (hint != null && hint.trim().isNotEmpty) {
          weakHints.add({'slot': slot, 'candidateName': hint.trim()});
        }
      }
    }

    return {
      'observed_speakers': labels,
      if (pairwiseSimilarities.isNotEmpty)
        'cluster_similarities': pairwiseSimilarities,
      if (weakHints.isNotEmpty) 'voiceprint_weak_hints': weakHints,
    };
  }

  Future<List<_ParsedRollingSection>> _processBatch({
    required List<_TimedUnit> batch,
    required List<TopicSectionOverride> accumulatedSections,
    required Map<String, Object?> speakerContext,
  }) async {
    final payload = <String, Object?>{
      'speaker_voiceprint_context': speakerContext,
      'previous_organized_context': _buildOverlapContext(
        accumulatedSections,
        batchStartMs: batch.first.absStartMs,
      ),
      'utterances': [
        for (var i = 0; i < batch.length; i++)
          {
            'u': i,
            'id': batch[i].utterance.id,
            'sliceId': batch[i].utterance.sliceId,
            'offsetSec': ((batch[i].absStartMs - batch.first.absStartMs) / 1000)
                .round(),
            'gapSincePrevSec': i == 0
                ? 0
                : ((batch[i].absStartMs - batch[i - 1].absEndMs) / 1000)
                      .round()
                      .clamp(0, 86400),
            'durSec':
                ((batch[i].absEndMs - batch[i].absStartMs) / 1000)
                    .clamp(0.2, 3600)
                    .toStringAsFixed(1),
            'speaker': batch[i].speaker,
            'spkConf': double.parse(
              (batch[i].utterance.spkConfidence ?? 0.0).toStringAsFixed(2),
            ),
            'text': batch[i].utterance.text.trim(),
            if ((batch[i].utterance.emotion ?? '').trim().isNotEmpty)
              'emotion': batch[i].utterance.emotion!.trim(),
          },
      ],
    };

    final modelToUse = effectiveModel;
    final temperature = (_agentConfig?.temperature ?? 0.2).clamp(0.0, 1.0);
    final raw = await _chat.complete(
      [
        ChatMessage(role: 'system', content: _buildSystemPrompt()),
        ChatMessage(role: 'user', content: jsonEncode(payload)),
      ],
      model: modelToUse,
      temperature: temperature,
      maxTokens: 3200,
    );

    final parsed = _parseResponse(raw, batch);
    return _normalizeAndFillCoverage(parsed, batch);
  }

  Map<String, Object?> _buildOverlapContext(
    List<TopicSectionOverride> accumulated, {
    required int batchStartMs,
  }) {
    if (accumulated.isEmpty) {
      return const {'hasPrevious': false};
    }
    final lastSec = accumulated.last;
    final allParagraphs = <TopicParagraph>[
      for (final s in accumulated) ...s.paragraphs,
    ];
    final tailParagraphs = <TopicParagraph>[];
    if (_overlapMode == 'minutes') {
      final cutoff = batchStartMs - _overlapMinutes * 60 * 1000;
      for (final p in allParagraphs) {
        if (p.endAtMs >= cutoff) tailParagraphs.add(p);
      }
      if (tailParagraphs.isEmpty && allParagraphs.isNotEmpty) {
        tailParagraphs.add(allParagraphs.last);
      }
    } else if (_overlapParagraphs > 0 && allParagraphs.isNotEmpty) {
      final skip = math.max(0, allParagraphs.length - _overlapParagraphs);
      tailParagraphs.addAll(allParagraphs.skip(skip));
    }

    return {
      'hasPrevious': true,
      'previousSection': {
        'title': lastSec.title,
        'brief': lastSec.brief,
        'overview': lastSec.overview,
        'summary': lastSec.summary.isNotEmpty ? lastSec.summary : lastSec.brief,
      },
      'overlapMode': _overlapMode,
      'tailParagraphs': [
        for (final p in tailParagraphs)
          {'speaker': p.speaker, 'text': p.text},
      ],
    };
  }

  String _buildSystemPrompt() {
    final customStyle = _agentConfig?.promptFor('polish').trim() ?? '';
    final skills = _agentConfig?.enabledSkillRules ?? const <String>[];
    final buf = StringBuffer()
      ..writeln(
        '你是录音语义清洗与主题整理专家。输入是一段连续语音识别原文列表 utterances（按时间顺序编号 u=0..N-1），'
        '以及上一轮已整理尾部上下文 previous_organized_context 和声纹聚类辅助信息 speaker_voiceprint_context。',
      )
      ..writeln()
      ..writeln('核心任务：')
      ..writeln(
        '1. **无内容和短内容不要成卡**：没有识别出语音、只有标点，或去掉「嗯啊呃哎哦」后不足 5 个字且没有独立事实的片段，不要输出 section。'
        '能并进前后相邻、已经有完整内容的话题就并进去，只保留新增事实；并不进去就整段省略。'
        '禁止用「未识别到语音」「现在」「哎」「好」「我」这类碎片当标题或单独卡片。',
      )
      ..writeln(
        '2. **语义 + 声纹联合说话人分析**：结合 `speaker`、置信度 `spkConf`、`cluster_similarities`（簇间声纹相似度）以及上下文语义连贯性判断。'
        '当某句标签为「未区分」或 `spkConf < 0.65`、或簇间相似度较高而该句语义明显属于同一人接续表达（或明确一问一答轮换）时，请主动纠正为最合理的说话人标签；无法确定则保留「未区分」，严禁凭空捏造陌生人名。',
      )
      ..writeln(
        '3. **按说话人与语义合并成完整自然段**：同一说话人连续发表的完整意思必须合并润色为通顺的书面/口语自然段（`paragraphs`），去掉「嗯啊呃」口水词与卡顿重复，修正明显同音错字，不要按短切片时间戳切碎。',
      )
      ..writeln(
        '4. **沉浸式大时段活动归拢（严禁按 1~2 分钟切碎）**：识别用户持续专注的生活/工作/学习状态'
        '（例如长时间开发写代码、写提示词、开会、系统调研）。即使中间有数分钟敲代码静默（`gapSincePrevSec` 较大），'
        '或中间短暂分心 1~2 分钟（刷个短视频、随口自言自语），只要前后仍处同一活动/工作主线，必须合并归拢为同一张沉浸记录卡'
        '（跨批通过 `continuesPrevious=true` 续接并更新标题与阶段概述），完整交代这段时间开发或聊了什么，绝不能切成一两分钟的碎片卡！'
        '只有明显切换为完全不同的独立事件或大时段休息后，才另起新卡。每个话题必须具备：\n'
        '   - `title`: 6-20字准确有信息量的标题（严禁使用"实时切片 #1"等编号标题，严禁生成“我”“嗯”等单字标题）；\n'
        '   - `summary`: 2-3句生活化卡片摘要，只写和这件事有关的内容；\n'
        '   - `brief`: 1-2句干练摘要，可与 summary 相同；若只返回 summary，将同时用作 brief；\n'
        '   - `overview`: 2-4句完整「阶段概述」，交代背景、核心讨论/工作内容与结论；若只返回 summary，将同时用作 overview；\n'
        '   - `lowValue`: 仅当该独立片段只有 1~2 句且完全没有实质信息价值（例如“我正在说话”、试麦测试、单字、纯口水/寒暄“喂/嗯/好/我看看”）时设为 true，供时间轴折叠收纳；正常专注工作/讨论一律为 false；\n'
        '   - `continuesPrevious`: 若本批开头话题紧接 `previousSection` 为同一持续活动/话题的延续则为 true（可提供更新后的完整 title/summary/brief/overview），新话题则为 false；\n'
        '   - `mergesPreviousParagraph`: 仅当 `continuesPrevious=true` 且首段与 `tailParagraphs` 末段实为同一人同一句话被打断续说时为 true（只输出新增续接内容，勿重复上文）；\n'
        '   - `paragraphs`: 每项 `{"uStart":起始u,"uEnd":结束u,"speaker":"说话人标签","text":"合并润色后的整段文本"}`。同一人连续完整意思合并为自然段，不要因分片边界拆开。',
      )
      ..writeln(
        '5. **情绪仅供理解**：输入里的 `emotion`、说话人置信度与声纹上下文只帮助你理解语气和说话人，'
        '禁止把情绪标签、模型名、切片编号、「已合并 N 段」、「（推测）」等工程标记写进 title / summary / brief / overview / paragraphs。',
      )
      ..writeln(
        '6. **忠实不编造**：严格忠于输入事实，只输出合法 JSON：'
        '{"sections":[{"continuesPrevious":false,"mergesPreviousParagraph":false,"lowValue":false,"title":"...","summary":"...","brief":"...","overview":"...","tags":["关键词"],"paragraphs":[{"uStart":0,"uEnd":2,"speaker":"说话人 1","text":"..."}]}]}。'
        '不要输出 Markdown 代码块之外的多余说明。',
      );
    if (customStyle.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('用户风格偏好：$customStyle');
    }
    if (skills.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('启用规则：${skills.join('；')}');
    }
    return buf.toString();
  }

  List<_ParsedRollingSection> _parseResponse(
    String raw,
    List<_TimedUnit> batch,
  ) {
    final jsonText = _extractJsonObject(raw);
    if (jsonText == null) return const [];
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) return const [];
    final rawSections = decoded['sections'];
    if (rawSections is! List) return const [];

    final count = batch.length;
    final parsed = <_ParsedRollingSection>[];
    for (final s in rawSections) {
      if (s is! Map<String, dynamic>) continue;
      final copy = SectionCopy.fromModel(s);
      final title = copy.title;
      final brief = copy.brief;
      final overview = copy.overview;
      final summary = copy.summary;
      final continuesPrev = s['continuesPrevious'] == true;
      final mergesPrevPara = continuesPrev && s['mergesPreviousParagraph'] == true;
      final tags = <String>[
        for (final t in (s['tags'] as List? ?? const []))
          if ('$t'.trim().isNotEmpty) '$t'.trim(),
      ];
      final rawParas = s['paragraphs'] as List? ?? const [];
      final paras = <_ParsedParagraph>[];
      for (final p in rawParas) {
        if (p is! Map<String, dynamic>) continue;
        final text = '${p['text'] ?? ''}'.trim();
        if (!isMeaningfulSpeechText(text)) continue;
        final uStart = ((p['uStart'] as num?)?.toInt() ?? 0).clamp(0, count - 1);
        final uEnd = ((p['uEnd'] as num?)?.toInt() ?? uStart).clamp(
          uStart,
          count - 1,
        );
        final rawLen = batch
            .sublist(uStart, uEnd + 1)
            .map((u) => u.utterance.text.trim().length)
            .fold<int>(0, (a, b) => a + b);
        if (text.length > (rawLen * 2.5 + 80)) {
          // 防模型幻觉大幅扩写：退回确定性口语整理拼接，不丢原句也不扩写
          final safeText = _joinUnitsClean(batch.sublist(uStart, uEnd + 1));
          if (!isMeaningfulSpeechText(safeText)) continue;
          paras.add(
            _ParsedParagraph(
              uStart: uStart,
              uEnd: uEnd,
              speaker: _resolveSpeaker(
                '${p['speaker'] ?? ''}',
                batch.sublist(uStart, uEnd + 1),
              ),
              text: safeText,
            ),
          );
          continue;
        }
        paras.add(
          _ParsedParagraph(
            uStart: uStart,
            uEnd: uEnd,
            speaker: _resolveSpeaker(
              '${p['speaker'] ?? ''}',
              batch.sublist(uStart, uEnd + 1),
            ),
            text: text,
          ),
        );
      }
      if (paras.isEmpty) continue;
      final evIds = SectionCopy.evidenceSliceIds(
        s,
        fallback: [
          for (final p in paras)
            for (var k = p.uStart; k <= p.uEnd && k < batch.length; k++)
              if (batch[k].utterance.sliceId.trim().isNotEmpty)
                batch[k].utterance.sliceId,
        ],
      );
      parsed.add(
        _ParsedRollingSection(
          continuesPrevious: continuesPrev,
          mergesPreviousParagraph: mergesPrevPara,
          title: title,
          brief: brief,
          overview: overview,
          summary: summary,
          tags: tags,
          paragraphs: paras,
          evidenceSliceIds: evIds,
          lowValue: s['lowValue'] == true,
        ),
      );
    }
    return parsed;
  }

  /// 确保 `[0 .. batch.length - 1]` 全部原始句都有落脚点，无遗漏也无越界。
  List<_ParsedRollingSection> _normalizeAndFillCoverage(
    List<_ParsedRollingSection> parsed,
    List<_TimedUnit> batch,
  ) {
    if (parsed.isEmpty) {
      return [_localFallbackSection(batch, 0, batch.length - 1)];
    }

    final covered = List<bool>.filled(batch.length, false);
    for (final sec in parsed) {
      for (final p in sec.paragraphs) {
        for (var i = p.uStart; i <= p.uEnd; i++) {
          covered[i] = true;
        }
      }
    }

    final normalized = [...parsed];
    // 检查遗漏区间并在本地合并补齐
    var i = 0;
    while (i < batch.length) {
      if (covered[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < batch.length && !covered[j + 1]) {
        j++;
      }
      final fallbackParas = _buildLocalParagraphs(batch, i, j);
      if (fallbackParas.isNotEmpty) {
        if (i == 0 && normalized.isNotEmpty) {
          final first = normalized.first;
          normalized[0] = _ParsedRollingSection(
            continuesPrevious: first.continuesPrevious,
            mergesPreviousParagraph: false,
            title: first.title,
            brief: first.brief,
            overview: first.overview,
            summary: first.summary,
            tags: first.tags,
            paragraphs: [...fallbackParas, ...first.paragraphs],
            evidenceSliceIds: first.evidenceSliceIds,
            lowValue: first.lowValue,
          );
        } else {
          final last = normalized.last;
          normalized[normalized.length - 1] = _ParsedRollingSection(
            continuesPrevious: last.continuesPrevious,
            mergesPreviousParagraph: last.mergesPreviousParagraph,
            title: last.title,
            brief: last.brief,
            overview: last.overview,
            summary: last.summary,
            tags: last.tags,
            paragraphs: [...last.paragraphs, ...fallbackParas],
            evidenceSliceIds: last.evidenceSliceIds,
            lowValue: last.lowValue,
          );
        }
      }
      i = j + 1;
    }

    // 二次合并同一 section 内连续相同说话人的相邻段落
    return [
      for (var sIdx = 0; sIdx < normalized.length; sIdx++)
        _compactSection(normalized[sIdx], batch, isFirstBatchSection: sIdx == 0),
    ];
  }

  _ParsedRollingSection _compactSection(
    _ParsedRollingSection sec,
    List<_TimedUnit> batch, {
    required bool isFirstBatchSection,
  }) {
    final merged = <_ParsedParagraph>[];
    for (final p in sec.paragraphs) {
      if (merged.isNotEmpty && merged.last.speaker == p.speaker) {
        final prev = merged.last;
        final gapMs = batch[p.uStart].absStartMs - batch[prev.uEnd].absEndMs;
        if (gapMs < 30 * 1000) {
          merged[merged.length - 1] = _ParsedParagraph(
            uStart: math.min(prev.uStart, p.uStart),
            uEnd: math.max(prev.uEnd, p.uEnd),
            speaker: prev.speaker,
            text: joinPolishedUtterances(prev.text, p.text),
          );
          continue;
        }
      }
      merged.add(p);
    }
    final seedText = merged.map((p) => p.text).join(' ');
    final safeTitle = isMeaningfulSpeechText(sec.title)
        ? sec.title.trim()
        : buildReadableFallbackTitle(seedText, fallback: '阶段整理');
    final safeBrief = isMeaningfulSpeechText(sec.brief)
        ? sec.brief.trim()
        : (isMeaningfulSpeechText(sec.summary) ? sec.summary.trim() : _truncate(seedText, 68));
    final safeOverview = isMeaningfulSpeechText(sec.overview)
        ? sec.overview.trim()
        : safeBrief;
    final safeSummary = isMeaningfulSpeechText(sec.summary)
        ? sec.summary.trim()
        : safeBrief;
    return _ParsedRollingSection(
      continuesPrevious: isFirstBatchSection && sec.continuesPrevious,
      mergesPreviousParagraph: isFirstBatchSection && sec.mergesPreviousParagraph,
      title: safeTitle,
      brief: safeBrief,
      overview: safeOverview,
      summary: safeSummary,
      tags: sec.tags,
      paragraphs: merged,
      evidenceSliceIds: sec.evidenceSliceIds,
      lowValue: sec.lowValue,
    );
  }

  void _mergeBatchSections(
    List<TopicSectionOverride> accumulated,
    List<_ParsedRollingSection> incoming,
    List<_TimedUnit> batch,
  ) {
    for (final sec in incoming) {
      final topicParagraphs = <TopicParagraph>[
        for (final p in sec.paragraphs)
          TopicParagraph(
            speaker: p.speaker,
            text: p.text,
            startAtMs: batch[p.uStart].absStartMs,
            endAtMs: batch[p.uEnd].absEndMs,
            srcUtteranceIds: [
              for (var k = p.uStart; k <= p.uEnd; k++) batch[k].compositeId,
            ],
          ),
      ];
      if (topicParagraphs.isEmpty) continue;

      final secStart = topicParagraphs.first.startAtMs;
      final secEnd = topicParagraphs.last.endAtMs;

      if (accumulated.isNotEmpty && sec.continuesPrevious) {
        final prev = accumulated.last;
        final mergedParas = [...prev.paragraphs];
        var startIdx = 0;
        final canJoinTail = mergedParas.isNotEmpty &&
            (sec.mergesPreviousParagraph ||
                (mergedParas.last.speaker == topicParagraphs.first.speaker &&
                    (topicParagraphs.first.startAtMs - mergedParas.last.endAtMs) <
                        30 * 1000));
        if (canJoinTail) {
          final tail = mergedParas.last;
          final head = topicParagraphs.first;
          mergedParas[mergedParas.length - 1] = TopicParagraph(
            speaker: tail.speaker == '未区分' ? head.speaker : tail.speaker,
            text: _dedupAndJoin(tail.text, head.text),
            startAtMs: tail.startAtMs,
            endAtMs: math.max(tail.endAtMs, head.endAtMs),
            srcUtteranceIds: {
              ...tail.srcUtteranceIds,
              ...head.srcUtteranceIds,
            }.toList(),
          );
          startIdx = 1;
        }
        mergedParas.addAll(topicParagraphs.skip(startIdx));
        accumulated[accumulated.length - 1] = prev.copyWith(
          title: sec.title.isNotEmpty ? sec.title : prev.title,
          brief: sec.brief.isNotEmpty ? sec.brief : prev.brief,
          overview: sec.overview.isNotEmpty ? sec.overview : prev.overview,
          summary: sec.summary.isNotEmpty
              ? sec.summary
              : (sec.brief.isNotEmpty ? sec.brief : prev.summary),
          tags: {...prev.tags, ...sec.tags}.toList(),
          paragraphs: mergedParas,
          cleanedByCloud: true,
          endAtMs: math.max(prev.endAtMs, secEnd),
          endTurnIndex: mergedParas.length - 1,
          evidenceSliceIds: {
            ...prev.evidenceSliceIds,
            ...sec.evidenceSliceIds,
          }.toList(),
          lowValue: prev.lowValue && sec.lowValue,
        );
      } else {
        accumulated.add(
          TopicSectionOverride(
            title: sec.title,
            brief: sec.brief,
            overview: sec.overview,
            summary: sec.summary.isNotEmpty ? sec.summary : sec.brief,
            startTurnIndex: 0,
            endTurnIndex: topicParagraphs.length - 1,
            tags: sec.tags,
            paragraphs: topicParagraphs,
            cleanedByCloud: true,
            startAtMs: secStart,
            endAtMs: secEnd,
            evidenceSliceIds: sec.evidenceSliceIds,
            lowValue: sec.lowValue,
          ),
        );
      }
    }
  }

  static String _dedupAndJoin(String prev, String next) {
    final p = prev.trim();
    final n = next.trim();
    if (p.isEmpty) return n;
    if (n.isEmpty) return p;
    if (p.endsWith(n) || p.contains(n)) return p;
    if (n.startsWith(p)) return n;
    return joinPolishedUtterances(p, n);
  }

  String _resolveSpeaker(String candidate, List<_TimedUnit> span) {
    final trimmed = candidate.trim();
    if (trimmed.isNotEmpty && trimmed != 'null') return trimmed;
    for (final u in span) {
      if (u.speaker != '未区分' && u.speaker.isNotEmpty) return u.speaker;
    }
    return '未区分';
  }

  String _joinUnitsClean(List<_TimedUnit> span) {
    var acc = '';
    for (final u in span) {
      final clean = cleanSpokenFillers(u.utterance.text);
      if (clean.isEmpty || !isMeaningfulSpeechText(clean)) continue;
      acc = acc.isEmpty ? clean : joinPolishedUtterances(acc, clean);
    }
    return acc;
  }

  _ParsedRollingSection _localFallbackSection(
    List<_TimedUnit> batch,
    int startIdx,
    int endIdx,
  ) {
    final paras = _buildLocalParagraphs(batch, startIdx, endIdx);
    final seed = paras.map((p) => p.text).join(' ');
    return _ParsedRollingSection(
      continuesPrevious: false,
      mergesPreviousParagraph: false,
      title: buildReadableFallbackTitle(seed, fallback: '录音整理'),
      brief: _truncate(seed, 68),
      overview: _truncate(seed, 120),
      summary: _truncate(seed, 68),
      tags: const [],
      paragraphs: paras,
    );
  }

  List<_ParsedParagraph> _buildLocalParagraphs(
    List<_TimedUnit> batch,
    int startIdx,
    int endIdx,
  ) {
    final paras = <_ParsedParagraph>[];
    for (var i = startIdx; i <= endIdx; i++) {
      final u = batch[i];
      final clean = cleanSpokenFillers(u.utterance.text);
      if (clean.isEmpty || !isMeaningfulSpeechText(clean)) continue;
      if (paras.isNotEmpty &&
          paras.last.speaker == u.speaker &&
          (u.absStartMs - batch[paras.last.uEnd].absEndMs) < 30 * 1000) {
        final prev = paras.last;
        paras[paras.length - 1] = _ParsedParagraph(
          uStart: prev.uStart,
          uEnd: i,
          speaker: prev.speaker,
          text: joinPolishedUtterances(prev.text, clean),
        );
      } else {
        paras.add(
          _ParsedParagraph(
            uStart: i,
            uEnd: i,
            speaker: u.speaker,
            text: clean,
          ),
        );
      }
    }
    return paras;
  }

  static String? _extractJsonObject(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return trimmed.substring(start, end + 1);
  }

  static String _truncate(String text, int maxLen) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}…';
  }
}
