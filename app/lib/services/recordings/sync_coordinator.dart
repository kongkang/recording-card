import 'dart:async';
import 'dart:io';

import '../settings/settings_repository.dart';
import 'network_policy.dart';
import 'recording_download_gateway.dart';
import 'recording_repository.dart';
import 'recording_uploader.dart';

export 'network_policy.dart';
export 'recording_download_gateway.dart';
export 'recording_uploader.dart';

class RecordingSyncResult {
  final List<RecordingImportResult> imports;
  final List<RecordingIndexEntry> uploaded;

  /// Local save can succeed with source retained when Native has no safe ack.
  final List<String> retainedSourceFileIds;
  bool get isMoveComplete => retainedSourceFileIds.isEmpty;
  const RecordingSyncResult({
    required this.imports,
    required this.uploaded,
    this.retainedSourceFileIds = const [],
  });
}

/// V1 sync is a local move: non-destructive pull -> durable import -> source ack.
/// No audio is uploaded; cloud analysis is a separate text-only pipeline.
/// Singleton per gateway; CardGateway must arbitrate recording/Wi-Fi/OTA itself.
class SyncCoordinator {
  final RecordingRepository repository;
  final SettingsRepository settingsRepository;
  final RecordingDownloadGateway? gateway;
  final RecordingUploader? uploader;
  final RecordingNetworkPolicy networkPolicy;

  /// Runs after the whole file group is durable and source receipt is recorded,
  /// before the next file. Processing errors never undo a verified local save.
  final FutureOr<void> Function(RecordingImportResult)? onImported;
  final StreamController<RecordingTask> _changes = StreamController.broadcast();
  bool _busy = false;
  bool _cancelled = false;
  RecordingTask? _currentTask;
  Completer<void>? _idle;
  Future<void> get drained => _idle?.future ?? Future.value();
  bool get isBusy => _busy;
  RecordingTask? get currentTask => _currentTask;
  Stream<RecordingTask> get changes => _changes.stream;

  SyncCoordinator({
    required this.repository,
    required this.settingsRepository,
    this.gateway,
    this.uploader,
    this.onImported,
    RecordingNetworkPolicy? networkPolicy,
  }) : networkPolicy = networkPolicy ?? RecordingNetworkPolicy();

  Future<List<RecordingImportResult>> importFromDevice(String deviceId) async =>
      (await sync(deviceId)).imports;

  /// Ordinary sync does not require login, Internet or an audio-upload endpoint.
  /// Model readiness is deliberately downstream of the durable file transfer.
  Future<RecordingSyncResult> sync(String deviceId) => _exclusive(
    () => _task<RecordingSyncResult>(
      id: 'sync:${RecordingRepository.identityKey(deviceId, 'all')}',
      kind: 'sync',
      deviceId: deviceId,
      action: () async {
        final imports = await _download(deviceId);
        _checkCancelled();
        if (imports.isEmpty &&
            !(await repository.load()).index.any(
              (entry) =>
                  entry.deviceId == deviceId &&
                  entry.integrity == RecordingIntegrity.valid,
            )) {
          throw const RecordingStorageException('没有可同步的已完成录音文件');
        }
        await repository.update(
          (state) => state.copyWith(
            metadata: {
              ...state.metadata,
              'lastSuccessfulSyncAt': DateTime.now().toIso8601String(),
              'lastSuccessfulSyncDeviceId': deviceId,
            },
          ),
        );
        final state = await repository.load();
        return RecordingSyncResult(
          imports: List.unmodifiable(imports),
          uploaded: const [],
          retainedSourceFileIds: List.unmodifiable([
            for (final result in imports)
              if ((state.metadata['source-commit:${result.entry.key}']
                      as Map?)?['state'] !=
                  'confirmed')
                result.entry.fileId,
          ]),
        );
      },
    ),
  );

