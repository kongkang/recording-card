import 'dart:io';

import '../analysis/analysis_gateway.dart';
import '../model_gateway/model_gateway.dart';
import '../transcription/asr_model_store.dart';

/// No secrets: explicit approved model ID and audited model mirror only.
class RuntimeConfig {
  const RuntimeConfig();
  static const allowModelDownload = bool.fromEnvironment(
    'RC_ASR_ALLOW_DOWNLOAD',
  );
  static const licenseAccepted = bool.fromEnvironment(
    'RC_ASR_LICENSE_ACCEPTED',
  );
  static const modelUrl = String.fromEnvironment('RC_ASR_MODEL_URL');
  static const tokensUrl = String.fromEnvironment('RC_ASR_TOKENS_URL');
  static const downloadHosts = String.fromEnvironment('RC_ASR_DOWNLOAD_HOSTS');
  static const uploadUrl = String.fromEnvironment('RC_UPLOAD_URL');
  static const vadUrl = String.fromEnvironment('RC_VAD_URL');
  static const vadSha256 = String.fromEnvironment('RC_VAD_SHA256');
  static const vadSize = int.fromEnvironment('RC_VAD_SIZE');
  static const uploadHosts = String.fromEnvironment('RC_UPLOAD_HOSTS');
  static const uploadContractApproved = bool.fromEnvironment(
    'RC_UPLOAD_RAW_CONTRACT_APPROVED',
  );
  static const uploadBearerApproved = bool.fromEnvironment(
    'RC_UPLOAD_OAUTH_BEARER_APPROVED',
  );
  static const firmwareManifest = String.fromEnvironment(
    'RC_FIRMWARE_MANIFEST_JSON',
  );

  static Set<String> hosts(String csv) => csv
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
  AsrModelStore models(Directory directory) => AsrModelStore(
    directory: directory,
    licenseAccepted: licenseAccepted,
    allowedDownloadHosts: hosts(downloadHosts),
    model: ModelArtifact(
      fileName: senseVoiceInt8Artifact.fileName,
      sizeBytes: senseVoiceInt8Artifact.sizeBytes,
      sha256Digest: senseVoiceInt8Artifact.sha256Digest,
      downloadUri: modelUrl.isEmpty ? null : Uri.parse(modelUrl),
    ),
    tokens: ModelArtifact(
      fileName: senseVoiceTokensArtifact.fileName,
      sizeBytes: senseVoiceTokensArtifact.sizeBytes,
      sha256Digest: senseVoiceTokensArtifact.sha256Digest,
      downloadUri: tokensUrl.isEmpty ? null : Uri.parse(tokensUrl),
    ),
    vad: vadSha256.isEmpty && vadSize == 0 && vadUrl.isEmpty
        ? null
        : ModelArtifact(
            fileName: 'silero_vad.onnx',
            sizeBytes: vadSize,
            sha256Digest: vadSha256,
            downloadUri: vadUrl.isEmpty ? null : Uri.parse(vadUrl),
          ),
  );
}

/// Directory validation is deferred to the user's first analysis action. No
/// auto fallback or model request on startup; an explicit approved ID is needed.
class AuthorizedAnalysisGateway implements AnalysisGateway {
  AuthorizedAnalysisGateway(this.gateway);
  final ModelGateway gateway;
  String? _validated;
  @override
  Future<String> complete(String prompt, {String? model}) async {
    final id = (model ?? gateway.configuredModel).trim();
    if (id.isEmpty) throw StateError('请在无密钥构建配置 RC_TEXT_MODEL 中指定获批文本模型ID');
    if (_validated != id) {
      final models = await gateway.listTextModels();
      if (!models.any((m) => m.id == id && m.supportsText)) {
        throw StateError('配置模型不在当前账号授权的文本模型目录中');
      }
      _validated = id;
    }
    return gateway.complete(prompt, model: id);
  }
}
