/// 录音卡设备状态机 —— 状态胶囊弹层 / Wi-Fi 配网 / 固件升级的全部业务逻辑。
///
/// 数据全部来自真实硬件（[CardGateway] → card_bridge FFI → reai-card-sdk BLE）。
/// 桥不可用（模拟器/未链接）时一律显式失败，界面呈现"需要连接录音卡"，
/// 不再用预置数据冒充真实设备状态。
///
/// 可靠性约定（照参考工程的血泪教训）：
/// - **连接代次 epoch**：每次 connect/disconnect 自增，所有异步回调回来先比 epoch，
///   过期结果直接丢弃（FFI 回调跨线程，晚到是常态）。
/// - **心跳**：连接期间每 20s 刷一次 snapshot，连续失败 2 次判掉线并重连（指数退避）。
/// - **独占守卫**：OTA 期间禁止同步/录音等其它命令，避免与 DFU 抢链路。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/audio/live_audio_recorder.dart';
import '../../services/audio/pcm_ring_buffer.dart';
import '../../services/audio/phone_mic_service.dart';
import '../../services/legacy_upgrade/legacy_upgrade_controller.dart';
import '../../services/legacy_upgrade/legacy_upgrade_gateway.dart';
import '../../services/legacy_upgrade/legacy_upgrade_models.dart';
import '../../services/platform/live_activity_service.dart';
import '../../services/watch/watch_hardware_service.dart';
import '../device/card_gateway.dart';
import '../platform/bluetooth_permission.dart';

export '../device/card_gateway.dart' show HardwareButtonEvent;

enum SyncState { idle, busy, done }

/// 最近一次同步是谁触发的：自动（停止录音/后台）还是用户点同步行。
enum SyncTrigger { auto, manual }

enum DeviceView { main, upg, wifi, btn }

/// 与录音卡的蓝牙连接状态：未连接时顶栏胶囊变灰，点开进扫描流程。
enum LinkState {
  unknown,
  unsupported,
  disconnected,
  scanning,
  connecting,

  /// 看门狗判定掉线、正在自动重连：胶囊蓝点（区分"从没连上"与"连着断了"）。
  reconnecting,
  connected,
}

class WifiNet {
  final String name;
  final int signal; // 1-3，由 RSSI 折算
  final bool lock;
  const WifiNet(this.name, this.signal, {this.lock = false});
}

class SavedWifi {
  final String name;
  const SavedWifi(this.name);
}

/// 固件阶段：与设计稿两阶段一致。
enum FwStage { idle, checking, main, wifi, done, failed }

class DeviceStore extends ChangeNotifier {
  DeviceStore({
    CardGateway? gateway,
    bool autoStart = false,
    PhoneMicBackend? phoneMicBackend,
    PhoneMicRecorder? phoneMicRecorder,
    LiveActivityService? liveActivityService,
    WatchHardwareService? watchHardware,
    LegacyUpgradeController? legacyUpgrade,
    DateTime Function()? now,
  }) : _bleGateway = gateway ?? realOrUnsupported(),
       _ownsWatchHardware = watchHardware == null,
       _watchHardware = watchHardware ?? WatchHardwareService(),
       _autoStart = autoStart,
       _phoneMicBackend = phoneMicBackend ?? PlatformPhoneMicBackend(),
       _ownsPhoneMicRecorder = phoneMicRecorder == null,
       _phoneMicRecorder = phoneMicRecorder ?? PhoneMicRecorder(),
       _liveActivityService = liveActivityService ?? LiveActivityService(),
       _ownsLegacyUpgrade = legacyUpgrade == null,
       _now = now ?? DateTime.now {
    _gateway = WatchCompositeCardGateway(
      bleGateway: _bleGateway,
      watchService: _watchHardware,
    );
    this.legacyUpgrade = legacyUpgrade ??
        LegacyUpgradeController(
          gateway: BridgeLegacyUpgradeGateway(_gw),
          onAutoReconnect: _autoReconnectAfterLegacyUpgrade,
        );
    _watchHardware.addListener(_onWatchHardwareChanged);
    if (autoStart) {
      unawaited(restoreLink());
      _startHeartbeat();
    }
  }

  /// 生产环境在启动时开启心跳；widget 测试传 false，避免悬挂定时器。
  final bool _autoStart;
  final DateTime Function() _now;

  final CardGateway _bleGateway;
  final bool _ownsWatchHardware;
  final WatchHardwareService _watchHardware;
  late final WatchCompositeCardGateway _gateway;
  final PhoneMicBackend _phoneMicBackend;
  final bool _ownsPhoneMicRecorder;
  final PhoneMicRecorder _phoneMicRecorder;
  final LiveActivityService _liveActivityService;
  final bool _ownsLegacyUpgrade;
  late final LegacyUpgradeController legacyUpgrade;

  /// 全部真实命令与实时流收包都经它转发：发出、返回与收到音频帧都视为"蓝牙活动"，供看门狗顺延。
  late final CardGateway _gw = ActivityGateway(
    _gateway,
    _markLinkActivity,
    onRealtimeError: _onRealtimeStreamError,
  );

  /// 供其它服务复用同一条硬件链路（录音同步、实时流、诊断）。
  CardGateway get gateway => _gw;
  WatchHardwareService get watchHardware => _watchHardware;
  Stream<LiveAudioSlice> get watchAudioSlices => _watchHardware.audioSlices;

  /// 真实桥或已开启 Apple Watch 协同是否就绪。
  bool get liveDeviceAvailable => _gateway.available;
  bool get canScan => _gateway.available;

  /// 桥版本串（含 SDK 版本），排障与「关于」页使用。
  String? get bridgeVersion {
    final gateway = _bleGateway;
    return gateway is RealCardGateway ? gateway.bridgeVersion : null;
  }

  // ── 蓝牙连接状态 ───────────────────────────────────────────
  static const Duration scanResultTtl = Duration(seconds: 60);

  LinkState linkState = LinkState.unknown;
  List<CardDevice> discovered = const [];
  String? linkError;
  String? connectedName;
  DeviceKind activeKind = DeviceKind.cardV2;
  HardwareCapabilities activeCapabilities = HardwareCapabilities.cardV2;
  String activeModelLabel = DeviceKind.cardV2.displayModel;

  DateTime? _bleScanSeenAt;
  bool _scanExpiredByTimer = false;
  bool _sheetAttached = false;
  Timer? _scanExpiryTimer;

  static bool isBleDiscoveredDevice(CardDevice device) =>
      device.deviceKind != DeviceKind.appleWatch;

  bool get hasBleDiscovered => discovered.any(isBleDiscoveredDevice);

  bool get isBleScanExpired {
    if (isConnected || isLinkBusy || !hasBleDiscovered) return false;
    if (_scanExpiredByTimer) return true;
    final seenAt = _bleScanSeenAt;
    if (seenAt == null) return false;
    return _now().difference(seenAt) >= scanResultTtl;
  }

  bool isDeviceScanExpired(CardDevice device) {
    if (!isBleDiscoveredDevice(device) || isConnected || isLinkBusy) {
      return false;
    }
    if (_scanExpiredByTimer) return true;
    final anchor = device.lastSeenAt ?? _bleScanSeenAt;
    if (anchor == null) return false;
    return _now().difference(anchor) >= scanResultTtl;
  }

  DateTime? _computeBleScanAnchor(List<CardDevice> list, DateTime completedAt) {
    DateTime? anchor;
    for (final device in list) {
      if (!isBleDiscoveredDevice(device)) continue;
      final seen = device.lastSeenAt;
      final effective =
          seen != null && !seen.isAfter(completedAt) ? seen : completedAt;
      if (anchor == null || effective.isBefore(anchor)) {
        anchor = effective;
      }
    }
    return anchor;
  }

  void _stopScanExpiryTimer() {
    _scanExpiryTimer?.cancel();
    _scanExpiryTimer = null;
  }

  void _scheduleScanExpiryTimer() {
    _stopScanExpiryTimer();
    if (!sheetOpen || isConnected || isLinkBusy || !hasBleDiscovered) {
      return;
    }
    if (isBleScanExpired) {
      _scanExpiredByTimer = true;
      return;
    }
    if (!_sheetAttached) {
      // 无 UI 挂载（如纯状态机单元测试）时不挂起定时器，避免悬挂到测试清理前。
      return;
    }
    final seenAt = _bleScanSeenAt;
    if (seenAt == null) return;
    final remaining = scanResultTtl - _now().difference(seenAt);
    if (remaining <= Duration.zero) {
      _scanExpiredByTimer = true;
      return;
    }
    _scanExpiryTimer = Timer(remaining, _onScanExpiryTimer);
  }

  void _onScanExpiryTimer() {
    _scanExpiryTimer = null;
    if (!sheetOpen || isConnected || isLinkBusy || !hasBleDiscovered) {
      return;
    }
    _scanExpiredByTimer = true;
    notifyListeners();
  }

  /// UI 展示的设备短名：剥离代际广播前缀（仅保留下划线后的蓝牙编号）。
  /// [connectedName] 保持完整原始广播名供 DFU 重连等底层匹配使用。
  String get connectedDisplayName {
    final raw = connectedName?.trim() ?? '';
    if (raw.isEmpty) return '录音卡';
    return DeviceKind.bleShortId(raw);
  }

  /// 点一机 V1 硬件拍照事件到达时触发（供外层同步硬件抓拍照片）。
  VoidCallback? onHardwarePhotoCaptured;

  final StreamController<HardwareButtonEvent> _hardwareButtonCtrl =
      StreamController<HardwareButtonEvent>.broadcast();

  /// 点一机 V1 硬件物理按键事件流（down / up / click / double_click / long_press_*）。
  Stream<HardwareButtonEvent> get hardwareButtonEvents =>
      _hardwareButtonCtrl.stream;

  /// 蓝牙授权状态（iOS 专用；Android 恒为 unknown 由系统自行申请）。
  BluetoothAuthorization bleAuth = BluetoothAuthorization.unknown;
  final BluetoothPermission _permission = const BluetoothPermission();

  /// 连接代次：异步结果回来时比对，过期丢弃。
  int _epoch = 0;

  bool get isConnected => linkState == LinkState.connected;

  /// 看门狗判掉线、正在自动重连（胶囊蓝点）。
  bool get isReconnecting => linkState == LinkState.reconnecting;
  bool get isLinkBusy =>
      linkState == LinkState.scanning ||
      linkState == LinkState.connecting ||
      linkState == LinkState.reconnecting;

  /// 启动时核对一次：桥可用且已连着卡 → 已连接；否则未连接。
  Future<void> restoreLink() async {
    final epoch = ++_epoch;
    bleAuth = await _permission.status();
    if (!_gateway.available) {
      linkState = LinkState.unsupported;
      linkError = '此设备不支持连接录音卡';
      notifyListeners();
      return;
    }
    try {
      final snapshot = await _gw.snapshot();
      if (epoch != _epoch) return;
      _stopScanExpiryTimer();
      linkState = LinkState.connected;
      linkError = null;
      _applySnapshot(snapshot);
      await _reconcileRecordingOnConnect();
      if (epoch != _epoch) return;
      _startHeartbeat();
      if (sheetOpen) {
        _startSheetWatch();
        unawaited(prefetchSummaryInfo());
      } else if (_autoStart) {
        unawaited(prefetchSummaryInfo());
      }
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      // 未连接是正常初始态，不算错误；其它错误如实呈现
      linkState = LinkState.disconnected;
      linkError = e.kind == CardErrorKind.disconnected ? null : e.message;
    }
    notifyListeners();
  }

  /// 支持的硬件蓝牙广播名前缀族：
  /// - `DYJV2_*`：录音卡 V2
  /// - `DYJ_*`：点一机 V1
  /// - `REAI_VB_*`：语音 AI 键盘 V2.1
  static const deviceNamePrefix = 'DYJ';

