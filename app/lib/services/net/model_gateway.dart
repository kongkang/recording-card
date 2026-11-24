/// 后端模型网关客户端（ASR 转写 + 文本总结）。
///
/// 端点（与参考工程 reai_mobile_app 的 `cloud_stt_service` / 总结服务一致）：
/// - 转写：`POST ${apiBase}/api/model-gateway/v1/audio/transcriptions`
///   multipart 字段 `model` / `language`(可选) / `response_format=json` + 文件 `file`；
/// - 总结：`POST ${apiBase}/api/model-gateway/v1/chat/completions`
///   body `{model, stream:false, temperature, max_tokens, messages[]}`。
///
/// 鉴权：不自己管 token，全部交给 [AuthorizedHttpClient]（Bearer + 401 刷新重放）。
///
/// 音频边界：本类**只接受已编码好的 WAV 字节**（录音卡的 ADPCM 解码 → WAV 封装
/// 由设备/音频模块负责），这样这里只有网络语义，不掺音频格式逻辑。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/config/remote/model_gateway_config.dart';
import 'api_exception.dart';
import 'model_catalog.dart';
import 'model_provider_store.dart';
import 'authorized_http_client.dart';

/// 转写结果。
class TranscriptionResult {
  const TranscriptionResult({required this.text, this.language, this.duration});

  /// 识别文本（可能是空串：静音或无法识别，**属于正常结果，不算失败**）。
  final String text;

  /// 识别语种；服务端返回 `auto` 或缺失时为 null。
  final String? language;

  /// 音频时长（服务端给出的估算，可能为 null）。
  final Duration? duration;

  /// 是否有有效文本。
  bool get hasText => text.trim().isNotEmpty;

  @override
  String toString() =>
      'TranscriptionResult(len=${text.length}, language=$language, duration=$duration)';
}

/// 对话消息（OpenAI 兼容的 `role` / `content`，支持纯文本与多模态图片）。
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.imageDataUrl,
  });

  /// 系统提示。
  const ChatMessage.system(this.content) : role = 'system', imageDataUrl = null;

  /// 用户输入。
  const ChatMessage.user(this.content) : role = 'user', imageDataUrl = null;

  /// 用户图文混合输入（OpenAI content parts，用于拍照识别）。
  const ChatMessage.userWithImage(
    this.content, {
    required String this.imageDataUrl,
  }) : role = 'user';

  /// 助手回复（多轮上下文用）。
  const ChatMessage.assistant(this.content)
    : role = 'assistant',
      imageDataUrl = null;

  /// `system` / `user` / `assistant`。
  final String role;

  /// 文本内容。
  final String content;

  /// 可选 `data:image/jpeg;base64,...` 多模态图片 URL。
  final String? imageDataUrl;

  Map<String, dynamic> toJson() {
    final img = imageDataUrl?.trim();
    if (img != null && img.isNotEmpty) {
      return {
        'role': role,
        'content': [
          {'type': 'text', 'text': content},
          {
            'type': 'image_url',
            'image_url': {'url': img},
          },
        ],
      };
    }
    return {'role': role, 'content': content};
  }
}

/// 模型网关客户端。
class ModelGateway {
  ModelGateway({
    required AuthorizedHttpClient client,
    ModelGatewayConfig? config,
    Duration defaultTimeout = const Duration(seconds: 60),
    bool Function()? enabledCheck,
    ModelProviderStore? providers,
    http.Client? providerClient,
  }) : _client = client,
       _config = config ?? ModelGatewayConfig.fromEnvironment(),
       _defaultTimeout = defaultTimeout,
       _enabledCheck = enabledCheck,
       _providers = providers,
       _providerClient = providerClient;

  final AuthorizedHttpClient _client;
  final ModelGatewayConfig _config;
  final Duration _defaultTimeout;
  final bool Function()? _enabledCheck;
  final ModelProviderStore? _providers;
  final http.Client? _providerClient;

  bool get usesExternalProvider =>
      _providers != null && _providers.activeProvider != ModelProvider.wainao;

  bool get isCloudEnabled => _enabledCheck?.call() ?? true;

  /// 运行时从服务端探测到的模型（dart-define 没配时用它）。
  String? _discoveredAsr;
  String? _discoveredText;
  String? _discoveredVision;
  List<GatewayModel> _discoveredModels = const [];
  bool _catalogLoaded = false;
  String? _catalogError;

  /// 当前配置（只读，便于 UI 展示「哪一项没配」）。
  ModelGatewayConfig get config => _config;

