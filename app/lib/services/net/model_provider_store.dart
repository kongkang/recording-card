import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/storage/storage.dart';
import 'api_exception.dart';

enum ModelProvider {
  wainao('外脑（Wainao）', ''),
  openai('OpenAI', 'https://api.openai.com/v1'),
  deepseek('DeepSeek', 'https://api.deepseek.com'),
  openrouter('OpenRouter', 'https://openrouter.ai/api/v1'),
  custom('自定义 API', '');

  const ModelProvider(this.label, this.defaultBaseUrl);

  final String label;
  final String defaultBaseUrl;
}

enum ModelScene {
  summary('总结'),
  agent('Agent 对话'),
  polish('润色'),
  segmentation('话题分段'),
  organize('整理记录'),
  vision('图片理解');

  const ModelScene(this.label);

  final String label;
}

class ModelProviderProfile {
  const ModelProviderProfile({
    this.baseUrl = '',
    this.summaryModel = '',
    this.models = const [],
    this.sceneModels = const {},
  });

  final String baseUrl;
  final String summaryModel;
  final List<String> models;
  final Map<ModelScene, String> sceneModels;

  String modelFor(ModelScene scene) {
    final override = sceneModels[scene]?.trim() ?? '';
    return scene == ModelScene.summary || override.isEmpty
        ? summaryModel
        : override;
  }

  Uri endpoint(String path) =>
      Uri.parse('$baseUrl/${path.replaceFirst(RegExp(r"^/+"), "")}');

  ModelProviderProfile copyWith({
    String? baseUrl,
    String? summaryModel,
    List<String>? models,
    Map<ModelScene, String>? sceneModels,
  }) => ModelProviderProfile(
    baseUrl: baseUrl ?? this.baseUrl,
    summaryModel: summaryModel ?? this.summaryModel,
    models: List.unmodifiable(models ?? this.models),
    sceneModels: Map.unmodifiable(sceneModels ?? this.sceneModels),
  );

  factory ModelProviderProfile._fromJson(Map<String, dynamic> data) {
    final rawModels = data['models'];
    final rawOverrides = data['sceneModels'];
    return ModelProviderProfile(
      baseUrl: data['baseUrl'] as String? ?? '',
      summaryModel: data['summaryModel'] as String? ?? '',
      models: List.unmodifiable(
        rawModels is List ? rawModels.whereType<String>() : const <String>[],
      ),
      sceneModels: Map.unmodifiable({
        if (rawOverrides is Map)
          for (final scene in ModelScene.values)
            if (rawOverrides[scene.name] case final String value) scene: value,
      }),
    );
  }

  Map<String, dynamic> _toJson() => {
    'baseUrl': baseUrl,
    'summaryModel': summaryModel,
    'models': models,
    'sceneModels': {
      for (final entry in sceneModels.entries) entry.key.name: entry.value,
    },
  };
}

/// A consistent model, endpoint and credential for one inference request.
class ModelProviderRoute {
  const ModelProviderRoute._(
    this.provider,
    this._profile,
    this.apiKey,
    this.model,
  );

  final ModelProvider provider;
  final ModelProviderProfile _profile;
  final String apiKey;
  final String model;

  Uri endpoint(String path) => _profile.endpoint(path);
}

class ModelProviderStore extends ChangeNotifier {
  ModelProviderStore({
    required SecureStore secureStore,
    http.Client Function()? clientFactory,
  }) : _secure = secureStore,
       _clientFactory = clientFactory ?? http.Client.new;

  static final instance = ModelProviderStore(
    secureStore: KeychainSecureStore(),
  );
  static const _storageKey = 'rc_model_providers_v1';
  static const _timeout = Duration(seconds: 15);

  final SecureStore _secure;
  final http.Client Function() _clientFactory;
  Future<void>? _loading;
  Future<void> _pendingWrite = Future.value();
  bool _loaded = false;
  ModelProvider _activeProvider = ModelProvider.wainao;
  Map<ModelProvider, ModelProviderProfile> _profiles = {};
  Map<ModelProvider, String> _apiKeys = {};

  ModelProvider get activeProvider => _activeProvider;

