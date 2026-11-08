/// 录音流水线领域模型 —— 一条录音文件 → 切片 → 原始句 → 润色 turn → 话题分段。
///
/// 时间语义（全链路统一）：
/// - **录音内时间**：`startMs` / `endMs` 一律是相对该录音文件起点的毫秒；
/// - **绝对时间**：只有 `RecordingFile.startAtMs` 与 `SegmentRecord.startAtMs`
///   是 Unix 毫秒；其余都靠"录音起点 + 相对时间"换算。
/// 这样设备时钟与手机墙钟不一致时，时间轴仍然自洽。
///
/// 数据只存本地；云端上行的是文本（见 `services/polish`），不是音频。
library;

/// 一条设备录音文件在流水线里的位置。
enum RecordingStage {
  queued, // 已入队，等待下载
  downloading, // 正在经 BLE 取回
  transcoding, // .apm → .wav
  slicing, // VAD 切片
  transcribing, // 本地 ASR
  polishing, // 云端窗口改写
  summarizing, // 阶段总结/话题分段
  ready, // 全部完成
  failed, // 失败（error 里有可读原因）
}

/// 单个切片的处理状态。
enum SliceStage { queued, transcribing, transcribed, polishing, polished, failed }

/// 分段状态：录音中为 live（时间轴顶部实时卡片），边界到达后 closed。
enum SegmentStatus { live, closed }

class AudioSlice {
  const AudioSlice({
    required this.id,
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.wavPath,
    this.stage = SliceStage.queued,
    this.silenceAfterMs = 0,
    this.error,
  });

  /// 形如 `0001`，同一录音内稳定。
  final String id;
  final int index;
  final int startMs;
  final int endMs;
  final String wavPath;
  final SliceStage stage;

  /// 切片末尾到下一段语音之间的真实静音（用于分段边界判断）。
  final int silenceAfterMs;
  final String? error;

  int get durationMs => endMs - startMs;

  AudioSlice copyWith({
    SliceStage? stage,
    int? silenceAfterMs,
    String? error,
    bool clearError = false,
  }) {
    return AudioSlice(
      id: id,
      index: index,
      startMs: startMs,
      endMs: endMs,
      wavPath: wavPath,
      stage: stage ?? this.stage,
      silenceAfterMs: silenceAfterMs ?? this.silenceAfterMs,
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'i': index,
    's': startMs,
    'e': endMs,
    'w': wavPath,
    'st': stage.name,
    'sil': silenceAfterMs,
    if (error != null) 'err': error,
  };

  factory AudioSlice.fromJson(Map<String, dynamic> j) => AudioSlice(
    id: '${j['id'] ?? ''}',
    index: (j['i'] as num?)?.toInt() ?? 0,
    startMs: (j['s'] as num?)?.toInt() ?? 0,
    endMs: (j['e'] as num?)?.toInt() ?? 0,
    wavPath: '${j['w'] ?? ''}',
    stage: SliceStage.values.firstWhere(
      (e) => e.name == j['st'],
      orElse: () => SliceStage.queued,
    ),
    silenceAfterMs: (j['sil'] as num?)?.toInt() ?? 0,
    error: j['err'] as String?,
  );
}

/// 本地 ASR 的一句原文（保留语气词、停顿；不经过云端润色）。
class RawUtterance {
  const RawUtterance({
    required this.id,
    required this.sliceId,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.lang,
    this.emotion,
    this.speakerCluster,
    this.speakerLabel,
    this.spkConfidence,
  });

  final String id;
  final String sliceId;
  final int startMs;
  final int endMs;
  final String text;
  final String? lang;

  /// SenseVoice 的情绪标签（NEUTRAL/HAPPY/SAD/ANGRY/...）；空表示模型未给。
  final String? emotion;

  /// 声纹聚类簇号（本地编号，不是身份）。
  final int? speakerCluster;

  /// 展示用标签：`说话人 1` 或 `未区分`。
  final String? speakerLabel;

  /// 0~1；低于阈值时界面按「未区分」展示。
  final double? spkConfidence;

  int get durationMs => endMs - startMs;

  RawUtterance copyWith({
    int? speakerCluster,
    String? speakerLabel,
    double? spkConfidence,
  }) => RawUtterance(
    id: id,
    sliceId: sliceId,
    startMs: startMs,
    endMs: endMs,
    text: text,
    lang: lang,
    emotion: emotion,
    speakerCluster: speakerCluster ?? this.speakerCluster,
    speakerLabel: speakerLabel ?? this.speakerLabel,
    spkConfidence: spkConfidence ?? this.spkConfidence,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sl': sliceId,
    's': startMs,
    'e': endMs,
    't': text,
    if (lang != null) 'lg': lang,
    if (emotion != null) 'em': emotion,
    if (speakerCluster != null) 'sc': speakerCluster,
    if (speakerLabel != null) 'sk': speakerLabel,
    if (spkConfidence != null) 'cf': spkConfidence,
  };

