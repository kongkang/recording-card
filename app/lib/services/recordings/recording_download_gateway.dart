import '../../core/models/record.dart';
import 'recording_models.dart';

/// Adapter metadata must come from a real file list / sidecar. Stable fileId
/// should include device session/sequence when firmware provides them.
class RemoteRecording {
  final String fileId;
  final String name;
  final int sizeBytes;
  final DateTime? recordedAt;
  final int? durationMs;
  final String? contentHash;
  final Map<String, dynamic> metadata;
  final int? metadataSizeBytes;
  final int? markSizeBytes;
  const RemoteRecording({
    required this.fileId,
    required this.name,
    required this.sizeBytes,
    this.recordedAt,
    this.durationMs,
    this.contentHash,
    this.metadata = const {},
    this.metadataSizeBytes,
    this.markSizeBytes,
  });
}

class DownloadedRecording {
  final String audioPath;
  final String? metadataPath;
  final String? markPath;
  final DateTime? recordedAt;
  final int? durationMs;
  final List<RecordMark> marks;
  const DownloadedRecording({
    required this.audioPath,
    this.metadataPath,
    this.markPath,
    this.recordedAt,
    this.durationMs,
    this.marks = const [],
  });
}

/// E adapts CardGateway here. Session cleanup is mandatory, including failed
/// opens; closeSession must be idempotent. There is intentionally no delete API.
/// AP/non-destructive reads are preferred; allowDestructive is ALWAYS false in
/// SyncCoordinator. A gateway that only supports BLE take must reject it.
abstract interface class RecordingDownloadGateway {
  bool get usesNetwork;
  Future<void> openSession(String deviceId);
  Future<void> closeSession(String deviceId);
  Future<List<RemoteRecording>> listRecordings(String deviceId);
  Future<DownloadedRecording> downloadRecording(
    String deviceId,
    RemoteRecording recording, {
    required String destinationPath,
    required bool allowDestructive,
    RecordingProgress? onProgress,
  });
  Future<void> cancelActive();
}

class RecordingSyncCancelled implements Exception {
  const RecordingSyncCancelled();
  @override
  String toString() => 'RecordingSyncCancelled: 同步已取消';
}
