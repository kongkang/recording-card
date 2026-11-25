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
  const GatewayModel({
    required this.id,
    required this.capabilities,
    this.available = true,
    this.unavailableReasons = const [],
    this.chatAvailable,
    this.thinkingSupportsOff = false,
  });

  final String id;
  final Set<String> capabilities;
  final bool available;
  final List<String> unavailableReasons;
  final bool? chatAvailable;
  final bool thinkingSupportsOff;

  bool has(String capability) => capabilities.contains(capability);

  bool get isChatAvailable => available && (chatAvailable ?? true);
}

class ModelCatalog {
  const ModelCatalog(this.models);

  final List<GatewayModel> models;

  GatewayModel? byId(String id) {
    final target = id.trim();
    if (target.isEmpty) return null;
    for (final m in models) {
      if (m.id == target) return m;
    }
    return null;
  }

  /// 第一个具备指定能力且当前供货可用的模型。
  String? firstAvailableWith(String capability, {bool requireChat = false}) {
    for (final m in models) {
      final ready = requireChat ? m.isChatAvailable : m.available;
      if (ready && m.has(capability)) return m.id;
    }
    return null;
  }

  /// 第一个具备指定能力的模型（优先可用模型，服务端返回顺序即优先级）。
  String? firstWith(String capability) {
    final availableMatch = firstAvailableWith(capability);
    if (availableMatch != null) return availableMatch;
    for (final m in models) {
      if (m.has(capability)) return m.id;
    }
    return null;
  }

  static const List<String> _nonChatTokens = <String>[
    'asr',
    'stt',
    'whisper',
    'embedding',
    'tts',
    'rerank',
    'moderation',
    'dall-e',
    'transcribe',
    'realtime',
    'sora',
  ];

  static bool _isNonChatId(String id) {
    final lower = id.toLowerCase();
    return _nonChatTokens.any(lower.contains);
  }

  String? get asrModel => firstAvailableWith('asr') ?? firstWith('asr');

  /// 文本能力：优先挑可用模型，不同版本后端可能标成 `text` / `chat`；若网关未附带
  /// capabilities 字段，则回退挑选首个非语音/向量类模型，避免标准 OpenAI 列表误判为空。
  String? get textModel =>
      _pickTextModel(models.where((m) => m.isChatAvailable)) ??
      _pickTextModel(models);

  String? _pickTextModel(Iterable<GatewayModel> pool) {
    for (final m in pool) {
      if (m.has('text')) return m.id;
    }
    for (final m in pool) {
      if (m.has('chat')) return m.id;
    }
    for (final m in pool) {
      if (m.capabilities.isNotEmpty &&
          m.capabilities.every(_nonChatTokens.contains)) {
        continue;
      }
      if (_isNonChatId(m.id)) continue;
      return m.id;
    }
    return null;
  }

  /// 当前可直接用于 `/chat/completions` 多模态识图的可用模型列表（按网关优先级排序）。
  List<String> get availableVisionModels => [
    for (final m in models)
      if (m.isChatAvailable && (m.has('vision') || m.has('multimodal'))) m.id,
  ];

  /// 多模态视觉能力：优先匹配可用 `vision` / `multimodal`，再匹配非纯生图类 `image`，
  /// 最后兜底复用文本对话模型。
  String? get visionModel {
    final direct = availableVisionModels;
    if (direct.isNotEmpty) return direct.first;
    for (final m in models) {
      if (m.isChatAvailable &&
          m.has('image') &&
          !m.has('image-generation') &&
          !m.has('image-edit') &&
          !_isNonChatId(m.id)) {
        return m.id;
      }
    }
    return textModel;
  }

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
      final availRaw = item['availability'];
      var available = true;
      var reasons = const <String>[];
      if (availRaw is Map) {
        if (availRaw['available'] is bool) {
          available = availRaw['available'] as bool;
        }
        final rawReasons = availRaw['reasons'];
        if (rawReasons is List) {
          reasons = [
            for (final r in rawReasons)
              if (r != null && '$r'.trim().isNotEmpty) '$r'.trim(),
          ];
        }
      }
      bool? chatAvailable;
      final opsRaw = item['operations'];
      if (opsRaw is List) {
        for (final op in opsRaw) {
          if (op is Map && op['id'] == 'chat') {
            final opAvail = op['availability'];
            if (opAvail is Map && opAvail['available'] is bool) {
              chatAvailable = opAvail['available'] as bool;
            }
            break;
          }
        }
      }
      final thinkingRaw = item['thinking'];
      final thinkingSupportsOff =
          thinkingRaw is Map && thinkingRaw['supports_off'] == true;
      models.add(
        GatewayModel(
          id: id.trim(),
          capabilities: caps,
          available: available,
          unavailableReasons: reasons,
          chatAvailable: chatAvailable,
          thinkingSupportsOff: thinkingSupportsOff,
        ),
      );
    }
    return ModelCatalog(models);
  }
}