  factory RawUtterance.fromJson(Map<String, dynamic> j) => RawUtterance(
    id: '${j['id'] ?? ''}',
    sliceId: '${j['sl'] ?? ''}',
    startMs: (j['s'] as num?)?.toInt() ?? 0,
    endMs: (j['e'] as num?)?.toInt() ?? 0,
    text: '${j['t'] ?? ''}',
    lang: j['lg'] as String?,
    emotion: j['em'] as String?,
    speakerCluster: (j['sc'] as num?)?.toInt(),
    speakerLabel: j['sk'] as String?,
    spkConfidence: (j['cf'] as num?)?.toDouble(),
  );
}

/// 云端窗口改写后的对话 turn。`srcUtteranceIds` 是回溯到原始数据的唯一凭据。
class PolishedTurn {
  const PolishedTurn({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.speakerLabel,
    required this.text,
    required this.srcUtteranceIds,
    this.revision = 1,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String speakerLabel;
  final String text;
  final List<String> srcUtteranceIds;
  final int revision;

  int get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => {
    'id': id,
    's': startMs,
    'e': endMs,
    'sk': speakerLabel,
    't': text,
    'src': srcUtteranceIds,
    'r': revision,
  };

  factory PolishedTurn.fromJson(Map<String, dynamic> j) => PolishedTurn(
    id: '${j['id'] ?? ''}',
    startMs: (j['s'] as num?)?.toInt() ?? 0,
    endMs: (j['e'] as num?)?.toInt() ?? 0,
    speakerLabel: '${j['sk'] ?? ''}',
    text: '${j['t'] ?? ''}',
    srcUtteranceIds: [
      for (final s in (j['src'] as List? ?? const [])) '$s',
    ],
    revision: (j['r'] as num?)?.toInt() ?? 1,
  );
}

/// 时间轴上的一个事件/话题段（一份数据三处展示的源头）。
class SegmentRecord {
  SegmentRecord({
    required this.id,
    required this.sessionId,
    required this.index,
    required this.startAtMs,
    this.endAtMs,
    this.title = '',
    this.brief = '',
    this.longText = '',
    this.speakerLabels = const [],
    this.speakerCount = 0,
    this.tags = const [],
    this.status = SegmentStatus.live,
    this.sliceIds = const [],
    this.turnIds = const [],
    this.mark,
    this.legacy = false,
    this.polishStale = false,
    this.fallback = false,
  });

  final String id;
  final String sessionId;
  final int index;
  final int startAtMs;
  int? endAtMs;
  String title;
  String brief;
  String longText;
  List<String> speakerLabels;
  int speakerCount;
  List<String> tags;
  SegmentStatus status;
  List<String> sliceIds;
  List<String> turnIds;
  String? mark;

  /// 旧版本（整文件一条记录）迁移过来的，界面不显示"分段"语义之外的差异。
  final bool legacy;

  /// 有切片润色失败时置 true，界面如实提示"部分内容未润色"。
  bool polishStale;

  /// 云端阶段总结失败、用原文兜底时置 true（标题/概述来自原文截取）。
  bool fallback;

  bool get closed => status == SegmentStatus.closed;
  int? get durationMs => endAtMs == null ? null : endAtMs! - startAtMs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ses': sessionId,
    'i': index,
    'st': startAtMs,
    if (endAtMs != null) 'en': endAtMs,
    'ti': title,
    'br': brief,
    'lo': longText,
    'spk': speakerLabels,
    'spn': speakerCount,
    'tg': tags,
    'ss': status.name,
    'sl': sliceIds,
    'tu': turnIds,
    if (mark != null) 'mk': mark,
    if (legacy) 'lg': true,
    if (polishStale) 'ps': true,
    if (fallback) 'fb': true,
  };

  factory SegmentRecord.fromJson(Map<String, dynamic> j) => SegmentRecord(
    id: '${j['id'] ?? ''}',
    sessionId: '${j['ses'] ?? ''}',
    index: (j['i'] as num?)?.toInt() ?? 0,
    startAtMs: (j['st'] as num?)?.toInt() ?? 0,
    endAtMs: (j['en'] as num?)?.toInt(),
    title: '${j['ti'] ?? ''}',
    brief: '${j['br'] ?? ''}',
    longText: '${j['lo'] ?? ''}',
    speakerLabels: [
      for (final s in (j['spk'] as List? ?? const [])) '$s',
    ],
    speakerCount: (j['spn'] as num?)?.toInt() ?? 0,
    tags: [for (final s in (j['tg'] as List? ?? const [])) '$s'],
    status: SegmentStatus.values.firstWhere(
      (e) => e.name == j['ss'],
      orElse: () => SegmentStatus.closed,
    ),
    sliceIds: [for (final s in (j['sl'] as List? ?? const [])) '$s'],
    turnIds: [for (final s in (j['tu'] as List? ?? const [])) '$s'],
    mark: j['mk'] as String?,
    legacy: j['lg'] == true,
    polishStale: j['ps'] == true,
    fallback: j['fb'] == true,
  );
}

/// 一条设备录音文件的完整本地状态（一份 JSON 落盘）。
class RecordingFile {
  RecordingFile({
    required this.deviceName,
    required this.session,
    required this.seq,
    required this.startAtMs,
    required this.apmPath,
    required this.createdAtMs,
    this.wavPath,
    this.durationMs = 0,
    this.timeSynced = true,
    this.stage = RecordingStage.queued,
    this.slices = const [],
    this.utterances = const [],
    this.turns = const [],
    this.segments = const [],
    this.polishedThroughSlice = -1,
    this.polishStale = false,
    this.error,
  });

