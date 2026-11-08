/// One canonical local audio slice. Times are offsets in its original recording,
/// not guessed speaker identities or UI labels. Raw text is write-once through
/// RecordingRepository.putChunk; cloud-polished text lives in derived RecordEvent.
class RecordingChunk {
  final String id;
  final String recordingId;
  final String audioPath;
  final int sizeBytes;
  final String contentHash;
  final int startMs;
  final int endMs;
  final DateTime? recordedAt;
  final String? rawTranscript;
  const RecordingChunk({
    required this.id,
    required this.recordingId,
    required this.audioPath,
    required this.sizeBytes,
    required this.contentHash,
    required this.startMs,
    required this.endMs,
    this.recordedAt,
    this.rawTranscript,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'recordingId': recordingId,
    'audioPath': audioPath,
    'sizeBytes': sizeBytes,
    'contentHash': contentHash,
    'startMs': startMs,
    'endMs': endMs,
    'recordedAt': recordedAt?.toIso8601String(),
    'rawTranscript': rawTranscript,
  };
  factory RecordingChunk.fromJson(Map<String, dynamic> json) {
    final chunk = RecordingChunk(
      id: json['id'] as String,
      recordingId: json['recordingId'] as String,
      audioPath: json['audioPath'] as String,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      contentHash: json['contentHash'] as String,
      startMs: (json['startMs'] as num).toInt(),
      endMs: (json['endMs'] as num).toInt(),
      rawTranscript: json['rawTranscript'] as String?,
      recordedAt: json['recordedAt'] == null
          ? null
          : DateTime.parse(json['recordedAt'] as String),
    );
    if (chunk.id.isEmpty ||
        chunk.recordingId.isEmpty ||
        chunk.sizeBytes <= 0 ||
        chunk.startMs < 0 ||
        chunk.endMs <= chunk.startMs ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(chunk.contentHash)) {
      throw const FormatException('Invalid audio slice metadata');
    }
    return chunk;
  }
  RecordingChunk copyWith({String? audioPath, String? rawTranscript}) =>
      RecordingChunk(
        id: id,
        recordingId: recordingId,
        audioPath: audioPath ?? this.audioPath,
        sizeBytes: sizeBytes,
        contentHash: contentHash,
        startMs: startMs,
        endMs: endMs,
        recordedAt: recordedAt,
        rawTranscript: rawTranscript ?? this.rawTranscript,
      );
}

class RecordingRevisionConflict implements Exception {
  final String message;
  const RecordingRevisionConflict(this.message);
  @override
  String toString() => 'RecordingRevisionConflict: $message';
}