  /// 模型目录是否已探测过（成功或失败都算）。
  bool get catalogLoaded => _catalogLoaded;
  String? get catalogError => _catalogError;
  List<GatewayModel> get discoveredModels => _discoveredModels;
  List<String> get discoveredTextModels => [
    for (final m in _discoveredModels)
      if (m.capabilities.isEmpty || m.has('text') || m.has('chat')) m.id,
  ];

  /// 实际生效的 ASR 模型名：显式配置优先，其次服务端探测结果。
  String get asrModel => _config.asrModel.trim().isNotEmpty
      ? _config.asrModel.trim()
      : (_discoveredAsr ?? '');

  /// 实际生效的文本模型名：显式配置优先，其次服务端探测结果。
  String get textModel => _config.refineModel.trim().isNotEmpty
      ? _config.refineModel.trim()
      : (_discoveredText ?? '');

  /// 实际生效的视觉模型名（多模态识图）：显式指定或网关声明的视觉/通用模型。
  String get visionModel {
    if (_config.refineModel.trim().isNotEmpty) {
      return _config.refineModel.trim();
    }
    final v = (_discoveredVision ?? '').trim();
    return v.isNotEmpty ? v : textModel;
  }

  /// 网关端点与两个模型名都配齐（纯配置判断，与登录态无关）。
  bool get configured =>
      _config.asrConfigured ||
      _config.refineConfigured ||
      (asrModel.isNotEmpty && textModel.isNotEmpty);

  /// 转写能力是否**配置齐全**（配置或探测到模型 + https 端点）。
  bool get asrAvailable => _config.configured && asrModel.isNotEmpty;

  /// 总结能力是否**配置齐全**（配置或探测到模型 + https 端点 + 未被开关关闭）。
  bool get chatAvailable => chatAvailableFor(ModelScene.summary);

  bool chatAvailableFor(ModelScene scene) =>
      isCloudEnabled &&
      (usesExternalProvider || _config.configured) &&
      modelFor(scene).isNotEmpty;

  bool readyFor(ModelScene scene) =>
      chatAvailableFor(scene) && (usesExternalProvider || _client.hasSession);

  String modelFor(ModelScene scene) {
    final providers = _providers;
    if (providers != null && usesExternalProvider) {
      return providers.profileFor(providers.activeProvider).modelFor(scene);
    }
    return _officialModelFor(scene);
  }

  String _officialModelFor(ModelScene scene) {
    if (scene == ModelScene.vision) return visionModel;
    if (_config.refineModel.trim().isNotEmpty) return textModel;
    return ModelCatalog(_discoveredModels).firstWith(scene.name) ?? textModel;
  }

  /// 登录后调用一次：向服务端问有哪些模型可用，填上未显式配置的模型名。
  ///
  /// 失败不抛异常（探测只是增强），把原因记在 [catalogError] 里供「关于」页排障。
  Future<void> discoverModels({Duration? timeout}) async {
    final cfg = _config;
    if (!cfg.configured) {
      _catalogLoaded = true;
      _catalogError = '未配置后端地址';
      return;
    }
    try {
      final catalog = await ModelCatalog.fetch(
        _client,
        gatewayBaseUrl: cfg.gatewayBaseUrl,
        timeout: timeout,
      );
      _discoveredModels = catalog.models;
      _discoveredAsr = catalog.asrModel;
      _discoveredText = catalog.textModel;
      _discoveredVision = catalog.visionModel;
      _catalogLoaded = true;
      _catalogError = catalog.isEmpty ? '服务端未返回可用模型' : null;
    } on Object catch (e) {
      _catalogLoaded = true;
      _catalogError = e is ApiException ? e.message : '$e';
    }
  }

  /// 整体配置可用（ASR 与总结都配齐）。
  ///
  /// 语义刻意只反映「配置」：模型名从 dart-define 读，空则 false。
  /// 未登录时该值仍为 true，真正发请求会抛 [ApiUnauthorizedException]。
  /// 需要「配置 + 登录态都就绪」的 UI 门控请用 [ready]。
  bool get available =>
      usesExternalProvider ? chatAvailable : isCloudEnabled && configured;

  /// 可以立即发起请求（配置齐全、开启云端模型且已有登录态）。
  bool get ready => readyFor(ModelScene.summary);

