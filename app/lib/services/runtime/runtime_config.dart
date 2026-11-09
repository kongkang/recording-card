import 'dart:io';

import '../analysis/analysis_gateway.dart';
import '../model_gateway/model_gateway.dart';
import '../transcription/asr_model_store.dart';
import '../transcription/bundled_vad_model.dart';

/// No secrets: explicit approved model ID and audited model mirror only.
class RuntimeConfig {
  const RuntimeConfig({
    this.modelArtifactProfile = asrArtifactProfile,
    this.localArtifactUseApproved = asrLocalArtifactsApproved,
  });
  static const productionArtifactProfile = 'sensevoice-mobile-20240717';
  static const localArtifactProfile = 'reai-vibe-board-local-20261109';
  static const asrArtifactProfile = String.fromEnvironment(
    'RC_ASR_ARTIFACT_PROFILE',
    defaultValue: productionArtifactProfile,
  );
  static const asrLocalArtifactsApproved = bool.fromEnvironment(
    'RC_ASR_LOCAL_ARTIFACTS_APPROVED',
  );
  final String modelArtifactProfile;
  final bool localArtifactUseApproved;
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
  AsrModelStore models(Directory directory) {
    if (modelArtifactProfile == localArtifactProfile) {
      if (!localArtifactUseApproved) {
        throw ArgumentError(
          '本机开发artifact必须显式批准RC_ASR_LOCAL_ARTIFACTS_APPROVED',
        );
      }
      // Deliberately local-only: do not attach URLs for the DIFFERENT default
      // registry weights, or silently replace this explicitly chosen artifact.
      return AsrModelStore(
        directory: directory,
        licenseAccepted: licenseAccepted,
        model: localSenseVoiceInt8Artifact,
        tokens: senseVoiceTokensArtifact,
        vad: BundledVadModel.artifact,
      );
    }
    if (modelArtifactProfile != productionArtifactProfile) {
      throw ArgumentError('未知本地ASR artifact profile：$modelArtifactProfile');
    }
    return AsrModelStore(
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
          ? BundledVadModel.artifact
          : ModelArtifact(
              fileName: 'silero_vad.onnx',
              sizeBytes: vadSize,
              sha256Digest: vadSha256,
              downloadUri: vadUrl.isEmpty ? null : Uri.parse(vadUrl),
            ),
    );
  }
}

/// Directory access is deferred to the user's analysis action, never startup.
/// With no configured ID, select ONCE per OAuth identity epoch from the actual
/// authorized text catalog. GatewayModel exposes no server-default metadata, so
/// the first choice follows server catalog order (not price/name/local IDs).
/// A removed/failed chosen model is an error, never a reason to switch models.
class AuthorizedAnalysisGateway implements AnalysisGateway {
  AuthorizedAnalysisGateway(this.gateway, {this.sessionEpoch});
  final ModelGateway gateway;

  /// Wire the SAME gateway's tokenStore.userIdentityEpoch. Optional only for
  /// explicit-ID callers; automatic choice fails closed without this binding.
  final int Function()? sessionEpoch;
  static const firstChoicePolicy =
      'first_authorized_text_in_server_catalog_order';
  int? _choiceEpoch;
  String? _firstChoice;
  Future<String>? _choosing;

  @override
  Future<String> complete(String prompt, {String? model}) async {
    if (prompt.trim().isEmpty) {
      throw const GatewayException('empty_prompt', '文本模型输入不能为空');
    }
    var id = (model ?? gateway.configuredModel).trim();
    final epoch = sessionEpoch?.call();
    if (id.isEmpty) {
      // An explicitly supplied empty ID is invalid, not an auto-choice request.
      if (model != null) {
        throw const GatewayException('model_not_configured', '明确选择的文本模型ID不能为空');
      }
      if (epoch == null) {
        throw const GatewayException(
          'session_epoch_required',
          '空默认模型需要绑定当前OAuth会话epoch后才能按授权目录选择',
        );
      }
      if (_choiceEpoch != epoch) {
        _choiceEpoch = epoch;
        _firstChoice = null;
        _choosing = null;
      }
      id = _firstChoice ?? await (_choosing ??= _chooseFirst(epoch));
    }
    _checkEpoch(epoch);
    // ModelGateway re-fetches /models and validates this EXACT ID before POST.
    // No validation cache can bypass fresh account permission or trigger fallback.
    final result = await gateway.complete(prompt, model: id);
    _checkEpoch(epoch);
    return result;
  }

  Future<String> _chooseFirst(int epoch) async {
    try {
      final catalog = await gateway.listTextModels();
      _checkEpoch(epoch);
      final textModels = catalog.where((item) => item.supportsText);
      if (textModels.isEmpty) {
        throw const GatewayException('no_text_models', '当前账号没有可用的已授权文本模型');
      }
      final id = textModels.first.id;
      if (id.trim().isEmpty) {
        throw const GatewayException('invalid_catalog', '模型目录包含无效模型ID');
      }
      _firstChoice = id;
      return id;
    } finally {
      // An old in-flight lookup must never clear a newer session's lookup.
      if (_choiceEpoch == epoch) _choosing = null;
    }
  }

  void _checkEpoch(int? epoch) {
    if (epoch != null && sessionEpoch!() != epoch) {
      throw const AuthRequiredException();
    }
  }
}
