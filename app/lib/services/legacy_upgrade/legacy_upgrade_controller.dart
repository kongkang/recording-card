/// 旧版固件独立引导升级状态机：
/// 「版本不兼容提示 → 扫描 Wi-Fi → 输入密码并配网 → 自动下载安装 → 自动重连蓝牙」。
///
/// 全流程独立持有状态与进度，不侵入正常连接状态（`LinkState` / `StatusSheet`）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/device/card_gateway.dart';
import 'legacy_upgrade_gateway.dart';
import 'legacy_upgrade_models.dart';

enum _RetryOrigin { wifiSetup, otaPipeline }

class LegacyUpgradeController extends ChangeNotifier {
  LegacyUpgradeController({
    required LegacyUpgradeGateway gateway,
    required Future<bool> Function(CardDevice updatedDevice) onAutoReconnect,
    Future<String?> Function(String ssid)? loadSavedPassword,
    Future<void> Function(String ssid, String password)? saveWifiPassword,
    Future<LegacyTargetOtaSpec?> Function()? fetchTargetOta,
    Duration reconnectRetryDelay = const Duration(seconds: 2),
  }) : _gateway = gateway,
       _onAutoReconnect = onAutoReconnect,
       _loadSavedPassword = loadSavedPassword,
       _saveWifiPassword = saveWifiPassword,
       _fetchTargetOta = fetchTargetOta,
       _reconnectRetryDelay = reconnectRetryDelay;

  final LegacyUpgradeGateway _gateway;
  final Future<bool> Function(CardDevice updatedDevice) _onAutoReconnect;
  final Future<String?> Function(String ssid)? _loadSavedPassword;
  final Future<void> Function(String ssid, String password)? _saveWifiPassword;
  final Future<LegacyTargetOtaSpec?> Function()? _fetchTargetOta;
  final Duration _reconnectRetryDelay;

  static const _prefPrefix = 'rc_legacy_wifi_pwd_v1_';
  static const _defaultTargetOtaUrl =
      'https://hdd.dev.reai.com/api/ota/info?mod=app';
  final Map<String, String> _memoryPasswords = {};

  LegacyUpgradeStep step = LegacyUpgradeStep.hidden;
  LegacyUpgradeMismatch? mismatch;
  LegacyUpgradeSessionInfo? sessionInfo;
  List<LegacyWifiNetwork> networks = const [];
  String? selectedSsid;
  String prefilledPassword = '';
  double progress = 0;
  String statusText = '';
  String? error;
  String? formError;

  bool _sessionOpened = false;
  int _flowEpoch = 0;
  _RetryOrigin _retryOrigin = _RetryOrigin.wifiSetup;
  String? _lastSubmittedSsid;
  String? _lastSubmittedPassword;

  bool get isVisible => step != LegacyUpgradeStep.hidden;

  bool get isBusy =>
      step == LegacyUpgradeStep.scanningWifi ||
      step == LegacyUpgradeStep.upgrading ||
      step == LegacyUpgradeStep.reconnecting;

  String get currentVersionLabel {
    final v = sessionInfo?.currentVersion.isNotEmpty == true
        ? sessionInfo!.currentVersion
        : (mismatch?.currentVersion ?? '');
    if (v.isEmpty) return '旧版固件';
    return v.startsWith('v') ? v : 'v$v';
  }

  String get targetVersionLabel {
    final v = sessionInfo?.targetVersion.isNotEmpty == true
        ? sessionInfo!.targetVersion
        : '0.8.15';
    return v.startsWith('v') ? v : 'v$v';
  }

  bool isSsidAlreadyConnected(String ssid) {
    final target = ssid.trim();
    if (target.isEmpty) return false;
    if (sessionInfo?.wifiConnected == true &&
        sessionInfo?.currentSsid?.trim() == target) {
      return true;
    }
    return networks.any((n) => n.connected && n.ssid.trim() == target);
  }

  LegacyWifiNetwork? get selectedNetwork {
    final sel = selectedSsid;
    if (sel == null) return null;
    for (final n in networks) {
      if (n.ssid == sel) return n;
    }
    return null;
  }

  /// 点击不兼容旧设备后进入独立提示层。
  void triggerFromMismatch(LegacyUpgradeMismatch m) {
    _flowEpoch++;
    mismatch = m;
    sessionInfo = null;
    networks = const [];
    selectedSsid = null;
    prefilledPassword = '';
    progress = 0;
    statusText = '';
    error = null;
    formError = null;
    _sessionOpened = false;
    _lastSubmittedSsid = null;
    _lastSubmittedPassword = null;
    step = LegacyUpgradeStep.prompt;
    notifyListeners();
  }

  /// 关闭引导弹层并释放旧通道蓝牙；升级安装/重连中禁止关闭。
  Future<void> dismiss() async {
    if (isBusy) return;
    _flowEpoch++;
    step = LegacyUpgradeStep.hidden;
    error = null;
    formError = null;
    _sessionOpened = false;
    notifyListeners();
    await _gateway.close();
  }