  /// 设备上的文件名（如 `059F19DF.APM`），去重键。
  final String deviceName;

  /// 设备会话号（8 位十六进制）；旧固件为空。
  final String session;

  /// 会话内段序号，从 1 递增。
  final int seq;

  /// 录音起点（Unix 毫秒）。来自设备 `.txt` 的 `start_at`；不可信时用 created - duration。
  int startAtMs;

  /// 设备时钟是否已同步；false 时界面标注「时间未校准」。
  bool timeSynced;

  String apmPath;
  String? wavPath;
  int durationMs;
  RecordingStage stage;
  List<AudioSlice> slices;
  List<RawUtterance> utterances;
  List<PolishedTurn> turns;
  List<SegmentRecord> segments;

  /// 已完成云端改写的最后一个切片下标；-1 表示还没润色过。
  int polishedThroughSlice;

  /// 有窗口润色失败并回退原文；界面提示「部分内容未润色」。
  bool polishStale;
  String? error;

  /// 本地入库时间（同步时刻），用于保留策略与排障。
  final int createdAtMs;

  String get id => 'rec-${deviceName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}';

  Map<String, dynamic> toJson() => {
    'v': 2,
    'name': deviceName,
    'ses': session,
    'seq': seq,
    'at': startAtMs,
    'sync': timeSynced,
    'apm': apmPath,
    if (wavPath != null) 'wav': wavPath,
    'dur': durationMs,
    'st': stage.name,
    'sl': [for (final s in slices) s.toJson()],
    'ut': [for (final u in utterances) u.toJson()],
    'tu': [for (final t in turns) t.toJson()],
    'sg': [for (final s in segments) s.toJson()],
    'pt': polishedThroughSlice,
    if (polishStale) 'ps': true,
    'cr': createdAtMs,
    if (error != null) 'err': error,
  };

  factory RecordingFile.fromJson(Map<String, dynamic> j) => RecordingFile(
    deviceName: '${j['name'] ?? ''}',
    session: '${j['ses'] ?? ''}',
    seq: (j['seq'] as num?)?.toInt() ?? 1,
    startAtMs: (j['at'] as num?)?.toInt() ?? 0,
    timeSynced: j['sync'] != false,
    apmPath: '${j['apm'] ?? ''}',
    wavPath: j['wav'] as String?,
    durationMs: (j['dur'] as num?)?.toInt() ?? 0,
    stage: RecordingStage.values.firstWhere(
      (e) => e.name == j['st'],
      orElse: () => RecordingStage.queued,
    ),
    slices: [
      for (final s in (j['sl'] as List? ?? const []))
        if (s is Map<String, dynamic>) AudioSlice.fromJson(s),
    ],
    utterances: [
      for (final u in (j['ut'] as List? ?? const []))
        if (u is Map<String, dynamic>) RawUtterance.fromJson(u),
    ],
    turns: [
      for (final t in (j['tu'] as List? ?? const []))
        if (t is Map<String, dynamic>) PolishedTurn.fromJson(t),
    ],
    segments: [
      for (final s in (j['sg'] as List? ?? const []))
        if (s is Map<String, dynamic>) SegmentRecord.fromJson(s),
    ],
    polishedThroughSlice: (j['pt'] as num?)?.toInt() ?? -1,
    polishStale: j['ps'] == true,
    createdAtMs: (j['cr'] as num?)?.toInt() ?? 0,
    error: j['err'] as String?,
  );
}