  bool _getSeedLinkEnabled = false;
  bool _omiLinkEnabled = false;
  bool _feishuLinkEnabled = false;

  bool get getSeedLinkEnabled => _getSeedLinkEnabled;
  bool get omiLinkEnabled => _omiLinkEnabled;
  bool get feishuLinkEnabled => _feishuLinkEnabled;

  /// 只展示我们自己的录音卡/点一机/键盘（按需含已开启的 Apple Watch 与第三方硬件）。
  ///
  /// [listAll] 仅供临时排障直通（2026-11-16 Omi 联调用过一次）：扫描列表无过滤列出全部
  /// BLE 设备，识别与开关过滤后置恢复——连接阶段仍按设备 kind 走对应驱动。
  static bool isOurDevice(
    CardDevice device, {
    bool allowWatch = true,
    bool allowGetSeed = false,
    bool allowOmi = false,
    bool allowFeishu = false,
    bool listAll = false,
  }) {
    if (listAll) return true;
    final kind = device.kind ?? DeviceKind.fromBleName(device.name);
    if (kind == null) return false;
    return switch (kind) {
      DeviceKind.cardV2 || DeviceKind.dyjV1 || DeviceKind.boardV21 => true,
      DeviceKind.appleWatch => allowWatch,
      DeviceKind.getSeedGsc10 => allowGetSeed,
      DeviceKind.omiCv1 => allowOmi,
      DeviceKind.feishuD3200 => allowFeishu,
    };
  }

  Future<void> setExtHardwareEnabled({
    bool? getSeed,
    bool? omi,
    bool? feishu,
  }) async {
    final nextGetSeed = getSeed ?? _getSeedLinkEnabled;
    final nextOmi = omi ?? _omiLinkEnabled;
    final nextFeishu = feishu ?? _feishuLinkEnabled;
    if (nextGetSeed == _getSeedLinkEnabled &&
        nextOmi == _omiLinkEnabled &&
        nextFeishu == _feishuLinkEnabled) {
      return;
    }
    _getSeedLinkEnabled = nextGetSeed;
    _omiLinkEnabled = nextOmi;
    _feishuLinkEnabled = nextFeishu;
    if ((!nextGetSeed && isConnected && activeKind == DeviceKind.getSeedGsc10) ||
        (!nextOmi && isConnected && activeKind == DeviceKind.omiCv1) ||
        (!nextFeishu && isConnected && activeKind == DeviceKind.feishuD3200)) {
      await disconnectSafely();
    }
    if (discovered.isNotEmpty) {
      discovered = discovered
          .where(
            (d) => isOurDevice(
              d,
              allowWatch: watchHardware.linkEnabled,
              allowGetSeed: _getSeedLinkEnabled,
              allowOmi: _omiLinkEnabled,
              allowFeishu: _feishuLinkEnabled,
            ),
          )
          .toList(growable: false);
      if (!hasBleDiscovered) {
        _stopScanExpiryTimer();
        _bleScanSeenAt = null;
        _scanExpiredByTimer = false;
      }
    }
    notifyListeners();
  }

  /// RSSI → 1~3 格信号（与 Wi-Fi 列表同一套阈值，UI 直接复用）。
  static int signalOf(int? rssi) => _signalOf(rssi ?? -100);

  /// 开启或关闭 Apple Watch 硬件联动；关闭时若当前正连着 Watch 则安全断开。
  Future<void> setWatchLinkEnabled(bool enabled) async {
    await _watchHardware.setLinkEnabled(enabled);
    if (!enabled && isConnected && activeKind == DeviceKind.appleWatch) {
      await disconnectSafely();
    } else {
      notifyListeners();
    }
  }

  /// 主动请求 Apple Watch 冲刷本地队列并将已传回切片送入端侧管线。
  Future<bool> flushWatchRecordingSlice() async {
    final count = await _watchHardware.flushAndDrain();
    return count > 0;
  }

  void _onWatchHardwareChanged() {
    if (isConnected && activeKind == DeviceKind.appleWatch) {
      if (_watchHardware.consumeUnexpectedDisconnect()) {
        unawaited(_retryReconnect());
        return;
      }
      final prevRec = _liveRecording ?? false;
      final prevClock = _clockTicks;
      _applySnapshot(_watchHardware.toSnapshot());
      final s = _watchHardware.currentStatus;
      final faultMsg = s.lastError?.trim() ?? '';
      if (prevRec && !s.isRecording) {
        if (faultMsg.isNotEmpty) {
          recordingError = faultMsg;
          if (_phoneStandbyArmed) {
            unawaited(_triggerPhoneFailover(carrySecOverride: prevClock));
          }
        } else {
          _phoneStandbyArmed = false;
        }
      }
    } else if (!isConnected &&
        linkState != LinkState.connecting &&
        linkState != LinkState.reconnecting &&
        _failoverPhoneRecording &&
        _lastDevice?.id == WatchHardwareService.watchDeviceId &&
        _watchHardware.linkEnabled) {
      final s = _watchHardware.currentStatus;
      if (s.supported &&
          s.paired &&
          s.watchAppInstalled &&
          !s.linkLost &&
          !_watchHardware.isOutOfRangeDisconnected &&
          s.isRecording) {
        unawaited(connectTo(_lastDevice!));
      }
    }
    notifyListeners();
  }

  /// 扫描附近硬件（DYJ / REAI_VB 前缀蓝牙硬件 + 开启联动后的已配对 Apple Watch）。
  Future<void> startScan() async {
    if (isLinkBusy || !_gateway.available) {
      if (!_gateway.available) {
        linkState = LinkState.unsupported;
        linkError = '此设备不支持连接录音卡';
        notifyListeners();
      }
      return; // 防重入：扫描中再点不重复发起（SDK 要求串行）
    }
    // 读一次授权状态用于解释失败原因。**不在这里阻塞等待用户点弹窗**：
    // 底层（Rust/CoreBluetooth）在扫描时会自己触发同一个系统对话框，
    // 这里若同步等 30 秒，用户看到的会是"点了扫描没反应"。
    bleAuth = await _permission.status();
    if (!_watchHardware.availableForScan &&
        (bleAuth == BluetoothAuthorization.denied ||
            bleAuth == BluetoothAuthorization.restricted)) {
      linkState = LinkState.disconnected;
      linkError = bleAuth.hint;
      notifyListeners();
      return;
    }

    final epoch = ++_epoch;
    _stopScanExpiryTimer();
    _bleScanSeenAt = null;
    _scanExpiredByTimer = false;
    linkState = LinkState.scanning;
    linkError = null;
    discovered = const [];
    notifyListeners();
    try {
      final list = await _gw.scan();
      if (epoch != _epoch) return;
      // 近的设备排前面：RSSI 越大信号越强（-50 比 -80 近）。无 RSSI 的排最后。
      discovered = [
        for (final device in list)
          if (isOurDevice(
            device,
            allowWatch: watchHardware.linkEnabled,
            allowGetSeed: _getSeedLinkEnabled,
            allowOmi: _omiLinkEnabled,
            allowFeishu: _feishuLinkEnabled,
          ))
            device,
      ]..sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
      final completedAt = _now();
      _bleScanSeenAt = _computeBleScanAnchor(discovered, completedAt);
      _scanExpiredByTimer = false;
      linkState = LinkState.disconnected;
      linkError = discovered.isEmpty
          ? (bleAuth == BluetoothAuthorization.notDetermined
              ? '请允许「录音卡」使用蓝牙后重试'
              : '没有找到附近的录音卡，请确认录音卡已开机')
          : null;
      _scheduleScanExpiryTimer();
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      _stopScanExpiryTimer();
      _bleScanSeenAt = null;
      _scanExpiredByTimer = false;
      discovered = const [];
      linkState = LinkState.disconnected;
      linkError = e.message;
    }
    notifyListeners();
  }

  Future<void> connectTo(CardDevice device) async {
    if (linkState == LinkState.connecting) return;
    if (isDeviceScanExpired(device)) {
      linkError = '蓝牙设备列表已过期，请重新扫描';
      notifyListeners();
      return;
    }
    final epoch = ++_epoch;
    _stopScanExpiryTimer();
    linkState = LinkState.connecting;
    linkError = null;
    notifyListeners();
    _markLinkActivity();
    try {
      var snapshot = await _gw.connect(
        device.id,
        name: device.name,
        deviceKind: device.deviceKind.code,
      );
      if (epoch != _epoch) return;
      snapshot ??= await _gw.snapshot().timeout(_snapshotTimeout);
      if (epoch != _epoch) return;
      _markLinkActivity();
      activeKind = device.deviceKind;
      activeCapabilities = device.resolvedCapabilities;
      activeModelLabel = device.modelLabel;
      connectedName = device.name;
      // 记住这台设备：掉线重连直接拿 id 直连，不靠扫描（已连接设备不广播）
      _lastDevice = device;
      linkState = LinkState.connected;
      linkError = null;
      _applySnapshot(snapshot);
      await _reconcileRecordingOnConnect();
      if (epoch != _epoch) return;
      _eventSeq = 0;
      _startHeartbeat();
      if (sheetOpen) {
        _startSheetWatch();
      }
      unawaited(_afterConnect(epoch));
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      final mismatch = LegacyUpgradeMismatch.tryParse(device, e);
      if (mismatch != null) {
        linkState = LinkState.disconnected;
        linkError = null;
        sheetOpen = false;
        _stopSheetWatch();
        unawaited(_releaseLink());
        legacyUpgrade.triggerFromMismatch(mismatch);
        notifyListeners();
        return;
      }
      linkState = LinkState.disconnected;
      linkError = e.message;
      _scheduleScanExpiryTimer();
      unawaited(_releaseLink());
    } on TimeoutException {
      if (epoch != _epoch) return;
      linkState = LinkState.disconnected;
      linkError = '读取设备状态超时，请重试连接';
      _scheduleScanExpiryTimer();
      unawaited(_releaseLink());
    }
    notifyListeners();
  }

  /// 连上后的收尾：若快照缺失关键状态则补拉一次，并立刻预取概要与版本检查。
  Future<void> _afterConnect(int epoch) async {
    if (epoch != _epoch || !isConnected) return;
    if (_fwVersionCode == 0 || _liveBattery == null) {
      await refreshFromDevice();
      if (epoch != _epoch) return;
    }
    await prefetchSummaryInfo();
  }

  Future<bool> _autoReconnectAfterLegacyUpgrade(CardDevice updated) async {
    await connectTo(updated);
    if (!isConnected) return false;
    sheetOpen = true;
    view = DeviceView.main;
    _startSheetWatch();
    notifyListeners();
    return true;
  }

  /// 用户主动断开：先把会占用链路的状态收干净，再断。
  ///
  /// 顺序：停录音 → 关实时流 → 停同步 → 断开。跳过任一步都可能留下半截会话，
  /// 下次连接时设备状态与 App 对不上（这次 code -2 就吃过这个亏）。
  Future<void> disconnectSafely() async {
    _phoneStandbyArmed = false;
    _hwRecordingStartedAt = null;
    if (isRecording) {
      try {
        await _gw.stopRecording().timeout(const Duration(seconds: 5));
      } on Object {
        // 停不下来也要继续断：不能因为一条命令失败就把用户卡在未断开状态
      }
      _liveRecording = false;
    }
    try {
      await _gw.closeRealtime().timeout(const Duration(seconds: 3));
    } on Object {
      // 同上
    }
    await disconnectDevice();
  }

