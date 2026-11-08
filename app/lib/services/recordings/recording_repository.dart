import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'atomic_json_file.dart';
import 'recording_models.dart';

export 'atomic_json_file.dart'
    show RecordingStorageException, RepositoryCorruptionException;
export 'recording_models.dart';

class RecordingRepository {
  final Directory directory;
  late final AtomicJsonFile _file = AtomicJsonFile(
    File('${directory.path}/recordings.json'),
  );
  RecordingSnapshot? _snapshot;
  Future<void> _tail = Future<void>.value();
  final List<String> _diagnostics = [];
  List<String> get diagnostics => List.unmodifiable(_diagnostics);
  RecordingRepository({required Directory directory})
    : directory = directory.absolute;

  static Future<RecordingRepository> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return RecordingRepository(
      directory: Directory('${support.path}/recording_card/v1'),
    );
  }

  static String identityKey(String deviceId, String fileId) =>
      sha256.convert(utf8.encode('$deviceId\u0000$fileId')).toString();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Hydrates once per instance, verifies managed audio and recovers interrupted
  /// tasks to queued. It never starts device/network/model work automatically.
  Future<RecordingSnapshot> load() =>
      _serial(() async => _clone(await _load()));

  Future<RecordingSnapshot> _load() async {
    if (_snapshot != null) return _snapshot!;
    await directory.create(recursive: true);
    final json = await _file.read(
      validate: (value) {
        _decode(value);
      },
    );
    var next = json == null ? RecordingSnapshot() : _decode(json);
    var changed = _file.recoveredBackup;
    if (changed) {
      _diagnostics.add(
        'Recording state recovered from previous committed generation',
      );
    }
    final index = <RecordingIndexEntry>[];
    final failedEvents = <String>{};
    for (final entry in next.index) {
      final integrity = await _integrity(entry);
      index.add(entry.copyWith(integrity: integrity));
      if (integrity != entry.integrity) changed = true;
      if (integrity != RecordingIntegrity.valid) {
        failedEvents.add(entry.eventId);
        _diagnostics.add(
          'An indexed audio asset is missing or corrupt; source was not deleted',
        );
      }
    }
    final tasks = [
      for (final task in next.tasks)
        if (task.state == RecordingTaskState.running)
          task.copyWith(
            state: RecordingTaskState.queued,
            stage: 'interrupted',
            clearProgress: true,
            error: 'Interrupted by restart; explicit retry required',
          )
        else
          task,
    ];
    if (next.tasks.any((task) => task.state == RecordingTaskState.running)) {
      changed = true;
    }
    final summaries = next.summaries;
    final interruptedSummaries = <String>[];
    for (final summary in summaries) {
      if (summary.state == SummaryState.generating) {
        summary.state = SummaryState.pending;
        summary.progress = 0;
        interruptedSummaries.add(summary.id);
        changed = true;
      }
    }
    next = next.copyWith(
      index: index,
      tasks: tasks,
      events: [
        for (final event in next.events)
          if (failedEvents.contains(event.id))
            event.copyWith(
              status: 'failed',
              error: 'Local audio asset is missing or corrupt',
            )
          else
            event,
      ],
      metadata: {
        ...next.metadata,
        if (interruptedSummaries.isNotEmpty)
          'interruptedSummaryIds': interruptedSummaries,
      },
    );
    final staging = Directory('${directory.path}/staging');
    if (await staging.exists() && !await staging.list().isEmpty) {
      _diagnostics.add(
        'Uncommitted transfer files preserved in staging; never indexed as complete audio',
      );
    }
    if (changed) await _file.write(_encode(next));
    _snapshot = next;
    return next;
  }

  /// Saves the full snapshot. For concurrent UI/service mutations prefer update,
  /// which reads the latest generation within the same serialized transaction.
  Future<void> save(RecordingSnapshot snapshot) {
    final frozen = _clone(snapshot);
    return _serial(() async {
      await _load();
      await _persist(frozen);
    });
  }

  Future<RecordingSnapshot> update(
    FutureOr<RecordingSnapshot> Function(RecordingSnapshot current) transform,
  ) => _serial(() async {
    final current = _clone(await _load());
    final next = await transform(current);
    await _persist(next);
    return _clone(_snapshot!);
  });

  Future<void> upsertTask(RecordingTask task) async {
    await update(
      (state) => state.copyWith(
        tasks: [...state.tasks.where((item) => item.id != task.id), task],
      ),
    );
  }

  Future<void> upsertEvent(RecordEvent event) async {
    await update(
      (state) => state.copyWith(
        events: [...state.events.where((item) => item.id != event.id), event],
      ),
    );
  }

  /// CAS update for overlapping windows: retains stable event ID, increments its
  /// revision once and rejects stale workers. The transform may change polished
  /// text/stage sources, never the canonical original transcript.
  Future<RecordEvent> updateEventRevision(
    String eventId, {
    required int expectedRevision,
    required RecordEvent Function(RecordEvent current) transform,
  }) => _serial(() async {
    final state = _clone(await _load());
    final event = state.events.where((item) => item.id == eventId).firstOrNull;
    if (event == null || event.revision != expectedRevision) {
      throw const RecordingRevisionConflict(
        'Event revision is stale or event does not exist',
      );
    }
    final updated = transform(event).copyWith(revision: expectedRevision + 1);
    if (updated.id != eventId) {
      throw const RecordingRevisionConflict(
        'Revision updates cannot change stable event ID',
      );
    }
    await _persist(
      state.copyWith(
        events: [
          for (final item in state.events)
            if (item.id == eventId) updated else item,
        ],
      ),
    );
    return updated;
  });

  /// Register an already-imported local slice. Metadata and raw text are
  /// write-once (null raw may be filled once, even an empty ASR result counts).
  Future<RecordingChunk> putChunk(RecordingChunk chunk) => _serial(() async {
    final state = await _load();
    final entry = state.index
        .where(
          (entry) =>
              entry.audioPath == chunk.audioPath &&
              entry.contentHash == chunk.contentHash &&
              entry.sizeBytes == chunk.sizeBytes,
        )
        .firstOrNull;
    if (entry == null || await _integrity(entry) != RecordingIntegrity.valid) {
      throw const RecordingStorageException(
        'Slice must reference a complete managed audio import',
      );
    }
    await _persist(
      state.copyWith(
        chunks: [...state.chunks.where((item) => item.id != chunk.id), chunk],
      ),
    );
    return chunk;
  });

  Future<RecordingIndexEntry> markUploaded(
    String key, {
    required String cloudFileId,
  }) => _serial(() async {
    if (cloudFileId.trim().isEmpty) {
      throw const RecordingStorageException(
        'Upload receipt has no remote file ID',
      );
    }
    final state = await _load();
    final entry = state.index.where((item) => item.key == key).firstOrNull;
    if (entry == null) {
      throw const RecordingStorageException('Recording is not indexed');
    }
    if (await _integrity(entry) != RecordingIntegrity.valid) {
      throw const RecordingStorageException(
        'Cannot mark incomplete audio uploaded',
      );
    }
    final updated = entry.copyWith(
      cloudFileId: cloudFileId,
      uploadedAt: DateTime.now(),
    );
    await _persist(
      state.copyWith(
        index: [
          for (final item in state.index)
            if (item.key == key) updated else item,
        ],
      ),
    );
    return updated;
  });

  Future<RecordingIntegrity> verifyRecording(String key) => _serial(() async {
    final state = await _load();
    final entry = state.index.where((item) => item.key == key).firstOrNull;
    if (entry == null) {
      throw const RecordingStorageException('Recording is not indexed');
    }
    final integrity = await _integrity(entry);
    if (integrity != entry.integrity) {
      await _persist(
        state.copyWith(
          index: [
            for (final item in state.index)
              if (item.key == key)
                item.copyWith(integrity: integrity)
              else
                item,
          ],
        ),
      );
    }
    return integrity;
  });

  /// Copies a real complete file into managed storage. Unknown recordedAt stays
  /// unknown; import time is not fabricated as recording time. This method never
  /// moves or deletes the provided source, including on errors and duplicates.
  Future<RecordingImportResult> importRecording(
    RecordingImport request, {
    RecordingProgress? onProgress,
  }) => _serial(() async {
    final state = await _load();
    if (request.fileId.isEmpty ||
        request.deviceId.isEmpty ||
        request.fileId.contains('\u0000') ||
        request.deviceId.contains('\u0000')) {
      throw ArgumentError(
        'Recording identity must be non-empty and contain no NUL',
      );
    }
    if (request.durationMs != null && request.durationMs! < 0) {
      throw ArgumentError('Negative duration');
    }
    if (request.marks.any(
      (mark) =>
          mark.offsetMs < 0 ||
          (request.durationMs != null && mark.offsetMs > request.durationMs!),
    )) {
      throw ArgumentError('Mark is outside the recording');
    }
    final source = File(request.sourcePath);
    final extension = source.path.split('.').last.toLowerCase();
    if (!const {
      'wav',
      'apm',
      'adpcm',
      'pcm',
      'mp3',
      'm4a',
      'aac',
      'ogg',
      'flac',
    }.contains(extension)) {
      throw const RecordingStorageException(
        'Unsupported audio extension or uncommitted partial file',
      );
    }
    if (!await source.exists()) {
      throw const RecordingStorageException('Audio source does not exist');
    }
    final size = await source.length();
    if (size <= 0 ||
        (request.expectedSize != null && request.expectedSize != size)) {
      throw const RecordingStorageException(
        'Audio source is empty or does not match expected length',
      );
    }
    final hash = await sha256.bind(source.openRead()).first;
    final contentHash = hash.toString();
    if (request.expectedSha256 != null &&
        request.expectedSha256!.toLowerCase() != contentHash) {
      throw const RecordingStorageException(
        'Audio source SHA-256 does not match',
      );
    }
    final key = identityKey(request.deviceId, request.fileId);
    final existing = state.index.where((entry) => entry.key == key).firstOrNull;
    if (existing != null && existing.contentHash != contentHash) {
      throw const RecordingStorageException(
        'Stable file identity conflicts with different content; provide a revision-aware file ID',
      );
    }
    if (existing != null &&
        (request.metadataPath == null || existing.metadataPath != null) &&
        (request.markPath == null || existing.markPath != null) &&
        await _integrity(existing) == RecordingIntegrity.valid) {
      final event = state.events
          .where((event) => event.id == existing.eventId)
          .first;
      return RecordingImportResult(
        entry: existing,
        event: event,
        duplicate: true,
      );
    }

    final audioPath = await _copyManaged(
      source,
      contentHash,
      extension,
      size,
      onProgress: onProgress,
    );
    Future<String?> sidecar(
      String? path,
      String extension,
      int? expectedLength,
    ) async {
      if (path == null) {
        if (expectedLength != null) {
          throw const RecordingStorageException(
            'Expected sidecar file is missing',
          );
        }
        return null;
      }
      final file = File(path);
      if (!await file.exists()) {
        throw const RecordingStorageException(
          'Required sidecar file is missing',
        );
      }
      final length = await file.length();
      if (path.endsWith('.part') ||
          path.endsWith('.tmp') ||
          (expectedLength != null && length != expectedLength)) {
        throw const RecordingStorageException(
          'Sidecar is partial or does not match expected length',
        );
      }
      final sideHash = (await sha256.bind(file.openRead()).first).toString();
      return _copyManaged(file, sideHash, extension, length);
    }

    final metadataPath = await sidecar(
      request.metadataPath,
      'txt',
      request.expectedMetadataSize,
    );
    final markPath = await sidecar(
      request.markPath,
      'mrk',
      request.expectedMarkSize,
    );
    final now = DateTime.now();
    final eventId = existing?.eventId ?? 'record-$key';
    final entry = RecordingIndexEntry(
      key: key,
      eventId: eventId,
      deviceId: request.deviceId,
      fileId: request.fileId,
      audioPath: audioPath,
      metadataPath: metadataPath ?? existing?.metadataPath,
      markPath: markPath ?? existing?.markPath,
      sizeBytes: size,
      contentHash: contentHash,
      importedAt: existing?.importedAt ?? now,
      recordedAt: request.recordedAt ?? existing?.recordedAt,
      durationMs: request.durationMs ?? existing?.durationMs,
      cloudFileId: existing?.cloudFileId,
      uploadedAt: existing?.uploadedAt,
    );
    final date = entry.recordedAt?.toLocal();
    final time = date == null
        ? ''
        : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final duration = entry.durationMs;
    final dur = duration == null
        ? ''
        : '${duration ~/ 60000}分${(duration ~/ 1000) % 60}秒';
    final oldEvent = state.events
        .where((event) => event.id == eventId)
        .firstOrNull;
    final event =
        oldEvent?.copyWith(
          audioPath: audioPath,
          status: 'imported',
          error: null,
        ) ??
        RecordEvent(
          id: eventId,
          dayOffset: 0,
          title: request.title ?? request.fileId,
          brief: '',
          longText: '',
          time: time,
          dur: dur,
          speakers: '',
          mark: '',
          srcMap: '',
          dialog: const [],
          raw: const [],
          audioPath: audioPath,
          fileId: request.fileId,
          deviceId: request.deviceId,
          recordedAt: entry.recordedAt,
          endedAt: entry.recordedAt != null && duration != null
              ? entry.recordedAt!.add(Duration(milliseconds: duration))
              : null,
          importedAt: entry.importedAt,
          durationMs: duration,
          marks: request.marks,
        );
    await _persist(
      state.copyWith(
        index: [...state.index.where((item) => item.key != key), entry],
        events: [...state.events.where((item) => item.id != eventId), event],
      ),
    );
    return RecordingImportResult(entry: entry, event: event, duplicate: false);
  });

  Future<String> _copyManaged(
    File source,
    String hash,
    String extension,
    int expectedSize, {
    RecordingProgress? onProgress,
  }) async {
    final staging = Directory('${directory.path}/staging');
    final assets = Directory('${directory.path}/audio');
    await staging.create(recursive: true);
    await assets.create(recursive: true);
    final staged = File('${staging.path}/$hash.$extension.part');
    final output = await staged.open(mode: FileMode.write);
    var received = 0;
    try {
      await for (final bytes in source.openRead()) {
        await output.writeFrom(bytes);
        received += bytes.length;
        onProgress?.call(received, expectedSize);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    // Re-check bytes on disk, detecting source mutation and truncated writes.
    if (received != expectedSize ||
        await staged.length() != expectedSize ||
        (await sha256.bind(staged.openRead()).first).toString() != hash) {
      throw const RecordingStorageException(
        'Transfer incomplete or source changed; partial file preserved',
      );
    }
    final destination = '${assets.path}/$hash.$extension';
    await staged.rename(destination);
    return destination;
  }

  Future<RecordingIntegrity> _integrity(RecordingIndexEntry entry) async {
    final audio = File(entry.audioPath);
    if (!await audio.exists()) return RecordingIntegrity.missing;
    if (await audio.length() != entry.sizeBytes) {
      return RecordingIntegrity.corrupt;
    }
    final actual = (await sha256.bind(audio.openRead()).first).toString();
    if (actual != entry.contentHash) return RecordingIntegrity.corrupt;
    for (final path in [entry.metadataPath, entry.markPath]) {
      if (path == null) continue;
      final file = File(path);
      if (!await file.exists()) return RecordingIntegrity.missing;
      final name = path.split('/').last;
      final match = RegExp(r'^([a-f0-9]{64})\.(txt|mrk)$').firstMatch(name);
      if (match == null ||
          (await sha256.bind(file.openRead()).first).toString() !=
              match.group(1)) {
        return RecordingIntegrity.corrupt;
      }
    }
    return RecordingIntegrity.valid;
  }

  Future<void> _persist(RecordingSnapshot next) async {
    final frozen = _clone(next);
    _validateTransition(_snapshot, frozen);
    await _file.write(_encode(frozen));
    _snapshot = frozen;
  }

  RecordingSnapshot _clone(RecordingSnapshot state) =>
      _decode(jsonDecode(jsonEncode(_encode(state))) as Map<String, dynamic>);

  String _storedPath(String path, {bool managed = false}) {
    final prefix = '${directory.path}/';
    if (path.startsWith(prefix)) return path.substring(prefix.length);
    if (managed) {
      throw const RecordingStorageException(
        'Indexed assets must belong to the repository directory',
      );
    }
    return path;
  }

  String _loadedPath(String path, {bool managed = false}) {
    if (path.startsWith('/')) {
      if (managed && !path.startsWith('${directory.path}/')) {
        throw const FormatException('Indexed asset escapes repository');
      }
      return path;
    }
    if (path.isEmpty ||
        path.contains('\\') ||
        path.split('/').any((part) => part == '..' || part.isEmpty)) {
      throw const FormatException('Unsafe relative audio path');
    }
    return '${directory.path}/$path';
  }

  Map<String, dynamic> _encode(RecordingSnapshot state) {
    final json = state.toJson();
    for (final event in json['events'] as List) {
      if (event['audioPath'] != null) {
        event['audioPath'] = _storedPath(event['audioPath'] as String);
      }
    }
    for (final chunk in json['chunks'] as List) {
      chunk['audioPath'] = _storedPath(
        chunk['audioPath'] as String,
        managed: true,
      );
    }
    for (final entry in json['index'] as List) {
      for (final field in ['audioPath', 'metadataPath', 'markPath']) {
        if (entry[field] != null) {
          entry[field] = _storedPath(entry[field] as String, managed: true);
        }
      }
    }
    _validateMetadata(state.settingsMetadata);
    return json;
  }

  RecordingSnapshot _decode(Map<String, dynamic> json) {
    final state = RecordingSnapshot.fromJson(json);
    void unique(Iterable<String> ids) {
      final values = ids.toList();
      if (values.any((id) => id.isEmpty) ||
          values.toSet().length != values.length) {
        throw const FormatException('Duplicate or empty persistent identity');
      }
    }

    unique(state.events.map((event) => event.id));
    unique(state.summaries.map((summary) => summary.id));
    unique(state.index.map((entry) => entry.key));
    unique(state.tasks.map((task) => task.id));
    unique(state.chunks.map((chunk) => chunk.id));
    final eventIds = state.events.map((event) => event.id).toSet();
    if (state.index.any((entry) => !eventIds.contains(entry.eventId))) {
      throw const FormatException('Index has no matching event');
    }
    _validateMetadata(state.settingsMetadata);
    return state.copyWith(
      events: [
        for (final event in state.events)
          if (event.audioPath != null)
            event.copyWith(audioPath: _loadedPath(event.audioPath!))
          else
            event,
      ],
      index: [
        for (final entry in state.index)
          entry.copyWith(
            audioPath: _loadedPath(entry.audioPath, managed: true),
            metadataPath: entry.metadataPath == null
                ? null
                : _loadedPath(entry.metadataPath!, managed: true),
            markPath: entry.markPath == null
                ? null
                : _loadedPath(entry.markPath!, managed: true),
          ),
      ],
      chunks: [
        for (final chunk in state.chunks)
          chunk.copyWith(
            audioPath: _loadedPath(chunk.audioPath, managed: true),
          ),
      ],
    );
  }

  void _validateTransition(RecordingSnapshot? old, RecordingSnapshot next) {
    for (final chunk in next.chunks) {
      if (!next.index.any(
        (entry) =>
            entry.audioPath == chunk.audioPath &&
            entry.contentHash == chunk.contentHash &&
            entry.sizeBytes == chunk.sizeBytes,
      )) {
        throw const RecordingStorageException(
          'Slice has no complete managed import identity',
        );
      }
    }
    if (old != null) {
      for (final previous in old.events) {
        final event = next.events
            .where((event) => event.id == previous.id)
            .firstOrNull;
        if (event == null) continue;
        if ((previous.originalTranscript != null &&
                previous.originalTranscript != event.originalTranscript) ||
            (previous.raw.isNotEmpty &&
                jsonEncode(
                      previous.raw.map((line) => line.toJson()).toList(),
                    ) !=
                    jsonEncode(
                      event.raw.map((line) => line.toJson()).toList(),
                    ))) {
          throw const RecordingStorageException(
            'Original transcript is immutable; write cloud-polished text to cleanedTranscript/dialog',
          );
        }
      }
      for (final previous in old.chunks) {
        final chunk = next.chunks
            .where((chunk) => chunk.id == previous.id)
            .firstOrNull;
        if (chunk == null ||
            chunk.recordingId != previous.recordingId ||
            chunk.audioPath != previous.audioPath ||
            chunk.contentHash != previous.contentHash ||
            chunk.sizeBytes != previous.sizeBytes ||
            chunk.startMs != previous.startMs ||
            chunk.endMs != previous.endMs ||
            chunk.recordedAt != previous.recordedAt ||
            (previous.rawTranscript != null &&
                chunk.rawTranscript != previous.rawTranscript)) {
          throw const RecordingStorageException(
            'Audio slice metadata and original transcript are immutable',
          );
        }
      }
    }
    for (final event in next.events) {
      if (event.revision < 0) {
        throw const RecordingRevisionConflict('Negative event revision');
      }
      if (event.sourceChunkIds.isEmpty) continue;
      if (event.sourceChunkIds.toSet().length != event.sourceChunkIds.length) {
        throw const RecordingStorageException('Duplicate source slices');
      }
      final chunks = [
        for (final id in event.sourceChunkIds)
          next.chunks.where((chunk) => chunk.id == id).firstOrNull,
      ];
      if (chunks.any((chunk) => chunk == null)) {
        throw const RecordingStorageException('Unknown source slice ID');
      }
      final values = chunks.cast<RecordingChunk>();
      final recordingIds = values.map((chunk) => chunk.recordingId).toSet();
      final starts = values.map((chunk) => chunk.startMs).toList()..sort();
      final ends = values.map((chunk) => chunk.endMs).toList()..sort();
      if (recordingIds.length != 1 ||
          (event.recordingId != null &&
              !recordingIds.contains(event.recordingId)) ||
          event.sourceStartMs == null ||
          event.sourceEndMs == null ||
          event.sourceStartMs! < starts.first ||
          event.sourceEndMs! > ends.last ||
          event.sourceEndMs! <= event.sourceStartMs!) {
        throw const RecordingStorageException(
          'Event source range is outside its recording slices',
        );
      }
    }
  }

  void _validateMetadata(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (key.contains('password') ||
            key.contains('secret') ||
            key.contains('token')) {
          throw const RecordingStorageException(
            'Secret credentials must not be stored in settings metadata',
          );
        }
        _validateMetadata(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _validateMetadata(item);
      }
    }
  }
}
