import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/ai/local_llm_models.dart';
import 'package:recording_card/services/ai/local_llm_service.dart';
import 'package:recording_card/services/ai/local_model_memory_guard.dart';

class _FakeLlmBackend implements LocalLlmBackend {
  _FakeLlmBackend(this.caps);

  DeviceLlmCapabilities caps;
  int loadCalls = 0;
  int unloadCalls = 0;
  int pauseAndDrainCalls = 0;
  String? lastLoadedEngine;
  String? lastLoadedPath;
  int? lastLoadedCtx;
  String responseText = '今天下午三点在会议室讨论下周发布计划。';

  @override
  Future<DeviceLlmCapabilities> probeCapabilities() async => caps;

  @override
  Future<void> loadModel({
    required String engine,
    required String? modelPath,
    required int nCtx,
    required bool useMetal,
    required bool quantizeKvQ8,
  }) async {
    loadCalls++;
    lastLoadedEngine = engine;
    lastLoadedPath = modelPath;
    lastLoadedCtx = nCtx;
  }

  @override
  Future<void> unloadModel() async {
    unloadCalls++;
  }

  @override
  Future<void> pauseAndDrain() async {
    pauseAndDrainCalls++;
  }

  @override
  Stream<String> generateStream({
    required String requestId,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required double temperature,
  }) async* {
    final mid = responseText.length ~/ 2;
    yield responseText.substring(0, mid);
    yield responseText.substring(mid);
  }

  @override
  Future<void> cancelGeneration(String requestId) async {}
}

Future<Directory> _prepareTempModelFiles({
  required bool installSmall,
  required bool installLarge,
}) async {
  final root = await Directory.systemTemp.createTemp('rc_local_llm_test_');
  if (installSmall) {
    final p = '${root.path}/${qwen35SmallPolishSpec.id}/${qwen35SmallPolishSpec.fileName}';
    await File(p).create(recursive: true);
    await File(p).writeAsBytes(const [1, 2, 3, 4]);
  }
  if (installLarge) {
    final p = '${root.path}/${qwen35LargeSummarySpec.id}/${qwen35LargeSummarySpec.fileName}';
    await File(p).create(recursive: true);
    await File(p).writeAsBytes(const [5, 6, 7, 8]);
  }
  return root;
}

