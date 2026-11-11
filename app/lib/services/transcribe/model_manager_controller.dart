/// 本地模型管理 —— Setting 页展示安装状态、下载/删除；下载地址走
/// `--dart-define=RC_MODEL_BASE`（生产由 manifest/CDN 提供）。
library;

import 'package:flutter/foundation.dart';

import 'asr_models.dart';

class ModelManagerController extends ChangeNotifier {
  ModelManagerController({
    ModelInstaller? installer,
    String? baseUrl,
    this.onInstalled,
  }) : _installer = installer ?? ModelInstaller(),
       _baseUrl = baseUrl ?? const String.fromEnvironment('RC_MODEL_BASE');

  final ModelInstaller _installer;
  final String _baseUrl;

  /// 安装完成后的回调（通常是 `AppStore.processPendingRecordings`）。
  final Future<void> Function()? onInstalled;

  final Map<String, ModelStatus> _statuses = {};
  bool _busy = false;
  double _progress = 0;
  String _text = '';
  String? _error;

  bool get busy => _busy;
  double get progress => _progress;
  String get text => _text;
  String? get error => _error;
  bool get configured => _baseUrl.trim().isNotEmpty;
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

  Future<void> refresh() async {
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
      await onInstalled?.call();
    } on Object catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      _text = '';
      await refresh();
    }
  }

  Future<void> delete(ModelSpec spec) async {
    if (_busy) return;
    try {
      await _installer.delete(spec);
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
