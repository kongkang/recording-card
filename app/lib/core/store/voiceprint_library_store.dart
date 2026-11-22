/// 声纹人物库与多设备多质心自动识别引擎（全库毫秒比对 + 5 常用核心置顶）。
///
/// 能力与边界：
/// 1. 常用置顶 5 槽位（1 号位永久锁定「我的声音」），优先写入云端语义名册提示词；
/// 2. 端侧流水线自动匹配全量已建档人物库（[matchAllProfiles]），按硬件通道维护
///    多质心（录音卡 / Apple Watch / 手机本机 / 电话窄带 / 第三方录音笔），结合
///    设备通道均值中心化、AS-Norm 相对 Z-score、Top-2 Margin 与语音时长质量加权；
/// 3. 保留 [matchFrequentOnly] 兼容既有用例对 5 槽位算力边界的显式校验；
/// 4. 维护待确认说话人猜测（[SpeakerCandidateSuggestion]）、单段防串音排斥集
///    （[_detachedSlots]）及最近使用名称（最多 5 个）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 硬件录音通道归一化工具：避免把 `.APM`/`.WAV` 文件名直接当成设备通道，
/// 统一把采集来源归类到稳定的声学信道（用于多质心隔离与通道均值剥离）。
class VoiceChannel {
  const VoiceChannel._();

  static const String cardBle = 'card_ble';
  static const String watch = 'watch';
  static const String phoneMic = 'phone_mic';
  static const String narrowband = 'narrowband';
  static const String extRecorder = 'ext_recorder';
  static const String fallback = 'default';

  static final RegExp _rawExtRe = RegExp(
    r'\.(?:apm|wav|mp3|m4a|aac|opus|ogg)$',
    caseSensitive: false,
  );
  static final RegExp _rawPrefixRe = RegExp(
    r'^(?:LIVE_PHONE_|LIVE_|OMI_RING_|REC[_-]|EXT_|GETNOTE_|R\d{4,}|20\d{6,})',
    caseSensitive: false,
  );

  static bool looksLikeRawFileName(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return true;
    return _rawExtRe.hasMatch(s) || _rawPrefixRe.hasMatch(s);
  }

  static String normalizeChannelKey(
    String? rawLabel, {
    String? sourceLane,
    String? sceneLabel,
  }) {
    final s = (rawLabel ?? '').trim();
    final lower = s.toLowerCase();
    final scene = (sceneLabel ?? '').trim().toLowerCase();
    final lane = (sourceLane ?? '').trim().toLowerCase();

    if (lower.startsWith('live_phone_') ||
        lane == 'phone' ||
        lower.contains('本机') ||
        lower.contains('手机') ||
        lower.contains('iphone') ||
        lower.contains('android') ||
        lower.contains('mac')) {
      if (lower.contains('电话') ||
          lower.contains('窄带') ||
          lower.contains('免提') ||
          lower.contains('外放') ||
          scene.contains('电话') ||
          scene.contains('回访') ||
          scene.contains('来电')) {
        return narrowband;
      }
      return phoneMic;
    }
    if (lower.contains('电话') ||
        lower.contains('窄带') ||
        lower.contains('通话') ||
        lower.contains('免提') ||
        lower.contains('外放') ||
        lower.contains('narrowband') ||
        scene.contains('电话') ||
        scene.contains('回访') ||
        scene.contains('来电')) {
      return narrowband;
    }
    if (lane == 'watch' ||
        lower.contains('watch') ||
        lower.contains('手表')) {
      return watch;
    }
    if (lower.contains('omi') ||
        lower.contains('讯飞') ||
        lower.contains('iflytek') ||
        lower.contains('飞书') ||
        lower.contains('feishu') ||
        lower.contains('d3200') ||
        lower.contains('getnote') ||
        lower.contains('get 笔记') ||
        lower.contains('得到') ||
        lower.contains('gsc10') ||
        lower.contains('plaud') ||
        lower.startsWith('ext_') ||
        lower.startsWith('getnote_')) {
      return extRecorder;
    }
    if (lane == 'ble' ||
        lower.contains('录音卡') ||
        lower.contains('点一机') ||
        lower.contains('蓝牙') ||
        lower.contains('键盘') ||
        lower.contains('dyj') ||
        lower.startsWith('live_') ||
        _rawExtRe.hasMatch(lower)) {
      return cardBle;
    }
    return fallback;
  }

  static String readableDeviceLabel(
    String? rawLabel, {
    String? sourceLane,
    String? sceneLabel,
  }) {
    final s = (rawLabel ?? '').trim();
    if (s.isNotEmpty && !looksLikeRawFileName(s)) {
      return s;
    }
    final key = normalizeChannelKey(
      s,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    return switch (key) {
      watch => 'Apple Watch',
      phoneMic => '手机本机',
      narrowband => '电话/窄带',
      extRecorder => '外部录音设备',
      cardBle => '录音卡',
      _ => '录音卡',
    };
  }
}

enum SpeakerSuggestionSource { voiceprint, semantic, joint }

class SpeakerCandidateSuggestion {
  const SpeakerCandidateSuggestion({
    required this.session,
    required this.speakerSlot,
    required this.candidateName,
    required this.confidence,
    required this.source,
    required this.reason,
    this.acousticScore = 0,
    this.semanticScore = 0,
    this.margin = 0,
    this.channelKey = VoiceChannel.fallback,
    this.deviceLabel = '录音卡',
    this.updatedAtMs = 0,
  });

