import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/device/card_gateway.dart';
import '../recordings/recording_download_gateway.dart';

/// One temporary, local-only AP lane shared by preparation and file transfer.
/// Native owns the join final event: never apply a Dart timeout to that future.
class AccessoryHotspotSession {
  AccessoryHotspotSession(
    this.gateway, {
    Future<void> Function()? join,
    Future<void> Function()? closePhoneConfiguration,
    Future<bool> Function(Uri, Duration)? probe,
    bool Function()? isIos,
    this.beforeWifiOpen,
    this.readyTimeout = const Duration(seconds: 30),
    this.probeTimeout = const Duration(seconds: 3),
    this.probeInterval = const Duration(milliseconds: 500),
  }) : _join = join ?? _joinNative,
       _closePhone = closePhoneConfiguration ?? _closeNative,
       _isIos = isIos ?? (() => Platform.isIOS) {
    _probe =
        probe ??
        (uri, timeout) => probeFileService(
          uri,
          timeout,
          onFailure: (message) => _lastProbeFailure = message,
        );
  }

  static const channel = MethodChannel('dev.kongkang.recording-card/hotspot');
  static final filesUri = Uri.parse('http://192.168.4.1/api/files');
  final CardGateway gateway;
  final Future<void> Function() _join;
  final Future<void> Function() _closePhone;
  late final Future<bool> Function(Uri, Duration) _probe;
  String? _lastProbeFailure;
  final bool Function() _isIos;
  final Future<void> Function()? beforeWifiOpen;
  final Duration readyTimeout;
  final Duration probeTimeout;
  final Duration probeInterval;
  bool _active = false;
  bool _ready = false;
  bool _cancelled = false;
  bool _cardTouched = false;
  bool _phoneTouched = false;
  String? _deviceId;
  Future<void>? _preparing;
  Future<void>? _closing;

  /// Remains true until BOTH cleanup operations have been confirmed.
  bool get active => _active;
  bool get ready => _ready && !_cancelled && _closing == null;
  bool get preparing => _preparing != null;

  static Future<void> _joinNative() async {
    final result = await channel.invokeMapMethod<String, dynamic>('join');
    if (result?['accepted'] != true) {
      throw PlatformException(code: 'hotspot_protocol', message: '系统未确认热点加入请求');
    }
  }

  static Future<void> _closeNative() => channel.invokeMethod<void>('close');

  Future<void> prepare(String deviceId) async {
    if (_active || _closing != null || _preparing != null) {
      throw StateError('快传会话尚未清理，不能重复加入');
    }
    if (!_isIos()) throw StateError('此平台的应用内快传连接未配置，请使用普通 BLE 传输');
    if (deviceId.isEmpty) throw StateError('设备未返回可验证身份');
    _active = true;
    _ready = false;
    _cancelled = false;
    _lastProbeFailure = null;
    _deviceId = deviceId;
    final operation = _prepare(deviceId);
    _preparing = operation;
    try {
      await operation;
    } catch (_) {
      final cancelled = _cancelled;
      // The raw preparation future has reached its final event. close() can
      // also be in flight from a cancel; share it, never recursively own it.
      await close();
      if (cancelled) throw const RecordingSyncCancelled();
      rethrow;
    } finally {
      if (identical(_preparing, operation)) _preparing = null;
    }
  }

  Future<void> _prepare(String deviceId) async {
    final before = await gateway.status();
    _checkCancelled();
    if (!before.infoAvailable || before.deviceId != deviceId) {
      throw StateError('快传目标身份与已连接设备不一致');
    }
    if (before.recording || before.realtimeEnabled) {
      throw StateError('快传需要先停止录音并关闭实时传输，不会暗中停录');
    }
    await beforeWifiOpen?.call();
    _checkCancelled();
    _cardTouched = true; // Even a failed command may have powered the card AP.
    await gateway.setWifiEnabled(true);
    _checkCancelled();
    _phoneTouched = true;
    await _join(); // accepted != connected, and not an Internet requirement.
    _checkCancelled();
    final watch = Stopwatch()..start();
    while (watch.elapsed < readyTimeout) {
      _checkCancelled();
      final remaining = readyTimeout - watch.elapsed;
      final timeout = remaining < probeTimeout ? remaining : probeTimeout;
      final ok = await _probe(filesUri, timeout);
      _checkCancelled();
      if (ok && watch.elapsed < readyTimeout) {
        _ready = true;
        return;
      }
      final rest = readyTimeout - watch.elapsed;
      if (rest <= Duration.zero) break;
      await Future<void>.delayed(rest < probeInterval ? rest : probeInterval);
    }
    throw StateError(
      '录音卡本地文件服务未就绪，请检查本地网络权限和设备后重试'
      '${_lastProbeFailure == null ? '' : '（$_lastProbeFailure）'}',
    );
  }