  Future<void> disconnectDevice() async {
    final epoch = ++_epoch;
    _phoneStandbyArmed = false;
    _hwRecordingStartedAt = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _eventWatch?.cancel();
    _eventWatch = null;
    _stopSheetWatch();
    _lastDevice = null;
    CardDisconnectReport? report;
    String? failure;
    try {
      // 桥会先停事件泵/实时流再断，并如实回报链路是否释放；
      // 不能把"命令发出去了"当"已经断开"——那正是设备端一直不广播的成因。
      report = await _gw.disconnect().timeout(const Duration(seconds: 12));
    } on TimeoutException {
      failure = '断开超时，蓝牙链路可能仍在连接';
    } on CardException catch (e) {
      // 桥不可用（模拟器）或已经断过：都不该把用户卡在"未断开"上
      failure = e.kind == CardErrorKind.unavailable ? null : e.message;
    }
    if (epoch != _epoch) return;
    _resetLiveState();
    linkState = LinkState.disconnected;
    connectedName = null;
    if (!_phoneRecording) {
      unawaited(_liveActivityService.stopLocalRecordingActivity());
    }
    linkError = failure ??
        (report != null && !report.released
            ? '蓝牙链路未确认释放，请重试连接后再断开'
            : null);
    if (linkError != null) debugPrint('[disconnect] $linkError');
    if (sheetOpen && hasBleDiscovered) {
      _scheduleScanExpiryTimer();
    }
    notifyListeners();
  }

  void _resetLiveState() {
    _stopClock();
    _hwRecordingStartedAt = null;
    _liveBattery = null;
    _liveCharging = null;
    _liveRecording = null;
    _recordSession = null;
    _clockTicks = 0;
    _fwVersion = '';
    _wifiVersion = '';
    _fwVersionCode = 0;
    _wifiVersionCode = 0;
    _otaMainInfo = null;
    _otaWifiInfo = null;
    _otaChecked = false;
    _wifiSummaryProbed = false;
    _storageFreeMb = null;
    _storageTotalMb = null;
    deviceWifiOpen = null;
    activeKind = DeviceKind.cardV2;
    activeCapabilities = HardwareCapabilities.cardV2;
    activeModelLabel = DeviceKind.cardV2.displayModel;
  }

  // ── 设备事件跟随（本地内存队列，零蓝牙流量）─────────────────
  Timer? _sheetWatch;
  Timer? _eventWatch;