void main() {
  group('设备分级评估与单槽位内存互斥守卫', () {
    test('iPhone 13 mini (4GB) -> compactLocal：仅端侧小模型润色，总结默认自动切云端', () async {
      final root = await _prepareTempModelFiles(
        installSmall: true,
        installLarge: true,
      );
      addTearDown(() => root.delete(recursive: true));

      final guard = LocalModelMemoryGuard();
      final backend = _FakeLlmBackend(
        const DeviceLlmCapabilities(
          platform: 'ios',
          physicalMemoryBytes: 4 * 1024 * 1024 * 1024, // 4GB
          availableMemoryBytes: 1500 * 1024 * 1024, // ~1.5GB
          osMajorVersion: 18,
          machineModel: 'iPhone14,4',
          llamaRuntimeLinked: true,
        ),
      );
      final service = LocalLlmService(
        backend: backend,
        memoryGuard: guard,
        locator: LocalLlmModelLocator(rootOverride: root),
      );

      final polishRoute = await service.decidePolishRoute(cloudReady: true);
      expect(polishRoute.deviceTier, DeviceLlmCapabilityTier.compactLocal);
      expect(polishRoute.route, LlmExecutionRoute.localSmall);
      expect(polishRoute.recommendedCtx, 1024);

      final summaryRoute = await service.decideSummaryRoute(cloudReady: true);
      expect(summaryRoute.deviceTier, DeviceLlmCapabilityTier.compactLocal);
      expect(summaryRoute.route, LlmExecutionRoute.cloud);

      // 支持双机压测时显式强开大模型
      final forcedLarge = await service.decideSummaryRoute(
        override: LocalLlmRoutingOverride.forceLocalLarge,
        cloudReady: true,
      );
      expect(forcedLarge.route, LlmExecutionRoute.localLarge);
    });

    test('iPhone 16 Pro (8GB) -> fullLocal：端侧小模型润色 + 端侧大模型总结均可启用', () async {
      final root = await _prepareTempModelFiles(
        installSmall: true,
        installLarge: true,
      );
      addTearDown(() => root.delete(recursive: true));

      final backend = _FakeLlmBackend(
        const DeviceLlmCapabilities(
          platform: 'ios',
          physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
          availableMemoryBytes: 4000 * 1024 * 1024,
          osMajorVersion: 26,
          machineModel: 'iPhone17,1',
          supportsFoundationModels: true,
          llamaRuntimeLinked: true,
        ),
      );
      final service = LocalLlmService(
        backend: backend,
        memoryGuard: LocalModelMemoryGuard(),
        locator: LocalLlmModelLocator(rootOverride: root),
      );

      final polishRoute = await service.decidePolishRoute(cloudReady: true);
      expect(polishRoute.deviceTier, DeviceLlmCapabilityTier.fullLocal);
      expect(polishRoute.route, LlmExecutionRoute.localSmall);

      final summaryRoute = await service.decideSummaryRoute(cloudReady: true);
      expect(summaryRoute.deviceTier, DeviceLlmCapabilityTier.fullLocal);
      expect(summaryRoute.route, LlmExecutionRoute.localLarge);
      expect(summaryRoute.recommendedCtx, 2048);
    });

    test('老旧机型 (3GB) 或低 Jetsam 余量 (<900MB) 自动切云端方案', () async {
      final root = await _prepareTempModelFiles(
        installSmall: true,
        installLarge: true,
      );
      addTearDown(() => root.delete(recursive: true));

      final backend = _FakeLlmBackend(
        const DeviceLlmCapabilities(
          platform: 'ios',
          physicalMemoryBytes: 3 * 1024 * 1024 * 1024,
          availableMemoryBytes: 600 * 1024 * 1024,
          osMajorVersion: 16,
          machineModel: 'iPhone12,1',
          llamaRuntimeLinked: true,
        ),
      );
      final service = LocalLlmService(
        backend: backend,
        memoryGuard: LocalModelMemoryGuard(),
        locator: LocalLlmModelLocator(rootOverride: root),
      );

      var cloudCalled = false;
      final out = await service.polishShortText(
        '嗯那个明天早上九点开会',
        cloudFallback: (text) async {
          cloudCalled = true;
          return '明天早上九点开会。';
        },
        cloudReady: true,
      );

      expect(cloudCalled, isTrue);
      expect(out.route, LlmExecutionRoute.cloud);
      expect(out.text, '明天早上九点开会。');
      expect(backend.loadCalls, 0);
    });

    test('单槽位互斥守卫：ASR <-> 小 LLM <-> 大 LLM 严格串行互斥释放，退后台全卸', () async {
      final events = <String>[];
      final guard = LocalModelMemoryGuard(
        onTrimNativeMemory: () async => events.add('trim'),
      );
      guard.registerReleaser(
        LocalHeavyModelSlot.asr,
        () async => events.add('release:asr'),
      );
      guard.registerReleaser(
        LocalHeavyModelSlot.smallLlm,
        () async => events.add('release:small_llm'),
      );
      guard.registerReleaser(
        LocalHeavyModelSlot.largeLlm,
        () async => events.add('release:large_llm'),
      );

      await guard.acquire(LocalHeavyModelSlot.asr);
      expect(guard.activeSlot, LocalHeavyModelSlot.asr);

      await guard.acquire(LocalHeavyModelSlot.smallLlm);
      expect(guard.activeSlot, LocalHeavyModelSlot.smallLlm);
      expect(events, containsAllInOrder(['release:asr', 'trim']));

      await guard.acquire(LocalHeavyModelSlot.largeLlm);
      expect(guard.activeSlot, LocalHeavyModelSlot.largeLlm);
      expect(guard.evictionCount, 2);

      await guard.releaseAll(reason: 'background');
      expect(guard.activeSlot, LocalHeavyModelSlot.none);
      expect(events.last, 'trim');
    });
  });
}
