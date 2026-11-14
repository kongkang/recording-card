/// 本地模型管理 —— Setting 页及声纹子页展示安装状态、单模型/全量下载与删除。
///
/// 下载源优先级：
/// 1. 显式传入 `baseUrl` 或 `--dart-define=RC_MODEL_BASE=...` 时走指定 HTTP 源；
/// 2. iOS 26+ 支持 Apple-Hosted Background Assets 时优先走免费 Apple CDN；
/// 3. 其余平台（Android / iOS 15~25）默认回落外脑 CDN `https://dl.wainao.chat/reai/models`。
library;

import 'package:flutter/foundation.dart';

import '../../core/config/remote/client_config.dart';
import 'apple_asset_pack_client.dart';
import 'asr_models.dart';

class ModelManagerController extends ChangeNotifier {
  ModelManagerController({
    ModelInstaller? installer,
    AppleAssetPackClient? appleAssets,
    String? baseUrl,
    ClientConfig? clientConfig,
    this.onInstalled,
  }) : _installer = installer ?? ModelInstaller(),
       _appleAssets = appleAssets ?? AppleAssetPackClient(),
       _explicitBaseUrl = baseUrl != null
           ? baseUrl.trim()
           : ((clientConfig ?? ClientConfig.instance).explicitModelBase ?? ''),
       _fallbackBaseUrl = baseUrl != null
           ? ''
           : (clientConfig ?? ClientConfig.instance).fallbackModelBase;

  final ModelInstaller _installer;
  final AppleAssetPackClient _appleAssets;
  final String _explicitBaseUrl;
  final String _fallbackBaseUrl;

  /// 安装完成后的回调（通常是 `AppStore.processPendingRecordings`）。
  final Future<void> Function()? onInstalled;

  final Map<String, ModelStatus> _statuses = {};
  final Set<String> _unavailableRemotePacks = {};
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

  bool get hasExplicitBaseUrl => _explicitBaseUrl.isNotEmpty;
  bool get hasFallbackBaseUrl => _fallbackBaseUrl.isNotEmpty;
  bool get appleAssetsAvailable => _appleAssetsAvailable;

  /// 未显式覆盖 `RC_MODEL_BASE` 且 iOS 26+ Apple-Hosted 可用时走 Apple CDN。
  bool get usesAppleAssets => !hasExplicitBaseUrl && _appleAssetsAvailable;

  /// 当前生效的 HTTP 下载根地址（走 Apple CDN 时仍返回兜底地址供排查，无则空串）。
  String get effectiveBaseUrl =>
      hasExplicitBaseUrl ? _explicitBaseUrl : _fallbackBaseUrl;

  bool get hasBaseUrl => effectiveBaseUrl.isNotEmpty;
  bool get configured =>
      hasExplicitBaseUrl || _appleAssetsAvailable || hasFallbackBaseUrl;
  String get baseUrl => effectiveBaseUrl;

  List<ModelSpec> get specs => const [
    senseVoiceSpec,
    sileroVadSpec,
    campplusEmbeddingSpec,
  ];

  ModelStatus? statusFor(ModelSpec spec) => _statuses[spec.id];

  bool get hasStatuses => _statuses.isNotEmpty;

  /// 核心离线转写（SenseVoice + VAD）是否已就绪。
  bool get asrReady =>
      _statuses[senseVoiceSpec.id]?.installed == true &&
      _statuses[sileroVadSpec.id]?.installed == true;

  bool get allReady =>
      specs.every((s) => _statuses[s.id]?.installed == true);

  bool get _allAvailableSpecsReady => specs
      .where((s) => !_unavailableRemotePacks.contains(s.id))
      .every((s) => _statuses[s.id]?.installed == true);

  /// 是否有明确的新版本可更新（版本与本地一致或离线未比对时不提示更新，避免打扰）。
  bool get hasRemoteUpdates => false;

  /// 若已配置下载地址（或 iOS Apple-Hosted）但本地模型缺失，则在后台自动触发下载与加载。
  Future<void> autoEnsureInstalled() async {
    if (!hasStatuses) {
      await refresh();
    }
    if (configured && !_allAvailableSpecsReady && !_busy) {
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

  /// 单独下载/重试指定模型（如「声纹识别」子页下载 `campplusEmbeddingSpec`）。
  Future<void> installSpec(ModelSpec spec, {bool force = false}) async {
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
    _text = '准备下载 ${spec.displayName}…';
    notifyListeners();
    try {
      if (spec.bundled) {
        await _installer.ensureBundled(spec);
      } else if (usesAppleAssets) {
        await _installFromAppleAssets(spec, force: force);
        _unavailableRemotePacks.remove(spec.id);
      } else {
        if (force) {
          await _installer.delete(spec);
        }
        final base = Uri.parse(effectiveBaseUrl);
        await _installer.installFrom(
          spec,
          baseUri: base,
          onProgress: _onProgress,
        );
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

  Future<void> installAll({bool force = false}) async {
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
      if (usesAppleAssets) {
        await _installFromAppleAssets(senseVoiceSpec, force: force);
        // 声纹模型为可选能力：若远端尚未上架该资源包则静默标记跳过；真实下载/校验故障如实提示
        try {
          await _installFromAppleAssets(campplusEmbeddingSpec, force: force);
          _unavailableRemotePacks.remove(campplusEmbeddingSpec.id);
        } on AppleAssetPackException catch (e) {
          if (e.isNotFound) {
            _unavailableRemotePacks.add(campplusEmbeddingSpec.id);
          } else {
            _error = '声纹模型下载失败：$e（转写仍可用）';
          }
        } on Object catch (e) {
          _error = '声纹模型下载失败：$e（转写仍可用）';
        }
      } else {
        final base = Uri.parse(effectiveBaseUrl);
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

  Future<void> _installFromAppleAssets(
    ModelSpec spec, {
    bool force = false,
  }) async {
    if (!force) {
      final current = await _installer.status(spec);
      if (current.installed) {
        return;
      }
    }
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
