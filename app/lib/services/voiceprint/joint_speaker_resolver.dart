/// 声纹 + 语义联合说话人归因决策器。
///
/// 职责：
/// 1. 端侧确定性提取对话中的「自报家门」与「直接呼语-应答对」，严格过滤「让XX/跟XX说」
///    等不在场第三人提及，防止误绑；
/// 2. 统一解析云端清洗/总结附带的可选 `speakerClues` JSON；
/// 3. 将 [VoiceprintLibraryStore.matchAllProfiles] 的声学分数（含同/跨设备通道校准、
///    AS-Norm、Margin）与语义线索融合决策：
///    - 高置信直接确认（含「跨设备中等声纹 + 强语义」搭桥自动入库新设备子质心）；
///    - 中等擦边或纯语义线索生成 [SpeakerCandidateSuggestion] 待用户 1-Tap 确认；
///    - 同会话内强制 1-to-1 排他，防止两个人同时被标为同一姓名。
library;

import 'dart:math' as math;

import '../../core/models/record.dart';
import '../../core/models/recording.dart';
import '../../core/store/voiceprint_library_store.dart';

enum SemanticClueKind { selfIntro, directVocative, llmInferred }

class SemanticSpeakerClue {
  const SemanticSpeakerClue({
    required this.speakerSlot,
    required this.candidateName,
    required this.confidence,
    required this.kind,
    required this.evidence,
    this.eventId,
  });

  final String speakerSlot;
  final String candidateName;
  final double confidence;
  final SemanticClueKind kind;
  final String evidence;
  final String? eventId;
}

class ResolvedSpeakerOutcome {
  const ResolvedSpeakerOutcome({
    required this.speakerSlot,
    required this.personName,
    required this.confidence,
    required this.source,
    required this.reason,
    required this.acousticScore,
    required this.semanticScore,
    required this.margin,
    this.shouldEnrollChannelCentroid = false,
    this.channelKey = VoiceChannel.fallback,
    this.deviceLabel = '录音卡',
  });

  final String speakerSlot;
  final String personName;
  final double confidence;
  final SpeakerSuggestionSource source;
  final String reason;
  final double acousticScore;
  final double semanticScore;
  final double margin;
  final bool shouldEnrollChannelCentroid;
  final String channelKey;
  final String deviceLabel;
}

class SessionJointResolution {
  const SessionJointResolution({
    this.autoConfirmed = const {},
    this.suggestions = const {},
  });

  final Map<String, ResolvedSpeakerOutcome> autoConfirmed;
  final Map<String, SpeakerCandidateSuggestion> suggestions;
}

class SemanticSpeakerClueExtractor {
  const SemanticSpeakerClueExtractor._();

  static const Set<String> stopWords = {
    '自己',
    '大家',
    '各位',
    '同学',
    '老师',
    '同事',
    '客户',
    '谢谢',
    '好的',
    '可以',
    '没有',
    '不是',
    '觉得',
    '同意',
    '那个',
    '这个',
    '主要',
    '负责',
    '今天',
    '明天',
    '昨天',
    '刚才',
    '现在',
    '这里',
    '这边',
    '那边',
    '我们',
    '你们',
    '他们',
    '咱们',
    '如果',
    '因为',
    '所以',
    '但是',
    '然后',
    '可能',
    '应该',
    '需要',
    '已经',
    '正在',
    '比较',
    '非常',
    '一下',
    '一起',
    '问题',
    '方案',
    '东西',
    '事情',
    '产品',
    '开发',
    '测试',
    '运维',
    '设计',
    '老板',
    '朋友',
    '家人',
    '未区分',
    '无语音',
    '说话人',
    '第三方',
    '对接方',
  };

  static const List<String> _nonNameSubstrings = [
    '觉得',
    '负责',
    '来说',
    '认为',
    '意思',
    '方面',
    '部分',
    '主要',
    '知道',
    '明白',
    '确定',
    '肯定',
    '这样',
    '那样',
    '什么',
    '怎么',
    '多少',
    '几个',
    '哪里',
    '对接',
    '测试',
    '工作',
    '他',
    '她',
    '助理',
    '秘书',
    '代表',
  ];

  static final RegExp _selfIntroRe = RegExp(
    r'(?:^|[，,。！？!\s])(?:大家好[，,\s]*)?(?:我是|我叫|本人是)\s*([\u4e00-\u9fff]{2,4}|[A-Za-z][A-Za-z0-9_-]{1,15})(?=[，,。！？!\s]|这边|这里|$)',
  );

