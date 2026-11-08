import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'recording_chunk.dart';

export 'recording_chunk.dart';

typedef RecordingProgress = void Function(int receivedBytes, int? totalBytes);

enum RecordingTaskState { queued, running, succeeded, failed, cancelled }

enum RecordingIntegrity { valid, missing, corrupt }

class RecordingIndexEntry {
  final String key;
  final String eventId;
  final String deviceId;
  final String fileId;
  final String audioPath;
  final String? metadataPath;
  final String? markPath;
  final int sizeBytes;
  final String contentHash;
  final DateTime importedAt;
  final DateTime? recordedAt;
  final int? durationMs;
  final RecordingIntegrity integrity;
  final String? cloudFileId;
  final DateTime? uploadedAt;
  const RecordingIndexEntry({
    required this.key,
    required this.eventId,
    required this.deviceId,
    required this.fileId,
    required this.audioPath,
    required this.sizeBytes,
    required this.contentHash,
    required this.importedAt,
    this.metadataPath,
    this.markPath,
    this.recordedAt,
    this.durationMs,
    this.integrity = RecordingIntegrity.valid,
    this.cloudFileId,
    this.uploadedAt,
  });
  Map<String, dynamic> toJson() => {
    'key': key,
    'eventId': eventId,
    'deviceId': deviceId,
    'fileId': fileId,
    'audioPath': audioPath,
    'metadataPath': metadataPath,
    'markPath': markPath,
    'sizeBytes': sizeBytes,
    'contentHash': contentHash,
    'importedAt': importedAt.toIso8601String(),
    'recordedAt': recordedAt?.toIso8601String(),
    'durationMs': durationMs,
    'integrity': integrity.name,
    'cloudFileId': cloudFileId,
    'uploadedAt': uploadedAt?.toIso8601String(),
  };
  factory RecordingIndexEntry.fromJson(Map<String, dynamic> json) {
    final hash = json['contentHash'] as String;
    final size = (json['sizeBytes'] as num).toInt();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) || size <= 0) {
      throw const FormatException('Invalid recording integrity metadata');
    }
    return RecordingIndexEntry(
      key: json['key'] as String,
      eventId: json['eventId'] as String,
      deviceId: json['deviceId'] as String,
      fileId: json['fileId'] as String,
      audioPath: json['audioPath'] as String,
      metadataPath: json['metadataPath'] as String?,
      markPath: json['markPath'] as String?,
      sizeBytes: size,
      contentHash: hash,
      importedAt: DateTime.parse(json['importedAt'] as String),
      recordedAt: json['recordedAt'] == null
          ? null
          : DateTime.parse(json['recordedAt'] as String),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      integrity: RecordingIntegrity.values.byName(
        json['integrity'] as String? ?? 'valid',
      ),
      cloudFileId: json['cloudFileId'] as String?,
      uploadedAt: json['uploadedAt'] == null
          ? null
          : DateTime.parse(json['uploadedAt'] as String),
    );
  }
  RecordingIndexEntry copyWith({
    String? audioPath,
    String? metadataPath,
    String? markPath,
    RecordingIntegrity? integrity,
    String? cloudFileId,
    DateTime? uploadedAt,
  }) => RecordingIndexEntry(
    key: key,
    eventId: eventId,
    deviceId: deviceId,
    fileId: fileId,
    audioPath: audioPath ?? this.audioPath,
    metadataPath: metadataPath ?? this.metadataPath,
    markPath: markPath ?? this.markPath,
    sizeBytes: sizeBytes,
    contentHash: contentHash,
    importedAt: importedAt,
    recordedAt: recordedAt,
    durationMs: durationMs,
    integrity: integrity ?? this.integrity,
    cloudFileId: cloudFileId ?? this.cloudFileId,
    uploadedAt: uploadedAt ?? this.uploadedAt,
  );
}

class RecordingTask {
  final String id;

  /// download/upload/sync/transcription/analysis; downstream may extend the kind.
  final String kind;
  final RecordingTaskState state;
  final String stage;
  final String? deviceId;
  final String? fileId;
  final double? progress;
  final int attempts;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic> metadata;
  const RecordingTask({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    this.state = RecordingTaskState.queued,
    this.stage = 'queued',
    this.deviceId,
    this.fileId,
    this.progress,
    this.attempts = 0,
    this.error,
    this.metadata = const {},
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'state': state.name,
    'stage': stage,
    'deviceId': deviceId,
    'fileId': fileId,
    'progress': progress,
    'attempts': attempts,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'metadata': metadata,
  };
  factory RecordingTask.fromJson(Map<String, dynamic> json) => RecordingTask(
    id: json['id'] as String,
    kind: json['kind'] as String,
    state: RecordingTaskState.values.byName(json['state'] as String),
    stage: json['stage'] as String,
    deviceId: json['deviceId'] as String?,
    fileId: json['fileId'] as String?,
    progress: (json['progress'] as num?)?.toDouble(),
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? const {}),
  );
  RecordingTask copyWith({
    RecordingTaskState? state,
    String? stage,
    double? progress,
    int? attempts,
    String? error,
    bool clearError = false,
    bool clearProgress = false,
    DateTime? updatedAt,
    Map<String, dynamic>? metadata,
  }) => RecordingTask(
    id: id,
    kind: kind,
    deviceId: deviceId,
    fileId: fileId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
    state: state ?? this.state,
    stage: stage ?? this.stage,
    progress: clearProgress ? null : progress ?? this.progress,
    attempts: attempts ?? this.attempts,
    error: clearError ? null : error ?? this.error,
    metadata: metadata ?? this.metadata,
  );
}