  /// Legacy composition roots use this name. It now has local sync semantics;
  /// keeping the name temporarily must NEVER re-enable audio upload implicitly.
  @Deprecated('V1 sync is local. Use sync(deviceId). No audio upload.')
  Future<RecordingSyncResult> syncAndUpload(String deviceId) => sync(deviceId);

  /// Persisted legacy upload tasks are retained for audit, never resumed in V1.
  Future<List<RecordingIndexEntry>> resumePendingUploads({String? deviceId}) =>
      Future.error(
        const RecordingStorageException('V1仅本机同步与本地转写，不支持音频上传；原音频与旧任务保留'),
      );

  Future<List<RecordingImportResult>> _download(String deviceId) async {
    final source = gateway;
    if (source == null) throw const RecordingStorageException('录音卡下载网关未配置');
    if (deviceId.isEmpty) throw ArgumentError('Empty device ID');
    if (source.usesNetwork) await _requireNetwork();
    final results = <RecordingImportResult>[];
    Object? primaryError;
    try {
      await source.openSession(deviceId);
      _checkCancelled();
      if (source.usesNetwork) await _requireNetwork();
      final files = (await source.listRecordings(deviceId)).indexed.toList()
        ..sort((a, b) {
          final left = _deviceFileTime(a.$2);
          final right = _deviceFileTime(b.$2);
          if (left == null && right == null) return a.$1.compareTo(b.$1);
          if (left == null) return 1;
          if (right == null) return -1;
          final order = right.compareTo(left);
          return order == 0 ? a.$1.compareTo(b.$1) : order;
        });
      for (final (_, file) in files) {
        _checkCancelled();
        if (file.sizeBytes <= 0) {
          throw const RecordingStorageException('设备文件大小无效或录音尚未完成');
        }
        final key = RecordingRepository.identityKey(deviceId, file.fileId);
        final state = await repository.load();
        final existing = state.index
            .where((entry) => entry.key == key)
            .firstOrNull;
        final sourceConfirmed =
            (state.metadata['source-commit:$key'] as Map?)?['state'] ==
            'confirmed';
        final canConfirmExisting =
            sourceConfirmed ||
            source is! RecordingSourceReceiptGateway ||
            (source as RecordingSourceReceiptGateway).hasPendingSourceReceipt(
              deviceId,
              file,
            );
        if (existing != null &&
            canConfirmExisting &&
            file.metadata['identityReliable'] != false &&
            (file.metadataSizeBytes == null || existing.metadataPath != null) &&
            (file.markSizeBytes == null || existing.markPath != null) &&
            await repository.verifyRecording(key) == RecordingIntegrity.valid) {
          if (existing.sizeBytes != file.sizeBytes ||
              (file.contentHash != null &&
                  existing.contentHash != file.contentHash!.toLowerCase())) {
            throw const RecordingStorageException(
              '设备文件身份复用但内容变化，请提供包含 session/seq 的稳定文件 ID',
            );
          }
          await _confirmImported(source, deviceId, file, existing);
          results.add(
            RecordingImportResult(
              entry: existing,
              event: state.events.firstWhere(
                (event) => event.id == existing.eventId,
              ),
              duplicate: true,
            ),
          );
          await _notifyImported(results.last);
          _checkCancelled();
          continue;
        }
        final imported = await _task<RecordingImportResult>(
          id: 'download:$key',
          kind: 'download',
          deviceId: deviceId,
          fileId: file.fileId,
          action: () async {
            final staging = Directory('${repository.directory.path}/staging');
            await staging.create(recursive: true);
            final extension = file.name.split('.').last.toLowerCase();
            if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension)) {
              throw const RecordingStorageException('设备音频文件扩展名无效');
            }
            if (source.usesNetwork) await _requireNetwork();
            final downloaded = await source.downloadRecording(
              deviceId,
              file,
              destinationPath: '${staging.path}/download-$key.$extension',
              allowDestructive: false,
              onProgress: _progress,
            );
            _checkCancelled();
            final result = await repository.importRecording(
              RecordingImport(
                sourcePath: downloaded.audioPath,
                fileId: file.fileId,
                deviceId: deviceId,
                title: file.name,
                expectedSize: file.sizeBytes,
                expectedSha256: file.contentHash,
                recordedAt: downloaded.recordedAt ?? file.recordedAt,
                durationMs: downloaded.durationMs ?? file.durationMs,
                metadataPath: downloaded.metadataPath,
                markPath: downloaded.markPath,
                marks: downloaded.marks,
                expectedMetadataSize: file.metadataSizeBytes,
                expectedMarkSize: file.markSizeBytes,
              ),
            );
            _checkCancelled();
            await _confirmImported(source, deviceId, file, result.entry);
            return result;
          },
        );
        results.add(imported);
        await _notifyImported(imported);
        _checkCancelled();
      }
    } catch (error) {
      primaryError = error;
      if (_cancelled) throw const RecordingSyncCancelled();
      rethrow;
    } finally {
      try {
        await source.closeSession(deviceId);
      } catch (error) {
        await repository.update(
          (state) => state.copyWith(
            metadata: {
              ...state.metadata,
              'error:sync-cleanup': error.toString(),
            },
          ),
        );
        if (primaryError == null) rethrow;
      }
    }
    return results;
  }

  static int? _deviceFileTime(RemoteRecording file) {
    if (file.recordedAt != null) return file.recordedAt!.millisecondsSinceEpoch;
    // Listing timestamps only order files; an unsynced clock is NOT presented
    // as a reliable recording date, and no wall clock/session/seq is invented.
    for (final key in ['deviceStartAt', 'deviceCreatedAt']) {
      final value = file.metadata[key];
      if (value is num && value.isFinite && value > 0) {
        return value.toInt() * 1000;
      }
    }
    return null;
  }

  Future<void> _notifyImported(RecordingImportResult result) async {
    final callback = onImported;
    if (callback == null) return;
    try {
      await callback(result);
    } catch (error) {
      await repository.update(
        (state) => state.copyWith(
          metadata: {
            ...state.metadata,
            'error:import-processing:${result.entry.key}': error.toString(),
          },
        ),
      );
    }
  }

  Future<void> _confirmImported(
    RecordingDownloadGateway source,
    String deviceId,
    RemoteRecording file,
    RecordingIndexEntry entry,
  ) async {
    _checkCancelled();
    if (entry.deviceId != deviceId ||
        entry.fileId != file.fileId ||
        entry.sizeBytes != file.sizeBytes ||
        (file.metadataSizeBytes != null && entry.metadataPath == null) ||
        (file.markSizeBytes != null && entry.markPath == null) ||
        (file.contentHash != null &&
            entry.contentHash != file.contentHash!.toLowerCase()) ||
        await repository.verifyRecording(entry.key) !=
            RecordingIntegrity.valid) {
      throw const RecordingStorageException('本机入库完整性校验失败，设备源文件保留');
    }
    final state = await repository.load();
    final key = 'source-commit:${entry.key}';
    final old = state.metadata[key] as Map?;
    if (old?['state'] == 'confirmed' &&
        old?['contentHash'] == entry.contentHash) {
      return;
    }
    final confirmed = source is RecordingSourceCommitGateway
        ? await (source as RecordingSourceCommitGateway)
              .confirmImportedRecording(
                deviceId,
                file,
                RecordingSourceReceipt(
                  repositoryKey: entry.key,
                  audioPath: entry.audioPath,
                  sizeBytes: entry.sizeBytes,
                  contentHash: entry.contentHash,
                  metadataPath: entry.metadataPath,
                  markPath: entry.markPath,
                ),
              )
        : false;
    // If cancel races with acknowledged deletion, first persist the receipt:
    // audio/index were already durable, so retry cannot lose the local source.
    await repository.update(
      (current) => current.copyWith(
        metadata: {
          ...current.metadata,
          key: {
            'state': confirmed ? 'confirmed' : 'source_retained',
            'contentHash': entry.contentHash,
            'sizeBytes': entry.sizeBytes,
            'fileId': file.fileId,
            'deviceId': deviceId,
          },
        },
      ),
    );
    // Publish an acknowledged local file even if cancel raced with the receipt.
    // The caller checks cancellation after its progressive callback.
  }

  Future<void> _requireNetwork() async {
    _checkCancelled();
    final settings = await settingsRepository.load();
    await networkPolicy.requireTransfer(settings.settings);
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) throw const RecordingStorageException('同步任务正在进行，请等待或取消');
    if (_changes.isClosed) {
      throw StateError('SyncCoordinator has been disposed');
    }
    _busy = true;
    _cancelled = false;
    _idle = Completer<void>();
    try {
      return await action();
    } finally {
      _busy = false;
      _currentTask = null;
      _idle!.complete();
      _idle = null;
    }
  }

  Future<T> _task<T>({
    required String id,
    required String kind,
    required Future<T> Function() action,
    String? deviceId,
    String? fileId,
  }) async {
    final state = await repository.load();
    final old = state.tasks.where((task) => task.id == id).firstOrNull;
    final now = DateTime.now();
    var task = RecordingTask(
      id: id,
      kind: kind,
      deviceId: deviceId,
      fileId: fileId,
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
      attempts: (old?.attempts ?? 0) + 1,
      state: RecordingTaskState.queued,
    );
    await repository.upsertTask(task);
    task = task.copyWith(
      state: RecordingTaskState.running,
      stage: kind,
      clearError: true,
    );
    await repository.upsertTask(task);
    final previous = _currentTask;
    _emit(task);
    try {
      final result = await action();
      task = task.copyWith(
        state: RecordingTaskState.succeeded,
        stage: 'complete',
        progress: 1,
        clearError: true,
      );
      await repository.upsertTask(task);
      _emit(task);
      return result;
    } catch (error) {
      final cancelled = _cancelled || error is RecordingSyncCancelled;
      final safeError = error is RecordingUploadConfigurationException
          ? error.message
          : error is RecordingNetworkPolicyException
          ? error.message
          : error is RecordingStorageException
          ? error.message
          : error is RecordingUploadException
          ? error.message
          : error.toString();
      task = task.copyWith(
        state: cancelled
            ? RecordingTaskState.cancelled
            : RecordingTaskState.failed,
        stage: cancelled ? 'cancelled' : 'failed',
        error: cancelled ? '同步已取消' : safeError,
        clearProgress: true,
      );
      await repository.upsertTask(task);
      _emit(task);
      if (cancelled) throw const RecordingSyncCancelled();
      rethrow;
    } finally {
      _currentTask = previous;
    }
  }

  void _progress(int received, int? total) {
    final task = _currentTask;
    if (task == null) return;
    final progress = total != null && total > 0
        ? (received / total).clamp(0.0, 1.0)
        : null;
    _emit(task.copyWith(progress: progress, clearProgress: progress == null));
  }

  void _emit(RecordingTask task) {
    _currentTask = task;
    if (!_changes.isClosed) _changes.add(task);
  }

  void _checkCancelled() {
    if (_cancelled) throw const RecordingSyncCancelled();
  }

  Future<void> cancel() async {
    _cancelled = true;
    // Never touch the legacy uploader: V1 owns no audio-upload operation.
    await gateway?.cancelActive();
  }

  /// Cancel/await active work before disposing. HttpRecordingUploader is disposed
  /// separately by its owner; no injected dependency is silently destroyed.
  Future<void> dispose() async {
    if (_busy) {
      throw StateError(
        'Cancel and await active synchronization before dispose',
      );
    }
    await _changes.close();
  }
}
