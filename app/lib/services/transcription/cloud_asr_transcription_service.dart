/// 云端 ASR 适配器 —— 把现有 ModelGateway.transcribe 包成
/// [TranscriptionService]，供分段转写管线复用。
library;

import 'dart:typed_data';

import '../net/model_gateway.dart';
import 'transcription.dart';

typedef AsrTranscribeCall = Future<TranscriptionResult> Function(
  Uint8List bytes, {
  String? language,
});

class CloudAsrTranscriptionService implements TranscriptionService {
  CloudAsrTranscriptionService(this._call);

  final AsrTranscribeCall _call;

  @override
  Future<TranscriptResult> transcribe(
    Uint8List audio, {
    String? language,
  }) async {
    final result = await _call(audio, language: language);
    return TranscriptResult(
      rawText: result.text,
      cleanText: result.text,
      language: result.language,
    );
  }
}
