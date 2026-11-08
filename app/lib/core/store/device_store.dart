/// Device UI state, driven solely by an injected real backend.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../device/card_gateway.dart';
import 'app_backend.dart';
import 'device_backend.dart';
import 'store_persistence.dart';
export 'device_backend.dart';

enum SyncState { idle, busy, done, failed }

enum DeviceView { main, upg, wifi }

class DeviceStore extends ChangeNotifier {
  DeviceStore({
    CardGateway? gateway,
    DeviceBackend? backend,
    StorePersistence? persistence,
    RecordingPolicy Function()? policy,
    this._onSynced,
  }) : backend =
           backend ?? GatewayDeviceBackend(gateway ?? RealCardGateway.maybe()),
       persistence =
           persistence ??
           PreferencesStorePersistence(key: 'recording-card.device-ui.v2'),
       _policy = policy ?? (() => const RecordingPolicy());
  final DeviceBackend backend;
  final StorePersistence persistence;
  final RecordingPolicy Function() _policy;
  final Future<void> Function()? _onSynced;
  bool _disposed = false;
  bool get liveDeviceAvailable => backend.available;
  DeviceReading? reading;
  String? lastDeviceId;
  String? get deviceIdentity => reading?.targetId ?? lastDeviceId;
  bool connected = false;
  bool scanning = false;
  bool connecting = false;
  List<DeviceChoice> scannedDevices = [];
  DateTime? _readingAt;
  Timer? _clock;
  Timer? _cooldown;
  bool _refreshing = false;
  int _connectionEpoch = 0;
  bool sheetOpen = false;
  DeviceView view = DeviceView.main;
  static const batteryLevel = 0; // Unknown, never a fake preset battery.
  int get battery => reading?.snapshot.batteryLevel.clamp(0, 100) ?? 0;
  bool get batteryKnown => connected && reading != null;
  String get batteryLevelText => !batteryKnown
      ? '电量未知'
      : reading!.snapshot.isCharging
      ? '充电中'
      : battery < 20
      ? '电量低'
      : battery < 40
      ? '电量中'
      : '电量高';
  String get batteryEtaText => reading?.batteryEstimate ?? '无法估算';
  String get connectionText => connecting
      ? '正在连接…'
      : connected
      ? '已连接 · 蓝牙'
      : '未连接 · 蓝牙';
  String get recordingText => !connected
      ? '未连接'
      : reading?.snapshot.recording == true
      ? '录音中'
      : '未录音';
  int get recSeconds {
    final base = reading?.recordedSeconds;
    if (base == null || !connected) return 0;
    final elapsed = reading!.snapshot.recording && _readingAt != null
        ? DateTime.now().difference(_readingAt!).inSeconds
        : 0;
    return (base + elapsed).clamp(0, 1 << 31);
  }

