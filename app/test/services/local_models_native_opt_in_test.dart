import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcription/bundled_vad_model.dart';
import 'package:recording_card/services/transcription/sherpa_backend.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

void main() {
  final directory = Platform.environment['ASR_LOCAL_TEST_MODEL_DIR'];
  final wav = Platform.environment['ASR_LOCAL_TEST_WAV'];
  final library = Platform.environment['ASR_NATIVE_LIBRARY_DIR'];
  final approved =
      Platform.environment['ASR_LOCAL_ARTIFACTS_APPROVED'] == 'true';
  final accepted = Platform.environment['ASR_MODEL_LICENSE_ACCEPTED'] == 'true';
  final skip = directory == null || wav == null || !approved || !accepted
      ? 'Requires explicit local artifact approval, model license and non-sensitive local fixture'
      : false;

  AsrModelStore store() => AsrModelStore(
    directory: Directory(directory!),
    model: localSenseVoiceInt8Artifact,
    tokens: senseVoiceTokensArtifact,
    vad: BundledVadModel.artifact,
    licenseAccepted: accepted,
    nativeLibraryPath: library,
  );

  test('local measured SenseVoice artifact recognizes offline on CPU with real VAD', () async {
    final service = TranscriptionService(models: store());
    try {
      final result = await service.transcribeFile(
        wav!,
        format: AudioFileFormat.wav,
      );
      expect(result.text.trim(), isNotEmpty);
      expect(result.vadVerified, isTrue);
      expect(result.vadSpeechRangesMs, isNotEmpty);
      for (final segment in result.segments) {
        expect(segment.start, greaterThanOrEqualTo(Duration.zero));
        expect(segment.end, lessThanOrEqualTo(result.audioDuration));
        expect(segment.end, greaterThan(segment.start));
      }
    } finally {
      await service.close();
    }
  }, skip: skip);

  for (final rate in [8000, 16000]) {
    test(
      'real Silero verifies ${rate}Hz silence without loading ASR or fabricating text',
      () async {
        final paths = await store()
            .ensureReady(); // exact model/tokens/VAD pins
        final temp = await Directory.systemTemp.createTemp(
          'local-vad-silence-',
        );
        final backend = SherpaTranscriptionBackend();
        try {
          final silence = File('${temp.path}/silence.pcm');
          await silence.writeAsBytes(Uint8List(rate * 2 * 2));
          final result = await backend.transcribe(
            AudioFileInput(
              silence.path,
              format: AudioFileFormat.pcm16,
              sampleRate: rate,
            ),
            AsrModelPaths(
              // Invalid ASR paths prove a VAD-empty plan never allocates ASR.
              modelPath: '/must-not-load-model-on-verified-silence',
              tokensPath: '/must-not-load-tokens-on-verified-silence',
              vadPath: paths.vadPath,
              nativeLibraryPath: library,
            ),
            options: const TranscriptionOptions(),
            cancellation: CancellationToken(),
          );
          expect(result.vadVerified, isTrue);
          expect(result.vadSpeechRangesMs, isEmpty);
          expect(result.text, isEmpty);
          expect(result.segments, isEmpty);
          expect(result.audioDuration, const Duration(seconds: 2));
          expect(await silence.exists(), isTrue);
        } finally {
          await backend.close();
          await temp.delete(recursive: true);
        }
      },
      skip: skip,
    );
  }
}
