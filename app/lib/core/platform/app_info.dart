/// 应用版本信息（「关于录音卡」页展示用）。
///
/// 版本号一律从构建产物读取（`package_info_plus` → pubspec 的 `version: 1.0.0+1`），
/// 不在 UI 里手写常量，避免发版后忘记改数字。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:package_info_plus/package_info_plus.dart';

String? _cachedDisplay;

/// 版本号展示串，形如 `1.0.0 (1)`（版本名 + 构建号）。
///
/// 首次调用走平台通道，之后走缓存；读取失败返回「未知版本」并打日志，
/// 不抛异常——关于页不应该因为取不到版本号而崩。
Future<String> appVersion() async {
  final cached = _cachedDisplay;
  if (cached != null) return cached;

  try {
    final info = await PackageInfo.fromPlatform();
    final buildNumber = info.buildNumber.trim();
    final display = buildNumber.isEmpty
        ? info.version
        : '${info.version} ($buildNumber)';
    _cachedDisplay = display;
    return display;
  } catch (e) {
    debugPrint('[app_info] 读取版本号失败: $e');
    return '未知版本';
  }
}

/// 清空缓存（测试或调试时让下次调用重新读平台信息）。
void resetAppInfoCache() => _cachedDisplay = null;