/// One transaction holds UI data, source index, tasks, route stack and non-secret
/// settings metadata. Wi-Fi passwords NEVER belong in this snapshot.
class RecordingSnapshot {
  final List<RecordEvent> events;
  final List<SummaryCard> summaries;
  final List<RecordingIndexEntry> index;
  final List<RecordingTask> tasks;
  final List<Map<String, dynamic>> routes;
  final Map<String, dynamic> settingsMetadata;
  final Map<String, dynamic> metadata;
  final Map<String, bool> todoStates;
  final List<RecordingChunk> chunks;
  RecordingSnapshot({
    List<RecordEvent> events = const [],
    List<SummaryCard> summaries = const [],
    List<RecordingIndexEntry> index = const [],
    List<RecordingTask> tasks = const [],
    List<Map<String, dynamic>> routes = const [],
    Map<String, dynamic> settingsMetadata = const {},
    Map<String, dynamic> metadata = const {},
    Map<String, bool> todoStates = const {},
    List<RecordingChunk> chunks = const [],
  }) : events = List.unmodifiable(events),
       summaries = List.unmodifiable(summaries),
       index = List.unmodifiable(index),
       tasks = List.unmodifiable(tasks),
       routes = List.unmodifiable(
         routes.map((route) => Map<String, dynamic>.unmodifiable(route)),
       ),
       settingsMetadata = Map.unmodifiable(settingsMetadata),
       metadata = Map.unmodifiable(metadata),
       todoStates = Map.unmodifiable(todoStates),
       chunks = List.unmodifiable(chunks);

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'events': events.map((event) => event.toJson()).toList(),
    // Existing summary JSON is authoritative for all business content. The
    // envelope preserves pending/generating, which the baseline serializer omits.
    'summaries': summaries
        .map(
          (summary) => {
            'card': summary.toJson(),
            'state': summary.state.name,
            'progress': summary.progress,
          },
        )
        .toList(),
    'index': index.map((entry) => entry.toJson()).toList(),
    'tasks': tasks.map((task) => task.toJson()).toList(), 'routes': routes,
    'settingsMetadata': settingsMetadata,
    'metadata': metadata,
    'todoStates': todoStates,
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
  };
  factory RecordingSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported recording schema');
    }
    Map<String, dynamic> map(Object? value) =>
        Map<String, dynamic>.from(value as Map);
    return RecordingSnapshot(
      events: [
        for (final e in json['events'] as List) RecordEvent.fromJson(map(e)),
      ],
      summaries: [for (final s in json['summaries'] as List) _summary(map(s))],
      index: [
        for (final i in json['index'] as List)
          RecordingIndexEntry.fromJson(map(i)),
      ],
      tasks: [
        for (final t in json['tasks'] as List) RecordingTask.fromJson(map(t)),
      ],
      routes: [for (final r in json['routes'] as List) map(r)],
      settingsMetadata: map(json['settingsMetadata']),
      metadata: map(json['metadata']),
      todoStates: Map<String, bool>.from(
        json['todoStates'] as Map? ?? const {},
      ),
      chunks: [
        for (final c in json['chunks'] as List? ?? const [])
          RecordingChunk.fromJson(map(c)),
      ],
    );
  }
  static SummaryCard _summary(Map<String, dynamic> envelope) {
    final summary = SummaryCard.fromJson(
      Map<String, dynamic>.from(envelope['card'] as Map),
    );
    summary.state = SummaryState.values.byName(envelope['state'] as String);
    summary.progress = (envelope['progress'] as num?)?.toDouble() ?? 0;
    return summary;
  }

  RecordingSnapshot copyWith({
    List<RecordEvent>? events,
    List<SummaryCard>? summaries,
    List<RecordingIndexEntry>? index,
    List<RecordingTask>? tasks,
    List<Map<String, dynamic>>? routes,
    Map<String, dynamic>? settingsMetadata,
    Map<String, dynamic>? metadata,
    Map<String, bool>? todoStates,
    List<RecordingChunk>? chunks,
  }) => RecordingSnapshot(
    events: events ?? this.events,
    summaries: summaries ?? this.summaries,
    index: index ?? this.index,
    tasks: tasks ?? this.tasks,
    routes: routes ?? this.routes,
    settingsMetadata: settingsMetadata ?? this.settingsMetadata,
    metadata: metadata ?? this.metadata,
    todoStates: todoStates ?? this.todoStates,
    chunks: chunks ?? this.chunks,
  );
}

class RecordingImport {
  final String sourcePath;
  final String fileId;
  final String deviceId;
  final String? title;
  final DateTime? recordedAt;
  final int? durationMs;
  final int? expectedSize;
  final String? expectedSha256;
  final String? metadataPath;
  final String? markPath;
  final List<RecordMark> marks;
  final int? expectedMetadataSize;
  final int? expectedMarkSize;
  const RecordingImport({
    required this.sourcePath,
    required this.fileId,
    this.deviceId = 'local',
    this.title,
    this.recordedAt,
    this.durationMs,
    this.expectedSize,
    this.expectedSha256,
    this.metadataPath,
    this.markPath,
    this.marks = const [],
    this.expectedMetadataSize,
    this.expectedMarkSize,
  });
}

class RecordingImportResult {
  final RecordingIndexEntry entry;
  final RecordEvent event;
  final bool duplicate;
  const RecordingImportResult({
    required this.entry,
    required this.event,
    required this.duplicate,
  });
}
