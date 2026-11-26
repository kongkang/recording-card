/// 系统相册录音窗口对齐导入服务（iOS PhotoKit `com.reai.recordingcard/photos`）。
///
/// 只读取录音记录时间窗口 `[startMs, endMs]` 内拍摄的照片，导出压缩 JPEG 到应用沙盒
/// `Application Support/photos/`，返回可关联到 `RecordEvent` 的照片条目。
/// 测试或非 iOS 环境通道缺失时静默返回空结果，不抛异常。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class PhotoWindow {
  final String eventId;
  final int startMs;
  final int endMs;

  const PhotoWindow({
    required this.eventId,
    required this.startMs,
    required this.endMs,
  });

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'startMs': startMs,
    'endMs': endMs,
  };
}

class ImportedAlbumPhoto {
  final String id;
  final String eventId;
  final String path;
  final int capturedAtMs;
  final String source;

  const ImportedAlbumPhoto({
    required this.id,
    required this.eventId,
    required this.path,
    required this.capturedAtMs,
    this.source = 'system_album',
  });
}

class PhotoImportReport {
  final bool authorized;
  final List<ImportedAlbumPhoto> photos;

  const PhotoImportReport({
    required this.authorized,
    required this.photos,
  });
}

class MediaAlbumSaveResult {
  final bool saved;
  final bool authorized;
  final String? localIdentifier;
  final String? error;

  const MediaAlbumSaveResult({
    required this.saved,
    required this.authorized,
    this.localIdentifier,
    this.error,
  });
}

enum PhotoPermissionState { granted, denied, notDetermined }

class PhotoLibraryService {
  const PhotoLibraryService({
    MethodChannel channel = const MethodChannel('com.reai.recordingcard/photos'),
    Future<PhotoPermissionState> Function()? statusOverride,
    Future<PhotoPermissionState> Function()? requestOverride,
    Future<PhotoPermissionState> Function()? addStatusOverride,
    Future<PhotoPermissionState> Function()? requestAddOverride,
    Future<PhotoImportReport> Function(
      List<PhotoWindow> windows, {
      bool promptIfNeeded,
    })?
    importOverride,
    Future<MediaAlbumSaveResult> Function({
      required String path,
      required String mediaType,
      int? capturedAtMs,
      bool promptIfNeeded,
    })?
    saveMediaOverride,
    Future<Directory> Function()? directoryOverride,
  }) : _channel = channel,
       _statusOverride = statusOverride,
       _requestOverride = requestOverride,
       _addStatusOverride = addStatusOverride,
       _requestAddOverride = requestAddOverride,
       _importOverride = importOverride,
       _saveMediaOverride = saveMediaOverride,
       _directoryOverride = directoryOverride;

  final MethodChannel _channel;
  final Future<PhotoPermissionState> Function()? _statusOverride;
  final Future<PhotoPermissionState> Function()? _requestOverride;
  final Future<PhotoPermissionState> Function()? _addStatusOverride;
  final Future<PhotoPermissionState> Function()? _requestAddOverride;
  final Future<PhotoImportReport> Function(
    List<PhotoWindow> windows, {
    bool promptIfNeeded,
  })?
  _importOverride;
  final Future<MediaAlbumSaveResult> Function({
    required String path,
    required String mediaType,
    int? capturedAtMs,
    bool promptIfNeeded,
  })?
  _saveMediaOverride;
  final Future<Directory> Function()? _directoryOverride;

  static PhotoPermissionState _parsePermission(String? raw) => switch (raw) {
    'granted' => PhotoPermissionState.granted,
    'notDetermined' => PhotoPermissionState.notDetermined,
    _ => PhotoPermissionState.denied,
  };

  Future<PhotoPermissionState> checkPermission() async {
    if (_statusOverride != null) return _statusOverride();
    try {
      final raw = await _channel.invokeMethod<String>('status');
      return _parsePermission(raw);
    } on MissingPluginException {
      return PhotoPermissionState.denied;
    } on PlatformException {
      return PhotoPermissionState.denied;
    }
  }

  Future<PhotoPermissionState> requestPermission() async {
    if (_requestOverride != null) return _requestOverride();
    try {
      final raw = await _channel.invokeMethod<String>('request');
      return _parsePermission(raw);
    } on MissingPluginException {
      return PhotoPermissionState.denied;
    } on PlatformException {
      return PhotoPermissionState.denied;
    }
  }

