/// 蓝牙授权（iOS 需要主动申请；Android 由系统在扫描时申请）。
///
/// 为什么单独做一层：Rust SDK 底层是 btleplug → CoreBluetooth，
/// 第一次创建 `CBCentralManager` 时系统才弹「允许使用蓝牙」。
/// 那个弹窗会阻塞扫描；如果用户错过或拒绝，扫描会一直等不到结果却看不出原因。
/// 所以在真正扫描前先同步一次授权状态，必要时主动发起申请，并把结果交给界面提示。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum BluetoothAuthorization {
  /// 已授权
  granted,

  /// 用户拒绝过（需要在系统设置里打开）
  denied,

  /// 被家长控制等策略限制
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
  const BluetoothPermission();

  static const _channel = MethodChannel('com.reai.recordingcard/bluetooth');

  /// 读取当前授权状态（不触发对话框）。
  Future<BluetoothAuthorization> status() async {
    if (!Platform.isIOS) return BluetoothAuthorization.unknown;
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
    if (!Platform.isIOS) return BluetoothAuthorization.unknown;
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
    if (!Platform.isIOS && !Platform.isAndroid) return;
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
}
