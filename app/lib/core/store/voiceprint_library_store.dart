/// 声纹人物库与 5 常用自动识别槽位（Compute-Bounded 自动匹配 + 无限手动人物库）。
///
/// 设计约束（NC #3）：
/// 1. 常用自动识别上限 5 个槽位（1..5），其中 1 号槽位永久锁定为「我的声音」（允许本机单独录制）；
/// 2. 端侧流水线自动匹配仅扫描「常用自动识别槽位（最多 5 人）」以控制算力（高分确认 >=0.72，次高区间 [0.48, 0.72) 作为弱提示）；
/// 3. 其余人数不设上限，存入「手动标记人物库」，支持跨设备 / 多场景多条样本合并归档到同一人物；
/// 4. 维护最近使用名称（最多 5 个）供快捷命名弹窗一键点选。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

class VoiceSampleRecord {
  const VoiceSampleRecord({
    required this.id,
    required this.embedding,
    required this.deviceLabel,
    required this.sceneLabel,
    required this.recordedAtMs,
    this.audioPath,
  });

  final String id;
  final List<double> embedding;
  final String deviceLabel;
  final String sceneLabel;
  final int recordedAtMs;

  /// 本机可回放的 WAV 路径（单独录音写入；旧数据可能为空）。
  final String? audioPath;

  Map<String, dynamic> toJson() => {
    'id': id,
    'v': [for (final x in embedding) double.parse(x.toStringAsFixed(6))],
    'dev': deviceLabel,
    'scn': sceneLabel,
    'at': recordedAtMs,
    if (audioPath != null && audioPath!.isNotEmpty) 'wav': audioPath,
  };

  factory VoiceSampleRecord.fromJson(Map<String, dynamic> j) =>
      VoiceSampleRecord(
        id: '${j['id'] ?? ''}',
        embedding: [
          for (final x in (j['v'] as List? ?? const []))
            if (x is num) x.toDouble(),
        ],
        deviceLabel: '${j['dev'] ?? '录音卡'}',
        sceneLabel: '${j['scn'] ?? '默认场景'}',
        recordedAtMs: (j['at'] as num?)?.toInt() ?? 0,
        audioPath: (j['wav'] as String?)?.trim().isEmpty == true
            ? null
            : j['wav'] as String?,
      );
}