  /// 语音转写。
  ///
  /// [wavBytes] 必须是完整的 WAV 文件字节（含 RIFF 头）。
  /// [language] 传 ISO-639-1（如 `zh`）可提升准确率；null 表示交给服务端判断。
  ///
  /// 2xx 且 `text` 为空（静音 / 无法识别）时返回空文本结果，**不抛异常**——
  /// 那是正常结果，抛错会让上层误以为需要重试。
  Future<TranscriptionResult> transcribe(
    List<int> wavBytes, {
    String filename = 'audio.wav',
    String? mimeType,
    String? language,
    Duration? timeout,
  }) async {
    final url = _config.audioTranscriptionsUrl;
    if (!_config.asrConfigured || url == null) {
      throw const ApiNotConfiguredException('未配置转写服务，暂时无法转写');
    }
    if (wavBytes.isEmpty) {
      throw const ApiFormatException('音频数据为空，无法转写');
    }

    final response = await _client.postBytes(
      url,
      fields: {
        'model': asrModel,
        if (language != null && language.trim().isNotEmpty)
          'language': language.trim(),
        'response_format': 'json',
      },
      fileField: 'file',
      bytes: wavBytes,
      filename: filename,
      mimeType: mimeType,
      timeout: timeout ?? _defaultTimeout,
    );

    _ensureSuccess(response, action: '转写');

    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      body = decoded;
    } catch (e) {
      throw ApiFormatException('转写结果解析失败', e);
    }

