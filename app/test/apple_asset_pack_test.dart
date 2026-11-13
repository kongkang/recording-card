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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelManagerController + AppleAssetPackClient', () {
    test('iOS Apple-Hosted 可用且未配置 RC_MODEL_BASE 时标记为已配置并走 Apple 资源包', () async {
      final root = await Directory.systemTemp.createTemp('rc-apple-assets-');
      addTearDown(() => root.deleteSync(recursive: true));

      final fakeApple = _FakeAppleAssetPackClient(
        available: true,
        onInstall: (packId, files, onProgress) async {
          onProgress?.call(0.5, '正在下载…');
          for (final f in files) {
            final file = File(f.destPath);
            await file.parent.create(recursive: true);
            if (f.assetPath.endsWith('tokens.txt')) {
              // skip sha mismatch by not checking? Wait: tokens.txt has real sha256!
              // Let's test that sha256 verification catches bad content!
              await file.writeAsString('bad');
            } else {
              await file.writeAsBytes(const [1, 2, 3]);
            }
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
      // tokens.txt 校验应拦截损坏文件
      expect(controller.error, contains('tokens.txt'));
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
