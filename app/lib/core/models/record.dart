/// 录音记录模型；真实数据使用 recordedAt，旧夹具仍可使用 dayOffset。
library;

class TurnLine {
  final String spk;
  final String text;
  final String src;
  final int? startMs;
  final int? endMs;
  const TurnLine(this.spk, this.text, this.src, {this.startMs, this.endMs});

  Map<String, dynamic> toJson() => {
    'spk': spk,
    'text': text,
    'src': src,
    if (startMs != null) 'startMs': startMs,
    if (endMs != null) 'endMs': endMs,
  };
  factory TurnLine.fromJson(Map<String, dynamic> json) => TurnLine(
    json['spk'] as String,
    json['text'] as String,
    json['src'] as String,
    startMs: (json['startMs'] as num?)?.toInt(),
    endMs: (json['endMs'] as num?)?.toInt(),
  );
}

class RecordMark {
  final int offsetMs;
  final String label;
  const RecordMark({required this.offsetMs, this.label = ''});
  Map<String, dynamic> toJson() => {'offsetMs': offsetMs, 'label': label};
  factory RecordMark.fromJson(Map<String, dynamic> json) {
    final offset = (json['offsetMs'] as num).toInt();
    if (offset < 0) throw const FormatException('Negative mark offset');
    return RecordMark(offsetMs: offset, label: json['label'] as String? ?? '');
  }
}

const _unchanged = Object();

class RecordEvent {
  final String id;
  final int dayOffset;
  final String title;
  final String brief;
  final String longText;
  final String time;
  final String dur;
  final String speakers;
  final String mark;
  final String srcMap;
  final List<TurnLine> dialog;
  final List<TurnLine> raw;

  final String? audioPath;
  final String? fileId;
  final String? deviceId;
  final DateTime? recordedAt;
  final DateTime? endedAt;
  final DateTime? importedAt;
  final int? durationMs;

  /// 原始转写独立保留；transcript 为当前展示/处理文本。
  final String? transcript;
  final String? originalTranscript;
  final String? cleanedTranscript;

  /// imported/transcribing/transcribed/analyzing/ready/failed，可由流水线扩展。
  final String status;
  final String? transcriptionStatus;
  final String? taskId;
  final String? error;
  final List<RecordMark> marks;
  final String? recordingId;
  final List<String> sourceChunkIds;
  final int? sourceStartMs;
  final int? sourceEndMs;
  final int revision;
  final List<String> polishedContextChunkIds;

  const RecordEvent({
    required this.id,
    required this.dayOffset,
    required this.title,
    required this.brief,
    required this.longText,
    required this.time,
    required this.dur,
    required this.speakers,
    required this.mark,
    required this.srcMap,
    required this.dialog,
    required this.raw,
    this.audioPath,
    this.fileId,
    this.deviceId,
    this.recordedAt,
    this.endedAt,
    this.importedAt,
    this.durationMs,
    this.transcript,
    this.originalTranscript,
    this.cleanedTranscript,
    this.status = 'imported',
    this.transcriptionStatus,
    this.taskId,
    this.error,
    this.marks = const [],
    this.recordingId,
    this.sourceChunkIds = const [],
    this.sourceStartMs,
    this.sourceEndMs,
    this.revision = 0,
    this.polishedContextChunkIds = const [],
  });

  /// 按本地日历计算，不以 24h 除法跨越夏令时；未知真实时间仍兼容旧数据。
  int dayOffsetAt(DateTime now) {
    final date = recordedAt?.toLocal();
    if (date == null) return dayOffset;
    return DateTime.utc(
      now.toLocal().year,
      now.toLocal().month,
      now.toLocal().day,
    ).difference(DateTime.utc(date.year, date.month, date.day)).inDays;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'dayOffset': dayOffset,
    'title': title,
    'brief': brief,
    'longText': longText,
    'time': time,
    'dur': dur,
    'speakers': speakers,
    'mark': mark,
    'srcMap': srcMap,
    'dialog': dialog.map((line) => line.toJson()).toList(),
    'raw': raw.map((line) => line.toJson()).toList(),
    'audioPath': audioPath,
    'fileId': fileId,
    'deviceId': deviceId,
    'recordedAt': recordedAt?.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'importedAt': importedAt?.toIso8601String(),
    'durationMs': durationMs,
    'transcript': transcript,
    'originalTranscript': originalTranscript,
    'cleanedTranscript': cleanedTranscript,
    'status': status,
    'transcriptionStatus': transcriptionStatus,
    'taskId': taskId,
    'error': error,
    'marks': marks.map((mark) => mark.toJson()).toList(),
    'recordingId': recordingId,
    'sourceChunkIds': sourceChunkIds,
    'sourceStartMs': sourceStartMs,
    'sourceEndMs': sourceEndMs,
    'revision': revision,
    'polishedContextChunkIds': polishedContextChunkIds,
  };