  static final RegExp _selfIntroNegPrefixRe = RegExp(
    r'(?:不是|并非|别说|以为我是)\s*$',
  );

  static final RegExp _leadingVocativeRe = RegExp(
    r'(?:^|[，,\s])(老[\u4e00-\u9fff]|小[\u4e00-\u9fff]|[\u4e00-\u9fff]{1,2}[总哥姐叔伯姨]|[\u4e00-\u9fff]{2,3}|[A-Z][a-zA-Z]{1,12})[，,]\s*([^。！？!\n]{1,36})',
  );

  static final RegExp _trailingVocativeRe = RegExp(
    r'(?:你觉得呢|你怎么看|对吧|行吗|好吗|是吧|喝什么|点什么|吃什么|怎么样|可以吗)[，,\s]+(老[\u4e00-\u9fff]|小[\u4e00-\u9fff]|[\u4e00-\u9fff]{1,2}[总哥姐叔伯姨]|[\u4e00-\u9fff]{2,3}|[A-Z][a-zA-Z]{1,12})[？?！!\s]*$',
  );

  static final RegExp _thirdPartyBeforeRe = RegExp(
    r'(?:让|叫|找|问问|问下|问一问|跟|和|给|通知|告诉|联系|托|替|听|听说|提到|关于|比|像|叫上|喊一下)\s*$',
  );

  static final RegExp _thirdPartyAfterRe = RegExp(
    r'^(?:昨天|刚才|之前|去年|上次|已经|不在|还没|那边|说|他|她|他们|她们|也说|没来)',
  );

  static final RegExp _directSecondPersonSignalRe = RegExp(
    r'(?:你|您|咱|咱们|顺手|请|帮|看|说|讲|来|点|喝|吃|觉得|同意|盯|怎么|吗|呢|[？?])',
  );

  static bool isPlausiblePersonName(
    String raw, {
    Set<String> knownNames = const {},
  }) {
    final s = raw.trim();
    if (s.length < 2 || s.length > 16) return false;
    if (s.startsWith('说话人') || s == '未区分' || s == '无语音') return false;
    if (s.endsWith('的') || s.endsWith('了') || s.endsWith('吧') || s.endsWith('吗')) {
      return false;
    }
    if (stopWords.contains(s)) return false;
    if (knownNames.contains(s)) return true;
    for (final sub in _nonNameSubstrings) {
      if (s.contains(sub)) return false;
    }
    if (RegExp(r'^[0-9\s\p{P}]+$', unicode: true).hasMatch(s)) return false;
    return true;
  }

