library;

import 'client_config.dart';

/// 后端模型网关配置（ASR 转写 + 文本总结统一走网关，不再直连第三方 provider）。
///
/// 端点约定（与参考工程 reai_mobile_app 的 `ModelGatewayConfig` 对齐）：
/// - 网关根：`${apiBase}/api/model-gateway/v1`
/// - 转写：`${网关根}/audio/transcriptions`（multipart，OpenAI 兼容）
/// - 总结：`${网关根}/chat/completions`（JSON body `{model, stream:false, ...}`）
///
/// 模型名**必须显式配置**：`--dart-define=RC_MODEL_ASR=...`、
/// `--dart-define=RC_MODEL_REFINE=...`。客户端不会猜模型、也不内置兜底模型名，
/// 未配置即「该能力不可用」（[asrConfigured] / [refineConfigured] 为 false）。
class ModelGatewayConfig {
  const ModelGatewayConfig({
    required this.baseUrl,
    required this.asrModel,
    required this.refineModel,
  });

  /// 从编译期环境解析（dart-define 优先，其次 [ClientConfig] 的编译默认）。
  factory ModelGatewayConfig.fromEnvironment({ClientConfig? clientConfig}) {
    final cfg = clientConfig ?? ClientConfig.instance;

    final asrDart = String.fromEnvironment('RC_MODEL_ASR');
    final hasAsrDart = bool.hasEnvironment('RC_MODEL_ASR');
    final refineDart = String.fromEnvironment('RC_MODEL_REFINE');
    final hasRefineDart = bool.hasEnvironment('RC_MODEL_REFINE');

    return ModelGatewayConfig(
      baseUrl: cfg.apiBase,
      asrModel: _resolveModel(
        hasDartDefine: hasAsrDart,
        dartDefineValue: asrDart,
      ),
      refineModel: _resolveModel(
        hasDartDefine: hasRefineDart,
        dartDefineValue: refineDart,
      ),
    );
  }

  /// 网关根路径（与 [baseUrl] 拼接）。
  static const String gatewayPath = '/api/model-gateway/v1';

  /// 网关使用的 API 主机；null = 未配置后端。
  final String? baseUrl;

  /// ASR 模型名；空字符串 = 未配置。
  final String asrModel;

  /// 总结（chat）模型名；空字符串 = 未配置。
  final String refineModel;

  /// 网关根是否可用（必须是 https 主机，防 token 在明文链路里裸奔）。
  bool get configured => isHttpsUrl(baseUrl);

  /// ASR 能力是否配置齐全。
  bool get asrConfigured => configured && asrModel.trim().isNotEmpty;

  /// 总结能力是否配置齐全。
  bool get refineConfigured => configured && refineModel.trim().isNotEmpty;

  /// 转写端点；未配置时为 null。
  String? get audioTranscriptionsUrl =>
      configured ? '$gatewayBaseUrl/audio/transcriptions' : null;

  /// 总结端点；未配置时为 null。
  String? get chatCompletionsUrl =>
      configured ? '$gatewayBaseUrl/chat/completions' : null;

  /// 归一化后的网关根（已去尾斜杠；若 `RC_API_BASE` 里已带网关路径则不再重复拼接）。
  String get gatewayBaseUrl {
    final base = (baseUrl ?? '').trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) return '';
    final path = Uri.tryParse(base)?.path ?? '';
    if (path.endsWith(gatewayPath)) return base;
    return '$base$gatewayPath';
  }

  /// 是否为 https 地址（纵深防御：拒绝明文端点，防 token 被明文上行）。
  static bool isHttpsUrl(String? url) =>
      Uri.tryParse((url ?? '').trim())?.isScheme('https') ?? false;

  /// 模型名解析：dart-define 非空才算配置（显式优于隐式，不做 compile 兜底）。
  static String _resolveModel({
    required bool hasDartDefine,
    required String dartDefineValue,
  }) {
    final value = dartDefineValue.trim();
    if (hasDartDefine && value.isNotEmpty) return value;
    return '';
  }
}
