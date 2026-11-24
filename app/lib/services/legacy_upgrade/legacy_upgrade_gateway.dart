/// 旧版固件引导升级通道抽象与基于 CardGateway 通用透传的实现。
library;

import '../../core/device/card_gateway.dart';
import 'legacy_upgrade_models.dart';

abstract class LegacyUpgradeGateway {
  Future<LegacyUpgradeSessionInfo> open(CardDevice device);

  Future<List<LegacyWifiNetwork>> scanWifi();

  Future<void> connectWifi({required String ssid, String? password});

  Stream<CardProgress> runOta(
    void Function(LegacyUpgradeResult result) onDone, {
    LegacyTargetOtaSpec? targetOta,
  });

  Future<void> close();
}

/// 通过 [CardGateway.invokeBridgeCommand] / [CardGateway.invokeBridgeStream]
/// 驱动 Rust `legacy_upgrade_*` 独立命令族。
class BridgeLegacyUpgradeGateway implements LegacyUpgradeGateway {
  BridgeLegacyUpgradeGateway(this._gateway);

  final CardGateway _gateway;

  Map<String, dynamic> _dataMap(Map<String, dynamic> res) {
    final inner = res['data'];
    if (inner is Map<String, dynamic>) return inner;
    return res;
  }

  @override
  Future<LegacyUpgradeSessionInfo> open(CardDevice device) async {
    final res = await _gateway.invokeBridgeCommand(
      'legacy_upgrade_open',
      {
        'id': device.id,
        'name': device.name,
        'deviceKind': device.deviceKind.code,
      },
      const Duration(seconds: 35),
    );
    return LegacyUpgradeSessionInfo.fromJson(_dataMap(res));
  }

  @override
  Future<List<LegacyWifiNetwork>> scanWifi() async {
    final res = await _gateway.invokeBridgeCommand(
      'legacy_upgrade_scan_wifi',
      null,
      const Duration(seconds: 25),
    );
    final data = _dataMap(res);
    final raw = data['networks'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(LegacyWifiNetwork.fromJson)
        .where((n) => n.ssid.isNotEmpty)
        .toList();
  }

  @override
  Future<void> connectWifi({required String ssid, String? password}) async {
    await _gateway.invokeBridgeCommand(
      'legacy_upgrade_connect_wifi',
      {
        'ssid': ssid,
        if (password != null && password.isNotEmpty) 'password': password,
      },
      const Duration(seconds: 65),
    );
  }

  @override
  Stream<CardProgress> runOta(
    void Function(LegacyUpgradeResult result) onDone, {
    LegacyTargetOtaSpec? targetOta,
  }) {
    return _gateway.invokeBridgeStream(
      'legacy_upgrade_run_ota',
      targetOta == null ? null : {'targetOta': targetOta.toJson()},
      (finalData) => onDone(LegacyUpgradeResult.fromJson(finalData)),
    );
  }

  @override
  Future<void> close() async {
    try {
      await _gateway.invokeBridgeCommand(
        'legacy_upgrade_close',
        null,
        const Duration(seconds: 6),
      );
    } on Object {
      // 兜底释放，关闭失败不阻断界面退出
    }
  }
}