  ModelProviderProfile profileFor(ModelProvider provider) =>
      _profiles[provider] ??
      ModelProviderProfile(baseUrl: provider.defaultBaseUrl);

  Future<void> load() async {
    if (_loaded) return;
    final pending = _loading ??= _restore();
    try {
      await pending;
    } finally {
      if (identical(_loading, pending)) _loading = null;
    }
  }

  Future<void> _restore() async {
    final raw = await _secure.read(_storageKey);
    if (raw != null) {
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw const ApiFormatException('无法读取模型服务配置');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const ApiFormatException('无法读取模型服务配置');
      }
      final active = decoded['active'];
      final saved = decoded['providers'];
      if (saved is Map) {
        for (final provider in ModelProvider.values) {
          final entry = saved[provider.name];
          if (entry is Map<String, dynamic>) {
            final parsed = ModelProviderProfile._fromJson(entry);
            _profiles[provider] = provider == ModelProvider.wainao
                ? parsed.copyWith(baseUrl: '', models: const [])
                : parsed;
            if (provider != ModelProvider.wainao) {
              if (entry['apiKey'] case final String value) {
                _apiKeys[provider] = value;
              }
            }
          }
          if (active == provider.name) _activeProvider = provider;
        }
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<bool> hasApiKey(ModelProvider provider) async =>
      (await readApiKey(provider)).isNotEmpty;

  Future<String> readApiKey(ModelProvider provider) async {
    await load();
    return _apiKeys[provider] ?? '';
  }

  Future<ModelProviderRoute?> activeRoute(ModelScene scene) async {
    await load();
    final provider = _activeProvider;
    if (provider == ModelProvider.wainao) return null;
    final profile = profileFor(provider);
    final apiKey = _apiKeys[provider] ?? '';
    final model = profile.modelFor(scene);
    if ((provider != ModelProvider.custom && apiKey.isEmpty) ||
        profile.baseUrl.isEmpty ||
        !profile.models.contains(model)) {
      throw const ApiNotConfiguredException('请先连接模型服务并选择模型');
    }
    _normalizedBaseUrl(profile.baseUrl);
    return ModelProviderRoute._(provider, profile, apiKey, model);
  }

  /// Older addresses customized the Wainao gateway and used Wainao OAuth.
  /// Preserve the address as a draft for explicit setup with its own credential.
  Future<bool> importLegacyDraft(String address, {String summaryModel = ''}) =>
      _serialized(() async {
        if (address.trim().isEmpty ||
            _profiles.containsKey(ModelProvider.custom)) {
          return false;
        }
        final String base;
        try {
          base = _normalizedBaseUrl(address);
        } on ApiNotConfiguredException {
          return false;
        }
        await _commit(
          profiles: {
            ..._profiles,
            ModelProvider.custom: ModelProviderProfile(
              baseUrl: base,
              summaryModel: summaryModel.trim(),
            ),
          },
        );
        return true;
      });

  Future<void> selectProvider(ModelProvider provider) => _serialized(() async {
    if (provider == _activeProvider) return;
    if (provider != ModelProvider.wainao) {
      final profile = profileFor(provider);
      if ((provider != ModelProvider.custom &&
              (_apiKeys[provider] ?? '').isEmpty) ||
          !profile.models.contains(profile.summaryModel)) {
        throw const ApiNotConfiguredException('请先连接模型服务并选择总结模型');
      }
    }
    await _commit(active: provider);
  });

  /// Only model selections can be edited without retesting the endpoint.
  Future<void> saveProfile(
    ModelProvider provider,
    ModelProviderProfile profile,
  ) => _serialized(() async {
    final connected = profileFor(provider);
    final summary = profile.summaryModel.trim();
    if (provider == ModelProvider.wainao ||
        (provider != ModelProvider.custom &&
            (_apiKeys[provider] ?? '').isEmpty) ||
        connected.baseUrl != profile.baseUrl ||
        !connected.models.contains(summary) ||
        profile.sceneModels.values.any(
          (model) => model.isNotEmpty && !connected.models.contains(model),
        )) {
      throw const ApiNotConfiguredException('请从当前服务的模型列表选择模型');
    }
    await _commit(
      profiles: {
        ..._profiles,
        provider: connected.copyWith(
          summaryModel: summary,
          sceneModels: profile.sceneModels,
        ),
      },
    );
  });

  /// 保存外脑（Wainao）的可选模型覆盖；留空表示跟随后端下发默认模型。
  Future<void> saveWainaoOverrides({
    String? summaryModel,
    Map<ModelScene, String>? sceneModels,
  }) => _serialized(() async {
    final current = profileFor(ModelProvider.wainao);
    final nextSummary = summaryModel != null
        ? summaryModel.trim()
        : current.summaryModel;
    final nextScenes = <ModelScene, String>{};
    final sourceScenes = sceneModels ?? current.sceneModels;
    for (final entry in sourceScenes.entries) {
      if (entry.key == ModelScene.summary) continue;
      final trimmed = entry.value.trim();
      if (trimmed.isNotEmpty) {
        nextScenes[entry.key] = trimmed;
      }
    }
    await _commit(
      profiles: {
        ..._profiles,
        ModelProvider.wainao: ModelProviderProfile(
          baseUrl: '',
          summaryModel: nextSummary,
          models: const [],
          sceneModels: nextScenes,
        ),
      },
    );
  });

  static String _pickDefaultSummaryModel(
    ModelProvider provider,
    List<String> available, {
    String manual = '',
  }) {
    if (manual.isNotEmpty && available.contains(manual)) return manual;
    final preferred = switch (provider) {
      ModelProvider.openai => const [
        'gpt-4o-mini',
        'gpt-4o',
        'gpt-4.1-mini',
        'gpt-4.1',
      ],
      ModelProvider.deepseek => const ['deepseek-chat', 'deepseek-reasoner'],
      ModelProvider.openrouter => const [
        'openai/gpt-4o-mini',
        'anthropic/claude-3.5-sonnet',
        'google/gemini-2.5-flash',
      ],
      _ => const <String>[],
    };
    for (final candidate in preferred) {
      if (available.contains(candidate)) return candidate;
    }
    const nonChatTokens = <String>[
      'embedding',
      'whisper',
      'tts',
      'dall-e',
      'moderation',
      'rerank',
      'transcribe',
      'realtime',
      'sora',
    ];
    for (final id in available) {
      final lower = id.toLowerCase();
      if (!nonChatTokens.any(lower.contains)) return id;
    }
    return available.first;
  }

  /// Probe the credential and load the available models before saving.
  /// Reusing a credential requires the exact same endpoint.
  Future<ModelProviderProfile> connect(
    ModelProvider provider, {
    required String apiKey,
    required String baseUrl,
    String? manualModel,
  }) async {
    await load();
    if (provider == ModelProvider.wainao) {
      throw const ApiNotConfiguredException('外脑使用账号登录');
    }
    final before = _profiles[provider];
    final current = profileFor(provider);
    final base = _normalizedBaseUrl(
      baseUrl.trim().isEmpty ? provider.defaultBaseUrl : baseUrl,
    );
    var key = apiKey.trim();
    if (key.isEmpty && current.baseUrl == base) {
      key = _apiKeys[provider] ?? '';
    }
    if ((provider != ModelProvider.custom && key.isEmpty) ||
        key.contains('\n') ||
        key.contains('\r')) {
      throw const ApiNotConfiguredException('请输入有效的 API Key');
    }
    final manual = manualModel?.trim() ?? '';
    final target = ModelProviderProfile(baseUrl: base);
    final client = _clientFactory();
    final List<String> available;
    try {
      if (manual.isEmpty) {
        if (provider == ModelProvider.openrouter &&
            base == provider.defaultBaseUrl) {
          await _probe(client, 'GET', target.endpoint('key'), key);
        }
        available = await _fetchModels(client, target, key);
      } else {
        final response = await _probe(
          client,
          'POST',
          target.endpoint('chat/completions'),
          key,
          body: {
            'model': manual,
            if (provider == ModelProvider.openai &&
                base == provider.defaultBaseUrl)
              'max_completion_tokens': 16
            else
              'max_tokens': 16,
            'messages': [
              {'role': 'user', 'content': 'Reply with OK.'},
            ],
          },
        );
        final choices = response is Map ? response['choices'] : null;
        if (choices is! List || choices.isEmpty) {
          throw const ApiFormatException('服务未返回有效的模型响应');
        }
        available = {
          if (base == current.baseUrl) ...current.models,
          manual,
        }.toList();
      }
    } finally {
      client.close();
    }
    return _serialized(() async {
      if (!identical(before, _profiles[provider])) {
        throw const ApiNotConfiguredException('服务配置已更新，请重试');
      }
      var summary = available.contains(current.summaryModel)
          ? current.summaryModel
          : '';
      // A refresh must not leave an active provider unable to handle requests.
      if (_activeProvider == provider && summary.isEmpty) {
        throw const ApiNotConfiguredException('新配置没有当前总结模型，请先切换到其他服务');
      }
      if (summary.isEmpty && available.isNotEmpty) {
        summary = _pickDefaultSummaryModel(
          provider,
          available,
          manual: manual,
        );
      }
      final profile = target.copyWith(
        summaryModel: summary,
        models: available,
        sceneModels: {
          for (final entry in current.sceneModels.entries)
            if (available.contains(entry.value)) entry.key: entry.value,
        },
      );
      await _commit(
        profiles: {..._profiles, provider: profile},
        apiKeys: {..._apiKeys, provider: key},
      );
      return profile;
    });
  }

  static String _normalizedBaseUrl(String address) {
    final url = Uri.tryParse(address.trim());
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.authority.contains('@') ||
        url.hasQuery ||
        url.hasFragment) {
      throw const ApiNotConfiguredException('请输入有效的 HTTPS API 地址');
    }
    final path = url.path
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'/(chat/completions|models)$'), '');
    return url
        .replace(path: path.isEmpty ? '/' : path)
        .toString()
        .replaceFirst(RegExp(r'/+$'), '');
  }

  static Future<List<String>> _fetchModels(
    http.Client client,
    ModelProviderProfile target,
    String key,
  ) async {
    final response = await _probe(
      client,
      'GET',
      target.endpoint('models'),
      key,
    );
    final raw = response is Map
        ? response['data'] ?? response['models']
        : response;
    final models = <String>{};
    if (raw is List) {
      for (final item in raw) {
        final id = item is Map ? item['id'] : item;
        if (id is String && id.trim().isNotEmpty) models.add(id.trim());
      }
    }
    if (models.isEmpty) {
      throw const ApiFormatException('未获取到模型，请在高级设置中填写模型 ID');
    }
    return models.toList()..sort();
  }

  static Future<Object?> _probe(
    http.Client client,
    String method,
    Uri uri,
    String key, {
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (key.isNotEmpty) request.headers['Authorization'] = 'Bearer $key';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);
    } on TimeoutException {
      throw const ApiTimeoutException();
    } catch (_) {
      throw const ApiNetworkException();
    }
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      final message = switch (status) {
        401 || 403 => '无法验证 API Key，请检查权限和密钥',
        404 when method == 'GET' => '此地址未提供模型列表，请检查地址或填写模型 ID',
        404 => '未找到模型，请检查地址和模型 ID',
        429 => '请求过于频繁，请稍后重试',
        _ => '模型服务连接失败，请检查配置',
      };
      throw ApiHttpException(message, statusCode: status);
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ApiFormatException();
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final pending = _pendingWrite.then((_) async {
      await load();
      return action();
    });
    _pendingWrite = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<void> _commit({
    ModelProvider? active,
    Map<ModelProvider, ModelProviderProfile>? profiles,
    Map<ModelProvider, String>? apiKeys,
  }) async {
    final nextActive = active ?? _activeProvider;
    final nextProfiles = profiles ?? _profiles;
    final nextKeys = apiKeys ?? _apiKeys;
    // One write keeps the endpoint and its credential paired across restarts.
    await _secure.writeJson(_storageKey, {
      'active': nextActive.name,
      'providers': {
        for (final entry in nextProfiles.entries)
          entry.key.name: {
            ...entry.value._toJson(),
            if (nextKeys[entry.key] case final String key) 'apiKey': key,
          },
      },
    });
    _activeProvider = nextActive;
    _profiles = nextProfiles;
    _apiKeys = nextKeys;
    notifyListeners();
  }
}