  /// 第 1 步：以旧协议建立安全控制通道，并扫描附近可用 Wi-Fi。
  Future<void> beginWifiSetup() async {
    final m = mismatch;
    if (m == null || isBusy) return;
    final epoch = ++_flowEpoch;
    _retryOrigin = _RetryOrigin.wifiSetup;
    step = LegacyUpgradeStep.scanningWifi;
    error = null;
    formError = null;
    statusText = '正在读取设备网络并扫描 Wi-Fi…';
    notifyListeners();

    try {
      if (!_sessionOpened) {
        final info = await _gateway.open(m.device);
        if (epoch != _flowEpoch) return;
        sessionInfo = info;
        _sessionOpened = true;
      }
      final scanned = await _gateway.scanWifi();
      if (epoch != _flowEpoch) return;
      await _applyScannedNetworks(scanned, epoch);
      if (epoch != _flowEpoch) return;
      step = LegacyUpgradeStep.selectingWifi;
    } on CardException catch (e) {
      if (epoch != _flowEpoch) return;
      _sessionOpened = false;
      unawaited(_gateway.close());
      error = e.message;
      step = LegacyUpgradeStep.failed;
    } on Object catch (e) {
      if (epoch != _flowEpoch) return;
      _sessionOpened = false;
      unawaited(_gateway.close());
      error = '$e';
      step = LegacyUpgradeStep.failed;
    }
    notifyListeners();
  }

  /// 刷新 Wi-Fi 列表。
  Future<void> rescanWifi() async {
    if (isBusy) return;
    if (!_sessionOpened) {
      await beginWifiSetup();
      return;
    }
    final epoch = ++_flowEpoch;
    _retryOrigin = _RetryOrigin.wifiSetup;
    step = LegacyUpgradeStep.scanningWifi;
    error = null;
    formError = null;
    statusText = '正在重新扫描 Wi-Fi…';
    notifyListeners();

    try {
      final scanned = await _gateway.scanWifi();
      if (epoch != _flowEpoch) return;
      await _applyScannedNetworks(scanned, epoch);
      if (epoch != _flowEpoch) return;
      step = LegacyUpgradeStep.selectingWifi;
    } on CardException catch (e) {
      if (epoch != _flowEpoch) return;
      error = e.message;
      step = LegacyUpgradeStep.failed;
    } on Object catch (e) {
      if (epoch != _flowEpoch) return;
      error = '$e';
      step = LegacyUpgradeStep.failed;
    }
    notifyListeners();
  }

  Future<void> _applyScannedNetworks(
    List<LegacyWifiNetwork> scanned,
    int epoch,
  ) async {
    networks = scanned;
    final prevSel = selectedSsid;
    if (prevSel != null && scanned.any((n) => n.ssid == prevSel)) {
      selectedSsid = prevSel;
    } else {
      final connected = scanned.where((n) => n.connected).firstOrNull;
      selectedSsid = connected?.ssid ?? scanned.firstOrNull?.ssid;
    }
    if (selectedSsid != null) {
      final saved = await _readPassword(selectedSsid!);
      if (epoch == _flowEpoch) {
        prefilledPassword = saved ?? '';
      }
    } else {
      prefilledPassword = '';
    }
  }

  Future<void> selectSsid(String ssid) async {
    if (isBusy) return;
    selectedSsid = ssid;
    formError = null;
    final saved = await _readPassword(ssid);
    prefilledPassword = saved ?? '';
    notifyListeners();
  }

