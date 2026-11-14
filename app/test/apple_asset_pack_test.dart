import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/transcribe/apple_asset_pack_client.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/model_manager_controller.dart';

import 'support/test_transitions.dart';

class _FakeAppleAssetPackClient extends AppleAssetPackClient {
  _FakeAppleAssetPackClient({
    required this.available,
    this.onInstall,
  }) : super(isIOSOverride: true);

  final bool available;
  final Future<void> Function(
    String packId,
    List<AppleAssetPackFile> files,
    void Function(double progress, String text)? onProgress,
  )?
  onInstall;

  final List<String> installedPacks = [];
  final List<String> removedPacks = [];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> installAssetPack({
    required String packId,
    required String displayName,
    required List<AppleAssetPackFile> files,
    void Function(double progress, String text)? onProgress,
  }) async {
    installedPacks.add(packId);
    if (onInstall != null) {
      await onInstall!(packId, files, onProgress);
      return;
    }
    onProgress?.call(0.5, '正在下载 $displayName（50%）…');
    for (final f in files) {
      final dest = File(f.destPath);
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(const [1, 2, 3]);
    }
    onProgress?.call(1.0, '$displayName已就绪');
  }

  @override
  Future<void> removeAssetPack(String packId) async {
    removedPacks.add(packId);
  }
}

