/// 本地模型管理 —— Setting 页展示安装状态、下载/删除。
///
/// 下载源优先级：
/// 1. 显式配置 `--dart-define=RC_MODEL_BASE` 时走 HTTP（Android 及自定义源）；
/// 2. iOS 26+ 未配置 `RC_MODEL_BASE` 时走 Apple-Hosted Background Assets。
library;

import 'package:flutter/foundation.dart';

import 'apple_asset_pack_client.dart';
import 'asr_models.dart';

class ModelManagerController extends ChangeNotifier {
  ModelManagerController({
    ModelInstaller? installer,
    AppleAssetPackClient? appleAssets,
    String? baseUrl,
    this.onInstalled,
  }) : _installer = installer ?? ModelInstaller(),
       _appleAssets = appleAssets ?? AppleAssetPackClient(),
       _baseUrl = baseUrl ?? const String.fromEnvironment('RC_MODEL_BASE');

  final ModelInstaller _installer;
  final AppleAssetPackClient _appleAssets;
  final String _baseUrl;

  /// 安装完成后的回调（通常是 `AppStore.processPendingRecordings`）。
  final Future<void> Function()? onInstalled;

  final Map<String, ModelStatus> _statuses = {};
  bool _busy = false;
  double _progress = 0;
  String _text = '';
  String? _error;
  bool _appleAssetsChecked = false;
  bool _appleAssetsAvailable = false;

  bool get busy => _busy;
  double get progress => _progress;
  String get text => _text;
  String? get error => _error;
  bool get hasBaseUrl => _baseUrl.trim().isNotEmpty;
  bool get appleAssetsAvailable => _appleAssetsAvailable;
  bool get usesAppleAssets => !hasBaseUrl && _appleAssetsAvailable;
  bool get configured => hasBaseUrl || _appleAssetsAvailable;
  String get baseUrl => _baseUrl;

  List<ModelSpec> get specs => const [
    senseVoiceSpec,
    sileroVadSpec,
    campplusEmbeddingSpec,
  ];

  ModelStatus? statusFor(ModelSpec spec) => _statuses[spec.id];

  bool get hasStatuses => _statuses.isNotEmpty;

  bool get allReady =>
      specs.every((s) => _statuses[s.id]?.installed == true);

  /// 是否有明确的新版本可更新（版本与本地一致或离线未比对时不提示更新，避免打扰）。
  bool get hasRemoteUpdates => false;

  /// 若已配置下载地址（或 iOS Apple-Hosted）但本地模型缺失，则在后台自动触发下载与加载。
  Future<void> autoEnsureInstalled() async {
    if (!hasStatuses) {
      await refresh();
    }
    if (configured && !allReady && !_busy) {
      await installAll();
    }
  }

  Future<void> _ensureAppleAssetsChecked() async {
    if (_appleAssetsChecked) return;
    _appleAssetsChecked = true;
    _appleAssetsAvailable = await _appleAssets.isAvailable();
  }

  Future<void> refresh() async {
    await _ensureAppleAssetsChecked();
    for (final spec in specs) {
      try {
        _statuses[spec.id] = await _installer.status(spec);
      } on Object {
        // 单个状态读取失败不影响其它模型展示
      }
    }
    notifyListeners();
  }

  Future<void> installAll() async {
    if (_busy) return;
    await _ensureAppleAssetsChecked();
    if (!configured) {
      _error = '未配置模型下载地址（RC_MODEL_BASE）';
      notifyListeners();
      return;
    }
    _busy = true;
    _error = null;
    _progress = 0;
    _text = '准备下载…';
    notifyListeners();
    try {
      await _installer.ensureBundled(sileroVadSpec);
      if (hasBaseUrl) {
        final base = Uri.parse(_baseUrl);
        await _installer.installFrom(
          senseVoiceSpec,
          baseUri: base,
          onProgress: _onProgress,
        );
        // 声纹模型失败不影响转写：只提示，不把整个安装判失败
        try {
          await _installer.installFrom(
            campplusEmbeddingSpec,
            baseUri: base,
            onProgress: _onProgress,
          );
        } on Object catch (e) {
          _error = '声纹模型下载失败：$e（转写仍可用）';
        }
      } else {
        await _installFromAppleAssets(senseVoiceSpec);
        // 声纹模型失败不影响转写：只提示，不把整个安装判失败
        try {
          await _installFromAppleAssets(campplusEmbeddingSpec);
        } on Object catch (e) {
          _error = '声纹模型下载失败：$e（转写仍可用）';
        }
      }
      await onInstalled?.call();
    } on Object catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      _text = '';
      await refresh();
    }
  }

  Future<void> _installFromAppleAssets(ModelSpec spec) async {
    final files = <AppleAssetPackFile>[];
    for (final f in spec.files) {
      files.add(
        AppleAssetPackFile(
          assetPath: '${spec.id}/${f.relPath}',
          destPath: await _installer.filePath(spec, f),
        ),
      );
    }
    await _appleAssets.installAssetPack(
      packId: spec.id,
      displayName: spec.displayName,
      files: files,
      onProgress: _onProgress,
    );
    await _installer.verifyInstalledFiles(spec);
  }

  Future<void> delete(ModelSpec spec) async {
    if (_busy) return;
    try {
      await _installer.delete(spec);
      if (_appleAssetsAvailable && !spec.bundled) {
        await _appleAssets.removeAssetPack(spec.id);
      }
    } on Object catch (e) {
      _error = '$e';
    }
    await refresh();
  }

  void _onProgress(double progress, String text) {
    _progress = progress.clamp(0, 1);
    _text = text;
    notifyListeners();
  }
}
