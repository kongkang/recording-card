/// 本地模型管理 —— Setting 页及声纹子页展示安装状态、单模型/全量下载与删除。
///
/// 下载源优先级：
/// 1. 显式传入 `baseUrl` 或 `--dart-define=RC_MODEL_BASE=...` 时走指定 HTTP 源；
/// 2. iOS 26+ 支持 Apple-Hosted Background Assets（TestFlight / App Store）时优先尝试免费 Apple CDN，
///    若远端资源包未上架或拉取失败，运行时自动回落外脑 CDN `https://dl.wainao.chat/reai/models`；
/// 3. 其余平台（Android / iOS 15~25 / 本地开发签名包）默认走外脑 CDN `https://dl.wainao.chat/reai/models`。
library;

import 'package:flutter/foundation.dart';

import '../../core/config/remote/client_config.dart';
import '../../core/store/agent_config_store.dart';
import 'apple_asset_pack_client.dart';
import 'asr_models.dart';
import 'system_speech_client.dart';

class ModelManagerController extends ChangeNotifier {
  ModelManagerController({
    ModelInstaller? installer,
    AppleAssetPackClient? appleAssets,
    SystemSpeechClient? systemSpeech,
    AgentConfigStore? agentConfig,
    String? baseUrl,
    ClientConfig? clientConfig,
    this.onInstalled,
  }) : _installer = installer ?? ModelInstaller(),
       _appleAssets = appleAssets ?? AppleAssetPackClient(),
       _systemSpeech = systemSpeech ?? SystemSpeechClient(),
       _agentConfig = agentConfig,
       _explicitBaseUrl = baseUrl != null
           ? baseUrl.trim()
           : ((clientConfig ?? ClientConfig.instance).explicitModelBase ?? ''),
       _fallbackBaseUrl = baseUrl != null
           ? ''
           : (clientConfig ?? ClientConfig.instance).fallbackModelBase {
    _agentConfig?.addListener(_onAgentConfigChanged);
  }

  final ModelInstaller _installer;
  final AppleAssetPackClient _appleAssets;
  final SystemSpeechClient _systemSpeech;
  final AgentConfigStore? _agentConfig;
  final String _explicitBaseUrl;
  final String _fallbackBaseUrl;

  ModelInstaller get installer => _installer;

  /// 安装完成后的回调（通常是 `AppStore.processPendingRecordings`）。
  final Future<void> Function()? onInstalled;

  final Map<String, ModelStatus> _statuses = {};
  final Set<String> _unavailableRemotePacks = {};
  SystemSpeechCapabilities _sysCaps = SystemSpeechCapabilities.unsupported;
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
  SystemSpeechCapabilities get systemCapabilities => _sysCaps;
  bool get supportsSystemAsr => _sysCaps.supportsModernSystemAsr;

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

  /// SenseVoice 增强转写（SenseVoice + VAD）文件是否已落盘就绪。
  bool get asrReady =>
      _statuses[senseVoiceSpec.id]?.installed == true &&
      _statuses[sileroVadSpec.id]?.installed == true;

  bool get speakerReady =>
      _statuses[campplusEmbeddingSpec.id]?.installed == true;

  bool get allReady =>
      specs.every((s) => _statuses[s.id]?.installed == true);

  /// 当前选中的语音转写引擎策略。
  LocalAsrEngineMode get selectedEngine {
    final pref = _agentConfig?.preferredAsrEngine;
    if (pref == 'sensevoice') return LocalAsrEngineMode.sensevoice;
    if (supportsSystemAsr) return LocalAsrEngineMode.system;
    return LocalAsrEngineMode.sensevoice;
  }

  /// 当前实际生效的转写状态：`'system'` | `'sensevoice'` | `'pending'`。
  String get effectiveAsrMode {
    if (supportsSystemAsr && selectedEngine == LocalAsrEngineMode.system) {
      return 'system';
    }
    if (asrReady) return 'sensevoice';
    return 'pending';
  }

  String get settingSummaryLabel => switch (effectiveAsrMode) {
    'system' => speakerReady ? '系统内置 · 即用' : '系统内置 · 缺声纹',
    'sensevoice' => speakerReady ? 'SenseVoice · 已就绪' : 'SenseVoice · 缺声纹',
    _ => '推荐下载增强模型',
  };

  /// 是否有明确的新版本可更新（版本与本地一致或离线未比对时不提示更新，避免打扰）。
  bool get hasRemoteUpdates => false;