  static String normalizeSlot(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'（推测）|\(推测\)'), '').trim();
    if (s.isEmpty || s == '—' || s == '未区分' || s == '说话人 未区分') {
      return '未区分';
    }
    if (s == '无语音') return '无语音';
    if (s.startsWith('说话人 ')) return s;
    if (s.startsWith('说话人')) {
      final rest = s.substring(3).trim();
      return rest.isEmpty ? '未区分' : '说话人 $rest';
    }
    if (RegExp(r'^[A-Za-z0-9]{1,3}$').hasMatch(s)) return '说话人 $s';
    return s;
  }

  static bool isClusterSlot(String raw) {
    final norm = normalizeSlot(raw);
    return norm.startsWith('说话人 ') && norm != '说话人 未区分';
  }

  static List<SemanticSpeakerClue> extractFromTurnLines(
    List<TurnLine> turns, {
    Set<String> knownNames = const {},
    String? eventId,
  }) => extractFromTurnPairs(
    [for (final t in turns) (speaker: t.spk, text: t.text)],
    knownNames: knownNames,
    eventId: eventId,
  );

  static List<SemanticSpeakerClue> extractFromUtterances(
    List<RawUtterance> utterances, {
    Set<String> knownNames = const {},
    String? eventId,
  }) => extractFromTurnPairs(
    [
      for (final u in utterances)
        (
          speaker: u.speakerCluster != null && u.speakerCluster! >= 0
              ? '说话人 ${u.speakerCluster! + 1}'
              : (u.speakerLabel ?? '未区分'),
          text: u.text,
        ),
    ],
    knownNames: knownNames,
    eventId: eventId,
  );

  static List<SemanticSpeakerClue> extractFromTurnPairs(
    List<({String speaker, String text})> turns, {
    Set<String> knownNames = const {},
    String? eventId,
  }) {
    final clues = <SemanticSpeakerClue>[];
    for (var i = 0; i < turns.length; i++) {
      final curSlot = normalizeSlot(turns[i].speaker);
      final curText = turns[i].text.trim();
      if (curText.isEmpty) continue;

      if (isClusterSlot(curSlot)) {
        for (final m in _selfIntroRe.allMatches(curText)) {
          final prefix = curText.substring(0, m.start);
          if (_selfIntroNegPrefixRe.hasMatch(prefix)) continue;
          final cand = (m.group(1) ?? '').trim();
          if (!isPlausiblePersonName(cand, knownNames: knownNames)) continue;
          clues.add(
            SemanticSpeakerClue(
              speakerSlot: curSlot,
              candidateName: cand,
              confidence: knownNames.contains(cand) ? 0.93 : 0.90,
              kind: SemanticClueKind.selfIntro,
              evidence: '对话中自报「${m.group(0)!.trim()}」',
              eventId: eventId,
            ),
          );
        }
      }

      if (i > 0 && isClusterSlot(curSlot)) {
        final prevSlot = normalizeSlot(turns[i - 1].speaker);
        final prevText = turns[i - 1].text.trim();
        if (prevSlot != curSlot && prevText.isNotEmpty) {
          final voc = _extractVocativeAddressee(
            prevText,
            knownNames: knownNames,
          );
          if (voc != null) {
            clues.add(
              SemanticSpeakerClue(
                speakerSlot: curSlot,
                candidateName: voc.name,
                confidence: knownNames.contains(voc.name) ? 0.86 : 0.78,
                kind: SemanticClueKind.directVocative,
                evidence: '上句呼语「${voc.snippet}」后直接应答',
                eventId: eventId,
              ),
            );
          }
        }
      }
    }
    return clues;
  }

  static ({String name, String snippet})? _extractVocativeAddressee(
    String text, {
    Set<String> knownNames = const {},
  }) {
    final clauses = text
        .split(RegExp(r'[。！？!；;\n]+'))
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (clauses.isEmpty) return null;

    // 优先检查靠近说话人切换位置的末尾分句
    final candidates = clauses.length <= 2
        ? clauses.reversed.toList()
        : [clauses.last, clauses[clauses.length - 2]];

    for (final clause in candidates) {
      final trail = _trailingVocativeRe.firstMatch(clause);
      if (trail != null) {
        final cand = (trail.group(1) ?? '').trim();
        if (isPlausiblePersonName(cand, knownNames: knownNames)) {
          return (name: cand, snippet: _truncate(clause, 24));
        }
      }

      for (final m in _leadingVocativeRe.allMatches(clause)) {
        final cand = (m.group(1) ?? '').trim();
        final tail = (m.group(2) ?? '').trim();
        if (!isPlausiblePersonName(cand, knownNames: knownNames)) continue;
        final before = clause.substring(0, m.start);
        if (_thirdPartyBeforeRe.hasMatch(before)) continue;
        if (_thirdPartyAfterRe.hasMatch(tail)) continue;
        if (!_directSecondPersonSignalRe.hasMatch(tail) &&
            !clause.contains('？') &&
            !clause.contains('?')) {
          continue;
        }
        return (name: cand, snippet: _truncate(clause, 24));
      }
    }
    return null;
  }

  static List<SemanticSpeakerClue> parseCloudClues(
    Object? rawClues, {
    Set<String> validSlots = const {},
    Set<String> knownNames = const {},
    String? eventId,
  }) {
    if (rawClues is! List) return const [];
    final out = <SemanticSpeakerClue>[];
    for (final item in rawClues) {
      if (item is! Map) continue;
      final rawSlot = '${item['slot'] ?? item['speakerSlot'] ?? ''}'.trim();
      final slot = normalizeSlot(rawSlot);
      if (!isClusterSlot(slot)) continue;
      if (validSlots.isNotEmpty && !validSlots.contains(slot)) continue;

      final name = '${item['name'] ?? item['candidateName'] ?? ''}'.trim();
      if (!isPlausiblePersonName(name, knownNames: knownNames)) continue;

      final rawConf = (item['confidence'] as num?)?.toDouble() ?? 0.78;
      final conf = rawConf.clamp(0.40, 0.95);
      final rawKind = '${item['kind'] ?? ''}'.trim().toLowerCase();
      final kind = switch (rawKind) {
        'self_intro' || 'selfintro' => SemanticClueKind.selfIntro,
        'vocative' || 'direct_vocative' => SemanticClueKind.directVocative,
        _ => SemanticClueKind.llmInferred,
      };
      var itemEventId = '${item['eventId'] ?? item['id'] ?? ''}'.trim();
      if (itemEventId.startsWith('[') &&
          itemEventId.endsWith(']') &&
          itemEventId.length > 2) {
        itemEventId = itemEventId.substring(1, itemEventId.length - 1).trim();
      }
      final resolvedEventId = itemEventId.isNotEmpty ? itemEventId : eventId;
      final ev = '${item['evidence'] ?? item['reason'] ?? ''}'.trim();
      out.add(
        SemanticSpeakerClue(
          speakerSlot: slot,
          candidateName: name,
          confidence: conf,
          kind: kind,
          evidence: ev.isEmpty ? '语义上下文推断' : _truncate(ev, 36),
          eventId: resolvedEventId,
        ),
      );
    }
    return out;
  }

  static String _truncate(String s, int maxLen) {
    final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}…';
  }
}

