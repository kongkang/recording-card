/// 会话级说话人档案 —— 让同一个 session 的多个设备文件共用一套「说话人 N」编号。
///
/// 为什么需要：设备每 10 分钟切一个 `.APM`，一次连续录音会横跨多个文件。
/// 每个文件的声纹聚类是独立做的，簇号从 0 重新开始；如果不做跨文件对齐，
/// 同一个人在第 2 个文件里可能变成「说话人 2」，产品语义（推测但稳定）就破了。
///
/// 做法：
/// - 每个文件聚类完成后，把簇质心与会话已有质心做余弦匹配；匹配上就沿用旧编号，
///   匹配不上才分配新编号；编号一旦分配就不再改（先出现的主导说话人是 1）。
/// - 质心按语音时长加权合并，并记录已并入的文件名：同一文件重跑只重新贴标签，
///   不重复累加（否则反复重试会让质心漂移）。
/// - 声纹 embedding 只落本机（`recordings/_sessions/`），不上行、不关联真实身份。
///
/// 这是**推测**：输出只有簇号与相似度；低置信度仍由聚类器判为「未区分」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'recording_store.dart';

/// 会话里一个说话人的质心。`index` 是会话级稳定编号（0-based）。
class SpeakerProfile {
  const SpeakerProfile({
    required this.index,
    required this.centroid,
    required this.speechMs,
  });

  final int index;

  /// 已归一化的质心向量。
  final List<double> centroid;

  /// 累计参与合并的语音时长，作为质心权重。
  final int speechMs;

  Map<String, dynamic> toJson() => {
    'i': index,
    'c': centroid,
    'ms': speechMs,
  };

  factory SpeakerProfile.fromJson(Map<String, dynamic> j) => SpeakerProfile(
    index: (j['i'] as num?)?.toInt() ?? 0,
    centroid: [
      for (final v in (j['c'] as List? ?? const []))
        if (v is num) v.toDouble(),
    ],
    speechMs: (j['ms'] as num?)?.toInt() ?? 0,
  );
}

/// 一个 session 的说话人档案表。
class SpeakerProfileSet {
  const SpeakerProfileSet({
    required this.session,
    this.profiles = const [],
    this.contributors = const {},
  });

  factory SpeakerProfileSet.empty(String session) =>
      SpeakerProfileSet(session: session);

  final String session;

  /// 按 [SpeakerProfile.index] 升序存储（读入时排序，不信任文件顺序）。
  final List<SpeakerProfile> profiles;

  /// 已经并入质心的设备文件名；用于防止重跑重复累加。
  final Set<String> contributors;

  bool get isEmpty => profiles.isEmpty;

  SpeakerProfile? byIndex(int index) {
    for (final p in profiles) {
      if (p.index == index) return p;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'ses': session,
    'files': contributors.toList()..sort(),
    'spk': [for (final p in profiles) p.toJson()],
  };

  factory SpeakerProfileSet.fromJson(Map<String, dynamic> j) {
    final profiles = [
      for (final p in (j['spk'] as List? ?? const []))
        if (p is Map<String, dynamic>) SpeakerProfile.fromJson(p),
    ]..sort((a, b) => a.index.compareTo(b.index));
    return SpeakerProfileSet(
      session: '${j['ses'] ?? ''}',
      profiles: profiles,
      contributors: {
        for (final f in (j['files'] as List? ?? const [])) '$f',
      },
    );
  }
}

/// 一个文件的簇号 → 会话编号映射，以及合并后的档案表。
class SpeakerMatchResult {
  const SpeakerMatchResult({
    required this.clusterToSpeaker,
    required this.profiles,
  });

  final Map<int, int> clusterToSpeaker;
  final SpeakerProfileSet profiles;
}

/// 把单文件聚类结果对齐到会话级编号。
///
/// 匹配规则比单文件聚类更严（默认 0.75，聚类内部是 0.62）：跨文件误合并会让
/// 两个人共用编号，比多分出一个「说话人 3（推测）」更难纠正。一对一贪心
/// （先匹配分数最高的组合），避免一个质心被两个簇抢走。新簇按语音时长从多到
/// 少分配新编号：主导说话人先拿到更小的号。
class SessionSpeakerMatcher {
  const SessionSpeakerMatcher({
    this.matchThreshold = 0.70,
    this.maxSpeakers = 6,
  });

  final double matchThreshold;

  /// 会话内说话人上限（与 SpeakerClusterer.maxSpeakers 一致）。
  final int maxSpeakers;