class PersonVoiceProfile {
  const PersonVoiceProfile({
    required this.id,
    required this.name,
    this.isSelf = false,
    this.frequentSlot,
    this.samples = const [],
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String name;
  final bool isSelf;

  /// 1..5 为常用自动识别槽位；null 表示仅存人物库、不参与自动扫描以省算力。
  final int? frequentSlot;
  final List<VoiceSampleRecord> samples;
  final int createdAtMs;
  final int updatedAtMs;

  bool get isInFrequentSlot =>
      frequentSlot != null &&
      frequentSlot! >= 1 &&
      frequentSlot! <= VoiceprintLibraryStore.maxFrequentSlots;

  Set<String> get deviceLabels => {
    for (final s in samples)
      if (s.deviceLabel.trim().isNotEmpty) s.deviceLabel.trim(),
  };

  Set<String> get sceneLabels => {
    for (final s in samples)
      if (s.sceneLabel.trim().isNotEmpty) s.sceneLabel.trim(),
  };

  PersonVoiceProfile copyWith({
    String? name,
    bool? isSelf,
    int? frequentSlot,
    bool clearFrequentSlot = false,
    List<VoiceSampleRecord>? samples,
    int? updatedAtMs,
  }) => PersonVoiceProfile(
    id: id,
    name: name ?? this.name,
    isSelf: isSelf ?? this.isSelf,
    frequentSlot: clearFrequentSlot ? null : (frequentSlot ?? this.frequentSlot),
    samples: samples ?? this.samples,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'n': name,
    if (isSelf) 'self': true,
    if (frequentSlot != null) 'slot': frequentSlot,
    if (samples.isNotEmpty) 'sp': [for (final s in samples) s.toJson()],
    'cr': createdAtMs,
    'up': updatedAtMs,
  };

  factory PersonVoiceProfile.fromJson(Map<String, dynamic> j) =>
      PersonVoiceProfile(
        id: '${j['id'] ?? ''}',
        name: '${j['n'] ?? ''}',
        isSelf: j['self'] == true,
        frequentSlot: (j['slot'] as num?)?.toInt(),
        samples: [
          for (final s in (j['sp'] as List? ?? const []))
            if (s is Map<String, dynamic>) VoiceSampleRecord.fromJson(s),
        ],
        createdAtMs: (j['cr'] as num?)?.toInt() ?? 0,
        updatedAtMs: (j['up'] as num?)?.toInt() ?? 0,
      );
}

class VoiceprintMatchResult {
  const VoiceprintMatchResult({
    this.confirmed,
    this.fuzzyHint,
    this.similarity = 0,
    this.scannedSlots = 0,
  });

  final PersonVoiceProfile? confirmed;
  final PersonVoiceProfile? fuzzyHint;
  final double similarity;
  final int scannedSlots;
}

class VoiceprintLibraryStore extends ChangeNotifier {
  VoiceprintLibraryStore({DateTime Function()? now})
    : _now = now ?? DateTime.now {
    ensureSelfProfile(notify: false);
  }

  static const int maxFrequentSlots = 5;
  static const int maxRecentNames = 5;
  static const String selfPersonId = 'vp-self';
  static const String selfDefaultName = '我的声音';

  final DateTime Function() _now;
  final List<PersonVoiceProfile> _persons = [];
  final List<String> _recentNames = [];
  final Map<String, String> _fuzzyHints = {};
  int _seq = 1;

  List<PersonVoiceProfile> get allPersons => List.unmodifiable(_persons);

  List<PersonVoiceProfile> get frequentProfiles {
    final list = _persons.where((p) => p.isInFrequentSlot).toList()
      ..sort((a, b) => a.frequentSlot!.compareTo(b.frequentSlot!));
    return List.unmodifiable(list);
  }

  PersonVoiceProfile? profileAtSlot(int slot) {
    for (final p in _persons) {
      if (p.frequentSlot == slot) return p;
    }
    return null;
  }

  PersonVoiceProfile? get selfProfile => profileAtSlot(1);

  List<String> get recentNames => List.unmodifiable(_recentNames);

  int? get firstFreeFrequentSlot {
    final occupied = {
      for (final p in _persons)
        if (p.frequentSlot != null) p.frequentSlot!,
    };
    for (var slot = 2; slot <= maxFrequentSlots; slot++) {
      if (!occupied.contains(slot)) return slot;
    }
    return null;
  }

  void ensureSelfProfile({bool notify = true}) {
    final nowMs = _now().millisecondsSinceEpoch;
    final idx = _persons.indexWhere((p) => p.isSelf || p.frequentSlot == 1);
    if (idx < 0) {
      _persons.insert(
        0,
        PersonVoiceProfile(
          id: selfPersonId,
          name: selfDefaultName,
          isSelf: true,
          frequentSlot: 1,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        ),
      );
      if (notify) notifyListeners();
      return;
    }
    final cur = _persons[idx];
    if (!cur.isSelf || cur.frequentSlot != 1 || cur.name.trim().isEmpty) {
      _persons[idx] = cur.copyWith(
        name: cur.name.trim().isEmpty ? selfDefaultName : cur.name,
        isSelf: true,
        frequentSlot: 1,
        updatedAtMs: nowMs,
      );
      if (notify) notifyListeners();
    }
  }

  PersonVoiceProfile? findByName(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return null;
    for (final p in _persons) {
      if (p.name.trim() == clean) return p;
    }
    return null;
  }

  PersonVoiceProfile? findById(String id) {
    for (final p in _persons) {
      if (p.id == id) return p;
    }
    return null;
  }

  void recordRecentName(String name, {bool notify = true}) {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _recentNames.removeWhere((n) => n == clean);
    _recentNames.insert(0, clean);
    if (_recentNames.length > maxRecentNames) {
      _recentNames.removeRange(maxRecentNames, _recentNames.length);
    }
    if (notify) notifyListeners();
  }

  /// 添加/合并人物并可附带多设备/多场景声纹样本：
  /// 若同名人物已存在，直接合并样本到同一 Person，避免因录音卡/手机端侧环境不同拆分出重复档案。
  PersonVoiceProfile upsertPersonAndSample({
    required String name,
    List<double>? embedding,
    String deviceLabel = '本机麦克风',
    String sceneLabel = '默认场景',
    String? audioPath,
    int? explicitSlot,
    bool preferFrequentSlot = false,
  }) {
    ensureSelfProfile(notify: false);
    final nowMs = _now().millisecondsSinceEpoch;
    final clean = name.trim();
    if (clean.isEmpty) {
      return selfProfile!;
    }
    recordRecentName(clean, notify: false);

    int? resolvedSlot = explicitSlot;
    if (resolvedSlot == 1) {
      // 1 号槽位永久锁定给「我的声音」，合并样本到 selfProfile
      return recordSelfSample(
        embedding: embedding ?? const [],
        deviceLabel: deviceLabel,
        sceneLabel: sceneLabel,
        audioPath: audioPath,
      );
    }

    var idx = _persons.indexWhere((p) => p.name.trim() == clean);
    final hasSample = embedding != null && embedding.isNotEmpty;
    final newSample = hasSample
        ? VoiceSampleRecord(
            id: 'vs-$nowMs-${_seq++}',
            embedding: List<double>.unmodifiable(embedding),
            deviceLabel: deviceLabel,
            sceneLabel: sceneLabel,
            recordedAtMs: nowMs,
            audioPath: audioPath,
          )
        : null;

    if (idx < 0) {
      if (resolvedSlot == null && preferFrequentSlot) {
        resolvedSlot = firstFreeFrequentSlot;
      }
      if (resolvedSlot != null) {
        _vacateSlot(resolvedSlot);
      }
      final created = PersonVoiceProfile(
        id: 'vp-$nowMs-${_seq++}',
        name: clean,
        isSelf: false,
        frequentSlot: resolvedSlot,
        samples: newSample == null ? const [] : [newSample],
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
      );
      _persons.add(created);
      notifyListeners();
      return created;
    }

    final existing = _persons[idx];
    if (existing.isSelf) {
      return recordSelfSample(
        embedding: embedding ?? const [],
        deviceLabel: deviceLabel,
        sceneLabel: sceneLabel,
      );
    }
    if (resolvedSlot != null && existing.frequentSlot != resolvedSlot) {
      _vacateSlot(resolvedSlot);
    } else if (resolvedSlot == null &&
        preferFrequentSlot &&
        existing.frequentSlot == null) {
      resolvedSlot = firstFreeFrequentSlot;
    }
    final mergedSamples = [
      ...existing.samples,
      ?newSample,
    ];
    final updated = existing.copyWith(
      frequentSlot: resolvedSlot ?? existing.frequentSlot,
      samples: mergedSamples,
      updatedAtMs: nowMs,
    );
    _persons[idx] = updated;
    notifyListeners();
    return updated;
  }

  /// 为 1 号固定槽位「我的声音」录入或追加一条本机/设备声纹样本。
  PersonVoiceProfile recordSelfSample({
    required List<double> embedding,
    String deviceLabel = '本机麦克风',
    String sceneLabel = '近场本人录入',
    String? audioPath,
  }) {
    ensureSelfProfile(notify: false);
    final nowMs = _now().millisecondsSinceEpoch;
    final idx = _persons.indexWhere((p) => p.isSelf || p.frequentSlot == 1);
    final cur = _persons[idx];
    final nextSamples = [
      ...cur.samples,
      if (embedding.isNotEmpty)
        VoiceSampleRecord(
          id: 'vs-self-$nowMs-${_seq++}',
          embedding: List<double>.unmodifiable(embedding),
          deviceLabel: deviceLabel,
          sceneLabel: sceneLabel,
          recordedAtMs: nowMs,
          audioPath: audioPath,
        ),
    ];
    final updated = cur.copyWith(
      isSelf: true,
      frequentSlot: 1,
      samples: nextSamples,
      updatedAtMs: nowMs,
    );
    _persons[idx] = updated;
    notifyListeners();
    return updated;
  }

  /// 删除某人物下的单条声纹样本；返回被删样本（便于调用方清理本地 WAV）。
  VoiceSampleRecord? removeSample({
    required String personId,
    required String sampleId,
  }) {
    final idx = _persons.indexWhere((p) => p.id == personId);
    if (idx < 0) return null;
    final cur = _persons[idx];
    VoiceSampleRecord? removed;
    final next = <VoiceSampleRecord>[];
    for (final s in cur.samples) {
      if (s.id == sampleId) {
        removed = s;
      } else {
        next.add(s);
      }
    }
    if (removed == null) return null;
    _persons[idx] = cur.copyWith(
      samples: next,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    notifyListeners();
    return removed;
  }

  void _vacateSlot(int slot) {
    if (slot <= 1 || slot > maxFrequentSlots) return;
    for (var i = 0; i < _persons.length; i++) {
      if (_persons[i].frequentSlot == slot && !_persons[i].isSelf) {
        _persons[i] = _persons[i].copyWith(clearFrequentSlot: true);
      }
    }
  }

  /// 将人物库成员设入常用自动识别槽位（2..5）；若常用槽位已满且未指定槽位返回 false。
  bool promoteToFrequentSlot(String personId, {int? targetSlot}) {
    final idx = _persons.indexWhere((p) => p.id == personId);
    if (idx < 0) return false;
    final p = _persons[idx];
    if (p.isSelf) return true;
    final slot = targetSlot ?? firstFreeFrequentSlot;
    if (slot == null || slot <= 1 || slot > maxFrequentSlots) {
      return false;
    }
    _vacateSlot(slot);
    _persons[idx] = p.copyWith(
      frequentSlot: slot,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    notifyListeners();
    return true;
  }

  /// 从 2..5 号常用槽位移除（保留在人物库中转为仅手动标记，不删除历史样本）。
  bool demoteFromFrequentSlot(String personId) {
    final idx = _persons.indexWhere((p) => p.id == personId);
    if (idx < 0) return false;
    final p = _persons[idx];
    if (p.isSelf || p.frequentSlot == 1) return false;
    _persons[idx] = p.copyWith(
      clearFrequentSlot: true,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    notifyListeners();
    return true;
  }

  /// 删除人物库成员（1 号「我的声音」不可删除，只能清空其样本重录）。
  bool deletePerson(String personId) {
    final idx = _persons.indexWhere((p) => p.id == personId);
    if (idx < 0) return false;
    if (_persons[idx].isSelf) return false;
    _persons.removeAt(idx);
    notifyListeners();
    return true;
  }

  bool clearSelfSamples() {
    final idx = _persons.indexWhere((p) => p.isSelf);
    if (idx < 0) return false;
    _persons[idx] = _persons[idx].copyWith(
      samples: const [],
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    notifyListeners();
    return true;
  }

  /// 仅在常用自动识别槽位（1..5）内比对向量，绝不遍历无限人物库（控算力）。
  VoiceprintMatchResult matchFrequentOnly(
    List<double> embedding, {
    double confirmThreshold = 0.72,
    double hintThreshold = 0.48,
  }) {
    if (embedding.isEmpty) return const VoiceprintMatchResult();
    final activeSlots = frequentProfiles;
    PersonVoiceProfile? bestProfile;
    var bestScore = 0.0;
    var scanned = 0;

    for (final profile in activeSlots) {
      if (profile.samples.isEmpty) continue;
      scanned++;
      for (final sample in profile.samples) {
        final score = cosineSimilarity(embedding, sample.embedding);
        if (score > bestScore) {
          bestScore = score;
          bestProfile = profile;
        }
      }
    }

    if (bestProfile == null) {
      return VoiceprintMatchResult(scannedSlots: scanned);
    }
    if (bestScore >= confirmThreshold) {
      return VoiceprintMatchResult(
        confirmed: bestProfile,
        similarity: bestScore,
        scannedSlots: scanned,
      );
    }
    if (bestScore >= hintThreshold) {
      return VoiceprintMatchResult(
        fuzzyHint: bestProfile,
        similarity: bestScore,
        scannedSlots: scanned,
      );
    }
    return VoiceprintMatchResult(
      similarity: bestScore,
      scannedSlots: scanned,
    );
  }

  static double cosineSimilarity(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    if (n == 0) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < n; i++) {
      final va = a[i];
      final vb = b[i];
      dot += va * vb;
      normA += va * va;
      normB += vb * vb;
    }
    if (normA <= 0 || normB <= 0) return 0;
    return (dot / (math.sqrt(normA) * math.sqrt(normB))).clamp(-1.0, 1.0);
  }

  void recordFuzzyHint({
    required String session,
    required String speakerSlot,
    required String candidateName,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    final cleanName = candidateName.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty || cleanName.isEmpty) return;
    _fuzzyHints['$cleanSes::$cleanSlot'] = cleanName;
    notifyListeners();
  }

  String? fuzzyHintFor({
    required String session,
    required String speakerSlot,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty) return null;
    return _fuzzyHints['$cleanSes::$cleanSlot'];
  }

  Map<String, dynamic> exportJson() => {
    'v': 1,
    'persons': [for (final p in _persons) p.toJson()],
    'recent': _recentNames,
    if (_fuzzyHints.isNotEmpty) 'hints': _fuzzyHints,
  };

  void restoreJson(Map<String, dynamic>? raw) {
    _persons.clear();
    _recentNames.clear();
    _fuzzyHints.clear();
    if (raw != null) {
      final list = raw['persons'];
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            _persons.add(PersonVoiceProfile.fromJson(item));
          }
        }
      }
      final rec = raw['recent'];
      if (rec is List) {
        for (final item in rec) {
          final clean = '$item'.trim();
          if (clean.isNotEmpty &&
              !_recentNames.contains(clean) &&
              _recentNames.length < maxRecentNames) {
            _recentNames.add(clean);
          }
        }
      }
      final hints = raw['hints'];
      if (hints is Map) {
        for (final e in hints.entries) {
          final k = '${e.key}'.trim();
          final v = '${e.value}'.trim();
          if (k.isNotEmpty && v.isNotEmpty) {
            _fuzzyHints[k] = v;
          }
        }
      }
    }
    ensureSelfProfile(notify: false);
    notifyListeners();
  }

  String encodeJsonString() => jsonEncode(exportJson());

  void restoreFromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      ensureSelfProfile(notify: false);
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        restoreJson(decoded);
      }
    } catch (_) {
      ensureSelfProfile(notify: false);
    }
  }
}
