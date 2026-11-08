import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcription/audio_decoder.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';
import 'package:recording_card/services/transcription/sherpa_backend.dart';
import 'package:recording_card/services/analysis/processed_transcript.dart';

Matcher code(String c) =>
    isA<TranscriptionException>().having((e) => e.code, 'code', c);
Uint8List pcm(List<int> samples) {
  final b = Uint8List(samples.length * 2), data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  b.setAll(0, data.buffer.asUint8List());
  return b;
}

Uint8List wav(Uint8List samples, {int channels = 1, bool junk = false}) {
  final bytes = Uint8List(44 + samples.length + (junk ? 10 : 0));
  final b = ByteData.sublistView(bytes);
  void tag(int i, String s) => bytes.setRange(i, i + s.length, s.codeUnits);
  tag(0, 'RIFF');
  b.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  var offset = 12;
  if (junk) {
    tag(12, 'JUNK');
    b.setUint32(16, 1, Endian.little);
    bytes[20] = 9;
    offset += 10;
  }
  tag(offset, 'fmt ');
  b.setUint32(offset + 4, 16, Endian.little);
  b.setUint16(offset + 8, 1, Endian.little);
  b.setUint16(offset + 10, channels, Endian.little);
  b.setUint32(offset + 12, 16000, Endian.little);
  b.setUint32(offset + 16, 16000 * channels * 2, Endian.little);
  b.setUint16(offset + 20, channels * 2, Endian.little);
  b.setUint16(offset + 22, 16, Endian.little);
  offset += 24;
  tag(offset, 'data');
  b.setUint32(offset + 4, samples.length, Endian.little);
  bytes.setRange(offset + 8, bytes.length, samples);
  return bytes;
}

ModelArtifact artifact(String name, List<int> data, {Uri? uri}) =>
    ModelArtifact(
      fileName: name,
      sizeBytes: data.length,
      sha256Digest: sha256.convert(data).toString(),
      downloadUri: uri,
    );
Future<AsrModelStore> fixture(Directory root) async {
  await File('${root.path}/model.onnx').writeAsBytes([1, 2, 3]);
  await File('${root.path}/tokens.txt').writeAsBytes([4, 5]);
  return AsrModelStore(
    directory: root,
    model: artifact('model.onnx', [1, 2, 3]),
    tokens: artifact('tokens.txt', [4, 5]),
    licenseAccepted: true,
  );
}