  Future<PhotoPermissionState> checkAddPermission() async {
    if (_addStatusOverride != null) return _addStatusOverride();
    try {
      final raw = await _channel.invokeMethod<String>('addStatus');
      return _parsePermission(raw);
    } on MissingPluginException {
      return PhotoPermissionState.denied;
    } on PlatformException {
      return PhotoPermissionState.denied;
    }
  }

  Future<PhotoPermissionState> requestAddPermission() async {
    if (_requestAddOverride != null) return _requestAddOverride();
    try {
      final raw = await _channel.invokeMethod<String>('requestAdd');
      return _parsePermission(raw);
    } on MissingPluginException {
      return PhotoPermissionState.denied;
    } on PlatformException {
      return PhotoPermissionState.denied;
    }
  }

  Future<MediaAlbumSaveResult> saveMediaToAlbum({
    required String path,
    String mediaType = 'photo',
    int? capturedAtMs,
    bool promptIfNeeded = true,
  }) async {
    if (_saveMediaOverride != null) {
      return _saveMediaOverride(
        path: path,
        mediaType: mediaType,
        capturedAtMs: capturedAtMs,
        promptIfNeeded: promptIfNeeded,
      );
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'saveMediaToAlbum',
        {
          'path': path,
          'mediaType': mediaType,
          'capturedAtMs': ?capturedAtMs,
          'promptIfNeeded': promptIfNeeded,
        },
      );
      if (raw == null) {
        return const MediaAlbumSaveResult(
          saved: false,
          authorized: false,
          error: '系统相册通道无响应',
        );
      }
      final localId = '${raw['localIdentifier'] ?? ''}'.trim();
      return MediaAlbumSaveResult(
        saved: raw['saved'] == true,
        authorized: raw['authorized'] == true,
        localIdentifier: localId.isEmpty ? null : localId,
        error: raw['error'] as String?,
      );
    } on MissingPluginException {
      return const MediaAlbumSaveResult(
        saved: false,
        authorized: false,
        error: '当前平台不支持写入系统相册',
      );
    } on PlatformException catch (e) {
      return MediaAlbumSaveResult(
        saved: false,
        authorized: false,
        error: e.message ?? '写入系统相册失败',
      );
    }
  }

  Future<Directory> photosDirectory() async {
    if (_directoryOverride != null) {
      final dir = await _directoryOverride();
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/photos');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 清空已导入/缓存到本地沙盒的照片副本（不碰系统相册原图）。
  Future<void> clearLocalCache() async {
    try {
      final dir = _directoryOverride != null
          ? await _directoryOverride()
          : Directory('${(await getApplicationSupportDirectory()).path}/photos');
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          try {
            await entity.delete(recursive: true);
          } on FileSystemException {
            // 忽略单文件占用
          }
        }
      }
    } on Object {
      // 无平台通道时忽略
    }
  }

  Future<PhotoImportReport> importInWindows(
    List<PhotoWindow> windows, {
    String? outputDirOverride,
    bool promptIfNeeded = false,
  }) async {
    if (windows.isEmpty) {
      return const PhotoImportReport(authorized: true, photos: []);
    }
    if (_importOverride != null) {
      return _importOverride(windows, promptIfNeeded: promptIfNeeded);
    }
    try {
      if (!promptIfNeeded) {
        final perm = await checkPermission();
        if (perm != PhotoPermissionState.granted) {
          return const PhotoImportReport(authorized: false, photos: []);
        }
      }
      final outDir = outputDirOverride ?? (await photosDirectory()).path;
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'importInWindows',
        {
          'windows': [for (final w in windows) w.toJson()],
          'outputDir': outDir,
          'promptIfNeeded': promptIfNeeded,
        },
      );
      if (raw == null) {
        return const PhotoImportReport(authorized: false, photos: []);
      }
      final authorized = raw['authorized'] == true;
      final list = raw['photos'] as List<Object?>? ?? const [];
      final items = <ImportedAlbumPhoto>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        final eventId = '${item['eventId'] ?? ''}';
        final path = '${item['path'] ?? ''}';
        final ms = (item['capturedAtMs'] as num?)?.toInt();
        if (id.isEmpty || eventId.isEmpty || ms == null) continue;
        items.add(
          ImportedAlbumPhoto(
            id: id,
            eventId: eventId,
            path: path,
            capturedAtMs: ms,
            source: '${item['source'] ?? 'system_album'}',
          ),
        );
      }
      return PhotoImportReport(authorized: authorized, photos: items);
    } on MissingPluginException {
      return const PhotoImportReport(authorized: false, photos: []);
    } on PlatformException {
      return const PhotoImportReport(authorized: false, photos: []);
    }
  }
}