  /// 弹层打开期间每 200ms 读一次本地事件队列：设备侧按键/开关/电源变化时界面立刻跟上。
  /// 只在弹层可见时高频跑，关掉即退回后台 1s 节拍，不额外耗蓝牙电。
  void _startSheetWatch() {
    _sheetWatch?.cancel();
    _sheetWatch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!sheetOpen || !isConnected) {
        _stopSheetWatch();
        return;
      }
      unawaited(_pullDeviceEvents());
    });
  }

  /// 事件队列里的序号：下一次只取比它新的。
  int _eventSeq = 0;

  /// 供测试或外部主动触发一次设备事件消费（autoStart=false 时无后台定时器）。
  Future<void> pollEventsNow() => _pullDeviceEvents();

  /// 取走设备主动推送的事件（录音开关、电源/电量、物理语音键、相机拍照、被动断连）并应用到状态。
  Future<void> _pullDeviceEvents() async {
    if (fwUpdating) return;
    try {
      final batch = await _gw.pullEvents(after: _eventSeq);
      if (batch.seq == _eventSeq && batch.events.isEmpty) return;
      _eventSeq = batch.seq;

      if (batch.disconnectedEvents.isNotEmpty && isConnected) {
        unawaited(_retryReconnect());
        return;
      }

      var changed = false;

      // 录音状态变化（拨杆 / 按键 / 固件自停）：直接改状态，不等下次查设备
      for (final item in batch.recordEvents) {
        final status = item['event']?['status'];
        if (status is! Map<String, dynamic>) continue;
        _applyRecordStatus(status);
        changed = true;
      }

      // 电源/充电/电量主动上报：插拔电源或充饱时立即更新，不等轮询
      for (final item in batch.powerEvents) {
        final battery = item['event']?['battery'];
        if (battery is! Map<String, dynamic>) continue;
        final level = (battery['level'] as num?)?.toInt();
        if (level != null && level > 0) {
          _liveBattery = level.clamp(1, 100);
        }
        if (battery['isCharging'] is bool) {
          _liveCharging = battery['isCharging'] as bool;
        }
        changed = true;
      }

      // 语音 AI 键盘物理语音键按下：翻转统一录音开关
      for (final item in batch.voiceKeyEvents) {
        if (item['event']?['pressed'] == true && !recordingBusy) {
          unawaited(toggleRecording());
          break;
        }
      }

      // 点一机 V1 硬件按键拍照：通知外层拉取新照片
      if (batch.cameraEvents.isNotEmpty) {
        onHardwarePhotoCaptured?.call();
      }

      // 物理按键手势事件（点一机 V1 down / up / click / double_click / long_press_*）
      for (final btnEv in batch.buttonEvents) {
        if (!_hardwareButtonCtrl.isClosed) {
          _hardwareButtonCtrl.add(btnEv);
        }
      }

      if (changed) notifyListeners();
    } on CardException {
      // 队列读不到不影响主链路：看门狗负责判掉线
    }
  }

  /// 把设备推来的录音状态落到本地（与快照里的 record 段同构）。
  void _applyRecordStatus(Map<String, dynamic> status) {
    final recording = status['isRecording'] == true;
    final session = status['session'];
    if (recording && session is String && session.isNotEmpty) {
      _recordSession = session;
    } else if (!recording) {
      _recordSession = null;
    }
    // 固件自停时会带 error 码（如存储异常）或 errorMessage（如手表存储不足）：必须让用户看见原因，
    // 不能只是把开关悄悄关掉。参考实现会把整条 RECORD_STATUS 原样展示。
    final error = status['error'];
    final errorMessage = status['errorMessage'];
    final hasErrorMessage =
        errorMessage is String && errorMessage.trim().isNotEmpty;
    final hasDeviceFault = error is num || hasErrorMessage;
    if (error is num) {
      recordingError = '录音中断（设备错误码 ${error.toInt()}）';
    } else if (hasErrorMessage) {
      recordingError = errorMessage.trim();
    } else if (recording) {
      recordingError = null; // 新一轮录音开始，清掉上次的失败
    }
    if (recording == (_liveRecording ?? false)) {
      if (!recording && !hasDeviceFault) {
        _phoneStandbyArmed = false;
      }
      return;
    }
    _liveRecording = recording;
    final carrySec = _clockTicks;
    _clockTicks = 0;
    if (!recording) {
      _stopClock();
      _hwRecordingStartedAt = null;
      if (hasDeviceFault && _phoneStandbyArmed) {
        // 硬件因故障/存储满意外停止录音（非用户主动停录）：自动启动手机麦克风保底接力
        unawaited(_triggerPhoneFailover(carrySecOverride: carrySec));
      } else {
        // 用户在硬件机身拨杆/按键主动停止录音：解除待命并关闭灵动岛实况
        _phoneStandbyArmed = false;
        if (!_phoneRecording) {
          unawaited(_liveActivityService.stopLocalRecordingActivity());
        }
      }
      return;
    }
    _hwRecordingStartedAt = DateTime.now();
    _phoneStandbyArmed = true;
    if (_clockUsers > 0) _startClock();
    if (_phoneRecording && !_otaHandoverPhoneRecording) {
      unawaited(
        stopPhoneRecording(keepStandbyArmed: true, stopLiveActivity: false),
      );
    }
    _syncLiveActivity();
  }



  /// 宿主挂载（UI 就绪）：允许为开着的连接列表安排过期定时器。
  void markSheetAttached() {
    _sheetAttached = true;
    if (sheetOpen && hasBleDiscovered && !isConnected && !isLinkBusy) {
      _scheduleScanExpiryTimer();
    }
  }

  /// 宿主被卸载（页面销毁/热重载）：登记弹层已关并停掉轮询，不发通知。
  void markSheetDetached() {
    _sheetAttached = false;
    sheetOpen = false;
    _stopSheetWatch();
    _stopScanExpiryTimer();
  }

  void _stopSheetWatch() {
    _sheetWatch?.cancel();
    _sheetWatch = null;
  }

  // ── 心跳（看门狗）与重连 ───────────────────────────────────
  //
  // 规则（2026-11-10 owner 定稿）：
  // 1. 每 30 秒查一次状态；**若这 30 秒内发生过任何蓝牙传输，就顺延**——
  //    只要还在用，看门狗永远不额外发查询，避免和正常通信反复抢链路。
  // 2. 查不通 **一次** 即判掉线，胶囊立刻转蓝点重连（不再等失败两次）。
  // 3. 重连**只试一次**、且用记住的设备标识直连——不走扫描：设备已连接时
  //    不再广播，扫描找不到它，这正是"断了以后再也连不回去"的老根因。
  // 4. 重连成功回绿/橙；失败回灰「无设备」。
  static const heartbeatIdle = Duration(seconds: 30);
  static const recordingHeartbeatIdle = Duration(seconds: 10);
  static const _reconnectDelay = Duration(milliseconds: 400);

  /// 重连只发 connect（不再预拉快照），但桥内要先扫描（4s→6s 两档）再建链路，
  /// 上限给到 20s，避免把"正在重连"误判成失败。
  static const _retryConnectTimeout = Duration(seconds: 25);

  Timer? _heartbeatTimer;
  bool _watchdogProbing = false;

  /// 距离最近一次蓝牙传输过去了多久（由看门狗自己的节拍累加，用单调时钟）。
  ///
  /// 刻意不用 DateTime.now() 之差：测试环境是假时钟、不随 pump 推进，
  /// 而真机上又可能被系统休眠拉长间隔；用定时器累加两边行为才一致。
  Duration _sinceLinkActivity = Duration.zero;

  /// 上一次连接用的设备：掉线时直接拿它的 id 重连，不靠扫描。
  CardDevice? _lastDevice;

  void _markLinkActivity() {
    _sinceLinkActivity = Duration.zero;
  }

  void _onRealtimeStreamError(Object error) {
    if (!_autoStart || linkState != LinkState.connected || !isRecording) {
      return;
    }
    if (fwUpdating || syncing) return;
    unawaited(_watchdogProbe());
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _eventWatch?.cancel();
    // widget 测试里 autoStart:false 不启，避免悬挂定时器
    if (!_autoStart) return;
    _sinceLinkActivity = Duration.zero;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _heartbeatTick();
    });
    final eventInterval = activeCapabilities.hasConfigurableButtons
        ? const Duration(milliseconds: 200)
        : const Duration(seconds: 1);
    _eventWatch = Timer.periodic(eventInterval, (_) {
      if (isConnected && !sheetOpen) {
        unawaited(_pullDeviceEvents());
      }
    });
  }

  /// 每 5 秒醒一次累计空闲时长：待机满 30 秒探一次；录音中若超过 10 秒无命令/实时流包，
  /// 发起轻量非侵入式链路存活探测，确保蓝牙意外失联 <=12s 内拉起本机麦克风保底接力。
  void _heartbeatTick() {
    if (linkState != LinkState.connected) return;
    // 固件升级/同步/录音命令链路忙：不插队，且这些动作本身已算活动
    if (fwUpdating || syncing || _linkBusy) {
      _markLinkActivity();
      return;
    }
    _sinceLinkActivity += const Duration(seconds: 5);
    final threshold = isRecording ? recordingHeartbeatIdle : heartbeatIdle;
    if (_sinceLinkActivity < threshold) return;
    unawaited(_watchdogProbe());
  }

  Future<void> _watchdogProbe() async {
    if (_watchdogProbing || linkState != LinkState.connected) return;
    _watchdogProbing = true;
    final epoch = _epoch;
    // 先占位再发命令：探测期间又一步 tick 不该叠第二次探测
    _sinceLinkActivity = Duration.zero;
    final probingWhileRecording = isRecording;
    try {
      final ble = _bleGateway;
      if (probingWhileRecording &&
          ble is RealCardGateway &&
          ble.isNativeFfi &&
          activeKind != DeviceKind.appleWatch) {
        final ping = await _gw
            .invokeBridgeCommand(
              'link.ping',
              null,
              const Duration(seconds: 6),
            )
            .timeout(const Duration(seconds: 6));
        if (epoch != _epoch) return;
        _markLinkActivity();
        final data = ping['data'];
        final rec = data is Map<String, dynamic> ? data['record'] : null;
        if (rec is Map<String, dynamic>) {
          _applyRecordStatus(rec);
          notifyListeners();
        }
      } else {
        final probeTimeout = probingWhileRecording
            ? const Duration(seconds: 6)
            : _snapshotTimeout;
        final snapshot = await _gw.snapshot().timeout(probeTimeout);
        if (epoch != _epoch) return;
        _markLinkActivity();
        _applySnapshot(snapshot);
        notifyListeners();
      }
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      await _handleWatchdogLinkLoss('（${e.kind}）：${e.message}', epoch);
    } on TimeoutException {
      if (epoch != _epoch) return;
      if (probingWhileRecording) {
        await _handleWatchdogLinkLoss('（录音存活探测超时）', epoch);
      }
    } finally {
      _watchdogProbing = false;
    }
  }

  Future<void> _handleWatchdogLinkLoss(String detail, int epoch) async {
    debugPrint('[watchdog] 探测失败$detail');
    // 先停表：重连只许试一次，不能被后续 tick 叠成无限重试
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // 若录音待命保底已武装，立即启动手机「本机录音」无缝接力，不等待旧链路释放超时
    if (_phoneStandbyArmed && !_phoneRecording && !_phoneRecordingBusy) {
      final carrySec = _clockTicks;
      _liveRecording = false;
      _stopClock();
      unawaited(_triggerPhoneFailover(carrySecOverride: carrySec));
    }
    // 判定掉线后先让桥真正释放旧链路，再重连。
    // 只换 UI 状态不释放链路（以前的"假断开"）会让设备端继续认为已连接、
    // 停止对外广播，重连也就扫不到它。
    await _releaseLink();
    if (epoch != _epoch) return;
    unawaited(_retryReconnect());
  }

  /// 尽力释放桥里的 BLE 链路；失败只记日志，不阻断重连/断开流程。
  Future<void> _releaseLink() async {
    try {
      final report = await _gw.disconnect().timeout(const Duration(seconds: 6));
      if (!report.released) {
        debugPrint('[watchdog] 旧链路未确认释放：${report.detail ?? "unknown"}');
      }
    } on Object catch (e) {
      debugPrint('[watchdog] 释放旧链路失败：$e');
    }
  }

  /// 掉线自动重连：蓝点 → 直连上次设备，只试一次。
  ///
  /// 若掉线前硬件正处于录音且已武装待命保底（[_phoneStandbyArmed]），立即启动手机「本机录音」
  /// 接力，不等待最长达 25s 的重连扫描超时，确保对话一秒不漏；若随后重连成功且硬件仍在录音，
  /// 自动停掉手机麦克风退回零功耗待命。
  Future<void> _retryReconnect() async {
    if (linkState == LinkState.reconnecting) return; // 已在重试中，不重复
    if (!isConnected) return;
    final carrySec = _clockTicks;
    // 探测失败或收到断连事件说明链路已中断：若录音保底已待命，立即开启手机麦克风无缝接力
    if (_phoneStandbyArmed && !_phoneRecording && !_phoneRecordingBusy) {
      _liveRecording = false;
      _stopClock();
      unawaited(_triggerPhoneFailover(carrySecOverride: carrySec));
    }
    // 先立刻转蓝点，别让用户看到「已连接」再闪断
    linkState = LinkState.reconnecting;
    linkError = null;
    notifyListeners();
    final device = _lastDevice;
    if (device == null || !_gateway.available) {
      // 连设备 id 都没有，重连无从谈起：立刻回到灰点，别让用户干等几秒蓝点。
      // 桥里的旧句柄仍要清掉（后台尽力而为），否则设备端可能保持连接、不重新广播。
      _dropToDisconnected('与录音卡的连接已断开');
      await _releaseLink();
      return;
    }

    final epoch = _epoch;
    try {
      await Future<void>.delayed(_reconnectDelay);
      if (epoch != _epoch) return;
      _markLinkActivity();
      var snapshot = await _gateway
          .connect(
            device.id,
            name: device.name,
            deviceKind: device.deviceKind.code,
          )
          .timeout(_retryConnectTimeout);
      if (epoch != _epoch) return;
      snapshot ??= await _gw.snapshot().timeout(_snapshotTimeout);
      if (epoch != _epoch) return;
      _markLinkActivity();
      linkState = LinkState.connected;
      linkError = null;
      _applySnapshot(snapshot);
      await _reconcileRecordingOnConnect();
      if (epoch != _epoch) return;
      // 重连成功后必须把看门狗重新挂上：只在首次 connect 启表的话，
      // 一次掉线重连之后就再也没人探测了。
      _startHeartbeat();
      if (sheetOpen) {
        _startSheetWatch();
      }
      unawaited(prefetchSummaryInfo());
    } on Object catch (e, st) {
      if (epoch != _epoch) return;
      debugPrint('[watchdog] 重连失败：$e');
      assert(() {
        debugPrintStack(stackTrace: st, maxFrames: 6);
        return true;
      }());
      // 半开连接也释放掉：留着它只会让下次连接更难
      await _releaseLink();
      if (epoch != _epoch) return;
      _dropToDisconnected('与录音卡的连接已断开，请重新连接');
    }
    notifyListeners();
  }

  void _dropToDisconnected(String message) {
    final carrySec = _clockTicks;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _eventWatch?.cancel();
    _eventWatch = null;
    _stopClock();
    _liveRecording = false;
    _recordSession = null;
    _hwRecordingStartedAt = null;
    linkState = LinkState.disconnected;
    linkError = message;
    if (_phoneStandbyArmed && !_phoneRecording && !_phoneRecordingBusy) {
      unawaited(_triggerPhoneFailover(carrySecOverride: carrySec));
    }
    if (sheetOpen && hasBleDiscovered) {
      _scheduleScanExpiryTimer();
    }
    notifyListeners();
  }

  /// 连接期间是否有别的命令正在占用链路（同步轮询等）。
  bool get _linkBusy => syncState == SyncState.busy;

  // ── 快照应用 ───────────────────────────────────────────────
  int? _liveBattery;
  bool? _liveCharging;
  bool? _liveRecording;
  String? _recordSession;
  String _fwVersion = '';
  String _wifiVersion = '';
  int _fwVersionCode = 0;
  int _wifiVersionCode = 0;
  int? _storageFreeMb;
  int? _storageTotalMb;

  /// 当前录音会话的设备端 8 位十六进制 session 号（固件 0.3.8+）。
  String? get recordSession => _recordSession;

  int? get storageTotalMb => _storageTotalMb;

  /// 设备管理层副标题：紧跟蓝牙图标，仅保留固件版本（Apple Watch 标注 watchOS/WCSession 本地直连）。
  String get deviceSubtitleText {
    if (activeKind == DeviceKind.appleWatch) {
      return _fwVersion.isNotEmpty
          ? '$_fwVersion · 本地直连'
          : 'WCSession · 本地直连';
    }
    if (!activeCapabilities.hasRemoteRecordControl) {
      final base = _fwVersion.isNotEmpty ? '固件 $_fwVersion · ' : '';
      return '$base机身按键控录 · 靠近自动传';
    }
    if (_fwVersion.isEmpty) return '';
    return '固件 $_fwVersion';
  }

  /// 设备端 Wi-Fi 模块是否开启（null = 未知，不冒充"已关闭"）。
  bool? deviceWifiOpen;

  void _applySnapshot(CardSnapshot s) {
    activeKind = s.effectiveKind;
    activeCapabilities = s.resolvedCapabilities;
    activeModelLabel = s.modelLabel;
    // 电量三态：读到 → 更新；读不到（命令失败/字段缺失）→ 保留上次值，
    // 不把已知电量抹成未知（单次查询失败不该清状态）；设备明确报 0 → 未知。
    if (s.hasBattery && s.batteryLevel > 0) {
      _liveBattery = s.batteryLevel.clamp(1, 100);
    } else if (!s.hasBattery) {
      // 保留 _liveBattery 原值
    } else {
      _liveBattery = null;
    }
    _liveCharging = s.isCharging;
    if ((connectedName == null || connectedName!.isEmpty) &&
        s.deviceName.isNotEmpty) {
      connectedName = s.deviceName;
    }
    // 固件版本只在快照真的带到时才覆盖：部分失败（如 BASE_INFO 没读到）若
    // 把 versionCode 抹成 0，「有可用更新」的比对会误判——设备明明比服务器新，
    // 却提示升级，点进去等于降级。断开时 _resetLiveState 统一清空。
    if (s.fwVersion.isNotEmpty) _fwVersion = s.fwVersion;
    if (s.fwVersionCode > 0) _fwVersionCode = s.fwVersionCode;
    if (s.wifiVersion.isNotEmpty) _wifiVersion = s.wifiVersion;
    if (s.wifiVersionCode > 0) _wifiVersionCode = s.wifiVersionCode;
    if (s.storageFreeMb != null) _storageFreeMb = s.storageFreeMb;
    if (s.storageTotalMb != null) _storageTotalMb = s.storageTotalMb;
    if (s.recording && s.recordSession != null && s.recordSession!.isNotEmpty) {
      _recordSession = s.recordSession;
    } else if (!s.recording) {
      _recordSession = null;
    }
    deviceWifiOpen = s.wifiOpen;
    final prevRecording = _liveRecording ?? false;
    if (s.recording != prevRecording) {
      _liveRecording = s.recording;
      _clockTicks = 0;
      // 录音计时跨页面持续走：Timeline 顶部状态块与弹层用的是同一个时钟。
      // 只有 UI 持有（retainClock）时才真正起表；停止录音/断开立即停表。
      if (s.recording) {
        _hwRecordingStartedAt = _phoneRecordingStartedAt ?? DateTime.now();
        _phoneStandbyArmed = true;
      } else {
        _hwRecordingStartedAt = null;
        _stopClock();
      }
    } else if (s.recording) {
      _phoneStandbyArmed = true;
      _hwRecordingStartedAt ??= DateTime.now();
    }
    if (s.recording && _clockUsers > 0) _startClock();
    if (isConnected) {
      if (s.recording) {
        if (_phoneRecording && !_otaHandoverPhoneRecording) {
          unawaited(
            stopPhoneRecording(keepStandbyArmed: true, stopLiveActivity: false),
          );
        }
        _syncLiveActivity();
      } else if (prevRecording && !_phoneRecording) {
        unawaited(_liveActivityService.stopLocalRecordingActivity());
      }
    }
  }

  /// 单次设备快照的超时上限。
  ///
  /// 蓝牙链路是单通道：同步取回文件期间（实测能卡在同一文件上一分多钟），
  /// 快照命令只能排队。给它一个上限，超过就当作"本次没读到"，
  /// 由下一次心跳/轮询重试，而不是无限等待。
  static const Duration _snapshotTimeout = Duration(seconds: 8);

  /// 弹层打开时刷新真实设备数据。
  ///
  /// **必须带超时**：蓝牙是单通道，文件传输（同步取回）会把链路占满，
  /// 此时 `snapshot` 会一直排队不返回。没有超时的话调用方会永远挂着——
  /// 录音开关就是这样卡在「忙」上：开关半透明、点击被吞，用户只觉得点不动。
  Future<void> refreshFromDevice() async {
    if (!_gateway.available) return;
    final epoch = _epoch;
    try {
      final snapshot = await _gw.snapshot().timeout(_snapshotTimeout);
      if (epoch != _epoch) return;
      _applySnapshot(snapshot);
      if (linkState != LinkState.connected) {
        linkState = LinkState.connected;
      }
      linkError = null;
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      if (e.kind == CardErrorKind.disconnected) {
        // 与看门狗同一套：先蓝点重连一次，失败才回灰
        unawaited(_retryReconnect());
        return;
      }
      // 超时/单次查询失败：保留上次状态，不把状态页突然翻成扫描页
    } on TimeoutException {
      // 链路被文件传输占满时 snapshot 会一直排队：这里放弃本次刷新即可，
      // 下一次心跳/轮询会再试。绝不让调用方无限等待。
      if (epoch != _epoch) return;
    }
    notifyListeners();
  }

  // ── 录音时钟：以设备真实录音起点为准 ───────────────────────
  int _clockTicks = 0;
  Timer? _clockTimer;
  int _clockUsers = 0;

  /// 兼容旧接口：无设备时返回 0，界面不显示假时长。
  int get recSeconds => _clockTicks;

  bool get isRecording => _liveRecording ?? false;

  /// UI 挂载时持有录音时钟（引用计数）：Timeline 状态块 / 状态弹层打开期间
  /// 计时持续走，全部释放后停表。没有 UI 消费时不空转（也便于单元测试）。
  void retainClock() {
    _clockUsers++;
    if (isRecording) _startClock();
  }

  void releaseClock() {
    if (_clockUsers > 0) _clockUsers--;
    if (_clockUsers == 0) _stopClock();
  }

  void _startClock() {
    if (_clockTimer != null) return;
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _clockTicks++;
      notifyListeners();
    });
  }

  void _stopClock() {
    _clockTimer?.cancel();
    _clockTimer = null;
  }

  String get recClockText {
    final s = recSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  /// 录音命令进行中：UI 用它禁用开关，避免连点造成 start/stop 竞态。
  bool recordingBusy = false;

  /// 最近一次录音操作的失败原因。
  ///
  /// 由弹层**就地展示**：以前用 SnackBar，但弹层是整屏覆盖层，SnackBar 显示在
  /// 它下面被完全挡住——用户点了开关看不到任何反馈，只会觉得"点了没反应"。
  String? recordingError;

  /// 开始/停止录音（真实命令）。
  ///
  /// 设备回包后立刻刷新快照，界面据 [isRecording] 切到「录音中 + 正计时」或
  /// 「未录音」；开启硬件录音后同步点亮灵动岛/锁屏实况，并将手机本机录音挂入零功耗待命保底。
  Future<String?> toggleRecording() async {
    if (!isConnected) return '录音卡未连接';
    if (!activeCapabilities.hasRemoteRecordControl) {
      recordingError = '该硬件仅支持通过机身物理按键启停录音';
      notifyListeners();
      return recordingError;
    }
    if (recordingBusy) {
      // 上一条命令还没回来：不静默丢弃点击，明确告诉用户在等什么。
      recordingError = '正在执行上一条命令，请稍候';
      notifyListeners();
      return null;
    }
    recordingBusy = true;
    recordingError = null;
    final wantStart = !isRecording;
    if (!wantStart) {
      // 用户主动关闭硬件录音：先解除本机待命保底，防止误判为异常停录触发保底
      _phoneStandbyArmed = false;
    }
    notifyListeners();
    try {
      if (wantStart && _phoneRecording) {
        await stopPhoneRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
      }
      // 用**明确的开始/停止**而不是 toggle：
      // toggle 依赖"App 认为的状态"与设备实际一致，一旦不一致（比如设备侧拨杆
      // 已开录、或状态推送丢失），再切就变成"停一条没在录的音" → 设备回 code -1/-2。
      // 硬超时也要有：设备无响应时必须给出明确结果，不能让开关永远停在"忙"。
      final action = wantStart ? _gw.startRecording() : _gw.stopRecording();
      await action.timeout(const Duration(seconds: 15));
      await refreshFromDevice();
      if (wantStart && isRecording) {
        _phoneStandbyArmed = true;
        _hwRecordingStartedAt ??= DateTime.now();
        _syncLiveActivity();
        unawaited(_prewarmStandbyMicPermission());
      } else if (!wantStart) {
        _phoneStandbyArmed = false;
        _hwRecordingStartedAt = null;
        if (!_phoneRecording) {
          unawaited(_liveActivityService.stopLocalRecordingActivity());
        }
      }
      return null;
    } on TimeoutException {
      if (wantStart && !isRecording) _phoneStandbyArmed = false;
      recordingError = '录音命令超时，请重试';
      return recordingError;
    } on CardException catch (e) {
      if (wantStart && !isRecording) _phoneStandbyArmed = false;
      recordingError = e.message;
      return e.message;
    } finally {
      recordingBusy = false;
      notifyListeners();
    }
  }

  /// 手动打点（重要对话标记）。
  Future<String?> markNow() async {
    if (!isConnected) return '录音卡未连接';
    try {
      await _gw.mark();
      return null;
    } on CardException catch (e) {
      return e.message;
    }
  }

  /// 点一机 V1 立即拍照并经 Wi-Fi AP 拉取原图到本地路径。
  Future<Map<String, dynamic>> captureAndFetchDyjPhoto({
    required String dir,
    String? serverOrigin,
  }) async {
    if (!isConnected) throw CardException.disconnected();
    if (!activeCapabilities.hasCameraMedia) {
      throw const CardException(CardErrorKind.device, '当前硬件不支持拍照');
    }
    return _gw.invokeBridgeCommand(
      'camera_capture_and_fetch',
      {
        'dir': dir,
        if (serverOrigin != null && serverOrigin.trim().isNotEmpty)
          'serverOrigin': serverOrigin.trim(),
      },
      const Duration(seconds: 45),
    );
  }

  /// 向点一机 V1 下发 LED 状态提示（best-effort，不抛异常中断主链路）。
  Future<void> sendDyjLedHint(String mode) async {
    if (!isConnected || !activeCapabilities.hasConfigurableButtons) return;
    try {
      await _gw.invokeBridgeCommand(
        'dyj_led_hint',
        {'mode': mode},
        const Duration(seconds: 5),
      );
    } on Object {
      // 固件未实现或链路忙时静默跳过
    }
  }

  /// 前向兼容调用点一机 V1 端侧 TTS 语音播报（`dyj_tts_speak`）：
  /// `0.8.14` 等尚未实现的固件会返回 `unsupported` 错误且保持蓝牙会话不断开，供上层回退手机 TTS。
  Future<Map<String, dynamic>> speakDyjTts(
    String text, {
    bool? interrupt,
  }) async {
    if (!isConnected) throw CardException.disconnected();
    return _gw.invokeBridgeCommand(
      'dyj_tts_speak',
      {
        'text': text,
        'interrupt': ?interrupt,
      },
      const Duration(seconds: 10),
    );
  }

  // ── 电量 ───────────────────────────────────────────────────
  int get battery => _liveBattery ?? 0;
  bool get batteryKnown => _liveBattery != null;
  bool get isCharging => _liveCharging == true;

  // ── 本机录音（独立录音 / 硬件零功耗待命保底 / OTA 接力 + 统一灵动岛实况）──
  bool _islandEnabled = true;
  DateTime? _hwRecordingStartedAt;
  bool _phoneStandbyArmed = false;
  bool _failoverPhoneRecording = false;
  bool _phoneRecording = false;
  bool _phoneRecordingBusy = false;
  int _phoneRecSec = 0;
  Timer? _phoneClockTimer;
  String? _phoneRecordingError;
  DateTime? _phoneRecordingStartedAt;
  bool _otaHandoverPhoneRecording = false;

  bool get islandEnabled => _islandEnabled;
  bool get isPhoneStandbyArmed => _phoneStandbyArmed;
  bool get isFailoverPhoneRecording => _failoverPhoneRecording;
  bool get isPhoneRecording => _phoneRecording;
  bool get phoneRecordingBusy => _phoneRecordingBusy;
  int get phoneRecSeconds => _phoneRecSec;
  String? get phoneRecordingError => _phoneRecordingError;
  DateTime? get phoneRecordingStartedAt => _phoneRecordingStartedAt;
  Stream<LiveAudioSlice> get phoneAudioSlices => _phoneMicRecorder.slices;
  PcmRingBuffer get phoneRingBuffer => _phoneMicRecorder.ringBuffer;
  LiveActivityService get liveActivityService => _liveActivityService;

  void setIslandEnabled(bool enabled) {
    if (_islandEnabled == enabled) return;
    _islandEnabled = enabled;
    if (!enabled) {
      unawaited(_liveActivityService.stopLocalRecordingActivity());
    } else {
      _syncLiveActivity();
    }
  }

  String get _hardwareActivityLabel {
    if (activeKind == DeviceKind.appleWatch) {
      return 'Apple Watch';
    }
    final model = activeModelLabel.trim();
    final shortId = connectedDisplayName.trim();
    if (model.isNotEmpty &&
        shortId.isNotEmpty &&
        shortId != '录音卡' &&
        shortId != model) {
      return '$model $shortId';
    }
    if (model.isNotEmpty) return model;
    if (shortId.isNotEmpty) return shortId;
    return '录音卡';
  }

  void _syncLiveActivity() {
    if (!_islandEnabled) return;
    if (isConnected && isRecording) {
      final startedAt =
          _hwRecordingStartedAt ??
          DateTime.now().subtract(Duration(seconds: _clockTicks));
      _hwRecordingStartedAt = startedAt;
      unawaited(
        _liveActivityService.startHardwareRecordingActivity(
          startedAt: startedAt,
          deviceLabel: _hardwareActivityLabel,
        ),
      );
      return;
    }
    if (_phoneRecording) {
      final activityStartedAt = DateTime.now().subtract(
        Duration(seconds: _phoneRecSec),
      );
      if (_failoverPhoneRecording) {
        unawaited(
          _liveActivityService.startFailoverRecordingActivity(
            startedAt: activityStartedAt,
          ),
        );
      } else {
        unawaited(
          _liveActivityService.startLocalRecordingActivity(
            startedAt: _phoneRecordingStartedAt ?? activityStartedAt,
          ),
        );
      }
    }
  }

  /// 硬件录音在前台开启时预检手机麦克风权限：
  /// 若尚未询问过（`notDetermined`），提前完成一次性授权，确保后续即使手机锁屏放在口袋里
  /// 发生蓝牙意外断连，也能直接在后台拉起 `AVAudioEngine` 自动保底接力。
  Future<void> _prewarmStandbyMicPermission() async {
    try {
      final perm = await _phoneMicBackend.checkPermission();
      if (perm == PhoneMicPermission.notDetermined) {
        await _phoneMicBackend.requestPermission();
      }
    } on Object {
      // 测试环境或非移动平台无通道时静默跳过，不阻塞硬件录音主流程
    }
  }

  /// 蓝牙设备意外断连或硬件故障停录时自动拉起手机「本机录音」作为保底。
  Future<void> _triggerPhoneFailover({int carrySecOverride = 0}) async {
    if (!_phoneStandbyArmed || _phoneRecording || _phoneRecordingBusy) return;
    await startPhoneRecording(
      forFailover: true,
      islandEnabled: _islandEnabled,
      initialElapsedSec: carrySecOverride,
    );
  }

  /// 硬件连接/重连完成后的录音状态收口：
  /// 1. 若硬件本身已在录音：关闭可能正在运行的断连保底本机麦克风，退回零功耗待命并同步硬件实况；
  /// 2. 若此前手机正在本机录音（如断连保底或连卡前独立本机录音）且非固件升级中：自动将录音交接给硬件，
  ///    关闭高功耗手机麦克风并挂起待命保底，确保已连硬件状态下绝不双端并行耗电。
  Future<void> _reconcileRecordingOnConnect() async {
    if (!isConnected) return;
    if (isRecording) {
      _phoneStandbyArmed = true;
      _hwRecordingStartedAt ??= DateTime.now();
      if (_phoneRecording && !_otaHandoverPhoneRecording) {
        await stopPhoneRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
      }
      _syncLiveActivity();
      return;
    }
    if (_phoneRecording && !_otaHandoverPhoneRecording && !fwUpdating) {
      final carrySec = _phoneRecSec;
      try {
        await _gw.startRecording().timeout(const Duration(seconds: 10));
        final refreshed = await _gw.snapshot().timeout(_snapshotTimeout);
        _applySnapshot(refreshed);
      } on Object catch (e) {
        debugPrint('[device] handover phone->hardware failed: $e');
      }
      if (isRecording) {
        _clockTicks = carrySec;
        _hwRecordingStartedAt = DateTime.now().subtract(
          Duration(seconds: carrySec),
        );
        _phoneStandbyArmed = true;
        await stopPhoneRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
        _syncLiveActivity();
      } else {
        await stopPhoneRecording();
      }
    }
  }

  String get phoneRecClockText {
    final s = _phoneRecSec;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  Future<PhoneMicPermission> checkPhoneMicPermission() =>
      _phoneMicBackend.checkPermission();

  Future<PhoneMicPermission> requestPhoneMicPermission() =>
      _phoneMicBackend.requestPermission();

  Future<bool> startPhoneRecording({
    bool forOtaHandover = false,
    bool forFailover = false,
    bool islandEnabled = true,
    int initialElapsedSec = 0,
  }) async {
    if (_phoneRecording) return true;
    if (_phoneRecordingBusy) return false;
    _phoneRecordingBusy = true;
    _phoneRecordingError = null;
    notifyListeners();
    try {
      var perm = await _phoneMicBackend.checkPermission();
      if (perm == PhoneMicPermission.notDetermined) {
        perm = await _phoneMicBackend.requestPermission();
      }
      if (perm != PhoneMicPermission.granted) {
        _phoneRecordingError = '需要开启麦克风权限才能使用本机录音';
        return false;
      }
      final startedAt = DateTime.now();
      await _phoneMicRecorder.start(startedAt: startedAt);
      await _phoneMicBackend.startCapture(
        _phoneMicRecorder.ingestPcm,
        onError: (err) {
          _phoneRecordingError = err;
          unawaited(stopPhoneRecording());
        },
      );
      _phoneRecording = true;
      _phoneRecordingStartedAt = startedAt;
      _phoneRecSec = initialElapsedSec < 0 ? 0 : initialElapsedSec;
      _otaHandoverPhoneRecording = forOtaHandover;
      _failoverPhoneRecording = forFailover;
      _islandEnabled = islandEnabled;
      _phoneClockTimer?.cancel();
      _phoneClockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _phoneRecSec++;
        notifyListeners();
      });
      if (islandEnabled) {
        final activityStartedAt = initialElapsedSec > 0
            ? startedAt.subtract(Duration(seconds: initialElapsedSec))
            : startedAt;
        if (forFailover) {
          unawaited(
            _liveActivityService.startFailoverRecordingActivity(
              startedAt: activityStartedAt,
            ),
          );
        } else {
          unawaited(
            _liveActivityService.startLocalRecordingActivity(
              startedAt: activityStartedAt,
            ),
          );
        }
      }
      return true;
    } on Object catch (e) {
      await _phoneMicRecorder.stop();
      _phoneRecording = false;
      _failoverPhoneRecording = false;
      _phoneRecordingError = '本机录音启动失败：$e';
      return false;
    } finally {
      _phoneRecordingBusy = false;
      notifyListeners();
    }
  }

  Future<void> stopPhoneRecording({
    bool keepStandbyArmed = false,
    bool stopLiveActivity = true,
  }) async {
    if (!_phoneRecording && !_phoneRecordingBusy) {
      if (!keepStandbyArmed) _phoneStandbyArmed = false;
      return;
    }
    _phoneRecordingBusy = true;
    notifyListeners();
    try {
      await _phoneMicBackend.stopCapture();
      await _phoneMicRecorder.stop();
    } finally {
      _phoneClockTimer?.cancel();
      _phoneClockTimer = null;
      _phoneRecording = false;
      _otaHandoverPhoneRecording = false;
      _failoverPhoneRecording = false;
      if (!keepStandbyArmed) {
        _phoneStandbyArmed = false;
      }
      _phoneRecordingStartedAt = null;
      _phoneRecordingBusy = false;
      if (stopLiveActivity && !(isConnected && isRecording)) {
        unawaited(_liveActivityService.stopLocalRecordingActivity());
      }
      notifyListeners();
    }
  }

  Future<bool> togglePhoneRecording({bool islandEnabled = true}) async {
    if (_phoneRecording) {
      await stopPhoneRecording();
      return false;
    }
    return startPhoneRecording(islandEnabled: islandEnabled);
  }

  /// 下拉刷新时不停录冲刷当前已缓冲的本机麦克风切片（至少 0.5 秒才切分）。
  Future<bool> flushPhoneRecordingSlice() async {
    if (!_phoneRecording) return false;
    return _phoneMicRecorder.flushActiveSlice();
  }

  /// 当前是否存在本机或硬件录音。
  bool get hasActiveRecording =>
      _phoneRecording || (isConnected && isRecording);

  /// 退出登录前安全关闭硬件录音（异常不阻塞退出登录流程）。
  Future<void> stopHardwareRecordingIfActive() async {
    _phoneStandbyArmed = false;
    _hwRecordingStartedAt = null;
    if (!isConnected || !isRecording) return;
    if (recordingBusy) return;
    recordingBusy = true;
    recordingError = null;
    notifyListeners();
    try {
      await _gw.stopRecording().timeout(const Duration(seconds: 6));
      await refreshFromDevice();
    } on TimeoutException {
      recordingError = '停止录音超时';
      debugPrint('[device] signOut stopRecording timeout');
    } on CardException catch (e) {
      recordingError = e.message;
      debugPrint('[device] signOut stopRecording failed: ${e.message}');
    } on Object catch (e) {
      recordingError = '$e';
      debugPrint('[device] signOut stopRecording failed: $e');
    } finally {
      recordingBusy = false;
      notifyListeners();
    }
  }

  /// 退出登录或会话失效时统一关闭本机/硬件录音与灵动岛，防止数据归属跨账号泄漏。
  Future<void> stopAllRecordingsForSignOut() async {
    _phoneStandbyArmed = false;
    _hwRecordingStartedAt = null;
    if (_phoneRecording || _phoneRecordingBusy) {
      await stopPhoneRecording();
    } else {
      unawaited(_liveActivityService.stopLocalRecordingActivity());
    }
    if (isConnected && isRecording) {
      await stopHardwareRecordingIfActive();
    }
  }

  String get batteryLevelText {
    if (_liveCharging == true) return '充电中';
    final level = battery;
    if (level <= 0) return '未知';
    return level < 20
        ? '电量低'
        : level < 40
        ? '电量中'
        : '电量高';
  }

  String get batteryEtaText {
    if (!batteryKnown) return '—';
    final hours = (battery * 0.24 * 0.7).floor().clamp(1, 24);
    final end = DateTime.now().add(Duration(hours: hours));
    final hm =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    final day = end.day == DateTime.now().day ? '今天' : '明天';
    return '$day $hm';
  }

  // ── 固件版本（真实回报）────────────────────────────────────
  String get fwVersion => _fwVersion;
  String get wifiVersion => _wifiVersion;
  int get fwVersionCode => _fwVersionCode;
  int get wifiVersionCode => _wifiVersionCode;
  int? get storageFreeMb => _storageFreeMb;

  // ── 同步：自动同步为主，点击行 = 手动同步 ───────────────────
  SyncState syncState = SyncState.idle;
  DateTime? lastSyncAt;

  /// 默认自动同步；用户点同步行后变成手动同步，行文案据此区分。
  SyncTrigger lastSyncTrigger = SyncTrigger.auto;
  String? syncError;
  bool _syncCooldown = false;

  bool get syncing => syncState == SyncState.busy;

  String get syncRelText {
    final at = lastSyncAt;
    if (at == null) return '尚未同步';
    final s = DateTime.now().difference(at).inSeconds;
    if (s < 30) return '刚刚';
    if (s < 60) return '30 秒前';
    return '${s ~/ 60} 分钟前';
  }

  String get syncText => switch (syncState) {
    SyncState.busy => '正在同步…',
    SyncState.done => '同步成功 · 刚刚',
    SyncState.idle =>
      '${lastSyncTrigger == SyncTrigger.manual ? '手动同步' : '自动同步'} · '
          '$syncRelText',
  };

  bool get canSync =>
      isConnected &&
      activeCapabilities.hasFileSync &&
      syncState == SyncState.idle &&
      !_syncCooldown &&
      !fwUpdating;

  /// 正式版接入蓝牙补传管线时注入：手动点击「同步」拉取卡上尚未通过实时流同步的离线录音文件，
  /// 而不是开启固件侧尚未配置的 Wi-Fi 云上传（开启 Wi-Fi 会抢占 SD 卡总线导致蓝牙读卡失败）。
  /// 未注入（单元测试）时保持原 `startSync` 固件通道行为。
  Future<String?> Function()? onManualBleSync;

  /// 点击同步行 = 手动同步。
  Future<void> syncNow({bool manual = true}) async {
    if (!canSync) return;
    if (isConnected && activeKind == DeviceKind.appleWatch) {
      syncState = SyncState.busy;
      syncError = null;
      notifyListeners();
      final epoch = _epoch;
      try {
        await _watchHardware.flushAndDrain();
        if (epoch != _epoch) return;
        _finishSync(manual ? SyncTrigger.manual : SyncTrigger.auto);
      } on CardException catch (e) {
        if (epoch != _epoch) return;
        syncState = SyncState.idle;
        syncError = e.message;
        notifyListeners();
      } on Object catch (e) {
        if (epoch != _epoch) return;
        syncState = SyncState.idle;
        syncError = '$e';
        notifyListeners();
      }
      return;
    }
    final bleSync = onManualBleSync;
    if (bleSync != null) {
      if (isRecording) {
        syncError = '录音期间正在实时切片转写，无需手动同步；停录后可补传离线文件';
        notifyListeners();
        return;
      }
      syncState = SyncState.busy;
      syncError = null;
      notifyListeners();
      final epoch = _epoch;
      try {
        final err = await bleSync();
        if (epoch != _epoch) return;
        if (err != null && err.isNotEmpty) {
          syncState = SyncState.idle;
          syncError = err;
          notifyListeners();
          return;
        }
        _finishSync(manual ? SyncTrigger.manual : SyncTrigger.auto);
      } on Object catch (e) {
        if (epoch != _epoch) return;
        syncState = SyncState.idle;
        syncError = '$e';
        notifyListeners();
      }
      return;
    }

    syncState = SyncState.busy;
    syncError = null;
    notifyListeners();
    final epoch = _epoch;
    try {
      await _gw.startSync();
      // 跟进设备回报的 Sync 事件；设备不实现轮询时也能在超时后给出结论
      final ok = await _waitSyncComplete(epoch);
      if (epoch != _epoch) return;
      if (!ok) {
        syncState = SyncState.idle;
        syncError = '同步未完成，请稍后重试';
        notifyListeners();
        return;
      }
      _finishSync(manual ? SyncTrigger.manual : SyncTrigger.auto);
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      syncState = SyncState.idle;
      syncError = e.message;
      notifyListeners();
    }
  }

  /// 自动同步（停止录音后由外壳触发的拉取/整理）完成后回报。
  ///
  /// 自动同步是静默的：只更新「自动同步 · 刚刚」与时间，不进入绿色对勾 +
  /// 10 秒冷却（那套反馈是给用户手动点击的）。
  void noteSyncFinished({required bool manual}) {
    if (manual) {
      _finishSync(SyncTrigger.manual);
      return;
    }
    lastSyncAt = DateTime.now();
    lastSyncTrigger = SyncTrigger.auto;
    syncState = SyncState.idle;
    notifyListeners();
  }

  void _finishSync(SyncTrigger trigger) {
    lastSyncAt = DateTime.now();
    lastSyncTrigger = trigger;
    syncState = SyncState.done;
    notifyListeners();
    _syncCooldown = true;
    Timer(const Duration(seconds: 10), () {
      _syncCooldown = false;
      syncState = SyncState.idle;
      notifyListeners();
    });
  }

  /// 轮询设备同步状态直到 running=false 或超时（默认 60s）。
  Future<bool> _waitSyncComplete(
    int epoch, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (epoch != _epoch) return false;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final status = await _gw.syncStatus();
        if (!status.running) return true;
      } on CardException {
        return false;
      }
    }
    return false;
  }

  bool _wifiSummaryProbed = false;
  bool _otaChecked = false;

  /// 预取弹层首屏要展示的概要信息（Wi-Fi 已配置数量、固件是否有更新）。
  ///
  /// 不做的话，用户不点进二级页就永远看到"0 个网络 / 已是最新"——那是假信息。
  Future<void> prefetchSummaryInfo() async {
    if (!isConnected) return;
    final epoch = _epoch;
    if (activeCapabilities.hasWifiConfig && !_wifiSummaryProbed) {
      try {
        final creds = await _gw.wifiCredentials(passive: true);
        if (epoch != _epoch) return;
        _wifiSummaryProbed = true;
        wifiSaved = creds.map((c) => SavedWifi(c.ssid)).toList();
        notifyListeners();
      } on CardException {
        // 卡片尚未记录被动缓存或设备暂不支持时保持原状
      }
    }
    if (activeCapabilities.hasOta && !_otaChecked) {
      await checkFirmware(silent: activeCapabilities.hasSingleOta);
    }
  }

  // ── 弹层视图 ───────────────────────────────────────────────
  bool sheetOpen = false;
  DeviceView view = DeviceView.main;

  void openSheet() {
    sheetOpen = true;
    view = DeviceView.main;
    if (isConnected) {
      unawaited(refreshFromDevice());
      unawaited(prefetchSummaryInfo());
      if (fwStage == FwStage.failed) {
        unawaited(checkFirmware());
      }
      // 弹层开着时盯住设备侧按钮/开关的录音变化：卡上按了开始，这里要马上跟上，
      // 而不是等 30 秒看门狗或用户再点一次。
      _startSheetWatch();
    } else if (linkState == LinkState.unknown) {
      unawaited(restoreLink());
    } else {
      unawaited(startScan());
    }
    notifyListeners();
  }

  void closeSheet() {
    if (fwUpdating) return; // 更新中弹层锁定
    if (activeCapabilities.hasDualChipOta &&
        view == DeviceView.wifi &&
        deviceWifiOpen == true &&
        !wifiJoining) {
      unawaited(_closeWifiQuietly());
    }
    sheetOpen = false;
    _stopSheetWatch();
    _stopScanExpiryTimer();
    // 不停录音时钟：录音还在继续，Timeline 顶部状态块要继续计时
    notifyListeners();
  }

  /// App 切回前台时对扫描结果做真实墙钟过期校准：
  /// 若弹层停在「连接设备」页且列表已超过 TTL，立即自动重扫一次；否则按真实剩余时间重排定时器。
  void handleAppResumed() {
    if (!sheetOpen || isConnected || isLinkBusy || view != DeviceView.main) {
      return;
    }
    if (!hasBleDiscovered) {
      return;
    }
    if (isBleScanExpired) {
      _scanExpiredByTimer = true;
      _stopScanExpiryTimer();
      if (canScan) {
        unawaited(startScan());
      } else {
        notifyListeners();
      }
      return;
    }
    _scheduleScanExpiryTimer();
  }

  void showView(DeviceView v) {
    final prev = view;
    view = v;
    if (activeCapabilities.hasDualChipOta &&
        prev == DeviceView.wifi &&
        v != DeviceView.wifi &&
        deviceWifiOpen == true &&
        !wifiJoining) {
      unawaited(_closeWifiQuietly());
    }
    if (v == DeviceView.wifi) {
      unawaited(wifiScan());
    }
    if (v == DeviceView.upg) {
      unawaited(checkFirmware());
    }
    notifyListeners();
  }

  Future<void> _closeWifiQuietly() async {
    try {
      await _gw.closeWifi();
      deviceWifiOpen = false;
    } on Object {
      // 忽略关闭失败，后续读文件前管线还会兜底再关一次
    }
  }

  // ── 固件：真实两阶段（主控 BLE DFU → Wi-Fi 模组在线 OTA）──
  FwStage fwStage = FwStage.idle;
  bool fwUpdating = false;
  double fwProgress = 0;
  String fwStageText = '';
  String fwStateText = '';
  String? fwError;
  CardOtaInfo? _otaMainInfo;
  CardOtaInfo? _otaWifiInfo;

  bool get mainNeedsUpdate =>
      _otaMainInfo?.isNewerThan(_fwVersionCode) == true;

  bool get wifiNeedsUpdate =>
      _otaWifiInfo?.isNewerThan(_wifiVersionCode) == true;

  bool get fwAvailable => mainNeedsUpdate || wifiNeedsUpdate;

  /// 固件行右侧文案：未查完显示「正在检查…」，失败显示「检查失败」，有更新提示「有可用更新」，否则「已是最新」。
  String get fwValText {
    if (fwStage == FwStage.failed) return '检查失败';
    if (fwUpdating) return fwPctText;
    if (!_otaChecked && activeCapabilities.hasOta && isConnected) {
      return '正在检查…';
    }
    return fwAvailable ? '有可用更新' : '已是最新';
  }

  /// 升级完成后的设备状态行（无更新时为空，不占位）。
  String get devStateText {
    if (fwStage != FwStage.done) return '';
    return '已更新到 $fwVersionText';
  }

  String get fwVersionText {
    if (_fwVersion.isEmpty) return '—';
    if (activeCapabilities.hasSingleOta) return _fwVersion;
    return '主控 $_fwVersion / Wi-Fi ${_wifiVersion.isEmpty ? '—' : _wifiVersion}';
  }

  String get fwPctText => '${fwProgress.round()}%';

  /// 固件更新页的版本对比行：有更新时显示当前版本 → 目标版本，无更新时标「已是最新」。
  String get mainVersionCompare {
    final target = _otaMainInfo;
    final current = _fwVersion.isEmpty ? '—' : _fwVersion;
    if (mainNeedsUpdate && target != null && target.version.isNotEmpty) {
      return '$current → ${target.version}';
    }
    if (fwStage == FwStage.checking && target == null) return current;
    if (_fwVersion.isNotEmpty) return '$_fwVersion · 已是最新';
    if (target != null && target.versionCode > 0) return '已是最新';
    return current;
  }

  String get wifiVersionCompare {
    final target = _otaWifiInfo;
    final current = _wifiVersion.isEmpty ? '—' : _wifiVersion;
    if (wifiNeedsUpdate && target != null && target.version.isNotEmpty) {
      return '$current → ${target.version}';
    }
    if (fwStage == FwStage.checking && target == null) return current;
    if (_wifiVersion.isNotEmpty) return '$_wifiVersion · 已是最新';
    if (target != null && target.versionCode > 0) return '已是最新';
    return current;
  }

  Future<CardOtaInfo> _fetchOtaModule(String module) async {
    try {
      return await _gateway.otaInfo(module);
    } on CardException {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return _gateway.otaInfo(module);
    }
  }

  /// 查服务器最新版本（只读，不写设备）。
  ///
  /// [silent] 为 true 时（用于单芯片 OTA 首页预检，未配网可能 3003）：
  /// 静默失败不把主弹层标为「检查失败」，等用户进入升级页再显式提示配网。
  Future<void> checkFirmware({bool silent = false}) async {
    if (!isConnected) return;
    final epoch = _epoch;
    if (!silent) {
      fwStage = FwStage.checking;
      fwError = null;
      notifyListeners();
    }
    try {
      if (activeCapabilities.hasWifiConfig && !_wifiSummaryProbed) {
        try {
          final creds = await _gw.wifiCredentials(passive: true);
          if (epoch != _epoch) return;
          _wifiSummaryProbed = true;
          wifiSaved = creds.map((c) => SavedWifi(c.ssid)).toList();
        } on CardException {
          // 读取被动缓存失败不阻断检查服务器最新版本
        }
      }
      if (activeCapabilities.hasSingleOta) {
        final mainInfo = await _fetchOtaModule('main');
        if (epoch != _epoch) return;
        _otaMainInfo = mainInfo;
        _otaWifiInfo = null;
        _otaChecked = true;
        fwStage = FwStage.idle;
      } else {
        final results = await Future.wait([
          _fetchOtaModule('main'),
          _fetchOtaModule('wifi'),
        ]);
        if (epoch != _epoch) return;
        _otaMainInfo = results[0];
        _otaWifiInfo = results[1];
        _otaChecked = true;
        fwStage = FwStage.idle;
      }
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      _otaMainInfo = null;
      _otaWifiInfo = null;
      if (silent && activeCapabilities.hasSingleOta) {
        _otaChecked = true;
        fwStage = FwStage.idle;
        fwError = null;
      } else {
        _otaChecked = false;
        fwError = e.message;
        fwStage = FwStage.failed;
      }
    }
    notifyListeners();
  }

  /// 执行升级：按模块独立门控（仅主控 / 仅 Wi-Fi / 两阶段）。
  ///
  /// [allowStopRecordingAndHandover] 为 true 时：若硬件正在录音，先停止硬件录音，
  /// 无缝切到手机「本机录音」（并亮起灵动岛），待固件升级且硬件重连后再自动停止本机录音。
  Future<void> startFwUpdate({
    bool allowStopRecordingAndHandover = false,
    bool islandEnabled = true,
  }) async {
    if (fwUpdating) return;
    if (!isConnected) {
      fwError = '录音卡未连接';
      notifyListeners();
      return;
    }
    if (isRecording) {
      if (!allowStopRecordingAndHandover) {
        fwError = '正在录音，请先停止录音后再升级固件';
        fwStateText = fwError!;
        notifyListeners();
        return;
      }
      final startedHandover = await startPhoneRecording(
        forOtaHandover: true,
        islandEnabled: islandEnabled,
        initialElapsedSec: _clockTicks,
      );
      if (!startedHandover) {
        fwError = _phoneRecordingError ?? '请先开启麦克风权限，确保升级期间录音数据不断';
        fwStateText = fwError!;
        notifyListeners();
        return;
      }
      _phoneStandbyArmed = false;
      try {
        await _gw.stopRecording().timeout(const Duration(seconds: 15));
        _liveRecording = false;
        _recordSession = null;
        _hwRecordingStartedAt = null;
        _stopClock();
        notifyListeners();
      } on Object catch (e) {
        await stopPhoneRecording();
        fwError = '停止硬件录音失败：$e';
        fwStateText = fwError!;
        notifyListeners();
        return;
      }
    }

    if (_otaMainInfo == null && _otaWifiInfo == null) {
      await checkFirmware();
      if (fwStage == FwStage.failed) return;
    }

    final doMain = mainNeedsUpdate;
    var doWifi = activeCapabilities.hasDualChipOta && wifiNeedsUpdate;
    if (!doMain && !doWifi) {
      fwError = null;
      fwStage = FwStage.idle;
      await refreshFromDevice();
      notifyListeners();
      return;
    }

    // 记录升级前设备端 Wi-Fi 开关模式：Stage 1 DFU 重启会把 nRF 的 wifiOpen 复位，
    // 升级结束后按此模式精准还原，不强制关掉原本就开着的 Wi-Fi。
    final priorWifiOpen = deviceWifiOpen == true;

    fwUpdating = true;
    fwError = null;
    fwProgress = 0;
    unawaited(_setKeepScreenOn(true));

    // 阶段 1：主控 / 单芯片系统固件
    if (doMain) {
      final mainStageLabel = activeCapabilities.hasSingleOta
          ? '正在升级系统固件'
          : (doWifi ? '阶段 1/2 · 主控芯片' : '阶段 1/1 · 主控芯片');
      fwStage = FwStage.main;
      fwStageText = mainStageLabel;
      fwStateText = '正在准备…';
      notifyListeners();

      try {
        await for (final p in _gw.otaMain()) {
          fwProgress = p.percent.clamp(0, 100) * (doWifi ? 0.5 : 0.85);
          fwStageText = mainStageLabel;
          fwStateText = p.text;
          notifyListeners();
        }
      } on CardException catch (e) {
        final recovered = await _recoverAfterMainOtaFailure();
        final suffix = recovered
            ? ''
            : '（连接已断开，请重连或扫描恢复模式设备后重试）';
        _failFw('主控固件升级失败：${e.message}$suffix');
        return;
      }

      // DFU 后原连接失效：扫描并重连，拉取最新 snapshot 刷新版本号
      fwProgress = doWifi ? 50 : 90;
      fwStageText = doWifi ? '阶段 2/2 · Wi-Fi 芯片' : mainStageLabel;
      fwStateText = '正在重新连接录音卡…';
      notifyListeners();
      var reconnected = false;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final list = await _gw.scan();
          final target = _pickReconnectedCardV2Target(
            list,
            allowDfuFallback: false,
          );
          if (target != null) {
            final snap = await _gw.connect(
              target.id,
              name: target.name,
              deviceKind: target.deviceKind.code,
            );
            _lastDevice = target;
            connectedName = target.name;
            linkState = LinkState.connected;
            if (snap != null) _applySnapshot(snap);
            try {
              final batch = await _gw.pullEvents(after: _eventSeq);
              _eventSeq = batch.seq;
            } on Object {
              // 忽略事件序号同步失败
            }
            reconnected = true;
            break;
          }
        } on CardException {
          continue;
        }
      }
      if (!reconnected) {
        linkState = LinkState.disconnected;
        connectedName = null;
        _failFw('升级后未能重新连接录音卡，请手动重连');
        return;
      }
      await refreshFromDevice();
      doWifi = activeCapabilities.hasDualChipOta && wifiNeedsUpdate;
      if (!doWifi && priorWifiOpen && deviceWifiOpen != true) {
        try {
          await _gw.openWifi();
          await refreshFromDevice();
        } on CardException {
          // 恢复开启失败不覆盖已完成的主控升级结果
        }
      }
    }

    // 阶段 2（或独立阶段 1）：Wi-Fi 模组
    if (doWifi) {
      final wifiStageLabel = doMain ? '阶段 2/2 · Wi-Fi 芯片' : '阶段 1/1 · Wi-Fi 芯片';
      fwStage = FwStage.wifi;
      fwStageText = wifiStageLabel;
      fwStateText = '正在检查 Wi-Fi 模块…';
      notifyListeners();
      try {
        await for (final p in _gw.otaWifi(restoreWifiOpen: priorWifiOpen)) {
          fwProgress = doMain
              ? 50 + p.percent.clamp(0, 100) * 0.5
              : p.percent.clamp(0, 100) * 1.0;
          fwStageText = wifiStageLabel;
          fwStateText = p.text;
          notifyListeners();
        }
      } on CardException catch (e) {
        await refreshFromDevice();
        _failFw('Wi-Fi 模组升级失败：${e.message}');
        return;
      }
      await refreshFromDevice();
    }

    fwUpdating = false;
    unawaited(_setKeepScreenOn(false));
    fwProgress = 100;
    fwStage = FwStage.done;
    view = DeviceView.main;
    _otaMainInfo = null;
    _otaWifiInfo = null;
    _otaChecked = true;
    if (_otaHandoverPhoneRecording && _phoneRecording) {
      await stopPhoneRecording();
    }
    notifyListeners();
  }

  Future<void> _setKeepScreenOn(bool enabled) =>
      _permission.setKeepScreenOn(enabled);

  static bool _isDfuBootloaderName(String? name) =>
      name != null && name.trim().toUpperCase().startsWith('DFU');

  CardDevice? _pickReconnectedCardV2Target(
    List<CardDevice> list, {
    required bool allowDfuFallback,
  }) {
    final normal = list.where((d) => !_isDfuBootloaderName(d.name)).toList();
    final currentName = connectedName;
    if (currentName != null &&
        currentName.isNotEmpty &&
        !_isDfuBootloaderName(currentName)) {
      final hit = normal.where((d) => d.name == currentName).firstOrNull;
      if (hit != null) return hit;
    }
    final lastName = _lastDevice?.name;
    if (lastName != null &&
        lastName.isNotEmpty &&
        !_isDfuBootloaderName(lastName)) {
      final hit = normal.where((d) => d.name == lastName).firstOrNull;
      if (hit != null) return hit;
    }
    final v2Hit = normal
        .where((d) => d.deviceKind == DeviceKind.cardV2)
        .firstOrNull;
    if (v2Hit != null) return v2Hit;
    if (normal.isNotEmpty) return normal.first;
    if (!allowDfuFallback) return null;
    return list.where((d) => _isDfuBootloaderName(d.name)).firstOrNull ??
        list.firstOrNull;
  }

  Future<bool> _recoverAfterMainOtaFailure() async {
    try {
      final snap = await _gw.snapshot().timeout(const Duration(seconds: 5));
      _applySnapshot(snap);
      return true;
    } on Object {
      // 桥在进入 DFU 前已取走设备句柄，扫描恢复正常连接或 DFU_DYJ 恢复模式
    }

    for (var i = 0; i < 2; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      try {
        final list = await _gw.scan();
        final target = _pickReconnectedCardV2Target(
          list,
          allowDfuFallback: true,
        );
        if (target == null) continue;
        final snap = await _gw.connect(
          target.id,
          name: target.name,
          deviceKind: target.deviceKind.code,
        );
        _lastDevice = target;
        connectedName = target.name;
        linkState = LinkState.connected;
        if (snap != null) {
          _applySnapshot(snap);
        } else {
          await refreshFromDevice();
        }
        try {
          final batch = await _gw.pullEvents(after: _eventSeq);
          _eventSeq = batch.seq;
        } on Object {
          // 忽略事件序号同步失败
        }
        if (_isDfuBootloaderName(target.name)) {
          _otaChecked = true;
        }
        return true;
      } on Object {
        continue;
      }
    }
    linkState = LinkState.disconnected;
    connectedName = null;
    return false;
  }

  void _failFw(String message) {
    fwUpdating = false;
    unawaited(_setKeepScreenOn(false));
    fwStage = FwStage.failed;
    fwError = message;
    fwStateText = message;
    notifyListeners();
  }

  // ── Wi-Fi：设备扫描 + 设备凭据 + 真实连接 ──────────────────
  List<SavedWifi> wifiSaved = const [];
  String? wifiLast;
  bool wifiMore = false;
  bool wifiScanDone = false;
  bool wifiJoining = false;
  String wifiJoinName = '';
  String? wifiSelName;
  String wifiStateText = '';
  String? wifiError;
  List<WifiNet> wifiScanRes = const [];
  final Set<String> _wifiInRange = {};

  int get wifiCountShown => wifiSaved.length;
  bool wifiInRange(String n) => _wifiInRange.contains(n);
  bool get wifiIsJoiningSaved =>
      wifiJoining && wifiSaved.any((w) => w.name == wifiJoinName);

  /// 设备端 Wi-Fi 模块状态；未知时界面显示"读取失败 + 重试"，不冒充已关闭。
  bool get wifiKnownOpen => deviceWifiOpen != null;

  Future<void> wifiRetry() async {
    await refreshFromDevice();
    await wifiScan();
  }

  /// 扫描附近网络（经设备 Wi-Fi 模块）。仅保留 2.4GHz（设计基线）。
  Future<void> wifiScan() async {
    if (!isConnected) {
      wifiError = '录音卡未连接';
      wifiStateText = '请先连接录音卡';
      wifiScanDone = false;
      notifyListeners();
      return;
    }
    wifiSelName = null;
    wifiJoining = false;
    wifiJoinName = '';
    wifiScanDone = false;
    wifiError = null;
    wifiStateText = '正在扫描附近网络…';
    notifyListeners();
    try {
      // 设备侧 Wi-Fi 模块需先开启
      if (deviceWifiOpen != true) {
        await _gw.openWifi();
        deviceWifiOpen = true;
      }
      final creds = await _gw.wifiCredentials();
      final nets = await _gw.scanWifi();
      wifiSaved = creds.map((c) => SavedWifi(c.ssid)).toList();
      wifiScanRes = nets
          .where((n) => n.ssid.isNotEmpty)
          .map((n) => WifiNet(n.ssid, _signalOf(n.rssi), lock: n.secured))
          .toList();
      _wifiInRange
        ..clear()
        ..addAll(wifiScanRes.map((r) => r.name));
      wifiScanDone = true;
      wifiStateText = '扫描完成 · 附近可见 ${wifiScanRes.length} 个 2.4GHz 网络';
    } on CardException catch (e) {
      wifiScanDone = false;
      wifiError = e.message;
      wifiStateText = '扫描失败：${e.message}';
    }
    notifyListeners();
  }

  static int _signalOf(int rssi) {
    if (rssi >= -55) return 3;
    if (rssi >= -70) return 2;
    return 1;
  }

  void wifiMoreToggle() {
    wifiMore = !wifiMore;
    notifyListeners();
  }

  /// 连接已保存网络：设备端凭据由固件自己管理，这里直接下发连接命令。
  Future<void> wifiConnectSaved(String n) async {
    if (wifiJoining || !wifiInRange(n)) return;
    wifiJoining = true;
    wifiJoinName = n;
    wifiError = null;
    notifyListeners();
    try {
      await _gw.connectWifi(n, '');
      wifiLast = n;
      wifiStateText = '$n 连接成功';
    } on CardException catch (e) {
      wifiError = e.message;
      wifiStateText = '连接 $n 失败：${e.message}';
    }
    wifiJoining = false;
    wifiJoinName = '';
    notifyListeners();
  }

  void wifiPick(String n) {
    if (wifiJoining) return;
    wifiSelName = n;
    wifiError = null;
    notifyListeners();
  }

  void wifiCancelPick() {
    wifiSelName = null;
    wifiError = null;
    notifyListeners();
  }

  /// 连接新网络：密码留空视为失败（设备侧会拒绝），错误就地提示可重试。
  Future<void> wifiJoinNew(String pwd) async {
    final sel = wifiSelName;
    if (sel == null) return;
    if (pwd.isEmpty) {
      wifiError = '请输入网络密码';
      notifyListeners();
      return;
    }
    wifiJoining = true;
    wifiJoinName = sel;
    wifiError = null;
    notifyListeners();
    try {
      await _gw.connectWifi(sel, pwd);
      wifiLast = sel;
      wifiStateText = '$sel 连接成功';
      wifiSelName = null;
      // 刷新凭据清单
      await wifiScan();
    } on CardException catch (e) {
      wifiError = e.message;
    }
    wifiJoining = false;
    wifiJoinName = '';
    notifyListeners();
  }

  /// 忘记一个已保存网络（设备端删除 + 本地刷新）。
  Future<void> wifiForget(String ssid) async {
    try {
      await _gw.forgetWifi(ssid);
      wifiSaved = wifiSaved.where((w) => w.name != ssid).toList();
      if (wifiLast == ssid) wifiLast = null;
      notifyListeners();
    } on CardException catch (e) {
      wifiError = e.message;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (fwUpdating) {
      unawaited(_setKeepScreenOn(false));
    }
    _watchHardware.removeListener(_onWatchHardwareChanged);
    if (_ownsWatchHardware) {
      _watchHardware.dispose();
    }
    _clockTimer?.cancel();
    _phoneClockTimer?.cancel();
    _heartbeatTimer?.cancel();
    _eventWatch?.cancel();
    _stopSheetWatch();
    _stopScanExpiryTimer();
    if (_ownsPhoneMicRecorder) {
      _phoneMicRecorder.dispose();
    }
    if (_ownsLegacyUpgrade) {
      legacyUpgrade.dispose();
    }
    if (!_hardwareButtonCtrl.isClosed) {
      unawaited(_hardwareButtonCtrl.close());
    }

    super.dispose();
  }
}