  /// 第 2~4 步：连接 Wi-Fi → 自动下载与静默安装 → 自动重连蓝牙。
  Future<void> submitWifiAndUpgrade({
    required String ssid,
    required String password,
  }) async {
    final trimmedSsid = ssid.trim();
    final trimmedPwd = password.trim();
    if (trimmedSsid.isEmpty) {
      formError = '请选择要连接的 Wi-Fi 网络';
      notifyListeners();
      return;
    }

    final net = networks.where((n) => n.ssid == trimmedSsid).firstOrNull;
    final reuseExisting = isSsidAlreadyConnected(trimmedSsid);
    final needPwd = (net?.secure ?? true) && !reuseExisting;
    if (needPwd && trimmedPwd.isEmpty) {
      formError = '请输入 Wi-Fi 密码';
      notifyListeners();
      return;
    }

    final m = mismatch;
    if (m == null) return;

    final epoch = ++_flowEpoch;
    _retryOrigin = _RetryOrigin.otaPipeline;
    _lastSubmittedSsid = trimmedSsid;
    _lastSubmittedPassword = trimmedPwd;
    selectedSsid = trimmedSsid;
    formError = null;
    error = null;
    step = LegacyUpgradeStep.upgrading;
    progress = 0.02;
    statusText = reuseExisting
        ? '正在验证设备 Wi-Fi 连接（$trimmedSsid）…'
        : '正在为点一机配置 Wi-Fi（$trimmedSsid）…';
    notifyListeners();

    try {
      if (!_sessionOpened) {
        final info = await _gateway.open(m.device);
        if (epoch != _flowEpoch) return;
        sessionInfo = info;
        _sessionOpened = true;
      }

      await _gateway.connectWifi(
        ssid: trimmedSsid,
        password: trimmedPwd.isEmpty ? null : trimmedPwd,
      );
      if (epoch != _flowEpoch) return;

      if (trimmedPwd.isNotEmpty) {
        await _persistPassword(trimmedSsid, trimmedPwd);
      }

      progress = 0.04;
      statusText = 'Wi-Fi 已连接，准备检查并下载新固件…';
      notifyListeners();

      final targetOta = await _resolveTargetOta();
      if (epoch != _flowEpoch) return;

      LegacyUpgradeResult? result;
      await for (final p in _gateway.runOta(
        (r) => result = r,
        targetOta: targetOta,
      )) {
        if (epoch != _flowEpoch) return;
        progress = (p.percent / 100.0).clamp(0.02, 0.96);
        if (p.text.isNotEmpty) statusText = p.text;
        notifyListeners();
      }
      if (epoch != _flowEpoch) return;

      // OTA 完成（或重启恢复完成）：进入自动重连正常蓝牙协议阶段
      _sessionOpened = false;
      step = LegacyUpgradeStep.reconnecting;
      progress = 0.96;
      statusText = '新固件已就绪，正在自动连接蓝牙…';
      notifyListeners();

      final r = result;
      final updatedDevice = CardDevice(
        id: (r != null && r.deviceId.isNotEmpty) ? r.deviceId : m.device.id,
        name: (r != null && r.name.isNotEmpty) ? r.name : m.device.name,
        rssi: m.device.rssi,
        kind: m.device.kind ?? DeviceKind.dyjV1,
        displayModel: m.device.displayModel,
        capabilities: m.device.capabilities,
      );

      var reconnected = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (epoch != _flowEpoch) return;
        if (attempt > 0) {
          await Future<void>.delayed(_reconnectRetryDelay);
          if (epoch != _flowEpoch) return;
        }
        try {
          if (await _onAutoReconnect(updatedDevice)) {
            reconnected = true;
            break;
          }
        } on Object {
          // 下次重试
        }
      }
      if (epoch != _flowEpoch) return;

      if (reconnected) {
        step = LegacyUpgradeStep.hidden;
        progress = 1.0;
        statusText = '';
        error = null;
      } else {
        step = LegacyUpgradeStep.failed;
        error = '新固件已升级完成，自动连接蓝牙未成功，请点击重试或返回设备列表连接';
      }
    } on CardException catch (e) {
      if (epoch != _flowEpoch) return;
      _sessionOpened = false;
      error = e.message;
      step = LegacyUpgradeStep.failed;
    } on Object catch (e) {
      if (epoch != _flowEpoch) return;
      _sessionOpened = false;
      error = '$e';
      step = LegacyUpgradeStep.failed;
    }
    notifyListeners();
  }

  /// 退回 Wi-Fi 选择页修改密码。
  Future<void> backToWifiSelection() async {
    if (isBusy) return;
    error = null;
    formError = null;
    if (networks.isEmpty || !_sessionOpened) {
      await beginWifiSetup();
    } else {
      step = LegacyUpgradeStep.selectingWifi;
      notifyListeners();
    }
  }

  /// 重试失败阶段。
  Future<void> retryFailedStep() async {
    if (isBusy) return;
    if (_retryOrigin == _RetryOrigin.otaPipeline && _lastSubmittedSsid != null) {
      await submitWifiAndUpgrade(
        ssid: _lastSubmittedSsid!,
        password: _lastSubmittedPassword ?? '',
      );
      return;
    }
    await beginWifiSetup();
  }

  Future<String?> _readPassword(String ssid) async {
    final cb = _loadSavedPassword;
    if (cb != null) {
      try {
        final v = await cb(ssid);
        if (v != null && v.isNotEmpty) return v;
      } on Object {
        // 降级本地缓存
      }
    }
    final mem = _memoryPasswords[ssid];
    if (mem != null && mem.isNotEmpty) return mem;
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString('$_prefPrefix$ssid');
      if (v != null && v.isNotEmpty) {
        _memoryPasswords[ssid] = v;
        return v;
      }
    } on Object {
      // 测试环境无原生 SharedPreferences 通道时静默跳过
    }
    return null;
  }

  Future<void> _persistPassword(String ssid, String password) async {
    _memoryPasswords[ssid] = password;
    final cb = _saveWifiPassword;
    if (cb != null) {
      try {
        await cb(ssid, password);
      } on Object {
        // 忽略保存异常
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefPrefix$ssid', password);
    } on Object {
      // 测试环境静默跳过
    }
  }

  Future<LegacyTargetOtaSpec?> _resolveTargetOta() async {
    final hook = _fetchTargetOta;
    if (hook != null) {
      try {
        return await hook();
      } on Object {
        return null;
      }
    }
    final client = http.Client();
    try {
      final resp = await client
          .get(Uri.parse(_defaultTargetOtaUrl))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;
      return LegacyTargetOtaSpec.tryParseManifestJson(decoded);
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }
}
