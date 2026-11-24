/// 蓝牙授权与硬件录音前台保活通道（iOS CoreBluetooth + Android 12+ BLUETOOTH_SCAN/CONNECT 及 <=11 定位权限）。
///
/// 为什么单独做一层：Rust SDK 底层是 btleplug（iOS CoreBluetooth / Android droidplug）。
/// iOS 第一次创建 `CBCentralManager` 时系统才弹「允许使用蓝牙」；Android 则需要宿主 Activity
/// 主动发起运行时权限申请。提前在 Dart 侧同步真实授权状态并在需要时申请，能避免无提示扫描失败。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum BluetoothAuthorization {
  /// 已授权
  granted,

  /// 用户拒绝过（需要在系统设置里打开）
  denied,

  /// 被家长控制或硬件策略限制
  restricted,

  /// 还没问过
  notDetermined,

  /// 平台不支持/无法判断
  unknown;

  static BluetoothAuthorization parse(String? value) => switch (value) {
    'granted' => granted,
    'denied' => denied,
    'restricted' => restricted,
    'notDetermined' => notDetermined,
    _ => unknown,
  };

  /// 能不能继续扫描。
  bool get canScan => this == granted || this == unknown;

  /// 给用户看的说明（null 表示无需提示）。
  String? get hint => switch (this) {
    granted || unknown => null,
    notDetermined => '请允许「录音卡」使用蓝牙',
    denied => '蓝牙权限已关闭，请在 设置 → 录音卡 中允许蓝牙访问',
    restricted => '当前设备限制了蓝牙访问，无法连接录音卡',
  };
}

class BluetoothPermission {
  const BluetoothPermission({
    @visibleForTesting bool forceChannelForTesting = false,
  }) : _forceChannelForTesting = forceChannelForTesting;

  static const _channel = MethodChannel('com.reai.recordingcard/bluetooth');

  final bool _forceChannelForTesting;

  bool get _supportsChannel =>
      _forceChannelForTesting || Platform.isIOS || Platform.isAndroid;

  /// 读取当前授权状态（不触发对话框）。
  Future<BluetoothAuthorization> status() async {
    if (!_supportsChannel) return BluetoothAuthorization.unknown;
    try {
      final value = await _channel.invokeMethod<String>('status');
      return BluetoothAuthorization.parse(value);
    } on PlatformException catch (e) {
      debugPrint('[ble] 读取蓝牙授权失败：$e');
      return BluetoothAuthorization.unknown;
    } on MissingPluginException {
      // 原生侧未注册该通道（例如测试环境）：按未知处理，不阻断流程
      return BluetoothAuthorization.unknown;
    }
  }

  /// 需要时触发系统授权对话框，返回最终状态。
  Future<BluetoothAuthorization> request() async {
    if (!_supportsChannel) return BluetoothAuthorization.unknown;
    try {
      final value = await _channel.invokeMethod<String>('request');
      return BluetoothAuthorization.parse(value);
    } on PlatformException catch (e) {
      debugPrint('[ble] 申请蓝牙授权失败：$e');
      return BluetoothAuthorization.unknown;
    } on MissingPluginException {
      return BluetoothAuthorization.unknown;
    }
  }

  /// 固件升级等长耗时流程期间请求保持屏幕常亮，避免系统休眠中断 BLE 连接。
  Future<void> setKeepScreenOn(bool enabled) async {
    if (!_supportsChannel) return;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } on PlatformException catch (e) {
      debugPrint('[ble] 设置屏幕常亮失败：$e');
    } on MissingPluginException {
      // 原生侧未注册该通道（例如测试环境）：安全忽略
    }
  }

  /// 退后台或收到内存警告时请求原生侧回收 URLCache 与空闲堆内存。
  Future<void> trimNativeMemory() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('trimMemory');
    } on PlatformException catch (e) {
      debugPrint('[mem] 原生内存整理失败：$e');
    } on MissingPluginException {
      // 测试环境或非 iOS 注册：安全忽略
    }
  }

  /// Android 录音期间启停前台保活服务（`connectedDevice|microphone`），防止锁屏或退后台后系统回收进程。
  Future<void> setRecordingForeground(
    bool enabled, {
    String? title,
    String? subtitle,
    bool useMicrophone = false,
  }) async {
    if (!_forceChannelForTesting && !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setRecordingForeground', <String, Object?>{
        'enabled': enabled,
        'title': ?title,
        'subtitle': ?subtitle,
        'useMicrophone': useMicrophone,
      });
    } on PlatformException catch (e) {
      debugPrint('[ble] 设置录音前台服务失败：$e');
    } on MissingPluginException {
      // 测试环境安全忽略
    }
  }
}
