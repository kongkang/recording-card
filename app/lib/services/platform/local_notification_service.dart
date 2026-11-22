/// 本地系统通知服务（蓝牙断连提醒 / 切换兜底提醒 / 重连恢复提醒）。
library;

import 'package:flutter/services.dart';

abstract interface class LocalNotificationBackend {
  Future<bool> requestPermission();
  Future<bool> notify({
    required String id,
    required String title,
    required String body,
    bool urgent = false,
  });
  Future<void> cancel(String id);
}

class PlatformLocalNotificationBackend implements LocalNotificationBackend {
  PlatformLocalNotificationBackend({
    MethodChannel channel = const MethodChannel(
      'com.reai.recordingcard/local_notifications',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> requestPermission() async {
    try {
      final res = await _channel.invokeMethod<String>('requestPermission');
      return res == 'granted';
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> notify({
    required String id,
    required String title,
    required String body,
    bool urgent = false,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('notify', <String, Object?>{
        'id': id,
        'title': title,
        'body': body,
        'urgent': urgent,
      });
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _channel.invokeMethod<void>('cancel', <String, Object?>{'id': id});
    } on MissingPluginException {
      // ignore in tests / desktop
    } on PlatformException {
      // ignore
    }
  }
}

class LocalNotificationService {
  LocalNotificationService({LocalNotificationBackend? backend})
    : _backend = backend ?? PlatformLocalNotificationBackend();

  static const String deviceAlertId = 'rc_ble_device_alert';

  final LocalNotificationBackend _backend;

  Future<bool> requestPermission() => _backend.requestPermission();

  Future<bool> notifyBleDisconnected({
    required String deviceName,
    required String body,
    bool urgent = false,
  }) => _backend.notify(
    id: deviceAlertId,
    title: '$deviceName 已断开连接',
    body: body,
    urgent: urgent,
  );

  Future<bool> notifyBleReconnected({
    required String deviceName,
    required String body,
  }) => _backend.notify(
    id: deviceAlertId,
    title: '$deviceName 已重新连接',
    body: body,
    urgent: false,
  );

  Future<void> cancelDeviceAlert() => _backend.cancel(deviceAlertId);
}
