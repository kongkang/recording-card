/// 本地模型路径解析接缝 —— 管线只关心"四个模型文件在哪"，不关心下载/安装。
library;

/// 当启用 iOS 26+ 系统自带语音识别时使用的哨兵模型路径。
const String kSystemSpeechSentinelModelPath = '__ios_system_speech__';

class SpeechModelPaths {
  const SpeechModelPaths({
    required this.asrModelPath,
    required this.tokensPath,
    required this.vadPath,
    this.speakerEmbeddingPath,
  });

  final String asrModelPath;
  final String tokensPath;
  final String vadPath;

  /// 为空表示声纹模型未安装：管线仍转写，只是不标说话人。
  final String? speakerEmbeddingPath;

  bool get usesSystemAsr => asrModelPath == kSystemSpeechSentinelModelPath;

  bool get canTranscribe =>
      vadPath.isNotEmpty &&
      (usesSystemAsr || (asrModelPath.isNotEmpty && tokensPath.isNotEmpty));

  bool get canLabelSpeakers =>
      speakerEmbeddingPath != null && speakerEmbeddingPath!.isNotEmpty;
}

abstract interface class SpeechModelProvider {
  /// 所有必需模型就绪时返回路径；缺 ASR/VAD 返回 null。
  Future<SpeechModelPaths?> resolve();
}