  final String session;
  final String speakerSlot;
  final String candidateName;
  final double confidence;
  final SpeakerSuggestionSource source;
  final String reason;
  final double acousticScore;
  final double semanticScore;
  final double margin;
  final String channelKey;
  final String deviceLabel;
  final int updatedAtMs;

  String get key => '$session::$speakerSlot';

  Map<String, dynamic> toJson() => {
    'ses': session,
    'sl': speakerSlot,
    'nm': candidateName,
    'cf': double.parse(confidence.toStringAsFixed(3)),
    'src': source.name,
    'rs': reason,
    if (acousticScore > 0)
      'as': double.parse(acousticScore.toStringAsFixed(3)),
    if (semanticScore > 0)
      'ss': double.parse(semanticScore.toStringAsFixed(3)),
    if (margin > 0) 'mg': double.parse(margin.toStringAsFixed(3)),
    if (channelKey != VoiceChannel.fallback) 'ch': channelKey,
    if (deviceLabel.isNotEmpty) 'dev': deviceLabel,
    if (updatedAtMs > 0) 'at': updatedAtMs,
  };

  factory SpeakerCandidateSuggestion.fromJson(Map<String, dynamic> j) =>
      SpeakerCandidateSuggestion(
        session: '${j['ses'] ?? ''}',
        speakerSlot: '${j['sl'] ?? ''}',
        candidateName: '${j['nm'] ?? ''}',
        confidence: (j['cf'] as num?)?.toDouble() ?? 0.5,
        source: SpeakerSuggestionSource.values.firstWhere(
          (e) => e.name == j['src'],
          orElse: () => SpeakerSuggestionSource.voiceprint,
        ),
        reason: '${j['rs'] ?? ''}',
        acousticScore: (j['as'] as num?)?.toDouble() ?? 0,
        semanticScore: (j['ss'] as num?)?.toDouble() ?? 0,
        margin: (j['mg'] as num?)?.toDouble() ?? 0,
        channelKey: '${j['ch'] ?? VoiceChannel.fallback}',
        deviceLabel: '${j['dev'] ?? '录音卡'}',
        updatedAtMs: (j['at'] as num?)?.toInt() ?? 0,
      );
}

class ChannelAcousticStats {
  const ChannelAcousticStats({required this.mean, required this.count});

  final List<double> mean;
  final int count;

  Map<String, dynamic> toJson() => {
    'c': count,
    'm': [for (final x in mean) double.parse(x.toStringAsFixed(6))],
  };

  factory ChannelAcousticStats.fromJson(Map<String, dynamic> j) =>
      ChannelAcousticStats(
        count: (j['c'] as num?)?.toInt() ?? 0,
        mean: [
          for (final x in (j['m'] as List? ?? const []))
            if (x is num) x.toDouble(),
        ],
      );
}

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

  String get channelKey => VoiceChannel.normalizeChannelKey(
    deviceLabel,
    sceneLabel: sceneLabel,
  );

  VoiceSampleRecord copyWith({
    List<double>? embedding,
    String? deviceLabel,
    String? sceneLabel,
    int? recordedAtMs,
    String? audioPath,
  }) => VoiceSampleRecord(
    id: id,
    embedding: embedding ?? this.embedding,
    deviceLabel: deviceLabel ?? this.deviceLabel,
    sceneLabel: sceneLabel ?? this.sceneLabel,
    recordedAtMs: recordedAtMs ?? this.recordedAtMs,
    audioPath: audioPath ?? this.audioPath,
  );

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

  /// 1..5 为常用置顶槽位；null 表示仅存人物库（同样参与 [matchAllProfiles] 端侧全库扫描）。
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

