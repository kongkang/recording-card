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
  const RecordingSyncResult({required this.imports, required this.uploaded});
}

/// Composition root injects a B gateway adapter and an approved uploader.
/// Download sessions finish before cloud upload begins (AP owns the SD/network).
/// Singleton per gateway; CardGateway must arbitrate recording/Wi-Fi/OTA itself.
class SyncCoordinator {
  final RecordingRepository repository;
  final SettingsRepository settingsRepository;
  final RecordingDownloadGateway? gateway;
  final RecordingUploader? uploader;
  final RecordingNetworkPolicy networkPolicy;
  final StreamController<RecordingTask> _changes = StreamController.broadcast();
  bool _busy = false;
  bool _cancelled = false;
  RecordingTask? _currentTask;
  bool get isBusy => _busy;
  RecordingTask? get currentTask => _currentTask;
  Stream<RecordingTask> get changes => _changes.stream;

  SyncCoordinator({
    required this.repository,
    required this.settingsRepository,
    this.gateway,
    this.uploader,
    RecordingNetworkPolicy? networkPolicy,
  }) : networkPolicy = networkPolicy ?? RecordingNetworkPolicy();

  /// Explicit local import only; never reported as "sync uploaded".
  Future<List<RecordingImportResult>> importFromDevice(String deviceId) =>
      _exclusive(() => _download(deviceId));

  /// The sync button must call this (not importFromDevice). Unconfigured upload
  /// fails before any device/download effects. No source deletion is ever called.
  Future<RecordingSyncResult> syncAndUpload(String deviceId) =>
      _exclusive(() async {
        _requireUploader();
        await _requireNetwork();
        final result = await _task<RecordingSyncResult>(
          id: 'sync:${RecordingRepository.identityKey(deviceId, 'all')}',
          kind: 'sync',
          deviceId: deviceId,
          action: () async {
            final imports = await _download(deviceId);
            _checkCancelled();
            final uploaded = await _uploadPending(deviceId: deviceId);
            if (imports.isEmpty && uploaded.isEmpty) {
              final state = await repository.load();
              if (!state.index.any(
                (entry) =>
                    entry.deviceId == deviceId && entry.cloudFileId != null,
              )) {
                throw const RecordingStorageException('没有可同步的录音文件');
              }
            }
            _checkCancelled();
            await repository.update(
              (state) => state.copyWith(
                metadata: {
                  ...state.metadata,
                  'lastSuccessfulSyncAt': DateTime.now().toIso8601String(),
                  'lastSuccessfulSyncDeviceId': deviceId,
                },
              ),
            );
            return RecordingSyncResult(
              imports: List.unmodifiable(imports),
              uploaded: List.unmodifiable(uploaded),
            );
          },
        );
        return result;
      });

  /// Explicit restart/retry entry for local pending uploads. Doesn't require a
  /// connected device and doesn't auto-start when loading persisted state.
  Future<List<RecordingIndexEntry>> resumePendingUploads({String? deviceId}) =>
      _exclusive(() async {
        _requireUploader();
        await _requireNetwork();
        return _uploadPending(deviceId: deviceId);
      });

  Future<List<RecordingImportResult>> _download(String deviceId) async {
    final source = gateway;
    if (source == null) throw const RecordingStorageException('录音卡下载网关未配置');
    if (deviceId.isEmpty) throw ArgumentError('Empty device ID');
    if (source.usesNetwork) await _requireNetwork();
    final results = <RecordingImportResult>[];
    try {
      await source.openSession(deviceId);
      _checkCancelled();
      if (source.usesNetwork) await _requireNetwork();
      final files = await source.listRecordings(deviceId);
      for (final file in files) {
        _checkCancelled();
        if (file.sizeBytes <= 0) {
          throw const RecordingStorageException('设备文件大小无效或录音尚未完成');
        }
        final key = RecordingRepository.identityKey(deviceId, file.fileId);
        final state = await repository.load();
        final existing = state.index
            .where((entry) => entry.key == key)
            .firstOrNull;
        if (existing != null &&
            await repository.verifyRecording(key) == RecordingIntegrity.valid) {
          if (existing.sizeBytes != file.sizeBytes ||
              (file.contentHash != null &&
                  existing.contentHash != file.contentHash!.toLowerCase())) {
            throw const RecordingStorageException(
              '设备文件身份复用但内容变化，请提供包含 session/seq 的稳定文件 ID',
            );
          }
          results.add(
            RecordingImportResult(
              entry: existing,
              event: state.events.firstWhere(
                (event) => event.id == existing.eventId,
              ),
              duplicate: true,
            ),
          );
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
            return repository.importRecording(
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
          },
        );
        results.add(imported);
      }
    } catch (_) {
      if (_cancelled) throw const RecordingSyncCancelled();
      rethrow;
    } finally {
      // Cleanup errors are not silently reported as successful sessions. If
      // cleanup masks a business error, persisted child tasks retain that error.
      await source.closeSession(deviceId);
    }
    return results;
  }

  Future<List<RecordingIndexEntry>> _uploadPending({String? deviceId}) async {
    final service = _requireUploader();
    final state = await repository.load();
    final entries = state.index
        .where(
          (entry) =>
              entry.cloudFileId == null &&
              (deviceId == null || entry.deviceId == deviceId),
        )
        .toList();
    final uploaded = <RecordingIndexEntry>[];
    for (final entry in entries) {
      _checkCancelled();
      final updated = await _task<RecordingIndexEntry>(
        id: 'upload:${entry.key}',
        kind: 'upload',
        deviceId: entry.deviceId,
        fileId: entry.fileId,
        action: () async {
          await _requireNetwork();
          if (await repository.verifyRecording(entry.key) !=
              RecordingIntegrity.valid) {
            throw const RecordingStorageException('本地录音文件不完整，不能上传');
          }
          final receipt = await service.upload(
            RecordingUploadRequest(
              entry: entry,
              requireNetwork: _requireNetwork,
            ),
            onProgress: _progress,
          );
          // A real accepted receipt is durable even if cancel happened while the
          // server accepted it. Never delete the source; idempotency handles retry.
          final result = await repository.markUploaded(
            entry.key,
            cloudFileId: receipt.cloudFileId,
          );
          _checkCancelled();
          return result;
        },
      );
      uploaded.add(updated);
    }
    return uploaded;
  }

  RecordingUploader _requireUploader() {
    final service = uploader;
    if (service == null) {
      throw const RecordingUploadConfigurationException(
        '同步上传服务未配置，不能将本地导入当作上传成功',
      );
    }
    service.validateConfiguration();
    return service;
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
    try {
      return await action();
    } finally {
      _busy = false;
      _currentTask = null;
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
          : '任务失败，请检查设备、网络与配置后重试';
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
    await Future.wait([
      if (gateway != null) gateway!.cancelActive(),
      if (uploader != null) uploader!.cancelActive(),
    ]);
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
