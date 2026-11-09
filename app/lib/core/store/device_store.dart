/// Device UI state, driven solely by an injected real backend.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../device/card_gateway.dart';
import 'app_backend.dart';
import 'device_backend.dart';
import 'store_persistence.dart';
import '../../services/recordings/recording_download_gateway.dart';
export 'device_backend.dart';

enum SyncState { idle, busy, done, failed, cancelled }

enum DeviceView { main, upg, wifi }

class DeviceStore extends ChangeNotifier {
  DeviceStore({
    CardGateway? gateway,
    DeviceBackend? backend,
    StorePersistence? persistence,
    RecordingPolicy Function()? policy,
    this._onSynced,
    this.firmwareStatusMessage,
    this.fastTransferActive,
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
  final String? Function()? firmwareStatusMessage;
  final bool Function()? fastTransferActive;
  bool _disposed = false;
  bool get liveDeviceAvailable => backend.available;
  DeviceReading? reading;
  String? lastDeviceId;
  String? get deviceIdentity => reading?.targetId ?? lastDeviceId;
  bool connected = false;
  bool scanning = false;
  bool connecting = false;
  List<DeviceChoice> scannedDevices = [];
  final Stopwatch _readingClock = Stopwatch();
  Timer? _clock;
  Timer? _cooldown;
  bool _refreshing = false;
  bool statusStale = false;
  String? statusError;
  bool recordingBusy = false;
  String? recordingError;
  int _connectionEpoch = 0;
  bool sheetOpen = false;
  DeviceView view = DeviceView.main;
  static const batteryLevel = 0; // Unknown, never a fake preset battery.
  int get battery => reading?.snapshot.batteryLevel.clamp(0, 100) ?? 0;
  bool get batteryKnown =>
      connected &&
      reading?.batteryKnown == true &&
      reading!.snapshot.batteryLevel >= 0 &&
      reading!.snapshot.batteryLevel <= 100;
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
  bool get isRecording => connected && reading?.snapshot.recording == true;
  bool get recordingKnown =>
      connected && reading?.recordingKnown == true && !statusStale;
  bool get deviceBusy =>
      recordingBusy ||
      _refreshing ||
      scanning ||
      connecting ||
      fwUpdating ||
      fwChecking ||
      syncState == SyncState.busy ||
      wifiJoining ||
      wifiScanning ||
      fastTransferPrepared ||
      fastTransferActive?.call() == true;
  bool get canControlRecording =>
      liveDeviceAvailable && recordingKnown && !deviceBusy;
  String get recordingText => !connected
      ? '未连接'
      : !recordingKnown
      ? '状态待确认'
      : isRecording
      ? '录音中'
      : '未录音';
  int get recSeconds {
    final base = reading?.recordedSeconds;
    if (base == null || base < 0 || !connected) return 0;
    final elapsed = recordingKnown && isRecording
        ? _readingClock.elapsed.inSeconds
        : 0;
    return (base + elapsed).clamp(0, 1 << 31);
  }

  String get recClockText {
    if (!recordingKnown ||
        reading?.recordedSeconds == null ||
        reading!.recordedSeconds! < 0) {
      return '—:——:——';
    }
    final s = recSeconds;
    return '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> startRecording() => _controlRecording(true);
  Future<void> stopRecording() => _controlRecording(false);

  Future<void> _controlRecording(bool enabled) async {
    if (_disposed) return;
    if (!connected || !liveDeviceAvailable) {
      _recordingFailure('未连接录音卡，请先连接设备');
      return;
    }
    if (deviceBusy) {
      _recordingFailure('设备任务正在运行，稍后重试');
      return;
    }
    if (!recordingKnown) {
      _recordingFailure('录音状态待确认，请等待状态刷新后重试');
      return;
    }
    recordingError = null;
    if (isRecording == enabled) {
      _notify();
      return;
    }
    final epoch = _connectionEpoch;
    recordingBusy = true;
    devStateIsError = false;
    devStateText = enabled ? '正在开始录音…' : '正在停止录音…';
    _notify();
    try {
      final confirmed = enabled
          ? await backend.startRecording()
          : await backend.stopRecording();
      if (_disposed || epoch != _connectionEpoch) return;
      if (!confirmed.recordingKnown ||
          confirmed.snapshot.recording != enabled) {
        throw StateError('设备未确认${enabled ? '开始' : '停止'}录音');
      }
      _accept(confirmed);
      recordingError = null;
      devStateIsError = false;
      devStateText = enabled ? '设备已确认开始录音' : '设备已确认停止录音';
    } catch (e) {
      if (_disposed || epoch != _connectionEpoch) return;
      // Never optimistically flip state or send a compensating hardware command.
      // A lost confirmation may follow an applied command: retain the last
      // reading but mark it stale until the next real status query succeeds.
      _statusFailure(e);
      _recordingFailure('${enabled ? '开始' : '停止'}录音失败：${_message(e)}');
    } finally {
      recordingBusy = false;
      _notify();
    }
  }

  void _recordingFailure(String message) {
    recordingError = message;
    devStateIsError = true;
    devStateText = message;
    _notify();
  }

  void _statusFailure(Object error) {
    statusError = _message(error);
    statusStale = true;
    _readingClock.stop();
    // Only an explicit transport/SDK disconnect proves physical disconnection.
    if (error is CardGatewayException && error.code == 'disconnected') {
      _connectionEpoch++;
      connected = false;
      reading = null;
    }
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
    if (deviceBusy) return;
    scanning = true;
    scannedDevices = [];
    devStateIsError = false;
    devStateText = '正在扫描录音卡…';
    _notify();
    try {
      scannedDevices = await backend.scan();
      devStateText = scannedDevices.isEmpty
          ? '未发现录音卡，请检查蓝牙权限和设备电源'
          : '请选择要连接的录音卡';
    } catch (e) {
      devStateIsError = true;
      devStateText = '扫描失败：${_message(e)}';
    } finally {
      scanning = false;
      _notify();
    }
  }

  Future<void> connectDevice(String id) async {
    if (deviceBusy) return;
    _connectionEpoch++;
    connecting = true;
    devStateIsError = false;
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
      devStateIsError = true;
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
    if (recordingBusy || fwUpdating) return;
    _connectionEpoch++;
    try {
      await backend.disconnect();
      connected = false;
      reading = null;
      statusStale = false;
      statusError = null;
      recordingError = null;
      _readingClock.stop();
      devStateIsError = false;
      devStateText = '已断开';
    } catch (e) {
      devStateIsError = true;
      devStateText = '断开失败：${_message(e)}';
    }
    _notify();
  }

  void _accept(DeviceReading value) {
    reading = value;
    _readingClock
      ..reset()
      ..start();
    statusStale = false;
    statusError = null;
    connected = true;
    if (value.id != null) lastDeviceId = value.id;
    wifiLast = value.connectedWifi ?? '';
  }

  Future<void> refreshFromDevice() async {
    if (_disposed || deviceBusy) return;
    _refreshing = true;
    _notify();
    final epoch = _connectionEpoch;
    try {
      final value = await backend.status();
      if (_disposed || epoch != _connectionEpoch) return;
      final wasStale = statusStale || recordingError != null;
      _accept(value);
      if (wasStale) {
        recordingError = null;
        devStateIsError = false;
        devStateText = '设备状态已刷新';
      }
    } catch (e) {
      if (_disposed || epoch != _connectionEpoch) return;
      _statusFailure(e);
      devStateIsError = true;
      devStateText = connected
          ? '状态刷新失败，保留上次读取：${_message(e)}'
          : '设备状态不可用：${_message(e)}';
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
  double? syncPercent;
  bool syncCancelling = false;
  Completer<void>? _syncDrain;
  bool get canCancelSync =>
      syncState == SyncState.busy &&
      !syncCancelling &&
      backend is CancelableSyncDeviceBackend;
  bool sourceRetained = false;
  int retainedSourceCount = 0;
  bool fastTransferPrepared = false;
  bool fastTransferPreparing = false;
  bool fastTransferCancelling = false;
  String get syncRelText {
    if (lastSync == null) return '尚未同步';
    final s = DateTime.now().difference(lastSync!).inSeconds;
    if (s < 30) return '刚刚';
    if (s < 60) return '30 秒前';
    return '${s ~/ 60} 分钟前';
  }

  String get syncText => switch (syncState) {
    SyncState.busy =>
      syncCancelling
          ? '正在取消 · 等待传输清理'
          : '${syncStage.isEmpty ? '正在同步…' : syncStage}${syncPercent == null ? '' : ' · 已收 ${syncPercent!.toStringAsFixed(0)}%'}',
    SyncState.done =>
      sourceRetained ? '已保存 · 卡端保留 $retainedSourceCount 项' : '同步成功 · 刚刚',
    SyncState.failed => '同步失败 · 点击重试',
    SyncState.cancelled => '同步已取消 · 已保存文件保留',
    SyncState.idle =>
      sourceRetained
          ? '卡端源保留 · 点击重试'
          : lastSync == null
          ? '尚未同步 · 点击同步'
          : '最近同步 · $syncRelText',
  };
  Future<bool> prepareFastTransfer() async {
    if (!connected || deviceBusy || backend is! FileTransferDeviceBackend) {
      devStateIsError = true;
      devStateText = '请先连接录音卡并等待当前任务完成';
      _notify();
      return false;
    }
    wifiJoining = true;
    fastTransferPreparing = true;
    devStateIsError = false;
    devStateText = '等待系统加入热点确认与本地文件服务就绪…';
    _notify();
    try {
      await (backend as FileTransferDeviceBackend).prepareFastTransfer();
      if (fastTransferCancelling || fastTransferActive?.call() == false) {
        return false;
      }
      fastTransferPrepared = true;
      return true;
    } catch (e) {
      fastTransferPrepared = fastTransferActive?.call() ?? false;
      devStateIsError = e is! RecordingSyncCancelled;
      devStateText = e is RecordingSyncCancelled
          ? '快传已取消；登录、已保存音频与原文保留'
          : '快传准备失败：${_message(e)}';
      return false;
    } finally {
      fastTransferPreparing = false;
      wifiJoining = fastTransferCancelling;
      _notify();
    }
  }

  Future<void> cancelFastTransfer() async {
    if (syncState == SyncState.busy || fastTransferCancelling) return;
    fastTransferCancelling = true;
    wifiJoining = true;
    _notify();
    try {
      if (backend is FileTransferDeviceBackend) {
        await (backend as FileTransferDeviceBackend).cancelFastTransfer();
      }
      fastTransferPrepared = false;
    } catch (e) {
      devStateIsError = true;
      devStateText = '快传退出失败：${_message(e)}';
    } finally {
      fastTransferPrepared = fastTransferActive?.call() ?? fastTransferPrepared;
      fastTransferCancelling = false;
      wifiJoining = fastTransferPreparing;
      _notify();
    }
  }

  Future<void> cancelSync() async {
    if (!canCancelSync) return;
    final drain = _syncDrain;
    syncCancelling = true;
    _notify();
    try {
      await (backend as CancelableSyncDeviceBackend).cancelSync();
    } catch (e) {
      syncError = '取消请求失败：${_message(e)}；等待原任务结束';
      devStateIsError = true;
      devStateText = syncError!;
    } finally {
      // Never unlock from the cancel ACK. The original sync owns final cleanup
      // and partial-import publication; no login/audio/text job is cancelled.
      await drain?.future;
    }
  }

  Future<void> syncNow({bool fast = false}) async {
    if (syncState == SyncState.busy ||
        syncState == SyncState.done ||
        fwUpdating ||
        recordingBusy ||
        wifiJoining ||
        fastTransferCancelling) {
      return;
    }
    syncState = SyncState.busy;
    syncError = null;
    syncStage = '正在同步…';
    syncPercent = null;
    syncCancelling = false;
    _syncDrain = Completer<void>();
    sourceRetained = false;
    retainedSourceCount = 0;
    var finalState = SyncState.failed;
    _notify();
    try {
      void progress(TaskProgress p) {
        syncStage = p.stage;
        syncPercent = p.percent?.isFinite == true
            ? p.percent!.clamp(0.0, 100.0)
            : null;
        _notify();
      }

      if (fast) {
        if (backend is! FileTransferDeviceBackend) throw StateError('快传服务未配置');
        await (backend as FileTransferDeviceBackend).fastSync(
          _policy(),
          progress,
        );
      } else {
        await backend.sync(_policy(), progress);
      }
      final outcome = backend is FileTransferDeviceBackend
          ? (backend as FileTransferDeviceBackend).lastSyncOutcome
          : null;
      retainedSourceCount = outcome?.retainedSourceCount ?? 0;
      sourceRetained = retainedSourceCount > 0;
      if (!sourceRetained) lastSync = DateTime.now();
      finalState = SyncState.done;
      await _persist();
    } catch (e) {
      if (e is RecordingSyncCancelled) {
        finalState = SyncState.cancelled;
        devStateIsError = false;
        devStateText = '同步已取消；登录、已保存音频与原文保留';
      } else {
        syncError = '同步失败：${_message(e)}';
        devStateIsError = true;
        devStateText = syncError!;
      }
    } finally {
      try {
        if (fast) fastTransferPrepared = fastTransferActive?.call() ?? false;
        // Partial imports are real local data even when a later transfer fails.
        if (_onSynced != null) await _onSynced();
      } catch (e) {
        syncError = '文件已保留，记录刷新或处理失败：${_message(e)}';
        devStateIsError = true;
        devStateText = syncError!;
        if (finalState != SyncState.cancelled) finalState = SyncState.failed;
      } finally {
        syncState = finalState;
        syncCancelling = false;
        _syncDrain!.complete();
        _syncDrain = null;
        if (syncState == SyncState.done && !_disposed) {
          _cooldown?.cancel();
          _cooldown = Timer(const Duration(seconds: 10), () {
            syncState = SyncState.idle;
            _notify();
          });
        }
        _notify();
      }
    }
  }

  bool fwUpdating = false;
  bool fwDone = false;
  bool fwChecking = false;
  double fwProgress = 0;
  double? fwPercent;
  String fwValText = '尚未检查更新';
  String devStateText = '';
  bool devStateIsError = false;
  bool fwHasError = false;
  String fwStateText = '';
  String fwStageText = '等待固件任务';
  FirmwareOffer? offer;
  String get fwPctText => fwPercent == null ? '进度未知' : '${fwPercent!.round()}%';
  static String _versionLabel(String? value) =>
      value == null || value.trim().isEmpty ? '未知' : value;
  String _versionComparison(String? current, String? target) {
    final installed = _versionLabel(connected ? current : null);
    return offer == null || target == null || target.trim().isEmpty
        ? installed
        : '$installed → $target';
  }

  String get mainVersionText =>
      _versionComparison(reading?.snapshot.fwVersion, offer?.targetMainVersion);
  String get wifiVersionText => _versionComparison(
    reading?.snapshot.wifiVersion,
    offer?.targetWifiVersion,
  );
  Future<void> checkFirmware() async {
    if (fwChecking || fwUpdating || recordingBusy) return;
    fwChecking = true;
    fwHasError = false;
    fwStateText = '正在检查固件清单…';
    _notify();
    try {
      offer = await backend.firmwareOffer();
      fwHasError = offer != null && !offer!.valid;
      fwValText = offer == null
          ? firmwareStatusMessage?.call() ?? '没有适用更新'
          : offer!.valid
          ? '有可用更新'
          : '固件包信息不完整';
      fwStateText = offer?.notes ?? firmwareStatusMessage?.call() ?? '没有适用更新';
    } catch (e) {
      offer = null;
      fwHasError = true;
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
      fwHasError = true;
      fwStateText = '升级被拒绝：请连接目标设备并确认有效固件包与校验值';
      _notify();
      return;
    }
    if (deviceBusy) {
      fwStateText = '设备任务正在运行，稍后重试';
      _notify();
      return;
    }
    fwUpdating = true;
    fwDone = false;
    fwHasError = false;
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
      devStateIsError = false;
      devStateText =
          '已更新到 主控 ${verified.snapshot.fwVersion} / Wi-Fi ${verified.snapshot.wifiVersion}';
    } catch (e) {
      fwHasError = true;
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
        recordingBusy ||
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
      final frequencyKnown =
          wifiScanRes.isNotEmpty &&
          wifiScanRes.every((r) => r.frequencyMhz != null);
      wifiStateText =
          '扫描完成 · 附近可见 ${wifiScanRes.length} 个${frequencyKnown ? ' 2.4GHz ' : ''}网络';
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
    if (!wifiInRange(name) || wifiJoining || fwUpdating || recordingBusy) {
      return;
    }
    await _join(name, () => backend.connectSavedWifi(name));
  }

  Future<void> wifiJoinNew(String password) async {
    final network = wifiScanRes.where((n) => n.name == wifiSelName).firstOrNull;
    if (network == null || wifiJoining || fwUpdating || recordingBusy) return;
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
    _connectionEpoch++;
    _readingClock.stop();
    _clock?.cancel();
    _cooldown?.cancel();
    super.dispose();
  }
}
