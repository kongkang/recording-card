import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/runtime/runtime_config.dart';
import 'package:recording_card/services/transcription/audio_decoder.dart';
import 'package:recording_card/services/transcription/bundled_vad_model.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

class _CountingBackend implements TranscriptionBackend {
  int calls = 0;
  @override
  Future<TranscriptionResult> transcribe(
    AudioFileInput input,
    AsrModelPaths model, {
    required TranscriptionOptions options,
    required CancellationToken cancellation,
    void Function(TranscriptionProgress)? onProgress,
  }) async {
    calls++;
    return const TranscriptionResult(
      text: '',
      audioDuration: Duration(seconds: 1),
      segments: [],
      vadVerified: true,
    );
  }

  @override
  Future<void> close() async {}
}

Matcher _code(String code) =>
    isA<TranscriptionException>().having((error) => error.code, 'code', code);

void main() {
  test('8k inference normalization preserves duration, samples and source', () {
    final audio = DecodedAudio(Float32List.fromList([0, 0.5, -0.5]), 8000);
    final normalized = AudioDecoder.forLocalModels(audio);
    expect(normalized.sampleRate, 16000);
    expect(normalized.samples, [0, 0.25, 0.5, 0, -0.5, -0.5]);
    expect(normalized.duration, audio.duration);
    expect(audio.samples, [0, 0.5, -0.5]);
    expect(AudioDecoder.forLocalModels(normalized), same(normalized));
  });

  test(
    'default production artifact remains the original exact size and hash',
    () {
      final store = const RuntimeConfig().models(Directory('/unused'));
      expect(store.model.sizeBytes, 239233841);
      expect(
        store.model.sha256Digest,
        'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
      );
      expect(
        store.model.sha256Digest,
        isNot(localSenseVoiceInt8Artifact.sha256Digest),
      );
    },
  );

  test('local artifact profile requires separate explicit approval', () {
    expect(
      () => const RuntimeConfig(
        modelArtifactProfile: RuntimeConfig.localArtifactProfile,
      ).models(Directory('/unused')),
      throwsArgumentError,
    );
    final store = const RuntimeConfig(
      modelArtifactProfile: RuntimeConfig.localArtifactProfile,
      localArtifactUseApproved: true,
    ).models(Directory('/unused'));
    expect(store.model.sizeBytes, 237115547);
    expect(
      store.model.sha256Digest,
      '12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d',
    );
    expect(store.tokens, same(senseVoiceTokensArtifact));
    expect(store.vad, same(BundledVadModel.artifact));
    expect(store.model.downloadUri, isNull);
    expect(store.tokens.downloadUri, isNull);
    expect(store.vad!.downloadUri, isNull);
    expect(store.allowedDownloadHosts, isEmpty);
    // Artifact approval never doubles as accepting the model license.
    expect(store.licenseAccepted, RuntimeConfig.licenseAccepted);
  });

  test('unknown artifact profile never silently chooses another model', () {
    expect(
      () => const RuntimeConfig(
        modelArtifactProfile: 'unknown',
        localArtifactUseApproved: true,
      ).models(Directory('/unused')),
      throwsArgumentError,
    );
  });

  test(
    'missing model reports waiting, retains source and permits later retry',
    () async {
      final dir = await Directory.systemTemp.createTemp('local-models-test-');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/source.pcm');
      await source.writeAsBytes([0, 0, 0, 0]);
      ModelArtifact pin(String name, List<int> bytes) => ModelArtifact(
        fileName: name,
        sizeBytes: bytes.length,
        sha256Digest: sha256.convert(bytes).toString(),
      );
      final backend = _CountingBackend();
      final service = TranscriptionService(
        models: AsrModelStore(
          directory: dir,
          model: pin('model.onnx', [1]),
          tokens: pin('tokens.txt', [2]),
          vad: pin('vad.onnx', [3]),
          licenseAccepted: true,
        ),
        backend: backend,
      );
      addTearDown(service.close);
      final stages = <TranscriptionProgress>[];
      await expectLater(
        service.transcribeFile(
          source.path,
          format: AudioFileFormat.pcm16,
          onProgress: stages.add,
        ),
        throwsA(_code('model_missing')),
      );
      expect(stages.last.stage, TranscriptionStage.waitingForModel);
      expect(stages.last.errorCode, 'model_missing');
      expect(stages.last.message, contains('音频保留本机'));
      expect(stages.last.message, contains('不会上传音频'));
      expect(backend.calls, 0);
      expect(await source.readAsBytes(), [0, 0, 0, 0]);
      await File('${dir.path}/model.onnx').writeAsBytes([1]);
      await File('${dir.path}/tokens.txt').writeAsBytes([2]);
      // Installing only ASR does not bypass missing VAD.
      await expectLater(
        service.transcribeFile(source.path, format: AudioFileFormat.pcm16),
        throwsA(_code('model_missing')),
      );
      expect(backend.calls, 0);
      await File('${dir.path}/vad.onnx').writeAsBytes([3]);
      await service.transcribeFile(source.path, format: AudioFileFormat.pcm16);
      expect(backend.calls, 1);
      await File('${dir.path}/vad.onnx').writeAsBytes([4]);
      await expectLater(
        service.transcribeFile(
          source.path,
          format: AudioFileFormat.pcm16,
          onProgress: stages.add,
        ),
        throwsA(_code('model_corrupt')),
      );
      expect(stages.last.errorCode, 'model_corrupt');
      expect(backend.calls, 1);
      expect(await source.exists(), isTrue);
    },
  );
}