class FakeBackend implements TranscriptionBackend {
  int active = 0, peak = 0, calls = 0;
  bool closed = false;
  Completer<void>? gate;
  @override
  Future<TranscriptionResult> transcribe(
    AudioFileInput input,
    AsrModelPaths model, {
    required TranscriptionOptions options,
    required CancellationToken cancellation,
    void Function(TranscriptionProgress)? onProgress,
  }) async {
    active++;
    calls++;
    if (active > peak) peak = active;
    try {
      if (gate != null) {
        await gate!.future;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      cancellation.throwIfCancelled();
      return const TranscriptionResult(
        text: '固定测试音频的测试替身',
        audioDuration: Duration(seconds: 1),
        segments: [
          TranscriptSegment(
            index: 0,
            start: Duration.zero,
            end: Duration(seconds: 1),
            text: '固定测试音频的测试替身',
          ),
        ],
      );
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test('known IMA vector follows low nibble first and persistent state', () {
    final decoder = CardAdpcmDecoder();
    expect(decoder.decode([0x21]), [1, 4]);
    expect(decoder.decode([0x43]), [8, 15]);
    expect(CardAdpcmDecoder().decode([0x21, 0x43]), [1, 4, 8, 15]);
    decoder.reset();
    expect(decoder.decode([0x21]), [1, 4]);
  });
  test('ADPCM clips predictor and preserves all samples', () {
    final samples = CardAdpcmDecoder().decode(List.filled(300, 0x77));
    expect(samples.length, 600);
    expect(samples.last, 32767);
  });
  test('PCM16 little endian normalization', () {
    final decoded = AudioDecoder.decode(
      pcm([-32768, 0, 16384, 32767]),
      AudioFileFormat.pcm16,
    );
    expect(decoded.samples[0], -1);
    expect(decoded.samples[2], 0.5);
    expect(decoded.sampleRate, 16000);
  });
  test('WAV extended odd chunk header and stereo downmix', () {
    final decoded = AudioDecoder.decode(
      wav(pcm([16384, -16384, 32767, 32767]), channels: 2, junk: true),
      AudioFileFormat.wav,
    );
    expect(decoded.samples, hasLength(2));
    expect(decoded.samples.first, 0);
    expect(decoded.samples.last, closeTo(1, 0.0001));
  });
  test('invalid/truncated/compressed WAV explicitly fails', () {
    final valid = wav(pcm([1, 2]));
    expect(
      () => AudioDecoder.decode(
        valid.sublist(0, valid.length - 1),
        AudioFileFormat.wav,
      ),
      throwsA(code('audio_corrupt')),
    );
    final compressed = wav(pcm([1, 2]));
    ByteData.sublistView(compressed).setUint16(20, 17, Endian.little);
    expect(
      () => AudioDecoder.decode(compressed, AudioFileFormat.wav),
      throwsA(code('audio_format')),
    );
  });
  test('duration/size/rate/misalignment limits are real errors', () {
    expect(
      () => AudioDecoder.decode(
        Uint8List(40000),
        AudioFileFormat.adpcm,
        options: const TranscriptionOptions(maxDuration: Duration(seconds: 1)),
      ),
      throwsA(code('audio_limit')),
    );
    expect(
      () => AudioDecoder.decode(Uint8List(3), AudioFileFormat.pcm16),
      throwsA(code('audio_corrupt')),
    );
    expect(
      () => AudioDecoder.decode(
        Uint8List(4),
        AudioFileFormat.pcm16,
        sampleRate: 44100,
      ),
      throwsA(code('audio_rate')),
    );
    expect(
      () => AudioDecoder.decode(
        Uint8List(100),
        AudioFileFormat.pcm16,
        options: const TranscriptionOptions(maxFileBytes: 20),
      ),
      throwsA(code('audio_limit')),
    );
  });
  test('model missing and license not accepted are fail-closed', () async {
    final dir = await Directory.systemTemp.createTemp('asr-model-test-');
    addTearDown(() => dir.delete(recursive: true));
    await expectLater(
      AsrModelStore(directory: dir).ensureReady(),
      throwsA(code('model_license')),
    );
    await expectLater(
      AsrModelStore(directory: dir, licenseAccepted: true).ensureReady(),
      throwsA(code('model_missing')),
    );
  });
  test('configured local models require exact SHA256 and size', () async {
    final dir = await Directory.systemTemp.createTemp('asr-model-test-');
    addTearDown(() => dir.delete(recursive: true));
    final store = await fixture(dir);
    expect((await store.ensureReady()).modelPath, '${dir.path}/model.onnx');
    await File('${dir.path}/model.onnx').writeAsBytes([9, 9, 9]);
    await expectLater(store.ensureReady(), throwsA(code('model_corrupt')));
  });
  test('untrusted or HTTP download refuses before any network', () async {
    final dir = await Directory.systemTemp.createTemp('asr-model-test-');
    addTearDown(() => dir.delete(recursive: true));
    final store = AsrModelStore(
      directory: dir,
      licenseAccepted: true,
      model: artifact('m.onnx', [1], uri: Uri.parse('http://localhost/m.onnx')),
      tokens: artifact('t.txt', [2]),
      allowedDownloadHosts: {'localhost'},
    );
    await expectLater(
      store.ensureReady(allowDownload: true),
      throwsA(code('model_source')),
    );
    expect(dir.listSync(), isEmpty);
  });
  test('manifest rejects traversal and absent hashes', () {
    expect(
      () => AsrModelStore(
        directory: Directory('/unused'),
        model: artifact('../m.onnx', [1]),
      ),
      throwsArgumentError,
    );
  });
  test(
    'serial task lane handles multiple files with no concurrent models',
    () async {
      final dir = await Directory.systemTemp.createTemp('asr-queue-test-');
      addTearDown(() => dir.delete(recursive: true));
      final backend = FakeBackend(),
          store = await fixture(dir),
          progress = <TranscriptionStage>[];
      final service = TranscriptionService(models: store, backend: backend);
      await Future.wait([
        service.transcribeFile(
          'a',
          format: AudioFileFormat.wav,
          onProgress: (p) => progress.add(p.stage),
        ),
        service.transcribeFile('b', format: AudioFileFormat.pcm16),
        service.transcribeFile('c', format: AudioFileFormat.adpcm),
      ]);
      expect(backend.peak, 1);
      expect(backend.calls, 3);
      expect(progress.last, TranscriptionStage.completed);
      await service.close();
      expect(backend.closed, isTrue);
    },
  );
  test(
    'queue full and queued cancellation do not infer fake success',
    () async {
      final dir = await Directory.systemTemp.createTemp('asr-queue-test-');
      addTearDown(() => dir.delete(recursive: true));
      final backend = FakeBackend()..gate = Completer<void>();
      final service = TranscriptionService(
        models: await fixture(dir),
        backend: backend,
        maxQueuedJobs: 1,
      );
      final first = service.transcribeFile('a', format: AudioFileFormat.wav);
      await expectLater(
        service.transcribeFile('b', format: AudioFileFormat.wav),
        throwsA(code('queue_full')),
      );
      backend.gate!.complete();
      await first;
      final token = CancellationToken()..cancel();
      await expectLater(
        service.transcribeFile(
          'c',
          format: AudioFileFormat.wav,
          cancellation: token,
        ),
        throwsA(isA<OperationCancelled>()),
      );
      expect(backend.calls, 1);
      await service.close();
    },
  );
  test(
    'native worker handles pre-model IO error and exits, no model call',
    () async {
      final backend = SherpaTranscriptionBackend();
      await expectLater(
        backend.transcribe(
          const AudioFileInput(
            '/no-such-asr-test-file',
            format: AudioFileFormat.wav,
          ),
          const AsrModelPaths(modelPath: '/no-model', tokensPath: '/no-tokens'),
          options: const TranscriptionOptions(),
          cancellation: CancellationToken(),
        ),
        throwsA(code('audio_missing')),
      );
      await backend.close();
    },
  );
  test('native metadata is preserved but never a fake voice identity', () {
    const s = TranscriptSegment(
      index: 0,
      start: Duration.zero,
      end: Duration(seconds: 1),
      text: 'test',
      tokens: ['test'],
      tokenTimestamps: [0.1],
      emotion: '<|HAPPY|>',
      audioEvent: '<|Speech|>',
    );
    expect(s.toJson()['emotion'], '<|HAPPY|>');
    expect(s.toJson()['speakerEmbedding'], isNull);
    final record = recordEventFromTranscription(
      id: 'r',
      title: 'test',
      startedAt: DateTime(2026, 11, 8, 9),
      transcript: const TranscriptionResult(
        text: 'test',
        audioDuration: Duration(seconds: 1),
        segments: [s],
      ),
    );
    expect(record.raw.single.spk, '未知');
    expect(record.srcMap, '来源 09:00:00—09:00:01');
  });
}
