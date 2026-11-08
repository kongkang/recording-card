import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class RecordingStorageException implements Exception {
  final String message;
  const RecordingStorageException(this.message);
  @override
  String toString() => 'RecordingStorageException: $message';
}

class RepositoryCorruptionException extends RecordingStorageException {
  const RepositoryCorruptionException(super.message);
}

/// Internal persistence primitive. Callers serialize all operations per repository.
/// Staged files are never treated as committed state. A bad main file can only
/// recover from a checksum/schema-valid backup, never from empty seed data.
class AtomicJsonFile {
  final File file;
  bool recoveredBackup = false;
  AtomicJsonFile(this.file);

  Future<Map<String, dynamic>?> read({
    void Function(Map<String, dynamic>)? validate,
  }) async {
    recoveredBackup = false;
    var found = false;
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      found = true;
      try {
        final decoded = _decode(await candidate.readAsString());
        validate?.call(decoded);
        recoveredBackup = candidate.path != file.path;
        return decoded;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    if (found) {
      throw const RepositoryCorruptionException(
        'Committed data and backup are invalid; preserved for manual recovery',
      );
    }
    return null;
  }

  Map<String, dynamic> _decode(String text) {
    final envelope = jsonDecode(text) as Map<String, dynamic>;
    if (envelope['version'] != 1 || envelope['payload'] is! String) {
      throw const FormatException('Unsupported storage envelope');
    }
    final payload = envelope['payload'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() !=
        envelope['checksum']) {
      throw const FormatException('Checksum mismatch');
    }
    return jsonDecode(payload) as Map<String, dynamic>;
  }

  Future<void> write(Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final payload = jsonEncode(value);
    final text = jsonEncode({
      'version': 1,
      'checksum': sha256.convert(utf8.encode(payload)).toString(),
      'payload': payload,
    });
    final staged = File('${file.path}.tmp');
    await staged.writeAsString(text, flush: true);
    if (await file.exists() && !recoveredBackup) {
      // Only a valid old generation is eligible to become the backup.
      try {
        final old = await file.readAsString();
        _decode(old);
        final backupStage = File('${file.path}.bak.tmp');
        await backupStage.writeAsString(old, flush: true);
        await backupStage.rename('${file.path}.bak');
      } on FormatException {
        // Preserve an existing good backup when the main generation is corrupt.
      } on TypeError {
        // Same rule for malformed envelopes.
      }
    }
    await staged.rename(file.path);
    recoveredBackup = false;
  }
}
