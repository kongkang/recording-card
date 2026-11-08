import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcription/bundled_vad_model.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

void main() {
  final directory = Platform.environment['ASR_TEST_MODEL_DIR'];
  final wav = Platform.environment['ASR_TEST_WAV'];
  final accepted = Platform.environment['ASR_MODEL_LICENSE_ACCEPTED'] == 'true';
  test(
    'verified SenseVoice plus real Silero VAD yields bounded native speech ranges',
    () async {
      final vad = File('$directory/${BundledVadModel.artifact.fileName}');
      if (!await vad.exists()) {
        await File(BundledVadModel.assetPath).copy(vad.path);
      }
      final service = TranscriptionService(
        models: AsrModelStore(
          directory: Directory(directory!),
          licenseAccepted: accepted,
          vad: BundledVadModel.artifact,
          nativeLibraryPath: Platform.environment['ASR_NATIVE_LIBRARY_DIR'],
        ),
      );
      try {
        final result = await service.transcribeFile(
          wav!,
          format: AudioFileFormat.wav,
        );
        expect(result.text.trim(), isNotEmpty);
        expect(result.vadVerified, isTrue);
        expect(result.vadSpeechRangesMs, isNotEmpty);
        for (final span in result.vadSpeechRangesMs) {
          expect(span[0], greaterThanOrEqualTo(0));
          expect(span[1], greaterThan(span[0]));
          expect(
            span[1],
            lessThanOrEqualTo(result.audioDuration.inMilliseconds),
          );
        }
        // This fixture is publicly distributed upstream, not a user's recording.
        // No request is made to a cloud model or speech API by this test.
      } finally {
        await service.close();
      }
    },
    skip: directory == null || wav == null || !accepted
        ? 'Native VAD/ASR requires explicitly accepted pinned models and a non-sensitive local fixture'
        : false,
  );
}
