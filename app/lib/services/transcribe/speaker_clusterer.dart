/// 声纹聚类 —— 用 Campplus 句级 embedding 推算"有几个人"并给每句打簇号。
///
/// 为什么不用 pyannote 分割：`OfflineSpeakerDiarization` 在 iOS 真机上会卡住
/// （fp32/int8 都超过 9 分钟不返回，Mac 上 6.5s 正常）。Campplus 嵌入在 iOS 上
/// 已被唤醒词功能验证过，且 VAD 已经把语音切成了句级片段，直接对片段做嵌入
/// 再聚类，足够支撑"说话人 1/2（推测）"的产品语义。
///
/// 这是**推测**，不是身份识别：输出只有簇号与相似度，不关联任何真实身份。
library;

import 'dart:math' as math;

class SpeakerSample {
  const SpeakerSample({
    required this.id,
    required this.embedding,
    required this.durationMs,
  });

  final String id;
  final List<double> embedding;
  final int durationMs;
}

class SpeakerAssignment {
  const SpeakerAssignment({
    required this.id,
    required this.cluster,
    required this.confidence,
  });

  final String id;

  /// 0-based 簇号；-1 表示无法判断（太短/向量为空/小簇）。
  final int cluster;

  /// 与所属簇质心的余弦相似度（0~1）。
  final double confidence;

  bool get known => cluster >= 0;
}

class SpeakerClusterResult {
  const SpeakerClusterResult({
    required this.assignments,
    required this.speakerCount,
    required this.centroids,
  });

  final List<SpeakerAssignment> assignments;

  /// 有效说话人数（不含未知）。
  final int speakerCount;

  /// 簇号 → 归一化质心，供跨文件匹配用。
  final Map<int, List<double>> centroids;

  int get knownCount => assignments.where((a) => a.known).length;
}

class SpeakerClusterer {
  const SpeakerClusterer({
    this.threshold = 0.62,
    this.mergeThreshold = 0.70,
    this.minClusterSpeechMs = 2500,
    this.shortSliceMinClusterSpeechMs = 1200,
    this.shortSliceThresholdMs = 90000,
    this.maxSpeakers = 6,
  });

  /// 新样本与已有质心相似度达到这个值就归入该簇。
  final double threshold;

  /// 两个簇质心相似度达到这个值就合并（同一人不同片段）。
  final double mergeThreshold;

  /// 长文件总语音时长低于这个值的簇判为噪声，成员标未区分。
  final int minClusterSpeechMs;

  /// 短切片（总语音/切片 `<= 90s`）的小簇阈值（1200ms），避免 1.5s 简短回应被抹成未区分。
  final int shortSliceMinClusterSpeechMs;

  /// 短切片判定阈值（默认 90 秒）。
  final int shortSliceThresholdMs;

  final int maxSpeakers;