Future<void> _seedSparseInstalled(
  ModelInstaller installer,
  ModelSpec spec,
) async {
  final dir = await installer.dirFor(spec);
  await dir.create(recursive: true);
  for (final f in spec.files) {
    final file = File('${dir.path}/${f.relPath}');
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    await raf.truncate(f.sizeBytes > 0 ? f.sizeBytes : 1024);
    await raf.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelManagerController 下载源优先级与单模型下载', () {
    test('生产默认（无 dart-define）：iOS 26+ 优先走免费 Apple CDN，不旁路到外脑 CDN', () async {
      final root = await Directory.systemTemp.createTemp('rc-prio-ios26-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(available: true);
      final controller = ModelManagerController(
        installer: ModelInstaller(root: root),
        appleAssets: fakeApple,
        clientConfig: const ClientConfig.forTesting(),
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.configured, isTrue);
      expect(controller.usesAppleAssets, isTrue);
      expect(controller.effectiveBaseUrl, ClientConfig.defaultModelBase);
    });

    test('生产默认（无 dart-define）：Android / 低版本 iOS 自动回落外脑 CDN', () async {
      final root = await Directory.systemTemp.createTemp('rc-prio-android-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(available: false);
      final controller = ModelManagerController(
        installer: ModelInstaller(root: root),
        appleAssets: fakeApple,
        clientConfig: const ClientConfig.forTesting(),
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.configured, isTrue);
      expect(controller.usesAppleAssets, isFalse);
      expect(controller.effectiveBaseUrl, 'https://dl.wainao.chat/reai/models');
    });

    test('显式注入 RC_MODEL_BASE 时最高优先覆盖 iOS Apple CDN', () async {
      final root = await Directory.systemTemp.createTemp('rc-prio-define-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(available: true);
      final controller = ModelManagerController(
        installer: ModelInstaller(root: root),
        appleAssets: fakeApple,
        clientConfig: const ClientConfig.forTesting(
          hasModelBaseDefine: true,
          modelBaseDefineValue: 'https://custom.example.com/models/',
        ),
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.configured, isTrue);
      expect(controller.usesAppleAssets, isFalse);
      expect(controller.effectiveBaseUrl, 'https://custom.example.com/models');
    });

    test('iOS Apple-Hosted 校验文件完整性拦截损坏产物', () async {
      final root = await Directory.systemTemp.createTemp('rc-apple-assets-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(
        available: true,
        onInstall: (packId, files, onProgress) async {
          onProgress?.call(0.5, '正在下载…');
          for (final f in files) {
            final file = File(f.destPath);
            await file.parent.create(recursive: true);
            await file.writeAsString('corrupted');
          }
        },
      );

      final controller = ModelManagerController(
        installer: ModelInstaller(root: root),
        appleAssets: fakeApple,
        baseUrl: '',
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.configured, isTrue);
      expect(controller.usesAppleAssets, isTrue);

      await controller.installAll();
      expect(fakeApple.installedPacks, contains('sensevoice-small-int8'));
      expect(controller.error, contains('model.int8.onnx'));
    });

    test('已安装的模型不重复触发 Apple 资源包下载；可选声纹包未上架时静默跳过且不循环重试', () async {
      final root = await Directory.systemTemp.createTemp('rc-apple-skip-');
      addTearDown(() => root.deleteSync(recursive: true));

      final installer = ModelInstaller(root: root);
      await _seedSparseInstalled(installer, senseVoiceSpec);

      final fakeApple = _FakeAppleAssetPackClient(
        available: true,
        onInstall: (packId, files, onProgress) async {
          if (packId == campplusEmbeddingSpec.id) {
            throw const AppleAssetPackException(
              'Asset pack not found',
              code: 'ASSET_PACK_NOT_FOUND',
            );
          }
        },
      );

      final controller = ModelManagerController(
        installer: installer,
        appleAssets: fakeApple,
        baseUrl: '',
      );
      addTearDown(controller.dispose);

      await controller.autoEnsureInstalled();
      expect(fakeApple.installedPacks, isNot(contains(senseVoiceSpec.id)));
      expect(fakeApple.installedPacks, [campplusEmbeddingSpec.id]);
      expect(controller.asrReady, isTrue);
      expect(controller.error, isNull);

      await controller.autoEnsureInstalled();
      expect(fakeApple.installedPacks, [campplusEmbeddingSpec.id]);
    });

    test('delete 在 Apple-Hosted 模式下同步清理托管资源包缓存', () async {
      final root = await Directory.systemTemp.createTemp('rc-apple-delete-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(available: true);
      final controller = ModelManagerController(
        installer: ModelInstaller(root: root),
        appleAssets: fakeApple,
        baseUrl: '',
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      await controller.delete(senseVoiceSpec);
      expect(fakeApple.removedPacks, ['sensevoice-small-int8']);
    });

    test('installSpec 支持单模型 HTTP 下载（.part -> SHA-256 -> 原子落盘）', () async {
      final root = await Directory.systemTemp.createTemp('rc-single-spec-');
      addTearDown(() => root.deleteSync(recursive: true));

      final payload = List<int>.generate(2048, (i) => (i * 13) % 251);
      final customSpec = ModelSpec(
        id: 'campplus-embedding',
        displayName: '声纹嵌入模型',
        version: 'test',
        kind: LocalModelKind.speakerEmbedding,
        files: [
          ModelFileSpec(
            relPath: 'test.onnx',
            sizeBytes: payload.length,
            sha256: sha256.convert(payload).toString(),
          ),
        ],
      );

      final installer = ModelInstaller(
        root: root,
        clientFactory: () => MockClient.streaming((request, _) async {
          if (request.url.path == '/reai/models/campplus-embedding/test.onnx') {
            return http.StreamedResponse(
              Stream<List<int>>.value(payload),
              200,
              contentLength: payload.length,
            );
          }
          return http.StreamedResponse(const Stream.empty(), 404);
        }),
      );
      final controller = ModelManagerController(
        installer: installer,
        appleAssets: _FakeAppleAssetPackClient(available: false),
        clientConfig: const ClientConfig.forTesting(),
      );
      addTearDown(controller.dispose);

      await controller.installSpec(customSpec);
      expect(controller.error, isNull);
      final st = await installer.status(customSpec);
      expect(st.installed, isTrue);
    });

    test('iOS 26+ Apple 资源包未上架或失败时，运行时自动回落外脑 CDN 下载声纹与转写模型', () async {
      final root = await Directory.systemTemp.createTemp('rc-apple-fallback-');
      addTearDown(() => root.deleteSync(recursive: true));

      final vpPayload = List<int>.generate(1024, (i) => (i * 7) % 251);
      final customVoiceprint = ModelSpec(
        id: 'campplus-embedding',
        displayName: '声纹嵌入模型',
        version: 'fallback-test',
        kind: LocalModelKind.speakerEmbedding,
        files: [
          ModelFileSpec(
            relPath: 'campplus.onnx',
            sizeBytes: vpPayload.length,
            sha256: sha256.convert(vpPayload).toString(),
          ),
        ],
      );

      var httpHits = 0;
      final installer = ModelInstaller(
        root: root,
        clientFactory: () => MockClient.streaming((request, _) async {
          if (request.url.toString() ==
              'https://dl.wainao.chat/reai/models/campplus-embedding/campplus.onnx') {
            httpHits++;
            return http.StreamedResponse(
              Stream<List<int>>.value(vpPayload),
              200,
              contentLength: vpPayload.length,
            );
          }
          return http.StreamedResponse(const Stream.empty(), 404);
        }),
      );

      final fakeApple = _FakeAppleAssetPackClient(
        available: true,
        onInstall: (packId, files, onProgress) async {
          throw const AppleAssetPackException(
            'Asset pack not found on Apple CDN',
            code: 'ASSET_PACK_NOT_FOUND',
          );
        },
      );

      final controller = ModelManagerController(
        installer: installer,
        appleAssets: fakeApple,
        clientConfig: const ClientConfig.forTesting(),
      );
      addTearDown(controller.dispose);

      await controller.installSpec(customVoiceprint);

      expect(fakeApple.installedPacks, ['campplus-embedding']);
      expect(httpHits, 1);
      expect(controller.error, isNull);
      final st = await installer.status(customVoiceprint);
      expect(st.installed, isTrue);
    });
  });

  testWidgets('声纹识别子页：未安装展示下载按钮，失败变重试，成功后显示已就绪并隐藏按钮', (tester) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('rc-voiceprint-ui-'),
    );
    addTearDown(() => root!.deleteSync(recursive: true));

    var shouldFail = true;
    final installer = ModelInstaller(root: root);
    final fakeApple = _FakeAppleAssetPackClient(
      available: true,
      onInstall: (packId, files, onProgress) async {
        if (shouldFail) {
          throw const AppleAssetPackException('网络波动中断');
        }
        await _seedSparseInstalled(installer, campplusEmbeddingSpec);
      },
    );
    // 注意：Apple 路径会跑 verifyInstalledFiles（含真实 SHA-256），因此成功分支用假 HTTP 失败/预置状态验证 UI 状态机
    final controller = ModelManagerController(
      installer: installer,
      appleAssets: fakeApple,
      baseUrl: '',
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.refresh);

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    addTearDown(agentConfig.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: SettingSubPage(
          subId: 'voiceprint',
          agentConfig: agentConfig,
          modelManager: controller,
          standalone: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('待下载'), findsOneWidget);
    expect(find.byKey(const Key('voiceprint-install-btn')), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);

    // 第一次点击触发失败 -> 按钮变为「重试」且展示错误原因
    await tester.runAsync(() => controller.installSpec(campplusEmbeddingSpec));
    await tester.pump();
    expect(find.byKey(const Key('voiceprint-error')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 模型落盘就绪后刷新 -> 展示「已就绪」且隐藏下载按钮
    shouldFail = false;
    await tester.runAsync(
      () => _seedSparseInstalled(installer, campplusEmbeddingSpec),
    );
    await tester.runAsync(controller.refresh);
    await tester.pump();

    expect(find.text('已就绪'), findsOneWidget);
    expect(find.byKey(const Key('voiceprint-install-btn')), findsNothing);
  });
}
