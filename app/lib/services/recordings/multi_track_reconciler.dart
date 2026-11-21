/// 多路冗余录音比对、去重合并与语义分叉判定服务。
///
/// 策略：
/// 1. 本机冗余存储始终保留：不删除原始音频与 `RecordingFile`，仅通过决策表隐藏冗余/空影子；
/// 2. 只允许两路逻辑轨对齐比对：`ble`（蓝牙硬件）vs `companion`（Apple Watch / 手机本机）；
/// 3. 三态比对结果：
///    - 一方为空：保留有内容且更完整、更靠近用户的一方；
///    - 文本一致 / 高相似度：自动合并保留最完整/高权威的一方，隐藏另一方；
///    - 语义不同：判定为真实并行分叉，保留双路并以同组 `forkGroupId` 在 Timeline 双列呈现。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../core/models/recording.dart';
import '../analysis/chat_completion.dart';
import '../transcribe/utterance_builder.dart';

enum TrackOverlapOutcome {
  keepNonEmpty,
  dedupKeepPrimary,
  forkParallel,
}

class ForkGroupInfo {
  const ForkGroupInfo({
    required this.forkGroupId,
    required this.leftSegmentId,
    required this.rightSegmentId,
    required this.reason,
  });

  final String forkGroupId;
  final String leftSegmentId;
  final String rightSegmentId;
  final String reason;

  Map<String, dynamic> toJson() => {
    'id': forkGroupId,
    'l': leftSegmentId,
    'r': rightSegmentId,
    'rs': reason,
  };

  factory ForkGroupInfo.fromJson(Map<String, dynamic> j) => ForkGroupInfo(
    forkGroupId: '${j['id'] ?? ''}',
    leftSegmentId: '${j['l'] ?? ''}',
    rightSegmentId: '${j['r'] ?? ''}',
    reason: '${j['rs'] ?? ''}',
  );
}

class TrackPairDecision {
  const TrackPairDecision({
    required this.pairKey,
    required this.fingerprint,
    required this.outcome,
    required this.primarySegmentId,
    required this.secondarySegmentId,
    required this.reason,
    this.forkGroupId,
  });

  final String pairKey;
  final String fingerprint;
  final TrackOverlapOutcome outcome;
  final String primarySegmentId;
  final String secondarySegmentId;
  final String reason;
  final String? forkGroupId;

  Map<String, dynamic> toJson() => {
    'pk': pairKey,
    'fp': fingerprint,
    'out': outcome.name,
    'p': primarySegmentId,
    's': secondarySegmentId,
    'rs': reason,
    if (forkGroupId != null) 'fk': forkGroupId,
  };

  factory TrackPairDecision.fromJson(Map<String, dynamic> j) => TrackPairDecision(
    pairKey: '${j['pk'] ?? ''}',
    fingerprint: '${j['fp'] ?? ''}',
    outcome: TrackOverlapOutcome.values.firstWhere(
      (e) => e.name == j['out'],
      orElse: () => TrackOverlapOutcome.dedupKeepPrimary,
    ),
    primarySegmentId: '${j['p'] ?? ''}',
    secondarySegmentId: '${j['s'] ?? ''}',
    reason: '${j['rs'] ?? ''}',
    forkGroupId: j['fk'] as String?,
  );
}

class MultiTrackReconciliationState {
  const MultiTrackReconciliationState({
    this.decisions = const [],
    this.hiddenSegmentIds = const {},
    this.forkGroupBySegmentId = const {},
    this.forks = const {},
  });

  final List<TrackPairDecision> decisions;
  final Set<String> hiddenSegmentIds;
  final Map<String, String> forkGroupBySegmentId;
  final Map<String, ForkGroupInfo> forks;

  static MultiTrackReconciliationState fromDecisions(
    List<TrackPairDecision> decisions,
  ) {
    final hidden = <String>{};
    final forkGroupBySeg = <String, String>{};
    final forks = <String, ForkGroupInfo>{};
    for (final d in decisions) {
      switch (d.outcome) {
        case TrackOverlapOutcome.keepNonEmpty:
        case TrackOverlapOutcome.dedupKeepPrimary:
          if (d.secondarySegmentId.isNotEmpty &&
              d.secondarySegmentId != d.primarySegmentId) {
            hidden.add(d.secondarySegmentId);
          }
        case TrackOverlapOutcome.forkParallel:
          final fk = (d.forkGroupId != null && d.forkGroupId!.isNotEmpty)
              ? d.forkGroupId!
              : 'fork-${d.pairKey}';
          if (!hidden.contains(d.primarySegmentId) &&
              !hidden.contains(d.secondarySegmentId)) {
            forkGroupBySeg[d.primarySegmentId] = fk;
            forkGroupBySeg[d.secondarySegmentId] = fk;
            forks[fk] = ForkGroupInfo(
              forkGroupId: fk,
              leftSegmentId: d.primarySegmentId,
              rightSegmentId: d.secondarySegmentId,
              reason: d.reason,
            );
          }
      }
    }
    return MultiTrackReconciliationState(
      decisions: List.unmodifiable(decisions),
      hiddenSegmentIds: Set.unmodifiable(hidden),
      forkGroupBySegmentId: Map.unmodifiable(forkGroupBySeg),
      forks: Map.unmodifiable(forks),
    );
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'dec': [for (final d in decisions) d.toJson()],
  };