class JointSpeakerResolver {
  const JointSpeakerResolver._();

  static SessionJointResolution resolveSession({
    required String session,
    required Map<String, List<double>> speakerCentroids,
    required VoiceprintLibraryStore voiceprintStore,
    Map<String, int> speakerSpeechMs = const {},
    List<SemanticSpeakerClue> semanticClues = const [],
    String? deviceLabel,
    String? sourceLane,
    String? sceneLabel,
    Map<String, String> lockedSlotToName = const {},
    int nowMs = 0,
  }) {
    final cleanSession = session.trim();
    if (cleanSession.isEmpty) return const SessionJointResolution();

    final readableDev = VoiceChannel.readableDeviceLabel(
      deviceLabel,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    final channelKey = VoiceChannel.normalizeChannelKey(
      deviceLabel,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );

    final lockedNames = <String>{
      for (final n in lockedSlotToName.values)
        if (n.trim().isNotEmpty) n.trim(),
    };

    final candidateSlots = <String>{
      ...speakerCentroids.keys,
      for (final c in semanticClues) c.speakerSlot,
    }
      ..removeWhere(
        (s) =>
            !SemanticSpeakerClueExtractor.isClusterSlot(s) ||
            lockedSlotToName.containsKey(s) ||
            voiceprintStore.isSlotDetached(
              session: cleanSession,
              speakerSlot: s,
            ),
      );

    if (candidateSlots.isEmpty) return const SessionJointResolution();

    // 聚合同槽位 + 同人名的多条语义线索
    final semBySlotName =
        <String, Map<String, ({double score, String evidence, SemanticClueKind kind})>>{};
    for (final clue in semanticClues) {
      if (!candidateSlots.contains(clue.speakerSlot)) continue;
      if (lockedNames.contains(clue.candidateName.trim())) continue;
      if (voiceprintStore.isSuggestionDismissed(
        session: cleanSession,
        speakerSlot: clue.speakerSlot,
        candidateName: clue.candidateName,
      )) {
        continue;
      }
      final byName = semBySlotName.putIfAbsent(clue.speakerSlot, () => {});
      final prev = byName[clue.candidateName];
      if (prev == null) {
        byName[clue.candidateName] = (
          score: clue.confidence,
          evidence: clue.evidence,
          kind: clue.kind,
        );
      } else {
        final bonus = prev.kind != clue.kind ? 0.04 : 0.01;
        final mergedScore = (math.max(prev.score, clue.confidence) + bonus)
            .clamp(0.0, 0.95);
        byName[clue.candidateName] = (
          score: mergedScore,
          evidence: clue.confidence >= prev.score
              ? clue.evidence
              : prev.evidence,
          kind: clue.confidence >= prev.score ? clue.kind : prev.kind,
        );
      }
    }

    final autoProposals = <ResolvedSpeakerOutcome>[];
    final suggestProposals = <SpeakerCandidateSuggestion>[];

    for (final slot in candidateSlots) {
      final centroid = speakerCentroids[slot];
      final peerCentroids = <List<double>>[
        for (final entry in speakerCentroids.entries)
          if (entry.key != slot && entry.value.isNotEmpty) entry.value,
      ];
      final speechMs = speakerSpeechMs[slot] ?? 5000;
      final eval = (centroid != null && centroid.isNotEmpty)
          ? voiceprintStore.matchAllProfiles(
              centroid,
              deviceLabel: deviceLabel,
              sourceLane: sourceLane,
              sceneLabel: sceneLabel,
              speechMs: speechMs,
              sessionPeerCentroids: peerCentroids,
              excludedPersonNames: lockedNames,
            )
          : null;

      final semMap = semBySlotName[slot] ?? const {};
      final candidateNames = <String>{
        if (eval != null)
          for (final c in eval.candidates.take(4))
            if (c.effectiveScore >= 0.34 &&
                !voiceprintStore.isSuggestionDismissed(
                  session: cleanSession,
                  speakerSlot: slot,
                  candidateName: c.profile.name,
                ))
              c.profile.name,
        ...semMap.keys,
      };

      for (final name in candidateNames) {
        final candAcoustic = eval?.scoreForName(name);
        final acoustic = candAcoustic?.effectiveScore ?? 0.0;
        final sameChannel = candAcoustic?.sameChannel ?? false;
        final margin =
            (eval != null &&
                eval.candidates.isNotEmpty &&
                eval.candidates.first.profile.name == name)
            ? eval.margin
            : (eval != null && eval.candidates.isNotEmpty
                  ? acoustic - eval.candidates.first.effectiveScore
                  : 0.0);

        final sem = semMap[name];
        final semScore = sem?.score ?? 0.0;
        var otherSemMax = 0.0;
        for (final other in semMap.entries) {
          if (other.key != name && other.value.score > otherSemMax) {
            otherSemMax = other.value.score;
          }
        }

        final enrolled = voiceprintStore.findByName(name);
        final hasVoiceprint = enrolled != null && enrolled.samples.isNotEmpty;
        final hasCurChannelSample =
            enrolled != null &&
            enrolled.samples.any((s) => s.channelKey == channelKey);

        final isAcousticConfirmed = eval?.confirmed?.name == name;
        final isSemanticConflict = otherSemMax >= 0.85 && acoustic < 0.80;

        // 1) 纯声纹高置信直接确认（且未与强语义产生冲突）
        if (isAcousticConfirmed && !isSemanticConflict) {
          final isJoint = semScore >= 0.65;
          autoProposals.add(
            ResolvedSpeakerOutcome(
              speakerSlot: slot,
              personName: name,
              confidence: isJoint
                  ? math.max(acoustic, semScore)
                  : acoustic,
              source: isJoint
                  ? SpeakerSuggestionSource.joint
                  : SpeakerSuggestionSource.voiceprint,
              reason: isJoint
                  ? '$readableDev声纹 ${(acoustic * 100).round()}% + ${sem!.evidence}'
                  : '$readableDev声纹高置信匹配 (${(acoustic * 100).round()}%)',
              acousticScore: acoustic,
              semanticScore: semScore,
              margin: margin,
              shouldEnrollChannelCentroid:
                  centroid != null &&
                  centroid.isNotEmpty &&
                  (!sameChannel || !hasCurChannelSample) &&
                  speechMs >= 2500,
              channelKey: channelKey,
              deviceLabel: readableDev,
            ),
          );
          continue;
        }

        // 2) 声纹 + 语义联合搭桥确认（专克跨设备音量/频响差异冷启动）
        final acousticGapFromTop =
            eval == null ? 0.0 : (eval.bestScore - acoustic);
        final passesJointBridge =
            hasVoiceprint &&
            acoustic >= 0.44 &&
            semScore >= 0.72 &&
            otherSemMax < semScore - 0.10 &&
            acousticGapFromTop <= 0.12 &&
            speechMs >= 800;

        if (passesJointBridge) {
          final jointConf = (0.45 * acoustic + 0.55 * semScore + 0.08).clamp(
            0.75,
            0.98,
          );
          autoProposals.add(
            ResolvedSpeakerOutcome(
              speakerSlot: slot,
              personName: name,
              confidence: jointConf,
              source: SpeakerSuggestionSource.joint,
              reason:
                  '$readableDev声纹 ${(acoustic * 100).round()}% 与${sem!.evidence}一致',
              acousticScore: acoustic,
              semanticScore: semScore,
              margin: margin,
              shouldEnrollChannelCentroid:
                  centroid != null &&
                  centroid.isNotEmpty &&
                  (!sameChannel || !hasCurChannelSample) &&
                  speechMs >= 1500,
              channelKey: channelKey,
              deviceLabel: readableDev,
            ),
          );
          continue;
        }

        // 3) 带猜测待确认（声纹擦边 / 声纹-语义分歧 / 纯语义新人物推断）
        final isAcousticFuzzy = eval?.fuzzyHint?.name == name;
        final isSemanticCandidate =
            semScore >= 0.72 &&
            (!hasVoiceprint || eval == null || acoustic >= 0.25);

        if (isAcousticConfirmed && isSemanticConflict) {
          suggestProposals.add(
            SpeakerCandidateSuggestion(
              session: cleanSession,
              speakerSlot: slot,
              candidateName: name,
              confidence: 0.65,
              source: SpeakerSuggestionSource.voiceprint,
              reason: '声纹匹配「$name」(${(acoustic * 100).round()}%)，请结合上下文确认',
              acousticScore: acoustic,
              semanticScore: semScore,
              margin: margin,
              channelKey: channelKey,
              deviceLabel: readableDev,
              updatedAtMs: nowMs,
            ),
          );
        } else if (isAcousticFuzzy || isSemanticCandidate) {
          final hasBoth = acoustic >= 0.36 && semScore >= 0.65;
          final source = hasBoth
              ? SpeakerSuggestionSource.joint
              : (semScore >= acoustic
                    ? SpeakerSuggestionSource.semantic
                    : SpeakerSuggestionSource.voiceprint);
          final conf = hasBoth
              ? ((0.45 * acoustic + 0.55 * semScore).clamp(0.50, 0.90))
              : math.max(acoustic, semScore);
          final reason = switch (source) {
            SpeakerSuggestionSource.joint =>
              '$readableDev声纹 ${(acoustic * 100).round()}% · ${sem!.evidence}',
            SpeakerSuggestionSource.semantic => sem!.evidence,
            SpeakerSuggestionSource.voiceprint =>
              '${sameChannel ? "同设备" : "跨设备($readableDev)"}声纹相似度 ${(acoustic * 100).round()}%',
          };
          suggestProposals.add(
            SpeakerCandidateSuggestion(
              session: cleanSession,
              speakerSlot: slot,
              candidateName: name,
              confidence: conf,
              source: source,
              reason: reason,
              acousticScore: acoustic,
              semanticScore: semScore,
              margin: margin,
              channelKey: channelKey,
              deviceLabel: readableDev,
              updatedAtMs: nowMs,
            ),
          );
        }
      }
    }

    // 同会话 1-to-1 贪心互斥分配：自动确认优先，不允许两个人同时自动占用同一个名字
    autoProposals.sort((a, b) {
      final aJoint = a.source == SpeakerSuggestionSource.joint ? 1 : 0;
      final bJoint = b.source == SpeakerSuggestionSource.joint ? 1 : 0;
      if (aJoint != bJoint) return bJoint.compareTo(aJoint);
      return b.confidence.compareTo(a.confidence);
    });

    final confirmed = <String, ResolvedSpeakerOutcome>{};
    final takenNames = <String>{...lockedNames};
    for (final p in autoProposals) {
      if (confirmed.containsKey(p.speakerSlot) ||
          takenNames.contains(p.personName)) {
        continue;
      }
      confirmed[p.speakerSlot] = p;
      takenNames.add(p.personName);
    }

    suggestProposals.sort((a, b) {
      final aJoint = a.source == SpeakerSuggestionSource.joint ? 1 : 0;
      final bJoint = b.source == SpeakerSuggestionSource.joint ? 1 : 0;
      if (aJoint != bJoint) return bJoint.compareTo(aJoint);
      return b.confidence.compareTo(a.confidence);
    });

    final suggestions = <String, SpeakerCandidateSuggestion>{};
    final suggestedNames = <String>{...takenNames};
    for (final s in suggestProposals) {
      if (confirmed.containsKey(s.speakerSlot) ||
          suggestions.containsKey(s.speakerSlot) ||
          suggestedNames.contains(s.candidateName)) {
        continue;
      }
      suggestions[s.speakerSlot] = s;
      suggestedNames.add(s.candidateName);
    }

    return SessionJointResolution(
      autoConfirmed: confirmed,
      suggestions: suggestions,
    );
  }
}
