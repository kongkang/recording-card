/// iOS Apple-Hosted Background Assets 客户端（MethodChannel + EventChannel）。
///
/// 在 iOS 26+ 且宿主配置了 `BAHasManagedAssetPacks` / `BAUsesAppleHosting` 时，
/// 通过系统 `AssetPackManager` 从 Apple CDN 下载模型资源包并原子复制到应用支持目录；
/// 其它平台（Android / macOS / 测试环境 / iOS < 26）返回 `isAvailable = false`，
/// 由上层走 `RC_MODEL_BASE` HTTP 下载源。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppleAssetPackFile {
  const AppleAssetPackFile({required this.assetPath, required this.destPath});

  /// 资源包内的相对路径，例如 `sensevoice-small-int8/model.int8.onnx`。
  final String assetPath;

  /// 目标本地绝对路径，例如 `<ApplicationSupport>/models/...`。
  final String destPath;

  Map<String, String> toMap() => {
    'assetPath': assetPath,
    'destPath': destPath,
  };
}

class AppleAssetPackException implements Exception {
  const AppleAssetPackException(this.message, {this.code = 'APPLE_ASSET_FAILED'});
  final String message;
  final String code;

  bool get isNotFound => code == 'ASSET_PACK_NOT_FOUND';

  @override
  String toString() => message;
}

class AppleAssetPackClient {
  AppleAssetPackClient({
    MethodChannel? methodChannel,
    EventChannel? progressChannel,
    bool? isIOSOverride,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel('com.reai.recordingcard/apple_assets'),
       _progressChannel =
           progressChannel ??
           const EventChannel('com.reai.recordingcard/apple_assets_progress'),
       _isIOSOverride = isIOSOverride;

  final MethodChannel _methodChannel;
  final EventChannel _progressChannel;
  final bool? _isIOSOverride;

  bool get _isIOS => _isIOSOverride ?? (!kIsWeb && Platform.isIOS);

  Future<bool> isAvailable() async {
    if (!_isIOS) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('isAvailable');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 查询当前 Apple 托管清单中已发布的资源包 ID 列表；查询失败返回 null（由实际下载兜底判断）。
  Future<Set<String>?> availablePackIds() async {
    if (!_isIOS) return null;
    try {
      final result = await _methodChannel.invokeListMethod<String>('availablePackIds');
      return result?.toSet();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> installAssetPack({
    required String packId,
    required String displayName,
    required List<AppleAssetPackFile> files,
    void Function(double progress, String text)? onProgress,
  }) async {
    if (!_isIOS) {
      throw const AppleAssetPackException(
        '当前平台不支持 Apple-Hosted Background Assets',
        code: 'UNSUPPORTED_OS',
      );
    }

    onProgress?.call(0, '正在准备下载 $displayName…');
    StreamSubscription<Object?>? sub;
    if (onProgress != null) {
      sub = _progressChannel.receiveBroadcastStream().listen((event) {
        if (event is! Map) return;
        if (event['packId'] != packId) return;
        final stage = event['stage'] as String? ?? '';
        final rawProgress = (event['progress'] as num?)?.toDouble() ?? 0.0;
        final progress = rawProgress.clamp(0.0, 1.0);
        switch (stage) {
          case 'began':
            onProgress(progress, '正在连接 Apple 资源服务…');
          case 'paused':
            onProgress(progress, '等待网络或系统调度…');
          case 'downloading':
            final pct = (progress * 100).round();
            onProgress(progress, '正在下载 $displayName（$pct%）…');
          case 'copying':
            onProgress(0.98, '正在校验并安装 $displayName…');
          case 'finished':
            onProgress(1.0, '$displayName已就绪');
        }
      }, onError: (_) {});
    }

    try {
      await _methodChannel.invokeMethod<bool>('installAssetPack', {
        'packId': packId,
        'files': files.map((f) => f.toMap()).toList(growable: false),
      });
      onProgress?.call(1.0, '$displayName已就绪');
    } on PlatformException catch (e) {
      throw AppleAssetPackException(
        e.message ?? 'Apple 资源包下载失败（${e.code}）',
        code: e.code,
      );
    } on MissingPluginException {
      throw const AppleAssetPackException(
        '原生 Apple 资源桥未注册',
        code: 'MISSING_PLUGIN',
      );
    } finally {
      await sub?.cancel();
    }
  }

  Future<void> removeAssetPack(String packId) async {
    if (!_isIOS) return;
    try {
      await _methodChannel.invokeMethod<void>('removeAssetPack', {
        'packId': packId,
      });
    } on MissingPluginException {
      // 忽略：非原生环境
    } on PlatformException {
      // 清理托管缓存失败不阻塞主流程
    }
  }
}