  factory MultiTrackReconciliationState.fromJson(Map<String, dynamic> j) {
    final decs = <TrackPairDecision>[
      for (final item in (j['dec'] as List? ?? const []))
        if (item is Map<String, dynamic>) TrackPairDecision.fromJson(item),
    ];
    return MultiTrackReconciliationState.fromDecisions(decs);
  }
}

class MultiTrackReconciliationStore {
  MultiTrackReconciliationStore({required this.resolveRoot});

  final Future<Directory> Function() resolveRoot;
  static const String fileName = 'multi_track_reconciliation.json';

  Future<File> _file() async {
    final dir = await resolveRoot();
    return File('${dir.path}/$fileName');
  }

  Future<MultiTrackReconciliationState> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        return const MultiTrackReconciliationState();
      }
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return const MultiTrackReconciliationState();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const MultiTrackReconciliationState();
      }
      return MultiTrackReconciliationState.fromJson(decoded);
    } on Object {
      return const MultiTrackReconciliationState();
    }
  }

  Future<void> save(MultiTrackReconciliationState state) async {
    final f = await _file();
    if (!await f.parent.exists()) {
      await f.parent.create(recursive: true);
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}

class _SegmentCandidate {
  _SegmentCandidate({
    required this.file,
    required this.segment,
    required this.lane,
    required this.startAtMs,
    required this.endAtMs,
    required this.rawText,
    required this.normalizedText,
  });

  final RecordingFile file;
  final SegmentRecord segment;
  final RecordingSourceLane lane;
  final int startAtMs;
  final int endAtMs;
  final String rawText;
  final String normalizedText;

  bool get isEmptySpeech => normalizedText.length < 2;
  String get logicalTrack => lane == RecordingSourceLane.ble ? 'ble' : 'companion';
  int get authority => lane.authorityWeight;
}

class MultiTrackReconciler {
  MultiTrackReconciler({
    this.chat,
    this.modelResolver,
    this.ready,
  });

  final ChatCompletion? chat;
  final String Function()? modelResolver;
  final bool Function()? ready;

  static final RegExp _punctuationRe = RegExp(
    r'''[\s\p{P}\p{S}]+''',
    unicode: true,
  );
  static final RegExp _fillerRe = RegExp(
    r'^(?:嗯+|啊+|呃+|哦+|哎+|那个|就是|然后|其实|对对对)+|(?:嗯+|啊+|呃+|哦+)$',
  );

  static String normalizeForComparison(String raw) {
    var s = raw.toLowerCase().replaceAll(_punctuationRe, '');
    if (s.isEmpty) return '';
    String prev;
    do {
      prev = s;
      s = s.replaceAll(_fillerRe, '');
    } while (s != prev && s.isNotEmpty);
    return s;
  }

  static ({double dice, double containment, double unigram, double score})
  computeSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) {
      return (dice: 0, containment: 0, unigram: 0, score: 0);
    }
    if (a == b) {
      return (dice: 1, containment: 1, unigram: 1, score: 1);
    }
    if (a.length < 2 || b.length < 2) {
      final contained = a.contains(b) || b.contains(a);
      final u = contained ? 1.0 : 0.0;
      return (dice: u, containment: u, unigram: u, score: u);
    }

    Set<String> bigrams(String s) {
      final set = <String>{};
      for (var i = 0; i < s.length - 1; i++) {
        set.add(s.substring(i, i + 2));
      }
      return set;
    }

    final bgA = bigrams(a);
    final bgB = bigrams(b);
    final bgInter = bgA.intersection(bgB).length;
    final dice = bgA.isEmpty || bgB.isEmpty
        ? 0.0
        : (2.0 * bgInter) / (bgA.length + bgB.length);
    final minBg = math.min(bgA.length, bgB.length);
    final containment = minBg == 0 ? 0.0 : bgInter / minBg;

    final ugA = a.split('').toSet();
    final ugB = b.split('').toSet();
    final ugInter = ugA.intersection(ugB).length;
    final minUg = math.min(ugA.length, ugB.length);
    final unigram = minUg == 0 ? 0.0 : ugInter / minUg;

    final score = math.max(dice, containment * 0.85);
    return (
      dice: dice,
      containment: containment,
      unigram: unigram,
      score: score,
    );
  }

  Future<MultiTrackReconciliationState> reconcile(
    List<RecordingFile> files, {
    MultiTrackReconciliationState? previous,
  }) async {
    final prevByKey = <String, TrackPairDecision>{
      for (final d in previous?.decisions ?? const <TrackPairDecision>[])
        d.pairKey: d,
    };

    final candidates = <_SegmentCandidate>[];
    for (final file in files) {
      if (file.isExternalImported) continue;
      if (file.stage != RecordingStage.ready && file.segments.isEmpty) continue;
      final lane = file.resolvedSourceLane;
      for (final seg in file.segments) {
        if (seg.status == SegmentStatus.live) continue;
        final text = _extractText(file, seg);
        final norm = normalizeForComparison(text);
        final endAtMs =
            seg.endAtMs ??
            (file.durationMs > 0
                ? file.startAtMs + file.durationMs
                : seg.startAtMs + 1000);
        candidates.add(
          _SegmentCandidate(
            file: file,
            segment: seg,
            lane: lane,
            startAtMs: seg.startAtMs,
            endAtMs: endAtMs > seg.startAtMs ? endAtMs : seg.startAtMs + 1000,
            rawText: text,
            normalizedText: norm,
          ),
        );
      }
    }

    candidates.sort((a, b) => a.startAtMs.compareTo(b.startAtMs));
    final bleList = [
      for (final c in candidates)
        if (c.logicalTrack == 'ble') c,
    ];
    final companionList = [
      for (final c in candidates)
        if (c.logicalTrack == 'companion') c,
    ];

    final decisions = <TrackPairDecision>[];
    final consumedCompanion = <String>{};

    for (final ble in bleList) {
      for (final comp in companionList) {
        if (consumedCompanion.contains(comp.segment.id)) continue;
        if (!_overlapsSignificantly(ble, comp)) continue;
        final decision = await _evaluatePair(
          a: ble,
          b: comp,
          prevByKey: prevByKey,
        );
        decisions.add(decision);
        if (decision.outcome != TrackOverlapOutcome.forkParallel) {
          if (decision.secondarySegmentId == comp.segment.id) {
            consumedCompanion.add(comp.segment.id);
          } else if (decision.secondarySegmentId == ble.segment.id) {
            break;
          }
        }
      }
    }

    // 伴随路内部重叠（如手表切换至手机的瞬间交接窗口）：同向比对去重
    final usedWithinCompanion = <String>{};
    for (var i = 0; i < companionList.length; i++) {
      final a = companionList[i];
      if (consumedCompanion.contains(a.segment.id) ||
          usedWithinCompanion.contains(a.segment.id)) {
        continue;
      }
      for (var j = i + 1; j < companionList.length; j++) {
        final b = companionList[j];
        if (a.lane == b.lane) continue;
        if (consumedCompanion.contains(b.segment.id) ||
            usedWithinCompanion.contains(b.segment.id)) {
          continue;
        }
        if (!_overlapsSignificantly(a, b)) continue;
        final d = await _evaluatePair(a: a, b: b, prevByKey: prevByKey);
        decisions.add(d);
        if (d.outcome != TrackOverlapOutcome.forkParallel) {
          usedWithinCompanion.add(d.secondarySegmentId);
        }
      }
    }

    return MultiTrackReconciliationState.fromDecisions(decisions);
  }

  static bool _overlapsSignificantly(
    _SegmentCandidate a,
    _SegmentCandidate b,
  ) {
    final overlapStart = math.max(a.startAtMs, b.startAtMs);
    final overlapEnd = math.min(a.endAtMs, b.endAtMs);
    final overlapMs = overlapEnd - overlapStart;
    if (overlapMs <= 0) return false;
    final durA = math.max(1, a.endAtMs - a.startAtMs);
    final durB = math.max(1, b.endAtMs - b.startAtMs);
    final minDur = math.min(durA, durB);
    return overlapMs >= 3000 || (overlapMs / minDur) >= 0.2;
  }

  static String _extractText(RecordingFile file, SegmentRecord seg) {
    final buf = StringBuffer();
    if (file.turns.isNotEmpty) {
      final matchedTurns = seg.turnIds.isNotEmpty
          ? file.turns.where((t) => seg.turnIds.contains(t.id))
          : file.turns;
      for (final t in matchedTurns) {
        if (isMeaningfulSpeechText(t.text)) {
          buf.write(t.text.trim());
        }
      }
    }
    if (buf.isEmpty && file.utterances.isNotEmpty) {
      final sliceSet = seg.sliceIds.toSet();
      final matched = sliceSet.isNotEmpty
          ? file.utterances.where((u) => sliceSet.contains(u.sliceId))
          : file.utterances;
      for (final u in matched) {
        if (isMeaningfulSpeechText(u.text)) {
          buf.write(u.text.trim());
        }
      }
    }
    if (buf.isEmpty && isMeaningfulSpeechText(seg.longText)) {
      buf.write(seg.longText.trim());
    }
    if (buf.isEmpty &&
        isMeaningfulSpeechText(seg.brief) &&
        !seg.brief.contains('没有识别到人声') &&
        !seg.brief.contains('未检测到有效人声')) {
      buf.write(seg.brief.trim());
    }
    return buf.toString();
  }

  static String _buildPairKey(String segA, String segB) =>
      segA.compareTo(segB) <= 0 ? '$segA::$segB' : '$segB::$segA';

  static String _buildFingerprint(_SegmentCandidate a, _SegmentCandidate b) {
    final items = [a, b]..sort((x, y) => x.segment.id.compareTo(y.segment.id));
    final first = items[0];
    final second = items[1];
    return '${first.segment.id}:${first.normalizedText.length}:${first.normalizedText.hashCode}|'
        '${second.segment.id}:${second.normalizedText.length}:${second.normalizedText.hashCode}';
  }

  Future<TrackPairDecision> _evaluatePair({
    required _SegmentCandidate a,
    required _SegmentCandidate b,
    required Map<String, TrackPairDecision> prevByKey,
  }) async {
    final ordered = [a, b]
      ..sort((x, y) => y.authority.compareTo(x.authority));
    final high = ordered[0];
    final low = ordered[1];
    final pairKey = _buildPairKey(high.segment.id, low.segment.id);
    final fp = _buildFingerprint(high, low);
    final cached = prevByKey[pairKey];
    if (cached != null && cached.fingerprint == fp) {
      return cached;
    }

    // 情况 1：任一方为空（无有效人声）
    if (high.isEmptySpeech && low.isEmptySpeech) {
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.keepNonEmpty,
        primarySegmentId: high.segment.id,
        secondarySegmentId: low.segment.id,
        reason: '双路均无有效人声，保留高权威设备记录',
      );
    }
    if (high.isEmptySpeech && !low.isEmptySpeech) {
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.keepNonEmpty,
        primarySegmentId: low.segment.id,
        secondarySegmentId: high.segment.id,
        reason: '${high.file.resolvedSourceDeviceLabel} 段落为空，保留更完整的 ${low.file.resolvedSourceDeviceLabel}',
      );
    }
    if (!high.isEmptySpeech && low.isEmptySpeech) {
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.keepNonEmpty,
        primarySegmentId: high.segment.id,
        secondarySegmentId: low.segment.id,
        reason: '${low.file.resolvedSourceDeviceLabel} 段落为空，保留更完整的 ${high.file.resolvedSourceDeviceLabel}',
      );
    }

    // 情况 2：双方均有语音内容
    final sim = computeSimilarity(high.normalizedText, low.normalizedText);
    if (sim.score >= 0.58 || sim.containment >= 0.72) {
      final preferred = _pickPreferred(high, low);
      final dropped = preferred.segment.id == high.segment.id ? low : high;
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.dedupKeepPrimary,
        primarySegmentId: preferred.segment.id,
        secondarySegmentId: dropped.segment.id,
        reason: '双路内容一致，保留 ${preferred.file.resolvedSourceDeviceLabel}',
      );
    }

    if (sim.score <= 0.14 && sim.unigram <= 0.22) {
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.forkParallel,
        primarySegmentId: high.segment.id,
        secondarySegmentId: low.segment.id,
        forkGroupId: 'fork-${high.segment.id}-${low.segment.id}',
        reason: '双路语义独立，并行保留两路现场记录',
      );
    }

    // 中间模糊相似度区间：若云端轻量判重可用则请求判重，否则退回本地阈值
    final cloudResult = await _judgeWithCloud(high, low);
    if (cloudResult != null) {
      if (cloudResult.sameScene) {
        final preferred = switch (cloudResult.preferred) {
          'B' => low,
          'A' => high,
          _ => _pickPreferred(high, low),
        };
        final dropped = preferred.segment.id == high.segment.id ? low : high;
        return TrackPairDecision(
          pairKey: pairKey,
          fingerprint: fp,
          outcome: TrackOverlapOutcome.dedupKeepPrimary,
          primarySegmentId: preferred.segment.id,
          secondarySegmentId: dropped.segment.id,
          reason: cloudResult.reason.isNotEmpty
              ? cloudResult.reason
              : '语义判重为同一对话，保留 ${preferred.file.resolvedSourceDeviceLabel}',
        );
      }
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.forkParallel,
        primarySegmentId: high.segment.id,
        secondarySegmentId: low.segment.id,
        forkGroupId: 'fork-${high.segment.id}-${low.segment.id}',
        reason: cloudResult.reason.isNotEmpty
            ? cloudResult.reason
            : '语义判重为不同对话场景，并行双列保留',
      );
    }

    // 离线 / 降级本地判定
    if (sim.score >= 0.35) {
      final preferred = _pickPreferred(high, low);
      final dropped = preferred.segment.id == high.segment.id ? low : high;
      return TrackPairDecision(
        pairKey: pairKey,
        fingerprint: fp,
        outcome: TrackOverlapOutcome.dedupKeepPrimary,
        primarySegmentId: preferred.segment.id,
        secondarySegmentId: dropped.segment.id,
        reason: '本地相似度判定为同一段对话，保留 ${preferred.file.resolvedSourceDeviceLabel}',
      );
    }
    return TrackPairDecision(
      pairKey: pairKey,
      fingerprint: fp,
      outcome: TrackOverlapOutcome.forkParallel,
      primarySegmentId: high.segment.id,
      secondarySegmentId: low.segment.id,
      forkGroupId: 'fork-${high.segment.id}-${low.segment.id}',
      reason: '双路文本差异较大，并行保留各自记录',
    );
  }

  static _SegmentCandidate _pickPreferred(
    _SegmentCandidate high,
    _SegmentCandidate low,
  ) {
    final lenHigh = high.normalizedText.length;
    final lenLow = low.normalizedText.length;
    if (lenLow >= (lenHigh * 1.25).ceil() && lenLow - lenHigh >= 6) {
      return low;
    }
    return high;
  }

  Future<({bool sameScene, String preferred, String reason})?> _judgeWithCloud(
    _SegmentCandidate a,
    _SegmentCandidate b,
  ) async {
    final completion = chat;
    final isReady = ready?.call() ?? false;
    final model = modelResolver?.call().trim() ?? '';
    if (completion == null || !isReady || model.isEmpty) {
      return null;
    }
    final textA = a.rawText.length > 600
        ? a.rawText.substring(0, 600)
        : a.rawText;
    final textB = b.rawText.length > 600
        ? b.rawText.substring(0, 600)
        : b.rawText;
    final prompt = '''你是语音转写多设备对齐助手。同一时间段内两台设备（A: ${a.file.resolvedSourceDeviceLabel}，B: ${b.file.resolvedSourceDeviceLabel}）分别录到了以下两段中文转写文本（可能存在同音字错别字或远近拾音完整度差异）。
请判断它们记录的是否为**同一场对话/同一话题场景**：
- 若是同一场对话（只是清晰度或错别字不同），返回 "same"，并在 preferred 中选出更完整、更清晰的一方（"A" 或 "B"，优先更贴近用户且完整的）。
- 若属于两场不同的对话（例如一台留在会议室录会议，另一台随身带出接打电话或在不同房间对话），必须返回 "different"。

请只输出严格 JSON：
{"relation":"same"|"different","preferred":"A"|"B","reason":"简短中文原因"}

[设备 A 文本]
$textA

[设备 B 文本]
$textB''';

    try {
      final raw = await completion
          .complete(
            [ChatMessage.user(prompt)],
            model: model,
            temperature: 0.0,
            maxTokens: 256,
          )
          .timeout(const Duration(seconds: 8));
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final jsonMap = jsonDecode(raw.substring(start, end + 1));
      if (jsonMap is! Map<String, dynamic>) return null;
      final rel = '${jsonMap['relation'] ?? ''}'.trim().toLowerCase();
      final pref = '${jsonMap['preferred'] ?? ''}'.trim().toUpperCase();
      final reason = '${jsonMap['reason'] ?? ''}'.trim();
      if (rel != 'same' && rel != 'different') return null;
      return (
        sameScene: rel == 'same',
        preferred: pref == 'B' ? 'B' : 'A',
        reason: reason,
      );
    } on Object {
      return null;
    }
  }
}
