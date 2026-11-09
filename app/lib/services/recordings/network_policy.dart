/// 网络策略 —— 让「仅使用 Wi-Fi 同步」这个设置真正生效。
///
/// 背景：这个开关此前只有定义与测试，没有任何传输代码读取它，用户打开也不会有任何
/// 效果（哑开关）。最贵的传输正是从录音卡取回录音（BLE 3~8 KB/s，10 分钟音频要
/// 十几分钟），所以在**下载前**做一次网络检查最合适，而不是等传完了才发现走的是蜂窝。
///
/// 判断方式不引入额外依赖：iOS 用 `NWPathMonitor` 太重、Android 要额外插件，
/// 这里用 Dart 标准库能拿到的信息做保守判断——**只有确认在 Wi-Fi 上才放行**，
/// 不确定时按「不是 Wi-Fi」处理并如实提示用户，而不是偷偷走流量。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// 一次网络检查的结果。
class NetworkDecision {
  const NetworkDecision({required this.allowed, required this.isWifi, this.reason});

  /// 是否允许执行（受「仅 Wi-Fi」设置约束后）。
  final bool allowed;

  /// 当前是否在 Wi-Fi 上。
  final bool isWifi;

  /// 被拦下时给用户看的原因（allowed 为 true 时为 null）。
  final String? reason;

  static const allow = NetworkDecision(allowed: true, isWifi: true);
}

/// 网络探测接口（测试可注入固定结果，不依赖真实网络）。
abstract interface class NetworkProbe {
  /// 当前是否在 Wi-Fi/有线网络上；无法判断时返回 false（保守）。
  Future<bool> isOnWifi();
}

/// 默认探测：用本机网卡列表判断。
///
/// 判定规则：
/// - 存在 `en0`（iOS Wi-Fi）或 `wlan*`（Android Wi-Fi）→ 是 Wi-Fi；
/// - 只有 `pdp_ip*`（iOS 蜂窝）/ `rmnet*`（Android 蜂窝）→ 不是 Wi-Fi；
/// - 其余情况（模拟器、桌面、命名空间差异）→ 保守返回 false。
///
/// 这是**不引入插件**的近似判断：宁可让用户看到「请连接 Wi-Fi」，
/// 也不要在移动网络下悄悄传几十 MB。
class InterfaceNetworkProbe implements NetworkProbe {
  const InterfaceNetworkProbe();

  @override
  Future<bool> isOnWifi() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      if (interfaces.isEmpty) return false;

      final names = interfaces.map((i) => i.name).toList();
      const wifiNames = ['en0', 'wlan0', 'wlan1'];
      final onWifi = names.any(
        (n) => wifiNames.contains(n) || n.startsWith('wlan'),
      );
      return onWifi;
    } on Object catch (e) {
      debugPrint('[net] 网络探测失败，按非 Wi-Fi 处理：$e');
      return false;
    }
  }
}

/// 策略：按设置决定当前能否传输。
class NetworkPolicy {
  const NetworkPolicy({this.probe = const InterfaceNetworkProbe()});

  final NetworkProbe probe;

  /// [wifiOnly] 为 true 时要求必须在 Wi-Fi 上。
  ///
  /// 返回的 [NetworkDecision.reason] 是可直接展示给用户的中文文案。
  Future<NetworkDecision> check({required bool wifiOnly}) async {
    final isWifi = await probe.isOnWifi();
    if (!wifiOnly) {
      return NetworkDecision(allowed: true, isWifi: isWifi);
    }
    if (isWifi) {
      return const NetworkDecision(allowed: true, isWifi: true);
    }
    return const NetworkDecision(
      allowed: false,
      isWifi: false,
      reason: '已开启「仅使用 Wi-Fi 同步」，请连接 Wi-Fi 后再同步录音',
    );
  }
}