  void requireReady(String deviceId) {
    _checkCancelled();
    if (!ready || _deviceId != deviceId) {
      throw StateError('快传热点尚未通过本地文件服务验证，请重新准备快传');
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw const RecordingSyncCancelled();
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    if (!_active) return Future.value();
    _cancelled = true;
    _ready = false;
    final operation = _cleanup();
    _closing = operation;
    return operation.whenComplete(() {
      if (identical(_closing, operation)) _closing = null;
    });
  }

  Future<void> _cleanup() async {
    Object? phoneError;
    StackTrace? phoneStack;
    var phoneAttempted = false;
    // Send close while join is in flight so Native can cancel its ticket. A
    // close ACK alone is insufficient: still await the ORIGINAL join final.
    if (_phoneTouched) {
      phoneAttempted = true;
      try {
        await _closePhone();
        _phoneTouched = false;
      } catch (error, stack) {
        phoneError = error;
        phoneStack = stack;
      }
    }
    try {
      await _preparing;
    } catch (_) {
      // Original preparation failure is delivered by prepare(), not swallowed.
    }
    if (_phoneTouched && !phoneAttempted) {
      try {
        await _closePhone();
        _phoneTouched = false;
      } catch (error, stack) {
        phoneError = error;
        phoneStack = stack;
      }
    }
    Object? cardError;
    StackTrace? cardStack;
    if (_cardTouched) {
      try {
        await gateway.setWifiEnabled(false);
        final after = await gateway.status();
        if (after.wifiOpen ||
            !after.infoAvailable ||
            after.deviceId != _deviceId) {
          throw StateError('尚未确认录音卡热点关闭及 SD 归还主控');
        }
        _cardTouched = false;
      } catch (error, stack) {
        cardError = error;
        cardStack = stack;
      }
    }
    if (!_phoneTouched && !_cardTouched) {
      _active = false;
      _deviceId = null;
    }
    // Both sides are always attempted; failure retains the local-only/busy lane
    // for explicit cleanup retry instead of pretending the connection is gone.
    if (phoneError != null) Error.throwWithStackTrace(phoneError, phoneStack!);
    if (cardError != null) Error.throwWithStackTrace(cardError, cardStack!);
  }

  /// No redirects, proxies, credentials, SSID/location or Internet checks.
  /// Read the bounded response, not just a successful TCP connection/header.
  static Future<bool> probeFileService(
    Uri uri,
    Duration timeout, {
    void Function(String)? onFailure,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    Future<bool> request() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        onFailure?.call('本地服务 HTTP ${response.statusCode}');
        return false;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          onFailure?.call('本地服务响应超出安全大小限制');
          return false;
        }
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      // SDK AccessPointFilePage is a JSON object with a files list (empty valid).
      final valid = data is Map && data['files'] is List;
      if (!valid) onFailure?.call('本地服务响应不是 SDK 文件列表');
      return valid;
    }

    try {
      return await request().timeout(timeout);
    } on TimeoutException {
      onFailure?.call('本地连接或响应超时');
      return false;
    } on SocketException catch (e) {
      onFailure?.call(
        '局域网连接失败${e.osError == null ? '' : ': ${e.osError!.errorCode} ${e.osError!.message}'}',
      );
      return false;
    } on FormatException {
      onFailure?.call('本地服务响应不是有效 JSON');
      return false;
    } on Exception catch (e) {
      onFailure?.call('本地请求失败：${e.runtimeType}');
      return false;
    } finally {
      // Abort pending socket/body reads on timeout; no orphan probe can mark a
      // newer session ready or keep its AP route alive.
      client.close(force: true);
    }
  }
}