  factory RecordEvent.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (id.isEmpty) throw const FormatException('Empty recording id');
    DateTime? date(String key) =>
        json[key] == null ? null : DateTime.parse(json[key] as String);
    List<TurnLine> lines(String key) => [
      for (final value in json[key] as List? ?? const [])
        TurnLine.fromJson(Map<String, dynamic>.from(value as Map)),
    ];
    return RecordEvent(
      id: id,
      dayOffset: (json['dayOffset'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      brief: json['brief'] as String? ?? '',
      longText: json['longText'] as String? ?? '',
      time: json['time'] as String? ?? '',
      dur: json['dur'] as String? ?? '',
      speakers: json['speakers'] as String? ?? '',
      mark: json['mark'] as String? ?? '',
      srcMap: json['srcMap'] as String? ?? '',
      dialog: lines('dialog'),
      raw: lines('raw'),
      audioPath: json['audioPath'] as String?,
      fileId: json['fileId'] as String?,
      deviceId: json['deviceId'] as String?,
      recordedAt: date('recordedAt'),
      endedAt: date('endedAt'),
      importedAt: date('importedAt'),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      transcript: json['transcript'] as String?,
      originalTranscript: json['originalTranscript'] as String?,
      cleanedTranscript: json['cleanedTranscript'] as String?,
      status: json['status'] as String? ?? 'imported',
      recordingId: json['recordingId'] as String?,
      sourceChunkIds: (json['sourceChunkIds'] as List? ?? const [])
          .cast<String>(),
      sourceStartMs: (json['sourceStartMs'] as num?)?.toInt(),
      sourceEndMs: (json['sourceEndMs'] as num?)?.toInt(),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      polishedContextChunkIds: (json['polishedContextChunkIds'] as List? ?? [])
          .cast<String>(),
      transcriptionStatus: json['transcriptionStatus'] as String?,
      taskId: json['taskId'] as String?,
      error: json['error'] as String?,
      marks: [
        for (final value in json['marks'] as List? ?? const [])
          RecordMark.fromJson(Map<String, dynamic>.from(value as Map)),
      ],
    );
  }

  /// Nullable fields may be explicitly cleared by passing null.
  RecordEvent copyWith({
    String? id,
    int? dayOffset,
    String? title,
    String? brief,
    String? longText,
    String? time,
    String? dur,
    String? speakers,
    String? mark,
    String? srcMap,
    List<TurnLine>? dialog,
    List<TurnLine>? raw,
    String? status,
    List<RecordMark>? marks,
    Object? audioPath = _unchanged,
    Object? fileId = _unchanged,
    Object? deviceId = _unchanged,
    Object? recordedAt = _unchanged,
    Object? endedAt = _unchanged,
    Object? importedAt = _unchanged,
    Object? durationMs = _unchanged,
    Object? transcript = _unchanged,
    Object? originalTranscript = _unchanged,
    Object? cleanedTranscript = _unchanged,
    Object? transcriptionStatus = _unchanged,
    Object? taskId = _unchanged,
    Object? error = _unchanged,
    Object? recordingId = _unchanged,
    List<String>? sourceChunkIds,
    Object? sourceStartMs = _unchanged,
    Object? sourceEndMs = _unchanged,
    int? revision,
    List<String>? polishedContextChunkIds,
  }) => RecordEvent(
    id: id ?? this.id,
    dayOffset: dayOffset ?? this.dayOffset,
    title: title ?? this.title,
    brief: brief ?? this.brief,
    longText: longText ?? this.longText,
    time: time ?? this.time,
    dur: dur ?? this.dur,
    speakers: speakers ?? this.speakers,
    mark: mark ?? this.mark,
    srcMap: srcMap ?? this.srcMap,
    dialog: dialog ?? this.dialog,
    raw: raw ?? this.raw,
    status: status ?? this.status,
    marks: marks ?? this.marks,
    audioPath: identical(audioPath, _unchanged)
        ? this.audioPath
        : audioPath as String?,
    fileId: identical(fileId, _unchanged) ? this.fileId : fileId as String?,
    deviceId: identical(deviceId, _unchanged)
        ? this.deviceId
        : deviceId as String?,
    recordedAt: identical(recordedAt, _unchanged)
        ? this.recordedAt
        : recordedAt as DateTime?,
    endedAt: identical(endedAt, _unchanged)
        ? this.endedAt
        : endedAt as DateTime?,
    importedAt: identical(importedAt, _unchanged)
        ? this.importedAt
        : importedAt as DateTime?,
    durationMs: identical(durationMs, _unchanged)
        ? this.durationMs
        : durationMs as int?,
    transcript: identical(transcript, _unchanged)
        ? this.transcript
        : transcript as String?,
    originalTranscript: identical(originalTranscript, _unchanged)
        ? this.originalTranscript
        : originalTranscript as String?,
    cleanedTranscript: identical(cleanedTranscript, _unchanged)
        ? this.cleanedTranscript
        : cleanedTranscript as String?,
    transcriptionStatus: identical(transcriptionStatus, _unchanged)
        ? this.transcriptionStatus
        : transcriptionStatus as String?,
    taskId: identical(taskId, _unchanged) ? this.taskId : taskId as String?,
    error: identical(error, _unchanged) ? this.error : error as String?,
    recordingId: identical(recordingId, _unchanged)
        ? this.recordingId
        : recordingId as String?,
    sourceChunkIds: sourceChunkIds ?? this.sourceChunkIds,
    sourceStartMs: identical(sourceStartMs, _unchanged)
        ? this.sourceStartMs
        : sourceStartMs as int?,
    sourceEndMs: identical(sourceEndMs, _unchanged)
        ? this.sourceEndMs
        : sourceEndMs as int?,
    revision: revision ?? this.revision,
    polishedContextChunkIds:
        polishedContextChunkIds ?? this.polishedContextChunkIds,
  );
}
