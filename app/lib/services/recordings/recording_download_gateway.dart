import '../../core/models/record.dart';
import 'recording_models.dart';

/// Metadata comes from the real file list / sidecar, never import wall-clock.
/// Stable fileId includes device session/sequence when firmware provides them.
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

/// Session cleanup is mandatory including failed opens, and is idempotent.
/// All downloads MUST be non-destructive, for both normal BLE and explicit AP.
/// BLE firmware "take" which deletes at transfer end must reject this contract.
abstract interface class RecordingDownloadGateway {
  /// Whether this adapter requires an Internet network-policy check. Card AP is
  /// local-network transfer, not an Internet upload, and does not require it.
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

/// Trusted local receipt produced only after atomic repository commit and a
/// second size/SHA-256 check of audio and paired sidecars. Not a cloud receipt.
class RecordingSourceReceipt {
  final String repositoryKey;
  final String audioPath;
  final int sizeBytes;
  final String contentHash;
  final String? metadataPath;
  final String? markPath;
  const RecordingSourceReceipt({
    required this.repositoryKey,
    required this.audioPath,
    required this.sizeBytes,
    required this.contentHash,
    this.metadataPath,
    this.markPath,
  });
}

typedef RecordingSourceCommit = Future<bool> Function(
  String deviceId,
  RemoteRecording recording,
  RecordingSourceReceipt receipt,
);

/// Optional second phase. Native must bind confirmation to the same device and
/// stable file identity, reject changed source, and be idempotent. Return true
/// ONLY when deletion was acknowledged; false means source remains on card.
/// Implementing this cannot make an early-delete BLE take safe retroactively.
abstract interface class RecordingSourceCommitGateway {
  Future<bool> confirmImportedRecording(
    String deviceId,
    RemoteRecording recording,
    RecordingSourceReceipt receipt,
  );
}

class RecordingSyncCancelled implements Exception {
  const RecordingSyncCancelled();
  @override
  String toString() => 'RecordingSyncCancelled: 同步已取消';
}

/// Optional adapter hint: an old local import may still need a fresh preserving
/// download to obtain a connection-bound Native source-deletion receipt.
abstract interface class RecordingSourceReceiptGateway {
  bool hasPendingSourceReceipt(String deviceId, RemoteRecording recording);
}