  String get recClockText {
    if (!connected || reading?.recordedSeconds == null) return '—:——:——';
    final s = recSeconds;
    return '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final data = await persistence.load();
      lastDeviceId = data?['lastDeviceId'] as String?;
      lastSync = DateTime.tryParse(data?['lastSync'] as String? ?? '');
      // Restoring identity never claims that BLE is currently connected.
    } catch (_) {
      devStateText = '设备状态读取失败';
    }
    await refreshSavedWifi();
    _notify();
  }

  Future<void> _persist() async {
    try {
      await persistence.save({
        'lastDeviceId': lastDeviceId,
        'lastSync': lastSync?.toIso8601String(),
      });
    } catch (_) {
      devStateText = '设备状态保存失败';
      _notify();
    }
  }

  Future<void> scanDevices() async {
    if (scanning || connecting || fwUpdating) return;
    scanning = true;
    scannedDevices = [];
    devStateText = '正在扫描录音卡…';
    _notify();
    try {
      scannedDevices = await backend.scan();
      devStateText = scannedDevices.isEmpty
          ? '未发现录音卡，请检查蓝牙权限和设备电源'
          : '请选择要连接的录音卡';
    } catch (e) {
      devStateText = '扫描失败：${_message(e)}';
    } finally {
      scanning = false;
      _notify();
    }
  }

  Future<void> connectDevice(String id) async {
    if (connecting || fwUpdating) return;
    _connectionEpoch++;
    connecting = true;
    devStateText = '正在连接…';
    _notify();
    try {
      _accept(await backend.connect(id));
      connected = true;
      lastDeviceId = id;
      devStateText = '已连接录音卡';
      await _persist();
    } catch (e) {
      connected = false;
      reading = null;
      devStateText = '连接失败：${_message(e)}';
    } finally {
      connecting = false;
      _notify();
    }
  }

  Future<void> reconnect() async {
    final id = lastDeviceId;
    if (id == null) {
      await scanDevices();
    } else {
      await connectDevice(id);
    }
  }

  Future<void> disconnect() async {
    if (fwUpdating) return;
    _connectionEpoch++;
    try {
      await backend.disconnect();
      connected = false;
      reading = null;
      devStateText = '已断开';
    } catch (e) {
      devStateText = '断开失败：${_message(e)}';
    }
    _notify();
  }

  void _accept(DeviceReading value) {
    reading = value;
    _readingAt = DateTime.now();
    connected = true;
    if (value.id != null) lastDeviceId = value.id;
    wifiLast = value.connectedWifi ?? '';
  }

  Future<void> refreshFromDevice() async {
    if (_refreshing ||
        fwUpdating ||
        scanning ||
        connecting ||
        syncState == SyncState.busy ||
        wifiJoining) {
      return;
    }
    _refreshing = true;
    final epoch = _connectionEpoch;
    try {
      final value = await backend.status();
      if (_disposed || epoch != _connectionEpoch) return;
      _accept(value);
    } catch (e) {
      if (_disposed || epoch != _connectionEpoch) return;
      connected = false;
      reading = null;
      devStateText = '设备状态不可用：${_message(e)}';
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  void openSheet() {
    sheetOpen = true;
    view = DeviceView.main;
    _clock?.cancel();
    var ticks = 0;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (++ticks % 5 == 0 && connected) unawaited(refreshFromDevice());
      _notify();
    });
    unawaited(refreshFromDevice());
    _notify();
  }

  void closeSheet() {
    if (fwUpdating) return;
    sheetOpen = false;
    _clock?.cancel();
    _clock = null;
    _notify();
  }

  void showView(DeviceView v) {
    if (fwUpdating) return;
    view = v;
    if (v == DeviceView.wifi) unawaited(wifiScan());
    if (v == DeviceView.upg) unawaited(checkFirmware());
    _notify();
  }

  SyncState syncState = SyncState.idle;
  DateTime? lastSync;
  String syncStage = '';
  String? syncError;
  String get syncRelText {
    if (lastSync == null) return '尚未同步';
    final s = DateTime.now().difference(lastSync!).inSeconds;
    if (s < 30) return '刚刚';
    if (s < 60) return '30 秒前';
    return '${s ~/ 60} 分钟前';
  }

  String get syncText => switch (syncState) {
    SyncState.busy => syncStage.isEmpty ? '正在同步…' : syncStage,
    SyncState.done => '同步成功 · 刚刚',
    SyncState.failed => '同步失败 · 点击重试',
    SyncState.idle => lastSync == null ? '尚未同步 · 点击同步' : '最近同步 · $syncRelText',
  };
  Future<void> syncNow() async {
    if (syncState == SyncState.busy ||
        syncState == SyncState.done ||
        fwUpdating) {
      return;
    }
    syncState = SyncState.busy;
    syncError = null;
    syncStage = '正在同步…';
    _notify();
    try {
      await backend.sync(_policy(), (p) {
        syncStage = p.stage;
        _notify();
      });
      lastSync = DateTime.now();
      syncState = SyncState.done;
      await _persist();
      if (_onSynced != null) await _onSynced();
      _cooldown?.cancel();
      _cooldown = Timer(const Duration(seconds: 10), () {
        syncState = SyncState.idle;
        _notify();
      });
    } catch (e) {
      syncState = SyncState.failed;
      syncError = '同步失败：${_message(e)}';
      devStateText = syncError!;
    }
    _notify();
  }

  bool fwUpdating = false;
  bool fwDone = false;
  bool fwChecking = false;
  double fwProgress = 0;
  double? fwPercent;
  String fwValText = '尚未检查更新';
  String devStateText = '';
  String fwStateText = '';
  String fwStageText = '等待固件任务';
  FirmwareOffer? offer;
  String get fwPctText => fwPercent == null ? '进度未知' : '${fwPercent!.round()}%';
  String get mainVersionText =>
      '${reading?.snapshot.fwVersion ?? '未知'} → ${offer?.targetMainVersion ?? '未配置'}';
  String get wifiVersionText =>
      '${reading?.snapshot.wifiVersion ?? '未知'} → ${offer?.targetWifiVersion ?? '未配置'}';
  Future<void> checkFirmware() async {
    if (fwChecking || fwUpdating) return;
    fwChecking = true;
    fwStateText = '正在检查固件清单…';
    _notify();
    try {
      offer = await backend.firmwareOffer();
      fwValText = offer == null
          ? '已是最新'
          : offer!.valid
          ? '有可用更新'
          : '固件包信息不完整';
      fwStateText = offer?.notes ?? '没有适用更新';
    } catch (e) {
      offer = null;
      fwValText = '更新检查失败';
      fwStateText = '固件检查失败：${_message(e)}';
    } finally {
      fwChecking = false;
      _notify();
    }
  }

  Future<void> startFwUpdate({FirmwareConsent? consent}) async {
    final package = offer;
    if (fwUpdating) return;
    if (!connected ||
        package == null ||
        !package.valid ||
        consent == null ||
        package.deviceId != deviceIdentity ||
        consent.deviceId != package.deviceId ||
        consent.packageId != package.packageId ||
        consent.checksum != package.checksum) {
      fwStateText = '升级被拒绝：请连接目标设备并确认有效固件包与校验值';
      _notify();
      return;
    }
    if (syncState == SyncState.busy || wifiJoining) {
      fwStateText = '设备任务正在运行，稍后重试';
      _notify();
      return;
    }
    fwUpdating = true;
    fwDone = false;
    fwPercent = null;
    _notify();
    try {
      await backend.updateFirmware(package, consent, (p) {
        fwStageText = p.stage;
        fwStateText = p.stage;
        fwPercent = p.percent;
        fwProgress = (p.percent ?? 0).clamp(0, 100).toDouble();
        _notify();
      });
      // Backend must verify reconnect/versions before resolving the task.
      final verified = await backend.status();
      if ((package.targetMainVersion.isNotEmpty &&
              verified.snapshot.fwVersion != package.targetMainVersion) ||
          (package.targetWifiVersion.isNotEmpty &&
              verified.snapshot.wifiVersion != package.targetWifiVersion)) {
        throw StateError('更新后版本校验未通过');
      }
      _accept(verified);
      fwDone = true;
      fwValText = '已是最新';
      view = DeviceView.main;
      devStateText =
          '已更新到 主控 ${verified.snapshot.fwVersion} / Wi-Fi ${verified.snapshot.wifiVersion}';
    } catch (e) {
      fwStateText = '固件更新失败：${_message(e)}';
      fwValText = '更新失败';
    } finally {
      fwUpdating = false;
      _notify();
    }
  }

  List<SavedWifi> wifiSaved = [];
  bool wifiSavedKnown = false;
  String get wifiConfigText => !connected
      ? '未连接'
      : wifiSavedKnown
      ? '已配置 · ${wifiSaved.length} 个网络'
      : '配置未知';
  Future<void> refreshSavedWifi() async {
    try {
      wifiSaved = await backend.savedWifi();
      wifiSavedKnown = true;
    } catch (_) {
      wifiSavedKnown = false;
    }
    _notify();
  }

  String wifiLast = '';
  bool wifiMore = false;
  bool wifiScanDone = false;
  bool wifiScanning = false;
  bool wifiJoining = false;
  String wifiJoinName = '';
  String? wifiSelName;
  String wifiStateText = '';
  List<WifiNet> wifiScanRes = [];
  int get wifiCountShown => wifiSaved.length;
  bool wifiInRange(String n) => wifiScanRes.any((r) => r.name == n);
  bool get wifiIsJoiningSaved =>
      wifiJoining && wifiSaved.any((w) => w.name == wifiJoinName);
  Future<void> wifiScan() async {
    if (wifiScanning ||
        wifiJoining ||
        fwUpdating ||
        syncState == SyncState.busy) {
      return;
    }
    wifiSelName = null;
    wifiScanDone = false;
    wifiScanning = true;
    wifiStateText = '正在扫描附近网络…';
    _notify();
    try {
      wifiSaved = await backend.savedWifi();
      wifiSavedKnown = true;
      wifiScanRes = await backend.scanWifi();
      // Do not label unknown frequency as verified 2.4G.
      wifiScanRes = wifiScanRes
          .where((r) => r.frequencyMhz == null || r.frequencyMhz! < 2500)
          .toList();
      final frequencyKnown = wifiScanRes.isNotEmpty && wifiScanRes.every((r) => r.frequencyMhz != null);
      wifiStateText = '扫描完成 · 附近可见 ${wifiScanRes.length} 个${frequencyKnown ? ' 2.4GHz ' : ''}网络';
    } catch (e) {
      wifiScanRes = [];
      wifiStateText = 'Wi-Fi扫描失败：${_message(e)}';
    } finally {
      wifiScanDone = true;
      wifiScanning = false;
      _notify();
    }
  }

  void wifiMoreToggle() {
    wifiMore = !wifiMore;
    _notify();
  }

  void wifiPick(String n) {
    if (wifiJoining) return;
    wifiSelName = n;
    _notify();
  }

  void wifiCancelPick() {
    wifiSelName = null;
    _notify();
  }

  Future<void> wifiConnectSaved(String name) async {
    if (!wifiInRange(name) || wifiJoining || fwUpdating) return;
    await _join(name, () => backend.connectSavedWifi(name));
  }

  Future<void> wifiJoinNew(String password) async {
    final network = wifiScanRes.where((n) => n.name == wifiSelName).firstOrNull;
    if (network == null || wifiJoining || fwUpdating) return;
    if (network.lock && password.isEmpty) {
      wifiStateText = '请输入网络密码';
      _notify();
      return;
    }
    await _join(network.name, () => backend.joinWifi(network.name, password));
  }

  Future<void> _join(String name, Future<void> Function() action) async {
    wifiJoining = true;
    wifiJoinName = name;
    wifiStateText = '正在验证连接可行性…';
    _notify();
    try {
      await action();
      final status = await backend.status();
      if (status.connectedWifi != name) throw StateError('设备未确认连接到目标网络');
      _accept(status);
      wifiSaved = await backend.savedWifi();
      wifiSavedKnown = true;
      wifiLast = name;
      wifiSelName = null;
      wifiStateText = '$name 连接成功';
    } catch (_) {
      wifiStateText = '$name 连接失败，请检查网络、密码或服务配置';
    } finally {
      wifiJoining = false;
      wifiJoinName = '';
      _notify();
    }
  }

  static String _message(Object e) =>
      e.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), '');
  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    _cooldown?.cancel();
    super.dispose();
  }
}