  SpeakerMatchResult assign({
    required SpeakerProfileSet existing,
    required Map<int, List<double>> fileCentroids,
    required Map<int, int> clusterSpeechMs,
    required String deviceName,
  }) {
    final profiles = [...existing.profiles];
    final clusterToSpeaker = <int, int>{};

    final pairs = <_Pair>[];
    for (final entry in fileCentroids.entries) {
      final vector = _normalized(entry.value);
      if (vector == null) continue;
      for (final profile in profiles) {
        final score = _dot(vector, profile.centroid);
        pairs.add(_Pair(entry.key, profile.index, score));
      }
    }
    pairs.sort((a, b) => b.score.compareTo(a.score));

    final usedProfiles = <int>{};
    for (final pair in pairs) {
      if (pair.score <= matchThreshold) break;
      if (clusterToSpeaker.containsKey(pair.cluster) ||
          usedProfiles.contains(pair.profile)) {
        continue;
      }
      clusterToSpeaker[pair.cluster] = pair.profile;
      usedProfiles.add(pair.profile);
    }

    var nextIndex = profiles.isEmpty
        ? 0
        : profiles.map((p) => p.index).reduce(math.max) + 1;

    final unmatched = [
      for (final cluster in fileCentroids.keys)
        if (!clusterToSpeaker.containsKey(cluster) &&
            _normalized(fileCentroids[cluster]!) != null)
          cluster,
    ]..sort(
      (a, b) =>
          (clusterSpeechMs[b] ?? 0).compareTo(clusterSpeechMs[a] ?? 0),
    );

    final created = <int>{};
    for (final cluster in unmatched) {
      final vector = _normalized(fileCentroids[cluster]!)!;
      if (profiles.length < maxSpeakers) {
        clusterToSpeaker[cluster] = nextIndex;
        profiles.add(
          SpeakerProfile(
            index: nextIndex,
            centroid: vector,
            speechMs: clusterSpeechMs[cluster] ?? 0,
          ),
        );
        created.add(nextIndex);
        nextIndex++;
        continue;
      }
      // 已到上限：宁可贴到最相近的旧编号，也不无限新增「说话人 7/8」
      var bestIndex = profiles.first.index;
      var bestScore = -1.0;
      for (final profile in profiles) {
        final score = _dot(vector, profile.centroid);
        if (score > bestScore) {
          bestScore = score;
          bestIndex = profile.index;
        }
      }
      clusterToSpeaker[cluster] = bestIndex;
    }

    // 同一文件只在第一次处理时并入质心；重试/续跑只重新贴标签。
    if (!existing.contributors.contains(deviceName)) {
      final byIndex = {for (final p in profiles) p.index: p};
      final keys = clusterToSpeaker.keys.toList()..sort();
      for (final cluster in keys) {
        final index = clusterToSpeaker[cluster]!;
        if (created.contains(index)) continue; // 新建档案已用本文件初始化过
        final vector = _normalized(fileCentroids[cluster]!);
        if (vector == null) continue;
        final previous = byIndex[index];
        if (previous == null) continue;
        final merged = _blend(
          previous.centroid,
          previous.speechMs,
          vector,
          clusterSpeechMs[cluster] ?? 0,
        );
        final updated = SpeakerProfile(
          index: index,
          centroid: merged,
          speechMs: previous.speechMs + (clusterSpeechMs[cluster] ?? 0),
        );
        byIndex[index] = updated;
        final at = profiles.indexWhere((p) => p.index == index);
        if (at >= 0) profiles[at] = updated;
      }
    }

    profiles.sort((a, b) => a.index.compareTo(b.index));
    return SpeakerMatchResult(
      clusterToSpeaker: clusterToSpeaker,
      profiles: SpeakerProfileSet(
        session: existing.session,
        profiles: profiles,
        contributors: {...existing.contributors, deviceName},
      ),
    );
  }
}

class _Pair {
  const _Pair(this.cluster, this.profile, this.score);
  final int cluster;
  final int profile;
  final double score;
}

/// 会话档案的本地持久化：`<recordings>/_sessions/<session>.json`。
///
/// 与录音 meta 一样走「临时文件 + rename」的原子写；读失败一律退回空表，
/// 声纹表坏掉不应阻塞转写——退化为单文件编号仍然是「推测」语义。
class SpeakerProfileStore {
  SpeakerProfileStore({required this.root});

  final Directory root;

  static const dirName = '_sessions';

  File fileFor(String session) => File(
    '${root.path}/$dirName/${RecordingStore.dirNameFor(session)}.json',
  );

  Future<SpeakerProfileSet> load(String session) async {
    final file = fileFor(session);
    try {
      if (!await file.exists()) return SpeakerProfileSet.empty(session);
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return SpeakerProfileSet.empty(session);
      }
      return SpeakerProfileSet.fromJson(decoded);
    } on Object {
      return SpeakerProfileSet.empty(session);
    }
  }

  Future<void> save(SpeakerProfileSet set) async {
    final file = fileFor(set.session);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(set.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}

List<double>? _normalized(List<double> vector) {
  var norm = 0.0;
  for (final v in vector) {
    norm += v * v;
  }
  if (norm <= 1e-12) return null;
  final inv = 1.0 / math.sqrt(norm);
  return [for (final v in vector) v * inv];
}

List<double> _blend(List<double> a, int aMs, List<double> b, int bMs) {
  final n = math.min(a.length, b.length);
  if (n == 0) return b.isEmpty ? a : b;
  final wa = aMs <= 0 ? 1 : aMs;
  final wb = bMs <= 0 ? 1 : bMs;
  final total = wa + wb;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    out[i] = (a[i] * wa + b[i] * wb) / total;
  }
  return _normalized(out) ?? out;
}

double _dot(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}