  Set<String> get channelKeys => {
    for (final s in samples) s.channelKey,
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

class VoiceprintCandidateScore {
  const VoiceprintCandidateScore({
    required this.profile,
    required this.rawScore,
    required this.calibratedScore,
    required this.effectiveScore,
    required this.asNormZ,
    required this.sameChannel,
    this.matchedDeviceLabel = '',
  });

  final PersonVoiceProfile profile;
  final double rawScore;
  final double calibratedScore;
  final double effectiveScore;
  final double asNormZ;
  final bool sameChannel;
  final String matchedDeviceLabel;
}

class VoiceprintMatchEvaluation {
  const VoiceprintMatchEvaluation({
    this.confirmed,
    this.fuzzyHint,
    this.bestScore = 0,
    this.secondBestScore = 0,
    this.margin = 0,
    this.asNormZ = 0,
    this.sameChannel = false,
    this.channelKey = VoiceChannel.fallback,
    this.scannedPersons = 0,
    this.candidates = const [],
  });

  final PersonVoiceProfile? confirmed;
  final PersonVoiceProfile? fuzzyHint;
  final double bestScore;
  final double secondBestScore;
  final double margin;
  final double asNormZ;
  final bool sameChannel;
  final String channelKey;
  final int scannedPersons;
  final List<VoiceprintCandidateScore> candidates;

  VoiceprintCandidateScore? scoreForName(String name) {
    final clean = name.trim();
    for (final c in candidates) {
      if (c.profile.name.trim() == clean) return c;
    }
    return null;
  }
}

class VoiceprintLibraryStore extends ChangeNotifier {
  VoiceprintLibraryStore({DateTime Function()? now})
    : _now = now ?? DateTime.now {
    ensureSelfProfile(notify: false);
  }

  static const int maxFrequentSlots = 5;
  static const int maxRecentNames = 5;
  static const int _maxDialogueSamplesPerChannel = 4;
  static const String selfPersonId = 'vp-self';
  static const String selfDefaultName = '我的声音';

  final DateTime Function() _now;
  final List<PersonVoiceProfile> _persons = [];
  final List<String> _recentNames = [];
  final Map<String, String> _fuzzyHints = {};
  final Map<String, SpeakerCandidateSuggestion> _suggestions = {};
  final Map<String, ChannelAcousticStats> _channelMeans = {};
  final Set<String> _detachedSlots = {};
  final Set<String> _dismissedSuggestions = {};
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

  /// 供云端清洗 / 总结附带的轻量人物名册（仅纯文本称呼，绝不传声纹向量）。
  List<String> preferredRosterNames({int limit = 12}) {
    final out = <String>[];
    final seen = <String>{};
    void addName(String raw) {
      final clean = raw.trim();
      if (clean.isEmpty || clean == selfDefaultName || seen.contains(clean)) {
        return;
      }
      seen.add(clean);
      out.add(clean);
    }

    for (final p in frequentProfiles) {
      addName(p.name);
      if (out.length >= limit) return out;
    }
    for (final name in _recentNames) {
      addName(name);
      if (out.length >= limit) return out;
    }
    for (final p in _persons) {
      addName(p.name);
      if (out.length >= limit) return out;
    }
    return out;
  }

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

  /// 记录各硬件通道的滑动全局均值，用于跨设备时剥离麦克风频响底色。
  void observeChannelEmbedding(
    List<double> embedding, {
    String? deviceLabel,
    String? sourceLane,
    String? sceneLabel,
    bool notify = false,
  }) {
    final unit = _normalize(embedding);
    if (unit == null) return;
    final channelKey = VoiceChannel.normalizeChannelKey(
      deviceLabel,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    final prev = _channelMeans[channelKey];
    if (prev == null || prev.mean.length != unit.length) {
      _channelMeans[channelKey] = ChannelAcousticStats(mean: unit, count: 1);
    } else {
      final weight = math.min(prev.count, 50);
      final blended = List<double>.filled(unit.length, 0);
      for (var i = 0; i < unit.length; i++) {
        blended[i] = (prev.mean[i] * weight + unit[i]) / (weight + 1);
      }
      _channelMeans[channelKey] = ChannelAcousticStats(
        mean: _normalize(blended) ?? prev.mean,
        count: prev.count + 1,
      );
    }
    if (notify) notifyListeners();
  }

  ChannelAcousticStats? channelStatsFor(String channelKey) =>
      _channelMeans[channelKey];

  /// 添加/合并人物并按硬件通道维护多质心档案：
  /// - 不同设备/场景通道（录音卡 / Apple Watch / 手机本机 / 电话窄带）独立留存子质心；
  /// - 同通道的对话自动样本保留多原型并在达上限后用 EMA 平滑防漂移；
  /// - 手动单独录制的带 `audioPath` 样本永不覆盖。
  PersonVoiceProfile upsertPersonAndSample({
    required String name,
    List<double>? embedding,
    String deviceLabel = '本机麦克风',
    String sceneLabel = '默认场景',
    String? sourceLane,
    String? audioPath,
    int? explicitSlot,
    bool preferFrequentSlot = false,
    bool notify = true,
  }) {
    ensureSelfProfile(notify: false);
    final nowMs = _now().millisecondsSinceEpoch;
    final clean = name.trim();
    if (clean.isEmpty) {
      return selfProfile!;
    }
    recordRecentName(clean, notify: false);

    final normalizedDevice = VoiceChannel.readableDeviceLabel(
      deviceLabel,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    final channelKey = VoiceChannel.normalizeChannelKey(
      normalizedDevice,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );

    int? resolvedSlot = explicitSlot;
    if (resolvedSlot == 1) {
      return recordSelfSample(
        embedding: embedding ?? const [],
        deviceLabel: normalizedDevice,
        sceneLabel: sceneLabel,
        sourceLane: sourceLane,
        audioPath: audioPath,
        notify: notify,
      );
    }

    var idx = _persons.indexWhere((p) => p.name.trim() == clean);
    final hasSample = embedding != null && embedding.isNotEmpty;
    if (hasSample) {
      observeChannelEmbedding(
        embedding,
        deviceLabel: normalizedDevice,
        sourceLane: sourceLane,
        sceneLabel: sceneLabel,
        notify: false,
      );
    }
    final newSample = hasSample
        ? VoiceSampleRecord(
            id: 'vs-$nowMs-${_seq++}',
            embedding: List<double>.unmodifiable(embedding),
            deviceLabel: normalizedDevice,
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
      if (notify) notifyListeners();
      return created;
    }

    final existing = _persons[idx];
    if (existing.isSelf) {
      return recordSelfSample(
        embedding: embedding ?? const [],
        deviceLabel: normalizedDevice,
        sceneLabel: sceneLabel,
        sourceLane: sourceLane,
        audioPath: audioPath,
        notify: notify,
      );
    }
    if (resolvedSlot != null && existing.frequentSlot != resolvedSlot) {
      _vacateSlot(resolvedSlot);
    } else if (resolvedSlot == null &&
        preferFrequentSlot &&
        existing.frequentSlot == null) {
      resolvedSlot = firstFreeFrequentSlot;
    }

    final mergedSamples = _mergeChannelSamples(
      existing.samples,
      newSample,
      channelKey: channelKey,
    );
    final updated = existing.copyWith(
      frequentSlot: resolvedSlot ?? existing.frequentSlot,
      samples: mergedSamples,
      updatedAtMs: nowMs,
    );
    _persons[idx] = updated;
    if (notify) notifyListeners();
    return updated;
  }

  List<VoiceSampleRecord> _mergeChannelSamples(
    List<VoiceSampleRecord> existingSamples,
    VoiceSampleRecord? incoming, {
    required String channelKey,
  }) {
    if (incoming == null) return existingSamples;
    final out = [...existingSamples];
    // 手动带本地 WAV 录音的样本始终独立保留
    if (incoming.audioPath != null && incoming.audioPath!.isNotEmpty) {
      out.add(incoming);
      return out;
    }
    final channelDialogueIndices = <int>[];
    for (var i = 0; i < out.length; i++) {
      final s = out[i];
      if ((s.audioPath == null || s.audioPath!.isEmpty) &&
          s.channelKey == channelKey) {
        channelDialogueIndices.add(i);
      }
    }
    if (channelDialogueIndices.length < 3) {
      out.add(incoming);
      return out;
    }

    // 同一通道已有 >= 3 条对话质心：若高相似 (>= 0.78) 做加权 EMA 防漂移；
    // 否则在达到上限时替换同通道最旧对话样本，保持多环境子原型多样性
    var bestIdx = -1;
    var bestSim = -1.0;
    for (final i in channelDialogueIndices) {
      final sim = cosineSimilarity(out[i].embedding, incoming.embedding);
      if (sim > bestSim) {
        bestSim = sim;
        bestIdx = i;
      }
    }
    if (bestIdx >= 0 && bestSim >= 0.78) {
      final oldVec = _normalize(out[bestIdx].embedding);
      final newVec = _normalize(incoming.embedding);
      if (oldVec != null && newVec != null && oldVec.length == newVec.length) {
        final blended = [
          for (var k = 0; k < oldVec.length; k++)
            oldVec[k] * 0.75 + newVec[k] * 0.25,
        ];
        out[bestIdx] = out[bestIdx].copyWith(
          embedding: List<double>.unmodifiable(_normalize(blended) ?? newVec),
          sceneLabel: incoming.sceneLabel,
          recordedAtMs: incoming.recordedAtMs,
        );
        return out;
      }
    }
    if (channelDialogueIndices.length >= _maxDialogueSamplesPerChannel) {
      var oldestIdx = channelDialogueIndices.first;
      for (final i in channelDialogueIndices) {
        if (out[i].recordedAtMs < out[oldestIdx].recordedAtMs) {
          oldestIdx = i;
        }
      }
      out[oldestIdx] = incoming;
      return out;
    }
    out.add(incoming);
    return out;
  }

  /// 为 1 号固定槽位「我的声音」录入或追加一条本机/设备声纹样本。
  PersonVoiceProfile recordSelfSample({
    required List<double> embedding,
    String deviceLabel = '本机麦克风',
    String sceneLabel = '近场本人录入',
    String? sourceLane,
    String? audioPath,
    bool notify = true,
  }) {
    ensureSelfProfile(notify: false);
    final nowMs = _now().millisecondsSinceEpoch;
    final idx = _persons.indexWhere((p) => p.isSelf || p.frequentSlot == 1);
    final cur = _persons[idx];
    final normalizedDevice = VoiceChannel.readableDeviceLabel(
      deviceLabel,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    final channelKey = VoiceChannel.normalizeChannelKey(
      normalizedDevice,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    if (embedding.isNotEmpty) {
      observeChannelEmbedding(
        embedding,
        deviceLabel: normalizedDevice,
        sourceLane: sourceLane,
        sceneLabel: sceneLabel,
        notify: false,
      );
    }
    final incoming = embedding.isNotEmpty
        ? VoiceSampleRecord(
            id: 'vs-self-$nowMs-${_seq++}',
            embedding: List<double>.unmodifiable(embedding),
            deviceLabel: normalizedDevice,
            sceneLabel: sceneLabel,
            recordedAtMs: nowMs,
            audioPath: audioPath,
          )
        : null;
    final nextSamples = _mergeChannelSamples(
      cur.samples,
      incoming,
      channelKey: channelKey,
    );
    final updated = cur.copyWith(
      isSelf: true,
      frequentSlot: 1,
      samples: nextSamples,
      updatedAtMs: nowMs,
    );
    _persons[idx] = updated;
    if (notify) notifyListeners();
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

  /// 从 2..5 号常用槽位移除（保留在人物库中转为普通人物档案，不删除历史样本）。
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
    final removedName = _persons[idx].name.trim();
    _persons.removeAt(idx);
    _suggestions.removeWhere((_, s) => s.candidateName == removedName);
    _fuzzyHints.removeWhere((_, v) => v == removedName);
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

  /// 仅在常用自动识别槽位（1..5）内比对向量（保留兼容接口与既有测试契约）。
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

  /// 全量人物库多设备多质心 + 通道均值中心化 + AS-Norm + Margin 综合评估。
  VoiceprintMatchEvaluation matchAllProfiles(
    List<double> embedding, {
    String? deviceLabel,
    String? sourceLane,
    String? sceneLabel,
    int speechMs = 5000,
    List<List<double>> sessionPeerCentroids = const [],
    Set<String> excludedPersonNames = const {},
  }) {
    final queryUnit = _normalize(embedding);
    final queryChannelKey = VoiceChannel.normalizeChannelKey(
      deviceLabel,
      sourceLane: sourceLane,
      sceneLabel: sceneLabel,
    );
    if (queryUnit == null) {
      return VoiceprintMatchEvaluation(channelKey: queryChannelKey);
    }

    final queryCal = _channelCalibrated(queryUnit, queryChannelKey);
    final queryHasCal = _hasChannelStats(queryChannelKey, queryUnit.length);

    final rawScored = <({
      PersonVoiceProfile profile,
      double rawScore,
      double calibratedScore,
      double effectiveScore,
      bool sameChannel,
      String matchedDeviceLabel,
    })>[];

    for (final profile in _persons) {
      if (profile.samples.isEmpty) continue;
      if (excludedPersonNames.contains(profile.name.trim())) continue;

      var bestEffective = -1.0;
      var bestRaw = -1.0;
      var bestCal = -1.0;
      var bestSameChan = false;
      var bestDev = '';
      var sameChannelConsistentCount = 0;

      for (final sample in profile.samples) {
        final sUnit = _normalize(sample.embedding);
        if (sUnit == null) continue;
        final sChan = sample.channelKey;
        final sameChan =
            sChan == queryChannelKey && queryChannelKey != VoiceChannel.fallback;
        final rawCos = _dot(queryUnit, sUnit).clamp(-1.0, 1.0);

        final sCal = _channelCalibrated(sUnit, sChan);
        final sHasCal = _hasChannelStats(sChan, sUnit.length);
        final calCos = _dot(queryCal, sCal).clamp(-1.0, 1.0);

        final double blended;
        if (queryHasCal && (sameChan || sHasCal)) {
          blended = (0.25 * rawCos + 0.75 * calCos).clamp(-1.0, 1.0);
        } else if (queryHasCal || sHasCal) {
          blended = (0.40 * rawCos + 0.60 * calCos).clamp(-1.0, 1.0);
        } else {
          blended = rawCos;
        }

        if (sameChan && blended >= 0.55) {
          sameChannelConsistentCount++;
        }

        if (blended > bestEffective) {
          bestEffective = blended;
          bestRaw = rawCos;
          bestCal = calCos;
          bestSameChan = sameChan;
          bestDev = sample.deviceLabel;
        }
      }

      if (bestEffective <= -1.0) continue;
      // 同通道多样本一致命中时给微小稳定性加分（上限 +0.02），防止单条异常向量抢跑
      final stabilityBonus =
          sameChannelConsistentCount >= 2 ? 0.015 : 0.0;
      final scoreWithStability = (bestEffective + stabilityBonus).clamp(
        -1.0,
        1.0,
      );
      rawScored.add((
        profile: profile,
        rawScore: bestRaw,
        calibratedScore: bestCal,
        effectiveScore: scoreWithStability,
        sameChannel: bestSameChan,
        matchedDeviceLabel: bestDev,
      ));
    }

    if (rawScored.isEmpty) {
      return VoiceprintMatchEvaluation(channelKey: queryChannelKey);
    }

    rawScored.sort((a, b) => b.effectiveScore.compareTo(a.effectiveScore));

    final peerCohortScores = <double>[];
    for (final peer in sessionPeerCentroids) {
      final pUnit = _normalize(peer);
      if (pUnit == null) continue;
      final pCal = _channelCalibrated(pUnit, queryChannelKey);
      final score = queryHasCal
          ? (0.25 * _dot(queryUnit, pUnit) + 0.75 * _dot(queryCal, pCal))
          : _dot(queryUnit, pUnit);
      peerCohortScores.add(score.clamp(-1.0, 1.0));
    }

    // 为每个候选人计算相对于其余人物与同场说话人 cohort 的 AS-Norm Z-score
    final candidates = <VoiceprintCandidateScore>[];
    for (var i = 0; i < rawScored.length; i++) {
      final cur = rawScored[i];
      final impostors = <double>[
        for (var j = 0; j < rawScored.length; j++)
          if (j != i) rawScored[j].effectiveScore,
        ...peerCohortScores,
      ]..sort((a, b) => b.compareTo(a));

      final asNormZ = _computeAsNormZ(cur.effectiveScore, impostors);
      candidates.add(
        VoiceprintCandidateScore(
          profile: cur.profile,
          rawScore: cur.rawScore,
          calibratedScore: cur.calibratedScore,
          effectiveScore: cur.effectiveScore,
          asNormZ: asNormZ,
          sameChannel: cur.sameChannel,
          matchedDeviceLabel: cur.matchedDeviceLabel,
        ),
      );
    }

    final best = candidates.first;
    final secondBestScore = candidates.length > 1
        ? candidates[1].effectiveScore
        : 0.0;
    final otherPersonCount = candidates.length - 1;
    final hasCompetition =
        otherPersonCount >= 1 || peerCohortScores.isNotEmpty;
    final margin = otherPersonCount >= 1
        ? (best.effectiveScore - secondBestScore)
        : (peerCohortScores.isNotEmpty
              ? best.effectiveScore -
                    peerCohortScores.reduce(math.max)
              : best.effectiveScore);
    final totalCohortCount = otherPersonCount + peerCohortScores.length;

    PersonVoiceProfile? confirmed;
    PersonVoiceProfile? fuzzyHint;

    if (speechMs < 1200) {
      // 超短片断仅给提示，不做纯声学自动直认
      if (best.effectiveScore >= 0.55) {
        fuzzyHint = best.profile;
      }
    } else if (speechMs < 2000) {
      if (best.effectiveScore >= 0.84 && (!hasCompetition || margin >= 0.08)) {
        confirmed = best.profile;
      } else if (best.effectiveScore >= 0.50) {
        fuzzyHint = best.profile;
      }
    } else if (best.sameChannel) {
      final passesStandard =
          best.effectiveScore >= 0.72 &&
          (!hasCompetition || margin >= 0.08) &&
          (totalCohortCount < 2 || best.asNormZ >= 1.35);
      final passesVeryHigh =
          best.effectiveScore >= 0.80 && (!hasCompetition || margin >= 0.05);
      if (passesStandard || passesVeryHigh) {
        confirmed = best.profile;
      } else if (best.effectiveScore >= 0.48 ||
          (totalCohortCount >= 2 &&
              best.asNormZ >= 1.4 &&
              margin >= 0.10 &&
              best.effectiveScore >= 0.40)) {
        fuzzyHint = best.profile;
      }
    } else {
      // 跨设备信道差异下：要求显著领先幅度或极高分才直接确认，否则落入猜测待确认
      final passesCrossMargin =
          best.effectiveScore >= 0.68 &&
          speechMs >= 2800 &&
          otherPersonCount >= 1 &&
          margin >= 0.13 &&
          best.asNormZ >= 1.75;
      final passesCrossAbs =
          best.effectiveScore >= 0.76 && (!hasCompetition || margin >= 0.08);
      if (passesCrossMargin || passesCrossAbs) {
        confirmed = best.profile;
      } else if (best.effectiveScore >= 0.44 ||
          (totalCohortCount >= 2 &&
              best.asNormZ >= 1.4 &&
              margin >= 0.10 &&
              best.effectiveScore >= 0.38)) {
        fuzzyHint = best.profile;
      }
    }

    return VoiceprintMatchEvaluation(
      confirmed: confirmed,
      fuzzyHint: confirmed == null ? fuzzyHint : null,
      bestScore: best.effectiveScore,
      secondBestScore: secondBestScore,
      margin: margin,
      asNormZ: best.asNormZ,
      sameChannel: best.sameChannel,
      channelKey: queryChannelKey,
      scannedPersons: candidates.length,
      candidates: candidates,
    );
  }

  bool _hasChannelStats(String channelKey, int dim) {
    if (dim < 16) return false;
    final stats = _channelMeans[channelKey];
    return stats != null && stats.count >= 3 && stats.mean.length == dim;
  }

  List<double> _channelCalibrated(List<double> unitVec, String channelKey) {
    if (!_hasChannelStats(channelKey, unitVec.length)) return unitVec;
    final mean = _channelMeans[channelKey]!.mean;
    final centered = List<double>.filled(unitVec.length, 0);
    for (var i = 0; i < unitVec.length; i++) {
      centered[i] = unitVec[i] - 0.35 * mean[i];
    }
    return _normalize(centered) ?? unitVec;
  }

  static double _computeAsNormZ(double score, List<double> sortedDescImpostors) {
    if (sortedDescImpostors.isEmpty) return 0.0;
    if (sortedDescImpostors.length == 1) {
      return (score - sortedDescImpostors.first) / 0.12;
    }
    final k = math.min(20, sortedDescImpostors.length);
    var sum = 0.0;
    for (var i = 0; i < k; i++) {
      sum += sortedDescImpostors[i];
    }
    final mu = sum / k;
    var sq = 0.0;
    for (var i = 0; i < k; i++) {
      final d = sortedDescImpostors[i] - mu;
      sq += d * d;
    }
    final sigma = math.max(0.06, math.sqrt(sq / k));
    return (score - mu) / sigma;
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
    bool notify = true,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    final cleanName = candidateName.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty || cleanName.isEmpty) return;
    final key = '$cleanSes::$cleanSlot';
    if (_dismissedSuggestions.contains('$key::$cleanName') ||
        _detachedSlots.contains(key)) {
      return;
    }
    _fuzzyHints[key] = cleanName;
    if (!_suggestions.containsKey(key)) {
      _suggestions[key] = SpeakerCandidateSuggestion(
        session: cleanSes,
        speakerSlot: cleanSlot,
        candidateName: cleanName,
        confidence: 0.62,
        source: SpeakerSuggestionSource.voiceprint,
        reason: '声纹相似度命中历史人物，待确认',
        updatedAtMs: _now().millisecondsSinceEpoch,
      );
    }
    if (notify) notifyListeners();
  }

  void recordCandidateSuggestion(
    SpeakerCandidateSuggestion suggestion, {
    bool notify = true,
  }) {
    final cleanSes = suggestion.session.trim();
    final cleanSlot = suggestion.speakerSlot.trim();
    final cleanName = suggestion.candidateName.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty || cleanName.isEmpty) return;
    final key = '$cleanSes::$cleanSlot';
    if (_dismissedSuggestions.contains('$key::$cleanName') ||
        _detachedSlots.contains(key)) {
      return;
    }
    _suggestions[key] = suggestion;
    _fuzzyHints[key] = cleanName;
    if (notify) notifyListeners();
  }

  void clearSuggestion({
    required String session,
    required String speakerSlot,
    bool notify = true,
  }) {
    final key = '${session.trim()}::${speakerSlot.trim()}';
    final r1 = _suggestions.remove(key);
    final r2 = _fuzzyHints.remove(key);
    if ((r1 != null || r2 != null) && notify) {
      notifyListeners();
    }
  }

  void dismissSuggestion({
    required String session,
    required String speakerSlot,
    String? candidateName,
    bool notify = true,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty) return;
    final key = '$cleanSes::$cleanSlot';
    final existingName =
        candidateName?.trim() ??
        _suggestions[key]?.candidateName ??
        _fuzzyHints[key] ??
        '';
    if (existingName.isNotEmpty) {
      _dismissedSuggestions.add('$key::$existingName');
    }
    _suggestions.remove(key);
    _fuzzyHints.remove(key);
    if (notify) notifyListeners();
  }

  bool isSuggestionDismissed({
    required String session,
    required String speakerSlot,
    required String candidateName,
  }) => _dismissedSuggestions.contains(
    '${session.trim()}::${speakerSlot.trim()}::${candidateName.trim()}',
  );

  void detachSlot({
    required String session,
    required String speakerSlot,
    String? eventId,
    String? personName,
    bool notify = true,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isNotEmpty && cleanSlot.isNotEmpty) {
      final key = '$cleanSes::$cleanSlot';
      _detachedSlots.add(key);
      _suggestions.remove(key);
      _fuzzyHints.remove(key);
      if (personName != null && personName.trim().isNotEmpty) {
        _dismissedSuggestions.add('$key::${personName.trim()}');
      }
    }
    if (eventId != null &&
        eventId.trim().isNotEmpty &&
        personName != null &&
        personName.trim().isNotEmpty) {
      _detachedSlots.add('ev::${eventId.trim()}::${personName.trim()}');
    }
    if (notify) notifyListeners();
  }

  void clearDetachedSlot({
    required String session,
    required String speakerSlot,
    String? eventId,
    String? personName,
    bool notify = true,
  }) {
    var changed = false;
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isNotEmpty && cleanSlot.isNotEmpty) {
      final key = '$cleanSes::$cleanSlot';
      if (_detachedSlots.remove(key)) changed = true;
      if (personName != null && personName.trim().isNotEmpty) {
        if (_dismissedSuggestions.remove('$key::${personName.trim()}')) {
          changed = true;
        }
      }
    }
    if (eventId != null &&
        eventId.trim().isNotEmpty &&
        personName != null &&
        personName.trim().isNotEmpty) {
      if (_detachedSlots.remove('ev::${eventId.trim()}::${personName.trim()}')) {
        changed = true;
      }
    }
    if (changed && notify) notifyListeners();
  }

  bool isSlotDetached({
    required String session,
    required String speakerSlot,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty) return false;
    return _detachedSlots.contains('$cleanSes::$cleanSlot');
  }

  bool isDetached({
    required String session,
    required String speakerSlot,
    String? eventId,
    String? rawName,
  }) {
    if (isSlotDetached(session: session, speakerSlot: speakerSlot)) return true;
    if (eventId != null &&
        eventId.trim().isNotEmpty &&
        rawName != null &&
        rawName.trim().isNotEmpty) {
      return _detachedSlots.contains(
        'ev::${eventId.trim()}::${rawName.trim()}',
      );
    }
    return false;
  }

  SpeakerCandidateSuggestion? suggestionFor({
    required String session,
    required String speakerSlot,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty) return null;
    final key = '$cleanSes::$cleanSlot';
    if (_detachedSlots.contains(key)) return null;
    final direct = _suggestions[key];
    if (direct != null) {
      if (_dismissedSuggestions.contains('$key::${direct.candidateName}')) {
        return null;
      }
      return direct;
    }
    final legacy = _fuzzyHints[key];
    if (legacy != null &&
        legacy.trim().isNotEmpty &&
        !_dismissedSuggestions.contains('$key::${legacy.trim()}')) {
      return SpeakerCandidateSuggestion(
        session: cleanSes,
        speakerSlot: cleanSlot,
        candidateName: legacy.trim(),
        confidence: 0.62,
        source: SpeakerSuggestionSource.voiceprint,
        reason: '端侧声纹疑似匹配',
      );
    }
    return null;
  }

  List<SpeakerCandidateSuggestion> suggestionsForSession(String session) {
    final cleanSes = session.trim();
    if (cleanSes.isEmpty) return const [];
    final out = <SpeakerCandidateSuggestion>[];
    final seenSlots = <String>{};
    for (final s in _suggestions.values) {
      if (s.session == cleanSes &&
          seenSlots.add(s.speakerSlot) &&
          !_detachedSlots.contains(s.key) &&
          !_dismissedSuggestions.contains('${s.key}::${s.candidateName}')) {
        out.add(s);
      }
    }
    for (final e in _fuzzyHints.entries) {
      if (!e.key.startsWith('$cleanSes::')) continue;
      final slot = e.key.substring(cleanSes.length + 2);
      if (seenSlots.contains(slot)) continue;
      final sug = suggestionFor(session: cleanSes, speakerSlot: slot);
      if (sug != null) {
        seenSlots.add(slot);
        out.add(sug);
      }
    }
    out.sort((a, b) => a.speakerSlot.compareTo(b.speakerSlot));
    return out;
  }

  String? fuzzyHintFor({
    required String session,
    required String speakerSlot,
  }) {
    final cleanSes = session.trim();
    final cleanSlot = speakerSlot.trim();
    if (cleanSes.isEmpty || cleanSlot.isEmpty) return null;
    final key = '$cleanSes::$cleanSlot';
    if (_detachedSlots.contains(key)) return null;
    final sugg = _suggestions[key]?.candidateName;
    if (sugg != null &&
        sugg.trim().isNotEmpty &&
        !_dismissedSuggestions.contains('$key::${sugg.trim()}')) {
      return sugg.trim();
    }
    final legacy = _fuzzyHints[key];
    if (legacy != null &&
        legacy.trim().isNotEmpty &&
        !_dismissedSuggestions.contains('$key::${legacy.trim()}')) {
      return legacy.trim();
    }
    return null;
  }

  Map<String, dynamic> exportJson() => {
    'v': 2,
    'persons': [for (final p in _persons) p.toJson()],
    'recent': _recentNames,
    if (_fuzzyHints.isNotEmpty) 'hints': _fuzzyHints,
    if (_suggestions.isNotEmpty)
      'sugg': {
        for (final e in _suggestions.entries) e.key: e.value.toJson(),
      },
    if (_channelMeans.isNotEmpty)
      'chMeans': {
        for (final e in _channelMeans.entries) e.key: e.value.toJson(),
      },
    if (_detachedSlots.isNotEmpty) 'detached': _detachedSlots.toList()..sort(),
    if (_dismissedSuggestions.isNotEmpty)
      'dismissed': _dismissedSuggestions.toList()..sort(),
  };

  void restoreJson(Map<String, dynamic>? raw, {bool notify = true}) {
    _persons.clear();
    _recentNames.clear();
    _fuzzyHints.clear();
    _suggestions.clear();
    _channelMeans.clear();
    _detachedSlots.clear();
    _dismissedSuggestions.clear();
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
      final sugg = raw['sugg'];
      if (sugg is Map) {
        for (final e in sugg.entries) {
          final k = '${e.key}'.trim();
          final v = e.value;
          if (k.isNotEmpty && v is Map<String, dynamic>) {
            final parsed = SpeakerCandidateSuggestion.fromJson(v);
            if (parsed.candidateName.trim().isNotEmpty) {
              _suggestions[k] = parsed;
            }
          }
        }
      }
      final chMeans = raw['chMeans'];
      if (chMeans is Map) {
        for (final e in chMeans.entries) {
          final k = '${e.key}'.trim();
          final v = e.value;
          if (k.isNotEmpty && v is Map<String, dynamic>) {
            final parsed = ChannelAcousticStats.fromJson(v);
            if (parsed.mean.isNotEmpty && parsed.count > 0) {
              _channelMeans[k] = parsed;
            }
          }
        }
      }
      final det = raw['detached'];
      if (det is List) {
        for (final item in det) {
          final clean = '$item'.trim();
          if (clean.isNotEmpty) _detachedSlots.add(clean);
        }
      }
      final dis = raw['dismissed'];
      if (dis is List) {
        for (final item in dis) {
          final clean = '$item'.trim();
          if (clean.isNotEmpty) _dismissedSuggestions.add(clean);
        }
      }
    }
    ensureSelfProfile(notify: false);
    if (notify) notifyListeners();
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

  static List<double>? _normalize(List<double> vector) {
    if (vector.isEmpty) return null;
    var norm = 0.0;
    for (final v in vector) {
      norm += v * v;
    }
    if (norm <= 1e-12) return null;
    final inv = 1.0 / math.sqrt(norm);
    return [for (final v in vector) v * inv];
  }

  static double _dot(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }
}
