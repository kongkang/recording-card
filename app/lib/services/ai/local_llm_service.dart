/// 端侧大小双模型推理服务（iOS 26 Foundation Models / llama.cpp GGUF / 自动回退云端）。
///
/// 工程守则：
/// - 严格接入 [LocalModelMemoryGuard]：任何时刻只允许 1 个重模型槽位（ASR / 小 LLM / 大 LLM）常驻内存；
/// - 退后台或收到系统内存警告时调用 [pauseAndDrainForBackground]，先排空 Metal GPU 命令再卸载模型；
/// - 真实性红线：本地运行时或模型未就绪时绝不编造输出，按策略明确回退云端或显式报错。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_llm_models.dart';
import 'local_model_memory_guard.dart';

class LocalLlmException implements Exception {
  const LocalLlmException(this.message, {this.code = 'LOCAL_LLM_ERROR'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class LocalLlmGenerationHandle {
  LocalLlmGenerationHandle({
    required this.stream,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  final Stream<String> stream;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

/// 原生端侧 LLM 引擎契约（可替换为测试桩）。
abstract class LocalLlmBackend {
  Future<DeviceLlmCapabilities> probeCapabilities();

  Future<void> loadModel({
    required String engine, // 'llama_gguf' | 'apple_foundation'
    required String? modelPath,
    required int nCtx,
    required bool useMetal,
    required bool quantizeKvQ8,
  });

  Future<void> unloadModel();

  Future<void> pauseAndDrain();

  Stream<String> generateStream({
    required String requestId,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required double temperature,
  });

  Future<void> cancelGeneration(String requestId);
}

/// 通过 MethodChannel / EventChannel 对接 iOS `LocalLlmBridge.swift`。
class MethodChannelLocalLlmBackend implements LocalLlmBackend {
  static const MethodChannel _channel = MethodChannel(
    'com.reai.recordingcard/local_llm',
  );
  static const EventChannel _events = EventChannel(
    'com.reai.recordingcard/local_llm_stream',
  );

  @override
  Future<DeviceLlmCapabilities> probeCapabilities() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'capabilities',
      );
      if (raw == null) return DeviceLlmCapabilities.unknown;
      return DeviceLlmCapabilities.fromMap(raw);
    } on MissingPluginException {
      return DeviceLlmCapabilities.unknown;
    } on PlatformException {
      return DeviceLlmCapabilities.unknown;
    }
  }

  @override
  Future<void> loadModel({
    required String engine,
    required String? modelPath,
    required int nCtx,
    required bool useMetal,
    required bool quantizeKvQ8,
  }) async {
    try {
      await _channel.invokeMethod<void>('loadModel', {
        'engine': engine,
        'modelPath': modelPath,
        'nCtx': nCtx,
        'useMetal': useMetal,
        'quantizeKvQ8': quantizeKvQ8,
      });
    } on MissingPluginException catch (e) {
      throw LocalLlmException(
        '当前平台未挂载端侧 LLM 桥接：$e',
        code: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (e) {
      throw LocalLlmException(
        e.message ?? '加载端侧模型失败',
        code: e.code,
      );
    }
  }

  @override
  Future<void> unloadModel() async {
    try {
      await _channel.invokeMethod<void>('unloadModel');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  @override
  Future<void> pauseAndDrain() async {
    try {
      await _channel.invokeMethod<void>('pauseAndDrain');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  @override
  Stream<String> generateStream({
    required String requestId,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required double temperature,
  }) {
    final controller = StreamController<String>();
    StreamSubscription<dynamic>? sub;

    sub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        if ('${event['requestId'] ?? ''}' != requestId) return;
        final kind = '${event['kind'] ?? ''}';
        if (kind == 'delta') {
          final text = '${event['text'] ?? ''}';
          if (text.isNotEmpty && !controller.isClosed) {
            controller.add(text);
          }
        } else if (kind == 'done') {
          unawaited(sub?.cancel());
          if (!controller.isClosed) unawaited(controller.close());
        } else if (kind == 'error') {
          final msg = '${event['message'] ?? '端侧推理异常'}';
          final code = '${event['code'] ?? 'LOCAL_LLM_ERROR'}';
          unawaited(sub?.cancel());
          if (!controller.isClosed) {
            controller.addError(LocalLlmException(msg, code: code));
            unawaited(controller.close());
          }
        }
      },
      onError: (Object err, StackTrace st) {
        if (!controller.isClosed) {
          controller.addError(
            LocalLlmException('$err', code: 'STREAM_ERROR'),
            st,
          );
          unawaited(controller.close());
        }
      },
    );

    unawaited(() async {
      try {
        await _channel.invokeMethod<void>('startGenerate', {
          'requestId': requestId,
          'systemPrompt': systemPrompt,
          'userPrompt': userPrompt,
          'maxTokens': maxTokens,
          'temperature': temperature,
        });
      } on MissingPluginException catch (e) {
        await sub?.cancel();
        if (!controller.isClosed) {
          controller.addError(
            LocalLlmException('端侧 LLM 未启用：$e', code: 'MISSING_PLUGIN'),
          );
          await controller.close();
        }
      } on PlatformException catch (e) {
        await sub?.cancel();
        if (!controller.isClosed) {
          controller.addError(
            LocalLlmException(e.message ?? '端侧推理启动失败', code: e.code),
          );
          await controller.close();
        }
      }
    }());

    controller.onCancel = () async {
      await sub?.cancel();
      await cancelGeneration(requestId);
    };

    return controller.stream;
  }

  @override
  Future<void> cancelGeneration(String requestId) async {
    try {
      await _channel.invokeMethod<void>('cancelGenerate', {
        'requestId': requestId,
      });
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }
}

class LocalLlmPolishOutcome {
  const LocalLlmPolishOutcome({
    required this.text,
    required this.route,
    required this.elapsedMs,
    this.fallbackReason,
  });

  final String text;
  final LlmExecutionRoute route;
  final int elapsedMs;
  final String? fallbackReason;
}

class LocalLlmService extends ChangeNotifier {
  LocalLlmService({
    LocalLlmBackend? backend,
    LocalModelMemoryGuard? memoryGuard,
    LocalLlmModelLocator? locator,
    DateTime Function()? clock,
  }) : _backend = backend ?? MethodChannelLocalLlmBackend(),
       _memoryGuard = memoryGuard ?? LocalModelMemoryGuard(),
       _locator = locator ?? LocalLlmModelLocator(),
       _clock = clock ?? DateTime.now {
    _memoryGuard.registerReleaser(
      LocalHeavyModelSlot.smallLlm,
      _unloadFromGuard,
    );
    _memoryGuard.registerReleaser(
      LocalHeavyModelSlot.largeLlm,
      _unloadFromGuard,
    );
  }

  final LocalLlmBackend _backend;
  final LocalModelMemoryGuard _memoryGuard;
  final LocalLlmModelLocator _locator;
  final DateTime Function() _clock;

  DeviceLlmCapabilities _cachedCaps = DeviceLlmCapabilities.unknown;
  LocalLlmModelSpec? _loadedSpec;
  String? _loadedEngine;
  String? _activeRequestId;
  int _reqSeq = 0;

  DeviceLlmCapabilities get capabilities => _cachedCaps;
  DeviceLlmCapabilityTier get deviceTier => evaluateDeviceLlmTier(_cachedCaps);
  LocalLlmModelSpec? get loadedSpec => _loadedSpec;
  bool get isModelLoaded => _loadedEngine != null;

  Future<DeviceLlmCapabilities> refreshCapabilities() async {
    _cachedCaps = await _backend.probeCapabilities();
    notifyListeners();
    return _cachedCaps;
  }

  Future<LocalLlmInstallStatus> smallModelStatus() =>
      _locator.statusFor(qwen35SmallPolishSpec);

  Future<LocalLlmInstallStatus> largeModelStatus() =>
      _locator.statusFor(qwen35LargeSummarySpec);

  /// 决策轻量润色路由（如输入法上屏前极速纠错）。
  Future<LlmRouteDecision> decidePolishRoute({
    LocalLlmRoutingOverride override = LocalLlmRoutingOverride.auto,
    required bool cloudReady,
  }) async {
    final caps = await refreshCapabilities();
    final tier = evaluateDeviceLlmTier(caps);

    if (override == LocalLlmRoutingOverride.forceCloud) {
      return LlmRouteDecision(
        route: cloudReady
            ? LlmExecutionRoute.cloud
            : LlmExecutionRoute.unavailable,
        deviceTier: tier,
        reason: '已配置强制云端润色',
      );
    }

    final smallStatus = await _locator.statusFor(qwen35SmallPolishSpec);
    final canRunLlamaSmall = caps.llamaRuntimeLinked && smallStatus.installed;
    final allowLocalInAuto =
        tier == DeviceLlmCapabilityTier.compactLocal ||
        tier == DeviceLlmCapabilityTier.fullLocal;

    if (override == LocalLlmRoutingOverride.forceLocalSmall) {
      if (canRunLlamaSmall) {
        return LlmRouteDecision(
          route: LlmExecutionRoute.localSmall,
          deviceTier: tier,
          spec: qwen35SmallPolishSpec,
          recommendedCtx: tier == DeviceLlmCapabilityTier.compactLocal
              ? 1024
              : 1536,
          reason: '已强制启用端侧小模型（${qwen35SmallPolishSpec.displayName}）',
        );
      }
      if (caps.supportsFoundationModels) {
        return LlmRouteDecision(
          route: LlmExecutionRoute.appleFoundation,
          deviceTier: tier,
          recommendedCtx: 2048,
          reason: '未安装 GGUF，回落 Apple 系统内置模型润色',
        );
      }
      return LlmRouteDecision(
        route: cloudReady
            ? LlmExecutionRoute.cloud
            : LlmExecutionRoute.unavailable,
        deviceTier: tier,
        reason: '端侧小模型未安装或运行时未就绪',
      );
    }

    // auto 模式：老旧/低余量机型直接走云端；4GB/8GB 机型优先端侧极小模型。
    if (!allowLocalInAuto) {
      return LlmRouteDecision(
        route: cloudReady
            ? LlmExecutionRoute.cloud
            : LlmExecutionRoute.unavailable,
        deviceTier: tier,
        reason: '设备内存或可用余量不足（${caps.physicalMemoryGiB.toStringAsFixed(1)}GB），自动切换云端润色',
      );
    }

    if (canRunLlamaSmall) {
      return LlmRouteDecision(
        route: LlmExecutionRoute.localSmall,
        deviceTier: tier,
        spec: qwen35SmallPolishSpec,
        recommendedCtx: tier == DeviceLlmCapabilityTier.compactLocal
            ? 1024
            : 1536,
        reason: '端侧极速小模型就绪',
      );
    }

    if (caps.supportsFoundationModels) {
      return LlmRouteDecision(
        route: LlmExecutionRoute.appleFoundation,
        deviceTier: tier,
        recommendedCtx: 2048,
        reason: '使用 iOS 系统内置端侧模型润色',
      );
    }

    return LlmRouteDecision(
      route: cloudReady
          ? LlmExecutionRoute.cloud
          : LlmExecutionRoute.unavailable,
      deviceTier: tier,
      reason: smallStatus.installed
          ? '端侧 LLM 运行时未链接，回落云端润色'
          : '未安装本地润色模型，回落云端润色',
    );
  }

  /// 决策前台流式总结路由。
  Future<LlmRouteDecision> decideSummaryRoute({
    LocalLlmRoutingOverride override = LocalLlmRoutingOverride.auto,
    required bool cloudReady,
  }) async {
    final caps = await refreshCapabilities();
    final tier = evaluateDeviceLlmTier(caps);

    if (override == LocalLlmRoutingOverride.forceCloud) {
      return LlmRouteDecision(
        route: cloudReady
            ? LlmExecutionRoute.cloud
            : LlmExecutionRoute.unavailable,
        deviceTier: tier,
        reason: '已配置强制云端总结',
      );
    }

    final largeStatus = await _locator.statusFor(qwen35LargeSummarySpec);
    final smallStatus = await _locator.statusFor(qwen35SmallPolishSpec);

    if (override == LocalLlmRoutingOverride.forceLocalLarge) {
      if (caps.llamaRuntimeLinked && largeStatus.installed) {
        return LlmRouteDecision(
          route: LlmExecutionRoute.localLarge,
          deviceTier: tier,
          spec: qwen35LargeSummarySpec,
          recommendedCtx: tier == DeviceLlmCapabilityTier.fullLocal ? 2048 : 1536,
          reason: '已强制启用端侧大模型（${qwen35LargeSummarySpec.displayName}）',
        );
      }
      return LlmRouteDecision(
        route: cloudReady
            ? LlmExecutionRoute.cloud
            : LlmExecutionRoute.unavailable,
        deviceTier: tier,
        reason: '端侧大模型文件或运行时未就绪',
      );
    }

    if (override == LocalLlmRoutingOverride.forceLocalSmall &&
        caps.llamaRuntimeLinked &&
        smallStatus.installed) {
      return LlmRouteDecision(
        route: LlmExecutionRoute.localSmall,
        deviceTier: tier,
        spec: qwen35SmallPolishSpec,
        recommendedCtx: 1536,
        reason: '已强制使用端侧小模型生成总结',
      );
    }

    // auto 模式：
    // - fullLocal (如 iPhone 16 Pro 8GB) 才启用端侧 2B 大模型；
    // - compactLocal (如 iPhone 13 mini 4GB) 与 legacyCloudOnly 默认走云端防 Jetsam。
    if (tier == DeviceLlmCapabilityTier.fullLocal) {
      if (caps.llamaRuntimeLinked && largeStatus.installed) {
        return LlmRouteDecision(
          route: LlmExecutionRoute.localLarge,
          deviceTier: tier,
          spec: qwen35LargeSummarySpec,
          recommendedCtx: qwen35LargeSummarySpec.recommendedCtx,
          reason: '设备内存充足，启用端侧大模型前台流式总结',
        );
      }
      if (caps.supportsFoundationModels) {
        return LlmRouteDecision(
          route: LlmExecutionRoute.appleFoundation,
          deviceTier: tier,
          recommendedCtx: 3072,
          reason: '启用系统内置端侧模型前台流式总结',
        );
      }
    }

    return LlmRouteDecision(
      route: cloudReady
          ? LlmExecutionRoute.cloud
          : LlmExecutionRoute.unavailable,
      deviceTier: tier,
      reason: tier == DeviceLlmCapabilityTier.compactLocal
          ? '4GB 级设备为防总结期杀后台，自动切换云端流式总结'
          : (tier == DeviceLlmCapabilityTier.legacyCloudOnly
                ? '设备内存或可用余量受限，自动切换云端总结'
                : '本地大模型未就绪，使用云端流式总结'),
    );
  }

  /// 输入法/短文本极速润色：优先端侧小模型（关闭扩写），不可用或失败时自动回落云端。
  Future<LocalLlmPolishOutcome> polishShortText(
    String rawText, {
    required Future<String> Function(String text) cloudFallback,
    required bool cloudReady,
    List<String> hotwords = const [],
    LocalLlmRoutingOverride override = LocalLlmRoutingOverride.auto,
    bool unloadAfterCompactDevice = false,
  }) async {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return const LocalLlmPolishOutcome(
        text: '',
        route: LlmExecutionRoute.unavailable,
        elapsedMs: 0,
      );
    }

    final startMs = _clock().millisecondsSinceEpoch;
    final decision = await decidePolishRoute(
      override: override,
      cloudReady: cloudReady,
    );

    if (decision.route == LlmExecutionRoute.localSmall ||
        decision.route == LlmExecutionRoute.appleFoundation) {
      try {
        final buf = StringBuffer();
        final stream = await generateTextStream(
          decision: decision,
          systemPrompt: _buildShortPolishPrompt(hotwords),
          userPrompt: trimmed,
          maxTokens: (trimmed.length * 2).clamp(128, 512),
          temperature: 0.1,
        );
        await for (final chunk in stream) {
          buf.write(chunk);
        }
        final polished = _sanitizePolishedOutput(buf.toString());
        if (unloadAfterCompactDevice ||
            decision.deviceTier == DeviceLlmCapabilityTier.compactLocal) {
          await unload();
        }
        if (polished.isNotEmpty) {
          return LocalLlmPolishOutcome(
            text: polished,
            route: decision.route,
            elapsedMs: _clock().millisecondsSinceEpoch - startMs,
          );
        }
      } on Object catch (e) {
        if (!cloudReady) rethrow;
        final fallback = await cloudFallback(trimmed);
        return LocalLlmPolishOutcome(
          text: fallback.trim().isEmpty ? trimmed : fallback.trim(),
          route: LlmExecutionRoute.cloud,
          elapsedMs: _clock().millisecondsSinceEpoch - startMs,
          fallbackReason: '端侧润色回落云端：$e',
        );
      }
    }

    if (decision.route == LlmExecutionRoute.cloud || cloudReady) {
      final fallback = await cloudFallback(trimmed);
      return LocalLlmPolishOutcome(
        text: fallback.trim().isEmpty ? trimmed : fallback.trim(),
        route: LlmExecutionRoute.cloud,
        elapsedMs: _clock().millisecondsSinceEpoch - startMs,
        fallbackReason: decision.reason,
      );
    }

    throw LocalLlmException(
      decision.reason,
      code: 'POLISH_UNAVAILABLE',
    );
  }

  /// 打开本地模型流式推理通道（供总结器或测试调用）。
  Future<Stream<String>> generateTextStream({
    required LlmRouteDecision decision,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    double temperature = 0.2,
  }) async {
    if (!decision.route.isLocal) {
      throw LocalLlmException(
        '路由 ${decision.route.code} 不是本地模型路由',
        code: 'INVALID_LOCAL_ROUTE',
      );
    }
    final slot = decision.route == LlmExecutionRoute.localLarge
        ? LocalHeavyModelSlot.largeLlm
        : LocalHeavyModelSlot.smallLlm;
    await _memoryGuard.acquire(slot, reason: 'llm:${decision.route.code}');

    final engine = decision.route == LlmExecutionRoute.appleFoundation
        ? 'apple_foundation'
        : 'llama_gguf';
    String? modelPath;
    if (engine == 'llama_gguf') {
      final spec = decision.spec ?? qwen35SmallPolishSpec;
      final status = await _locator.statusFor(spec);
      if (!status.installed) {
        await _memoryGuard.release(slot, reason: 'missing_file');
        throw LocalLlmException(
          '本地模型文件未安装：${spec.fileName}',
          code: 'MODEL_NOT_INSTALLED',
        );
      }
      modelPath = status.filePath;
    }

    if (_loadedEngine != engine || _loadedSpec?.id != decision.spec?.id) {
      await _backend.loadModel(
        engine: engine,
        modelPath: modelPath,
        nCtx: decision.recommendedCtx,
        useMetal: true,
        quantizeKvQ8: true,
      );
      _loadedEngine = engine;
      _loadedSpec = decision.spec;
    }

    final reqId = 'llm_${++_reqSeq}';
    _activeRequestId = reqId;
    final rawStream = _backend.generateStream(
      requestId: reqId,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    return rawStream.transform(
      StreamTransformer<String, String>.fromHandlers(
        handleDone: (sink) {
          if (_activeRequestId == reqId) _activeRequestId = null;
          sink.close();
        },
        handleError: (err, st, sink) {
          if (_activeRequestId == reqId) _activeRequestId = null;
          sink.addError(err, st);
        },
      ),
    );
  }

  /// 退后台前立即停止在途 GPU 推理并排空命令队列，随后卸载模型防止 Jetsam/Metal 闪退。
  Future<void> pauseAndDrainForBackground() async {
    final req = _activeRequestId;
    _activeRequestId = null;
    if (req != null) {
      await _backend.cancelGeneration(req);
    }
    await _backend.pauseAndDrain();
    await unload();
  }

  Future<void> unload() async {
    await _memoryGuard.release(
      _loadedSpec?.tier == LocalLlmTier.largeQuality
          ? LocalHeavyModelSlot.largeLlm
          : LocalHeavyModelSlot.smallLlm,
      reason: 'unload',
    );
  }

  Future<void> _unloadFromGuard() async {
    final req = _activeRequestId;
    _activeRequestId = null;
    if (req != null) {
      await _backend.cancelGeneration(req);
    }
    await _backend.unloadModel();
    _loadedEngine = null;
    _loadedSpec = null;
  }

  static String _buildShortPolishPrompt(List<String> hotwords) {
    final cleanHotwords = [
      for (final w in hotwords)
        if (w.trim().isNotEmpty) w.trim(),
    ];
    final hw = cleanHotwords.isEmpty
        ? ''
        : '\n专有名词参考（仅在同音误字时修正，勿硬塞）：${cleanHotwords.join('、')}';
    return '你是极速文本润色助手。只做三件事：删去口水词与无意义重复、补全标点符号、修正明显同音错字。'
        '严禁扩写、严禁总结、严禁解释、不要输出思考过程，只直接输出润色后的最终文本。$hw';
  }

  static String _sanitizePolishedOutput(String raw) {
    var s = raw.trim();
    // 剥离模型偶发残留的 <think>...</think>
    s = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>', multiLine: true), '');
    return s.trim();
  }
}