    final rawText = body['text'];
    final text = rawText is String ? rawText.trim() : '';
    final rawLanguage = body['language'];
    final rawDuration = body['duration'];
    return TranscriptionResult(
      text: text,
      language: (rawLanguage is String && rawLanguage != 'auto')
          ? rawLanguage
          : null,
      duration: rawDuration is num
          ? Duration(milliseconds: (rawDuration * 1000).round())
          : null,
    );
  }

  /// 文本对话（总结 / 润色 / 清洗都用它）。
  ///
  /// [messages] 至少一条；[temperature] / [maxTokens] 走网关默认语义，
  /// 不传则由本方法给保守默认值。[model] 缺省用 `RC_MODEL_REFINE`。
  Future<String> chat(
    List<ChatMessage> messages, {
    String? model,
    ModelScene scene = ModelScene.summary,
    double temperature = 0.3,
    int maxTokens = 2048,
    Duration? timeout,
  }) async {
    if (!isCloudEnabled) {
      throw const ApiNotConfiguredException('请先在设置中选择模型服务');
    }
    if (messages.isEmpty) {
      throw const ApiFormatException('没有可发送的内容');
    }

    final route = await _providers?.activeRoute(scene);
    final url = _config.chatCompletionsUrl;
    final resolvedModel =
        route?.model ??
        (_providers == null
            ? (model ?? _officialModelFor(scene)).trim()
            : _officialModelFor(scene));
    if (resolvedModel.isEmpty || (route == null && url == null)) {
      throw const ApiNotConfiguredException('请先在设置中选择可用的模型服务');
    }
    final officialOpenAi =
        route?.provider == ModelProvider.openai &&
        route?.endpoint('chat/completions').host == 'api.openai.com';
    final reasoningModel = RegExp(r'^(o[0-9]|gpt-5)').hasMatch(resolvedModel);
    final deepSeekSummary =
        route?.provider == ModelProvider.deepseek &&
        route?.endpoint('chat/completions').host == 'api.deepseek.com' &&
        scene == ModelScene.summary;
    final payload = {
      'model': resolvedModel,
      'stream': false,
      if (deepSeekSummary) 'thinking': {'type': 'disabled'},
      if (!officialOpenAi || !reasoningModel) 'temperature': temperature,
      if (officialOpenAi)
        'max_completion_tokens': maxTokens
      else
        'max_tokens': deepSeekSummary ? math.max(maxTokens, 3200) : maxTokens,
      'messages': [for (final message in messages) message.toJson()],
    };
    final requestTimeout = timeout ?? _defaultTimeout;
    final response = route == null
        ? await _client.postJson(url!, payload, timeout: requestTimeout)
        : await _postToProvider(route, payload, requestTimeout);
    if (deepSeekSummary &&
        const bool.fromEnvironment('RC_DEEPSEEK_SUMMARY_DIAGNOSTICS')) {
      await _recordSummaryDiagnostic(route!, payload, response, 'disabled');
    }
    _ensureSuccess(response, action: '生成');

    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      body = decoded;
    } catch (e) {
      throw ApiFormatException('总结结果解析失败', e);
    }

    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const ApiFormatException('总结服务没有返回内容');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw const ApiFormatException('总结服务返回了空内容');
    }
    return content.trim();
  }

  Future<void> _recordSummaryDiagnostic(
    ModelProviderRoute route,
    Map<String, Object> payload,
    http.Response response,
    String thinking,
  ) async {
    final result = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'model': route.model,
      'thinking': thinking,
      'maxTokens': payload['max_tokens'],
      'httpStatus': response.statusCode,
    };
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final choices = body is Map ? body['choices'] : null;
      final first = choices is List && choices.isNotEmpty
          ? choices.first
          : null;
      final message = first is Map ? first['message'] : null;
      final finish = first is Map ? first['finish_reason'] : null;
      final content = message is Map ? message['content'] : null;
      final reasoning = message is Map ? message['reasoning_content'] : null;
      final usage = body is Map ? body['usage'] : null;
      final details = usage is Map ? usage['completion_tokens_details'] : null;
      result.addAll({
        'finishReason':
            const {
              'stop',
              'length',
              'content_filter',
              'tool_calls',
              'insufficient_system_resource',
            }.contains(finish)
            ? finish
            : null,
        'contentChars': content is String ? content.trim().length : 0,
        'reasoningChars': reasoning is String ? reasoning.length : 0,
        if (usage is Map && usage['completion_tokens'] is int)
          'completionTokens': usage['completion_tokens'],
        if (details is Map && details['reasoning_tokens'] is int)
          'reasoningTokens': details['reasoning_tokens'],
      });
    } on FormatException {
      result['responseFormat'] = 'invalid_json';
    }
    try {
      final dir = await getApplicationSupportDirectory();
      await File('${dir.path}/deepseek-summary-diagnostic.jsonl').writeAsString(
        '${jsonEncode(result)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Exception {
      // A diagnostic write must not interfere with the summary under test.
    }
  }

  Future<http.Response> _postToProvider(
    ModelProviderRoute route,
    Map<String, Object> payload,
    Duration timeout,
  ) async {
    final client = _providerClient ?? http.Client();
    try {
      final request = http.Request('POST', route.endpoint('chat/completions'))
        ..followRedirects = false
        ..headers.addAll({
          if (route.apiKey.isNotEmpty)
            'Authorization': 'Bearer ${route.apiKey}',
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
        })
        ..bodyBytes = utf8.encode(jsonEncode(payload));
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        final message = switch (status) {
          401 || 403 => '服务商拒绝访问，请检查 API Key 和模型权限',
          429 => '服务商请求过多或额度不足，请稍后重试',
          _ => '所选模型服务暂时无法完成请求',
        };
        throw ApiHttpException(message, statusCode: status);
      }
      return response;
    } on TimeoutException {
      throw const ApiTimeoutException();
    } on http.ClientException {
      throw const ApiNetworkException();
    } finally {
      if (_providerClient == null) client.close();
    }
  }

  /// 便捷封装：把转写文本整理成总结（一次 system + user 的常规调用）。
  ///
  /// [instruction] 为空时用默认的系统提示；不同产品形态可覆盖。
  Future<String> summarize({
    required String transcript,
    String? instruction,
    String? model,
    double temperature = 0.3,
    int maxTokens = 2048,
    Duration? timeout,
  }) {
    return chat(
      [
        ChatMessage.system(instruction ?? defaultSummarizeInstruction),
        ChatMessage.user(transcript),
      ],
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      timeout: timeout,
    );
  }

  /// 默认总结系统提示（中文、结构化、不加戏）。
  static const String defaultSummarizeInstruction =
      '你是录音整理助手。请把用户提供的录音转写文本整理成结构化摘要：'
      '先给一句话概览，再列关键信息点，最后列行动项（若有）。'
      '只依据原文内容，不要编造原文没有的事实；不确定的信息保留原话。';

  /// 非 2xx 统一转成带中文文案的 [ApiHttpException]。
  ///
  /// 会尽力从响应体里挖出服务端的 `error.message` / `message`，
  /// 让「模型不支持」「额度不足」之类的原因能直达用户。
  void _ensureSuccess(http.Response response, {required String action}) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;

    String? code;
    String? detail;
    try {
      if (response.bodyBytes.isNotEmpty) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) {
          final error = decoded['error'];
          if (error is Map) {
            code = error['code']?.toString() ?? error['type']?.toString();
            detail = error['message']?.toString();
          } else if (error is String) {
            code = error;
          }
          code ??= decoded['code']?.toString();
          detail ??= decoded['message']?.toString();
        }
      }
    } catch (_) {
      // 错误体不是 JSON：保留状态码文案即可
    }

    final message = detail != null && detail.trim().isNotEmpty
        ? '$action失败：${detail.trim()}'
        : '$action失败（HTTP $status）';
    throw ApiHttpException(message, statusCode: status, code: code);
  }
}
