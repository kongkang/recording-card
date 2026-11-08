/// 转写管线 —— 把 Setting 里的开关真正作用到转写结果上。
///
/// 规则（与设计基线一致）：
/// - '自动转录' 关闭：不调用服务，返回 null（录音本身照常保存）。
/// - 调用服务后 rawText 原样保留，任何开关都不丢原文。
/// - '自动清洗口语' 关闭：cleanText 回填为 rawText。
/// - '说话人推测归类' 关闭：turns 置空，raw / clean 仍保留。
/// - 服务异常向上抛，不伪造成功结果。
library;

import 'dart:typed_data';

import '../../core/store/settings_store.dart';
import 'transcription.dart';

class TranscriptionPipeline {
  TranscriptionPipeline({required this.service, required this.settings});

  final TranscriptionService service;
  final SettingsStore settings;

  static const autoTranscribeKey = 'rc.set.trans.auto';
  static const cleanSpeechKey = 'rc.set.trans.clean';
  static const speakerLabelKey = 'rc.set.trans.speaker';

  /// 返回 null 表示用户关闭了自动转录；其余情况返回非空结果。
  Future<TranscriptResult?> process(Uint8List audio, {String? language}) async {
    if (!settings.value(autoTranscribeKey)) return null;

    final result = await service.transcribe(audio, language: language);
    final cleanEnabled = settings.value(cleanSpeechKey);
    final speakerEnabled = settings.value(speakerLabelKey);

    // 开关都开且服务已给出完整结果时原样返回，不做无谓重建。
    if (cleanEnabled && (speakerEnabled || result.turns.isEmpty)) {
      return result;
    }

    return TranscriptResult(
      rawText: result.rawText,
      cleanText: cleanEnabled ? result.cleanText : result.rawText,
      turns: speakerEnabled
          ? result.turns
          : const <TranscriptionTurn>[],
      language: result.language,
    );
  }
}
