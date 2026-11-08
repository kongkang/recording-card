/// 模型目录探测 —— 登录后向后端问"有哪些模型可用"，而不是在客户端硬编码模型名。
///
/// 参考工程的口径（见 reai_mobile_app `docs/model-oss.md`）：
/// `GET /api/model-gateway/v1/models` 用当前用户的 OAuth 鉴权调用一次，
/// 响应里的模型 `id` 与 `capabilities` 是唯一可用的真源——ASR 需要 `asr` 能力，
/// 文本总结需要 `text` 能力。这个调用不产生推理用量。
///
/// 我们不猜模型名、也不内置兜底：探测失败就如实返回 null，界面显示"服务不可用"。
library;

import 'dart:convert';

import 'authorized_http_client.dart';
import 'api_exception.dart';

/// 网关里的一个模型。
class GatewayModel {
  const GatewayModel({required this.id, required this.capabilities});
  final String id;
  final Set<String> capabilities;

  bool has(String capability) => capabilities.contains(capability);
}

class ModelCatalog {
  const ModelCatalog(this.models);

  final List<GatewayModel> models;

  /// 第一个具备指定能力的模型（服务端返回顺序即优先级）。
  String? firstWith(String capability) {
    for (final m in models) {
      if (m.has(capability)) return m.id;
    }
    return null;
  }

  String? get asrModel => firstWith('asr');

  /// 文本能力：不同版本后端可能标成 `text` / `chat`。
  String? get textModel => firstWith('text') ?? firstWith('chat');

  bool get isEmpty => models.isEmpty;

  /// 拉取一次模型目录。失败抛 [ApiException]（带中文文案），由调用方决定降级。
  static Future<ModelCatalog> fetch(
    AuthorizedHttpClient client, {
    required String gatewayBaseUrl,
    Duration? timeout,
  }) async {
    final response = await client.getJson(
      '$gatewayBaseUrl/models',
      timeout: timeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiHttpException(
        '获取模型列表失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      throw ApiFormatException('模型列表解析失败', e);
    }

    // 兼容 `{data: [...]}` / `{models: [...]}` / 裸数组三种形态
    final List<Object?> raw;
    if (decoded is List) {
      raw = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final list = decoded['data'] ?? decoded['models'];
      raw = list is List ? list : const [];
    } else {
      raw = const [];
    }

    final models = <GatewayModel>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = item['id'] ?? item['model'] ?? item['name'];
      if (id is! String || id.trim().isEmpty) continue;
      final capsRaw = item['capabilities'] ?? item['capability'] ?? const [];
      final caps = <String>{
        if (capsRaw is List)
          for (final c in capsRaw)
            if (c != null) '$c'.toLowerCase(),
        if (capsRaw is String) capsRaw.toLowerCase(),
      };
      models.add(GatewayModel(id: id.trim(), capabilities: caps));
    }
    return ModelCatalog(models);
  }
}
