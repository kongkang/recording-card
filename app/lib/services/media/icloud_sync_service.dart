/// iCloud 云盘同步服务（iOS `com.reai.recordingcard/icloud_sync`）。
///
/// 仅在用户手动开启 iCloud 同步后按所选范围将音频、转录文本（Markdown）、
/// 硬件照片与视频同步至 `iCloud 云盘 → 录音卡`。
/// 非 iOS 或测试环境通道缺失时安全降级返回不可用状态，不抛异常。
library;

import 'package:flutter/services.dart';

class ICloudStatus {
  const ICloudStatus({
    required this.available,
    required this.signedIn,
    this.containerPath = '',
    this.error,
  });

  final bool available;
  final bool signedIn;
  final String containerPath;
  final String? error;
}

class ICloudSyncResult {
  const ICloudSyncResult({
    required this.ok,
    required this.available,
    this.skipped = false,
    this.path = '',
    this.error,
  });

  final bool ok;
  final bool available;
  final bool skipped;
  final String path;
  final String? error;
}

class ICloudStats {
  const ICloudStats({
    required this.available,
    required this.signedIn,
    this.audio = 0,
    this.transcripts = 0,
    this.photos = 0,
    this.videos = 0,
    this.total = 0,
  });

  final bool available;
  final bool signedIn;
  final int audio;
  final int transcripts;
  final int photos;
  final int videos;
  final int total;
}

class ICloudSyncService {
  const ICloudSyncService({
    MethodChannel channel = const MethodChannel('com.reai.recordingcard/icloud_sync'),
    Future<ICloudStatus> Function()? statusOverride,
    Future<ICloudSyncResult> Function(String sourcePath, String relativePath)?
        syncFileOverride,
    Future<ICloudSyncResult> Function(String content, String relativePath)?
        syncTextOverride,
    Future<ICloudStats> Function()? statsOverride,
  }) : _channel = channel,
       _statusOverride = statusOverride,
       _syncFileOverride = syncFileOverride,
       _syncTextOverride = syncTextOverride,
       _statsOverride = statsOverride;

  final MethodChannel _channel;
  final Future<ICloudStatus> Function()? _statusOverride;
  final Future<ICloudSyncResult> Function(String sourcePath, String relativePath)?
      _syncFileOverride;
  final Future<ICloudSyncResult> Function(String content, String relativePath)?
      _syncTextOverride;
  final Future<ICloudStats> Function()? _statsOverride;

  Future<ICloudStatus> checkStatus() async {
    if (_statusOverride != null) return _statusOverride();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      if (raw == null) {
        return const ICloudStatus(
          available: false,
          signedIn: false,
          error: '当前设备不支持 iCloud 云盘同步',
        );
      }
      return ICloudStatus(
        available: raw['available'] == true,
        signedIn: raw['signedIn'] == true,
        containerPath: '${raw['containerPath'] ?? ''}',
        error: raw['error'] as String?,
      );
    } on MissingPluginException {
      return const ICloudStatus(
        available: false,
        signedIn: false,
        error: '当前平台暂不支持 iCloud 云盘同步',
      );
    } on PlatformException catch (e) {
      return ICloudStatus(
        available: false,
        signedIn: false,
        error: e.message ?? '检查 iCloud 状态失败',
      );
    }
  }

  Future<ICloudSyncResult> syncFile({
    required String sourcePath,
    required String relativePath,
  }) async {
    if (_syncFileOverride != null) {
      return _syncFileOverride(sourcePath, relativePath);
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'syncFile',
        {'sourcePath': sourcePath, 'relativePath': relativePath},
      );
      if (raw == null) {
        return const ICloudSyncResult(
          ok: false,
          available: false,
          error: 'iCloud 同步无响应',
        );
      }
      return ICloudSyncResult(
        ok: raw['ok'] == true,
        available: raw['available'] != false,
        skipped: raw['skipped'] == true,
        path: '${raw['path'] ?? ''}',
        error: raw['error'] as String?,
      );
    } on MissingPluginException {
      return const ICloudSyncResult(
        ok: false,
        available: false,
        error: '当前平台暂不支持 iCloud 云盘同步',
      );
    } on PlatformException catch (e) {
      return ICloudSyncResult(
        ok: false,
        available: false,
        error: e.message ?? '写入 iCloud 失败',
      );
    }
  }

  Future<ICloudSyncResult> syncText({
    required String content,
    required String relativePath,
  }) async {
    if (_syncTextOverride != null) {
      return _syncTextOverride(content, relativePath);
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'syncText',
        {'content': content, 'relativePath': relativePath},
      );
      if (raw == null) {
        return const ICloudSyncResult(
          ok: false,
          available: false,
          error: 'iCloud 同步无响应',
        );
      }
      return ICloudSyncResult(
        ok: raw['ok'] == true,
        available: raw['available'] != false,
        skipped: raw['skipped'] == true,
        path: '${raw['path'] ?? ''}',
        error: raw['error'] as String?,
      );
    } on MissingPluginException {
      return const ICloudSyncResult(
        ok: false,
        available: false,
        error: '当前平台暂不支持 iCloud 云盘同步',
      );
    } on PlatformException catch (e) {
      return ICloudSyncResult(
        ok: false,
        available: false,
        error: e.message ?? '写入 iCloud 文本失败',
      );
    }
  }

  Future<ICloudStats> listStats() async {
    if (_statsOverride != null) return _statsOverride();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('listStats');
      if (raw == null) {
        return const ICloudStats(available: false, signedIn: false);
      }
      return ICloudStats(
        available: raw['available'] == true,
        signedIn: raw['signedIn'] == true,
        audio: (raw['audio'] as num?)?.toInt() ?? 0,
        transcripts: (raw['transcripts'] as num?)?.toInt() ?? 0,
        photos: (raw['photos'] as num?)?.toInt() ?? 0,
        videos: (raw['videos'] as num?)?.toInt() ?? 0,
        total: (raw['total'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return const ICloudStats(available: false, signedIn: false);
    }
  }
}
