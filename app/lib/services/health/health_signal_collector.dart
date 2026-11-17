/// 健康与位置采集的平台接口。
///
/// iOS 走 HealthKit + Core Location。Android 只保留这个接口，Health Connect
/// 的真正采集不在本版范围内。查询已落盘样本不经过这里。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'health_signal_bucket.dart';

class HealthPlatformInfo {
  const HealthPlatformInfo({
    required this.platform,
    required this.available,
    this.clinicalRecords = false,
    this.clinicalReason,
    this.detail,
  });

  final String platform;
  final bool available;
  final bool clinicalRecords;
  final String? clinicalReason;
  final String? detail;
}

class HealthAccessResult {
  const HealthAccessResult({
    required this.available,
    required this.requestedTypeCount,
    this.location = 'unsupported',
    this.clinicalSkipped = true,
    this.message,
  });

  final bool available;
  final int requestedTypeCount;

  /// `always` / `whenInUse` / `denied` / `restricted` / `notDetermined` / `unsupported`。
  final String location;
  final bool clinicalSkipped;
  final String? message;
}

abstract class HealthSignalCollector {
  Future<HealthPlatformInfo> info();

  Future<HealthAccessResult> requestAccess();

  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  });

  /// 向平台要一段增量。样本写入平台暂存，再用 [drainSpool] 取回。
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  });

  Future<List<HealthSignalDraft>> drainSpool();

  Stream<void> get updates;
}

HealthSignalCollector createPlatformHealthCollector() {
  if (kIsWeb) return const UnsupportedHealthSignalCollector('web');
  if (Platform.isIOS) return IosHealthSignalCollector();
  if (Platform.isAndroid) return const AndroidHealthSignalCollector();
  return UnsupportedHealthSignalCollector(Platform.operatingSystem);
}

class UnsupportedHealthSignalCollector implements HealthSignalCollector {
  const UnsupportedHealthSignalCollector(this.platform);

  final String platform;

  @override
  Future<HealthPlatformInfo> info() async => HealthPlatformInfo(
    platform: platform,
    available: false,
    clinicalRecords: false,
    clinicalReason: '当前平台没有健康采集实现',
    detail: '当前平台不能采集健康与位置数据',
  );

  @override
  Future<HealthAccessResult> requestAccess() async => const HealthAccessResult(
    available: false,
    requestedTypeCount: 0,
    message: '当前平台不能采集健康与位置数据',
  );

  @override
  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<List<HealthSignalDraft>> drainSpool() async => const [];

  @override
  Stream<void> get updates => const Stream<void>.empty();
}

/// Android Health Connect 留到后续版本。本类只让调用方能区分平台。
class AndroidHealthSignalCollector implements HealthSignalCollector {
  const AndroidHealthSignalCollector();

  static const _detail = '本版尚未接入 Android Health Connect，不会在 Android 上采集健康或位置数据';

  @override
  Future<HealthPlatformInfo> info() async => const HealthPlatformInfo(
    platform: 'android',
    available: false,
    clinicalRecords: false,
    clinicalReason: 'Health Connect 采集未实现',
    detail: _detail,
  );

  @override
  Future<HealthAccessResult> requestAccess() async => const HealthAccessResult(
    available: false,
    requestedTypeCount: 0,
    message: _detail,
  );

  @override
  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<List<HealthSignalDraft>> drainSpool() async => const [];

  @override
  Stream<void> get updates => const Stream<void>.empty();
}

class IosHealthSignalCollector implements HealthSignalCollector {
  IosHealthSignalCollector({
    MethodChannel channel = const MethodChannel(
      'com.reai.recordingcard/health_signal',
    ),
  }) : _channel = channel {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSpoolReady') {
        if (!_updates.isClosed) _updates.add(null);
      }
      return null;
    });
  }

  final MethodChannel _channel;
  final StreamController<void> _updates = StreamController<void>.broadcast();

  @override
  Stream<void> get updates => _updates.stream;

  @override
  Future<HealthPlatformInfo> info() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('info');
      return HealthPlatformInfo(
        platform: 'ios',
        available: raw?['available'] == true,
        clinicalRecords: raw?['clinicalRecords'] == true,
        clinicalReason: raw?['clinicalReason'] as String?,
        detail: raw?['detail'] as String?,
      );
    } on MissingPluginException {
      return const HealthPlatformInfo(
        platform: 'ios',
        available: false,
        clinicalRecords: false,
        clinicalReason: '签名未包含临床病历权限',
        detail: '健康采集通道不可用',
      );
    } on PlatformException catch (error) {
      return HealthPlatformInfo(
        platform: 'ios',
        available: false,
        clinicalRecords: false,
        clinicalReason: '签名未包含临床病历权限',
        detail: error.message ?? '无法读取健康数据',
      );
    }
  }

  @override
  Future<HealthAccessResult> requestAccess() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'requestAccess',
      );
      final requested = raw?['requested'];
      return HealthAccessResult(
        available: raw?['available'] != false,
        requestedTypeCount: requested is num ? requested.toInt() : 0,
        location: '${raw?['location'] ?? 'notDetermined'}',
        clinicalSkipped: raw?['clinicalSkipped'] != false,
        message: raw?['error'] as String?,
      );
    } on MissingPluginException {
      return const HealthAccessResult(
        available: false,
        requestedTypeCount: 0,
        message: '健康采集通道不可用',
      );
    } on PlatformException catch (error) {
      return HealthAccessResult(
        available: false,
        requestedTypeCount: 0,
        message: error.message ?? '系统没有完成健康授权',
      );
    }
  }

  @override
  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  }) async {
    try {
      await _channel.invokeMethod<void>('setCollectionActive', {
        'active': active,
        'intervalMs': intervalMs,
        'phaseMs': phaseMs,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      rethrow;
    }
  }

  @override
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  }) async {
    try {
      await _channel.invokeMethod<void>('catchUp', {
        'defaultSinceMs': defaultSinceMs,
        'untilMs': untilMs,
        'sinceByType': sinceByType,
        'intervalMs': intervalMs,
        'phaseMs': phaseMs,
        'quick': false,
      });
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<List<HealthSignalDraft>> drainSpool() async {
    final out = <HealthSignalDraft>[];
    try {
      while (true) {
        final raw = await _channel.invokeMethod<Object?>('drainSpool');
        if (raw is! List || raw.isEmpty) break;
        for (final item in raw) {
          if (item is Map) {
            out.add(
              HealthSignalDraft.fromJson(Map<String, Object?>.from(item)),
            );
          }
        }
        if (raw.length < 200) break;
        if (out.length > 200000) break;
      }
    } on MissingPluginException {
      return out;
    }
    return out;
  }
}
