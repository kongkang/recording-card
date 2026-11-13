import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcribe/apple_asset_pack_client.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/model_manager_controller.dart';

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

  group('ModelManagerController + AppleAssetPackClient', () {
    test('iOS Apple-Hosted 可用且未配置 RC_MODEL_BASE 时标记为已配置并校验文件完整性', () async {
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
      // model.int8.onnx 大小/SHA 校验应拦截损坏文件
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
      // senseVoice 已安装，不应重复调用 installAssetPack
      expect(fakeApple.installedPacks, isNot(contains(senseVoiceSpec.id)));
      // campplus 尝试一次发现未上架后静默记录，不报错
      expect(fakeApple.installedPacks, [campplusEmbeddingSpec.id]);
      expect(controller.asrReady, isTrue);
      expect(controller.error, isNull);

      // 再次调用 autoEnsureInstalled 不应循环重试未上架的可选包
      await controller.autoEnsureInstalled();
      expect(fakeApple.installedPacks, [campplusEmbeddingSpec.id]);
    });

    test('配置了 RC_MODEL_BASE 时优先走 HTTP 而非 Apple 资源包', () async {
      final root = await Directory.systemTemp.createTemp('rc-apple-override-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(available: true);
      final controller = ModelManagerController(
        installer: ModelInstaller(root: root),
        appleAssets: fakeApple,
        baseUrl: 'https://cdn.example.com/models',
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.configured, isTrue);
      expect(controller.usesAppleAssets, isFalse);
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
  });
}
