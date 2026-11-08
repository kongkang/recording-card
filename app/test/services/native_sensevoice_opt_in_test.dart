import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

/// This is NOT counted as native inference passed when skipped. Only use a
/// licensed, non-sensitive fixture and explicitly accepted model license.
void main() {
  final dir = Platform.environment['ASR_TEST_MODEL_DIR'];
  final wav = Platform.environment['ASR_TEST_WAV'];
  final accepted = Platform.environment['ASR_MODEL_LICENSE_ACCEPTED'] == 'true';
  test(
    'opt-in: verified SenseVoice native model transcribes fixed fixture',
    () async {
      final service = TranscriptionService(
        models: AsrModelStore(
          directory: Directory(dir!),
          licenseAccepted: accepted,
          nativeLibraryPath: Platform.environment['ASR_NATIVE_LIBRARY_DIR'],
        ),
      );
      try {
        final result = await service.transcribeFile(
          wav!,
          format: AudioFileFormat.wav,
        );
        expect(result.segments, isNotEmpty);
        expect(result.audioDuration, greaterThan(Duration.zero));
        expect(result.text.trim(), isNotEmpty);
        // Any returned CTC metadata comes from native; no speaker IDs invented.
        for (final s in result.segments) {
          expect(s.end, lessThanOrEqualTo(result.audioDuration));
        }
      } finally {
        await service.close();
      }
    },
    skip: dir == null || wav == null || !accepted
        ? '未配置已校验模型、获许可固定测试音频和模型许可确认；不能据此声称真实ASR通过'
        : false,
  );
}