  SpeakerClusterResult cluster(
    List<SpeakerSample> samples, {
    int? audioDurationMs,
  }) {
    final normalized = <_NormSample>[];
    final unknowns = <int>{};
    for (var i = 0; i < samples.length; i++) {
      final v = _normalize(samples[i].embedding);
      if (v == null || samples[i].durationMs <= 0) {
        unknowns.add(i);
        continue;
      }
      normalized.add(_NormSample(i, v, samples[i].durationMs));
    }

    final clusters = <_Cluster>[];
    final assignment = <int, int>{}; // sample index → cluster index

    for (final sample in normalized) {
      if (clusters.isEmpty) {
        clusters.add(_Cluster(sample.vector, sample.durationMs));
        assignment[sample.index] = 0;
        continue;
      }
      var best = -1;
      var bestScore = -1.0;
      for (var c = 0; c < clusters.length; c++) {
        final score = _dot(sample.vector, clusters[c].centroid);
        if (score > bestScore) {
          bestScore = score;
          best = c;
        }
      }
      if (bestScore >= threshold || clusters.length >= maxSpeakers) {
        clusters[best].add(sample.vector, sample.durationMs);
        assignment[sample.index] = best;
      } else {
        clusters.add(_Cluster(sample.vector, sample.durationMs));
        assignment[sample.index] = clusters.length - 1;
      }
    }

    // 合并同一人的重复簇
    var merged = true;
    while (merged && clusters.length > 1) {
      merged = false;
      var bestA = -1;
      var bestB = -1;
      var bestScore = -1.0;
      for (var a = 0; a < clusters.length; a++) {
        for (var b = a + 1; b < clusters.length; b++) {
          final score = _dot(clusters[a].centroid, clusters[b].centroid);
          if (score > bestScore) {
            bestScore = score;
            bestA = a;
            bestB = b;
          }
        }
      }
      if (bestScore >= mergeThreshold) {
        clusters[bestA].absorb(clusters[bestB]);
        clusters.removeAt(bestB);
        for (final key in assignment.keys.toList()) {
          final v = assignment[key]!;
          if (v == bestB) {
            assignment[key] = bestA;
          } else if (v > bestB) {
            assignment[key] = v - 1;
          }
        }
        merged = true;
      }
    }

    // 小簇判噪声：短切片（<= 90s）自适应采用 1200ms，保留简短应答；长文件维持 2500ms 抗杂音。
    final totalClusterSpeechMs = clusters.fold<int>(
      0,
      (sum, c) => sum + c.totalMs,
    );
    final isShortSlice = audioDurationMs != null
        ? (audioDurationMs <= shortSliceThresholdMs &&
              totalClusterSpeechMs <= shortSliceThresholdMs)
        : (totalClusterSpeechMs <= shortSliceThresholdMs);
    final effectiveMinSpeechMs = isShortSlice
        ? math.min(minClusterSpeechMs, shortSliceMinClusterSpeechMs)
        : minClusterSpeechMs;
    final small = <int>{};
    for (var c = 0; c < clusters.length; c++) {
      if (clusters[c].totalMs < effectiveMinSpeechMs) small.add(c);
    }
    // 只剩一个簇时不判噪声（单人录音也可能话很少）
    if (clusters.length == 1) small.clear();

    // 按总语音时长排序重编号：说话最多的是「说话人 1」
    final order = List<int>.generate(clusters.length, (i) => i)
      ..sort((a, b) => clusters[b].totalMs.compareTo(clusters[a].totalMs));
    final renumber = <int, int>{};
    for (var i = 0; i < order.length; i++) {
      renumber[order[i]] = i;
    }

    final finalAssignments = <SpeakerAssignment>[];
    final centroids = <int, List<double>>{};
    for (var c = 0; c < clusters.length; c++) {
      if (!small.contains(c)) centroids[renumber[c]!] = clusters[c].centroid;
    }

    for (var i = 0; i < samples.length; i++) {
      if (unknowns.contains(i)) {
        finalAssignments.add(
          SpeakerAssignment(id: samples[i].id, cluster: -1, confidence: 0),
        );
        continue;
      }
      final c = assignment[i];
      if (c == null) {
        finalAssignments.add(
          SpeakerAssignment(id: samples[i].id, cluster: -1, confidence: 0),
        );
        continue;
      }
      final newId = renumber[c]!;
      if (small.contains(c)) {
        finalAssignments.add(
          SpeakerAssignment(id: samples[i].id, cluster: -1, confidence: 0),
        );
        continue;
      }
      final norm = _normalize(samples[i].embedding);
      final confidence = norm == null ? 0.0 : _dot(norm, clusters[c].centroid);
      finalAssignments.add(
        SpeakerAssignment(
          id: samples[i].id,
          cluster: newId,
          confidence: confidence.clamp(0.0, 1.0),
        ),
      );
    }

    return SpeakerClusterResult(
      assignments: finalAssignments,
      speakerCount: centroids.length,
      centroids: centroids,
    );
  }
}

class _NormSample {
  const _NormSample(this.index, this.vector, this.durationMs);
  final int index;
  final List<double> vector;
  final int durationMs;
}

class _Cluster {
  _Cluster(List<double> vector, int durationMs) {
    add(vector, durationMs);
  }

  List<double> _sum = List<double>.filled(0, 0);
  int totalMs = 0;

  void add(List<double> vector, int durationMs) {
    if (_sum.isEmpty) {
      _sum = List<double>.filled(vector.length, 0);
    }
    for (var i = 0; i < _sum.length && i < vector.length; i++) {
      _sum[i] += vector[i] * durationMs;
    }
    totalMs += durationMs;
  }

  void absorb(_Cluster other) {
    if (_sum.isEmpty) {
      _sum = List<double>.from(other._sum);
    } else {
      for (var i = 0; i < _sum.length && i < other._sum.length; i++) {
        _sum[i] += other._sum[i];
      }
    }
    totalMs += other.totalMs;
  }

  List<double> get centroid => _normalize(_sum) ?? List<double>.filled(_sum.length, 0);
}

List<double>? _normalize(List<double> vector) {
  var norm = 0.0;
  for (final v in vector) {
    norm += v * v;
  }
  if (norm <= 1e-12) return null;
  final inv = 1.0 / math.sqrt(norm);
  return [for (final v in vector) v * inv];
}

double _dot(List<double> a, List<double> b) {
  final n = a.length < b.length ? a.length : b.length;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}
