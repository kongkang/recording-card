/// 旧版固件独立引导升级模型定义（与正常连接主状态完全解耦）。
library;

import '../../core/device/card_gateway.dart';

/// 引导升级当前所处步骤。
enum LegacyUpgradeStep {
  hidden,
  prompt,
  scanningWifi,
  selectingWifi,
  upgrading,
  reconnecting,
  failed,
}

/// 连接阶段捕获到的"旧固件需引导升级"描述信息。
class LegacyUpgradeMismatch {
  const LegacyUpgradeMismatch({
    required this.device,
    required this.deviceKind,
    required this.currentVersion,
    required this.minRequiredVersion,
    required this.message,
  });

  final CardDevice device;
  final String deviceKind;
  final String currentVersion;
  final String minRequiredVersion;
  final String message;

  static const _prefix = 'LEGACY_UPGRADE_REQUIRED|';

  /// 解析结构化前缀：`LEGACY_UPGRADE_REQUIRED|<deviceKind>|<currentVer>|<minVer>|<message>`。
  static LegacyUpgradeMismatch? tryParse(CardDevice device, CardException error) {
    final raw = error.message.trim();
    if (!raw.startsWith(_prefix)) return null;
    final parts = raw.split('|');
    if (parts.length < 5) return null;
    final kind = parts[1].trim().isEmpty ? device.deviceKind.code : parts[1].trim();
    final current = parts[2].trim();
    final minVer = parts[3].trim().isEmpty ? '0.8.12' : parts[3].trim();
    final msg = parts.sublist(4).join('|').trim();
    return LegacyUpgradeMismatch(
      device: device,
      deviceKind: kind,
      currentVersion: current,
      minRequiredVersion: minVer,
      message: msg.isEmpty ? '检测到设备固件版本过低，请配置 Wi-Fi 后自动升级' : msg,
    );
  }
}

/// 打开旧固件升级会话后读回的设备摘要信息。
class LegacyUpgradeSessionInfo {
  const LegacyUpgradeSessionInfo({
    required this.deviceId,
    required this.name,
    required this.deviceKind,
    required this.currentVersion,
    required this.targetVersion,
    required this.wifiEnabled,
    required this.wifiConnected,
    this.currentSsid,
  });

  factory LegacyUpgradeSessionInfo.fromJson(Map<String, dynamic> json) {
    final rawSsid = (json['currentSsid'] as String?)?.trim();
    return LegacyUpgradeSessionInfo(
      deviceId: (json['deviceId'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      deviceKind: (json['deviceKind'] as String?) ?? 'dyj_v1',
      currentVersion: (json['currentVersion'] as String?) ?? '',
      targetVersion: (json['targetVersion'] as String?) ?? '0.8.15',
      wifiEnabled: json['wifiEnabled'] == true,
      wifiConnected: json['wifiConnected'] == true,
      currentSsid: (rawSsid == null || rawSsid.isEmpty) ? null : rawSsid,
    );
  }

  final String deviceId;
  final String name;
  final String deviceKind;
  final String currentVersion;
  final String targetVersion;
  final bool wifiEnabled;
  final bool wifiConnected;
  final String? currentSsid;
}

/// 旧协议扫到的 Wi-Fi 接入点。
class LegacyWifiNetwork {
  const LegacyWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secure,
    this.connected = false,
  });

  factory LegacyWifiNetwork.fromJson(Map<String, dynamic> json) =>
      LegacyWifiNetwork(
        ssid: ((json['ssid'] as String?) ?? '').trim(),
        rssi: (json['rssi'] as num?)?.toInt() ?? -80,
        secure: json['secure'] == true,
        connected: json['connected'] == true,
      );

  final String ssid;
  final int rssi;
  final bool secure;
  final bool connected;

  int get signalLevel {
    if (rssi >= -55) return 3;
    if (rssi >= -70) return 2;
    return 1;
  }
}

/// 升级安装完成且新协议广播就绪后返回的新建连参数。
class LegacyUpgradeResult {
  const LegacyUpgradeResult({
    required this.deviceId,
    required this.name,
    required this.targetVersion,
  });

  factory LegacyUpgradeResult.fromJson(Map<String, dynamic> json) =>
      LegacyUpgradeResult(
        deviceId: (json['deviceId'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        targetVersion: (json['targetVersion'] as String?) ?? '0.8.15',
      );

  final String deviceId;
  final String name;
  final String targetVersion;
}

/// 从固件清单服务拉取的目标版本规格，传给原生引导升级链路（尤其初代 `v0.5/0.6.x` `updateApp`）。
class LegacyTargetOtaSpec {
  const LegacyTargetOtaSpec({
    required this.versionName,
    required this.versionCode,
    required this.url,
  });

  static LegacyTargetOtaSpec? tryParseManifestJson(Map<String, dynamic> raw) {
    final data = raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    final url =
        (data['url'] as String? ?? data['downloadUrl'] as String? ?? '').trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return null;
    }
    final ver =
        (data['versionName'] as String? ?? data['version'] as String? ?? '')
            .trim()
            .replaceFirst(RegExp(r'^[vV]'), '');
    final codeNum = data['versionCode'];
    final code = codeNum is num
        ? codeNum.toInt()
        : int.tryParse(codeNum?.toString().trim() ?? '') ?? 0;
    if (ver.isEmpty || code <= 0) {
      return null;
    }
    return LegacyTargetOtaSpec(
      versionName: ver,
      versionCode: code,
      url: url,
    );
  }

  final String versionName;
  final int versionCode;
  final String url;

  Map<String, dynamic> toJson() => {
    'versionName': versionName,
    'versionCode': versionCode,
    'url': url,
  };
}
