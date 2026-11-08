/// 模型网关配置 —— `RC_MODEL_GATEWAY_BASE_URL` 指向 `/api/model-gateway/v1`，
/// `RC_TEXT_MODEL` / `RC_ASR_MODEL` 显式指定模型；为空即未配置，不回落假模型。
library;

class ModelGatewayConfig {
  const ModelGatewayConfig({
    required this.baseUrl,
    required this.textModel,
    required this.asrModel,
  });

  static const fromEnvironment = ModelGatewayConfig(
    baseUrl: String.fromEnvironment('RC_MODEL_GATEWAY_BASE_URL'),
    textModel: String.fromEnvironment('RC_TEXT_MODEL'),
    asrModel: String.fromEnvironment('RC_ASR_MODEL'),
  );

  final String baseUrl;
  final String textModel;
  final String asrModel;

  bool get isConfigured {
    if (textModel.trim().isEmpty) return false;
    final uri = Uri.tryParse(baseUrl.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty;
  }

  String get _base => baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

  Uri get modelsUri => Uri.parse('$_base/models');
  Uri get chatCompletionsUri => Uri.parse('$_base/chat/completions');
}
