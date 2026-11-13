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

enum PhotoPermissionState { granted, denied, notDetermined }

class PhotoLibraryService {
  const PhotoLibraryService({
    MethodChannel channel = const MethodChannel('com.reai.recordingcard/photos'),
    Future<PhotoPermissionState> Function()? statusOverride,
    Future<PhotoPermissionState> Function()? requestOverride,
  }) : _channel = channel,
       _statusOverride = statusOverride,
       _requestOverride = requestOverride;

  final MethodChannel _channel;
  final Future<PhotoPermissionState> Function()? _statusOverride;
  final Future<PhotoPermissionState> Function()? _requestOverride;

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

  Future<Directory> photosDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/photos');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<PhotoImportReport> importInWindows(
    List<PhotoWindow> windows, {
    String? outputDirOverride,
  }) async {
    if (windows.isEmpty) {
      return const PhotoImportReport(authorized: true, photos: []);
    }
    try {
      final outDir = outputDirOverride ?? (await photosDirectory()).path;
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'importInWindows',
        {
          'windows': [for (final w in windows) w.toJson()],
          'outputDir': outDir,
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