  void _onAgentConfigChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _agentConfig?.removeListener(_onAgentConfigChanged);
    super.dispose();
  }

  /// 切换转写引擎；若切到 SenseVoice 且本地未下载，立即按需下载并在成功后启用。
  Future<void> selectAsrEngine(LocalAsrEngineMode mode) async {
    if (mode == LocalAsrEngineMode.system) {
      if (!supportsSystemAsr) return;
      await _agentConfig?.setPreferredAsrEngine('system');
      notifyListeners();
      await onInstalled?.call();
      return;
    }

    if (_statuses[senseVoiceSpec.id]?.installed == true) {
      if (_statuses[sileroVadSpec.id]?.installed != true) {
        await _installer.ensureBundled(sileroVadSpec);
        await refresh();
      }
      await _agentConfig?.setPreferredAsrEngine('sensevoice');
      notifyListeners();
      await onInstalled?.call();
      return;
    }

    if (configured && !_busy) {
      await installSpec(senseVoiceSpec);
    }
  }

  /// 在支持系统端侧引擎但离线语音包未预装时（如 Android 13+），拉起系统语言包下载。
  Future<bool> requestSystemLanguagePack({String language = 'zh'}) async {
    final ok = await _systemSpeech.triggerSystemModelDownload(
      language: language,
    );
    await refresh();
    return ok;
  }

  /// 启动自动就绪：
  /// - 仅确保随包 VAD（644 KB）与小型声纹模型 CAM++（~27 MB）就绪；
  /// - 绝不自动下载 ~228 MB 的 SenseVoice 语音包（iOS 26+ 默认使用系统内置免下载即用，
  ///   旧系统与 Android 引导用户按需手动下载）。
  Future<void> autoEnsureInstalled() async {
    if (!hasStatuses) {
      await refresh();
    }
    if (_statuses[sileroVadSpec.id]?.installed != true) {
      try {
        await _installer.ensureBundled(sileroVadSpec);
        _statuses[sileroVadSpec.id] = await _installer.status(sileroVadSpec);
        notifyListeners();
      } on Object {
        // 随包资源在纯 Dart 单元测试环境中可能不存在，交由调用方显式装配
      }
    }
    final spkInstalled = _statuses[campplusEmbeddingSpec.id]?.installed == true;
    if (!configured ||
        _busy ||
        spkInstalled ||
        _unavailableRemotePacks.contains(campplusEmbeddingSpec.id)) {
      return;
    }

    _busy = true;
    _error = null;
    _progress = 0;
    _text = '正在准备声纹模型…';
    notifyListeners();
    try {
      await _installRemoteSpec(campplusEmbeddingSpec, force: false);
      await onInstalled?.call();
    } on AppleAssetPackException catch (e) {
      if (e.isNotFound) {
        _unavailableRemotePacks.add(campplusEmbeddingSpec.id);
      } else {
        _error = '声纹模型下载失败：$e（转写仍可用）';
      }
    } on Object catch (e) {
      _error = '声纹模型下载失败：$e（转写仍可用）';
    } finally {
      _busy = false;
      _text = '';
      await refresh();
    }
  }

  Future<void> _ensureAppleAssetsChecked() async {
    if (_appleAssetsChecked) return;
    _appleAssetsChecked = true;
    _appleAssetsAvailable = await _appleAssets.isAvailable();
  }

  Future<void> refresh() async {
    await _ensureAppleAssetsChecked();
    try {
      _sysCaps = await _systemSpeech.capabilities();
    } on Object {
      _sysCaps = SystemSpeechCapabilities.unsupported;
    }
    for (final spec in specs) {
      try {
        _statuses[spec.id] = await _installer.status(spec);
      } on Object {
        // 单个状态读取失败不影响其它模型展示
      }
    }
    notifyListeners();
  }

  /// 单独下载/重试指定模型（如按需下载 `senseVoiceSpec` 或「声纹识别」子页下载 `campplusEmbeddingSpec`）。
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
      } else {
        if (spec.kind == LocalModelKind.asr &&
            _statuses[sileroVadSpec.id]?.installed != true) {
          await _installer.ensureBundled(sileroVadSpec);
        }
        await _installRemoteSpec(spec, force: force);
        if (spec.id == senseVoiceSpec.id) {
          await _agentConfig?.setPreferredAsrEngine('sensevoice');
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

  Future<void> installAll({bool force = false}) async {
    if (_busy) return;
    await _ensureAppleAssetsChecked();
    if (!configured) {
      _error = '未配置模型下载地址（RC_MODEL_BASE）';
      notifyListeners();
      return;
    }
    final wasAsrMissing = _statuses[senseVoiceSpec.id]?.installed != true;
    _busy = true;
    _error = null;
    _progress = 0;
    _text = '准备下载…';
    notifyListeners();
    try {
      await _installer.ensureBundled(sileroVadSpec);
      await _installRemoteSpec(senseVoiceSpec, force: force);
      if (wasAsrMissing || !supportsSystemAsr) {
        await _agentConfig?.setPreferredAsrEngine('sensevoice');
      }
      // 声纹模型为可选能力：若无兜底 HTTP 源且 Apple 远端尚未上架该资源包则静默标记跳过；真实下载/校验故障如实提示
      try {
        await _installRemoteSpec(campplusEmbeddingSpec, force: force);
      } on AppleAssetPackException catch (e) {
        if (e.isNotFound) {
          _unavailableRemotePacks.add(campplusEmbeddingSpec.id);
        } else {
          _error = '声纹模型下载失败：$e（转写仍可用）';
        }
      } on Object catch (e) {
        _error = '声纹模型下载失败：$e（转写仍可用）';
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

  /// 远程模型下载统一入口：
  /// - `usesAppleAssets` 为 true 时优先走 Apple-Hosted Background Assets；
  /// - 若 Apple 资源包尚未发布、清单不可用或校验失败，且存在 HTTP 兜底源（`_fallbackBaseUrl`），
  ///   自动无缝回落外脑 CDN 下载，避免 iOS 26+ 设备卡在「待下载」。
  Future<void> _installRemoteSpec(
    ModelSpec spec, {
    required bool force,
  }) async {
    if (usesAppleAssets) {
      try {
        await _installFromAppleAssets(spec, force: force);
        _unavailableRemotePacks.remove(spec.id);
        return;
      } on Object catch (appleErr) {
        if (!hasFallbackBaseUrl) {
          rethrow;
        }
        debugPrint(
          '[ModelManager] Apple 资源包 ${spec.id} 不可用 ($appleErr)，自动回落外脑 CDN ($_fallbackBaseUrl)',
        );
      }
    }
    if (force) {
      await _installer.delete(spec);
    }
    final base = Uri.parse(effectiveBaseUrl);
    await _installer.installFrom(
      spec,
      baseUri: base,
      onProgress: _onProgress,
    );
    _unavailableRemotePacks.remove(spec.id);
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
      if (spec.id == senseVoiceSpec.id && supportsSystemAsr) {
        await _agentConfig?.setPreferredAsrEngine('system');
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
