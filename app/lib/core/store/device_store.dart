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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/audio/live_audio_recorder.dart';
import '../../services/audio/pcm_ring_buffer.dart';
import '../../services/audio/phone_mic_service.dart';
import '../../services/device/oled_bitmap_renderer.dart';
import '../../services/legacy_upgrade/legacy_upgrade_controller.dart';
import '../../services/legacy_upgrade/legacy_upgrade_gateway.dart';
import '../../services/legacy_upgrade/legacy_upgrade_models.dart';
import '../../services/platform/live_activity_service.dart';
import '../../services/platform/local_notification_service.dart';
import '../../services/watch/watch_hardware_service.dart';
import '../device/card_gateway.dart';
import '../platform/bluetooth_permission.dart';
import '../storage/json_store.dart';
import '../storage/secure_store.dart';
import 'agent_config_store.dart';

export '../device/card_gateway.dart' show HardwareButtonEvent;

enum SyncState { idle, busy, done }

/// 最近一次同步是谁触发的：自动（停止录音/后台）还是用户点同步行。
enum SyncTrigger { auto, manual }

enum DeviceView { main, upg, wifi, btn, more }

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
    BluetoothPermission? permission,
    PhoneMicBackend? phoneMicBackend,
    PhoneMicRecorder? phoneMicRecorder,
    LiveActivityService? liveActivityService,
    LocalNotificationService? localNotifications,
    WatchHardwareService? watchHardware,
    LegacyUpgradeController? legacyUpgrade,
    JsonStore? stateStore,
    bool initialWatchLinkEnabled = false,
    bool initialOmiLinkEnabled = false,
    bool initialFeishuLinkEnabled = false,
    bool initialIflytekA1LinkEnabled = false,
    bool deferInitialRestore = false,
    this.onAutoSyncMissedData,
    AgentConfigStore? agentConfig,
    SecureStore? wifiCredentialStore,
    OledBitmapRenderer? oledRenderer,
    Duration? oledHardwareEventDelay,
    Duration? restartReconnectDelay,
    @visibleForTesting Duration? wifiIdleCloseTimeout,
    DateTime Function()? now,
    @visibleForTesting List<Duration>? backgroundReconnectDelays,
    @visibleForTesting Future<CardGateway?> Function()? nativeBridgeRecovery,
  }) : _bleGateway = gateway ?? realOrUnsupported(),
       _allowNativeBridgeRecovery =
           gateway == null || nativeBridgeRecovery != null,
       _nativeBridgeRecovery = nativeBridgeRecovery,
       _permission = permission ?? const BluetoothPermission(),
       _ownsWatchHardware = watchHardware == null,
       _watchHardware = watchHardware ?? WatchHardwareService(),
       _autoStart = autoStart,
       _phoneMicBackend = phoneMicBackend ?? PlatformPhoneMicBackend(),
       _ownsPhoneMicRecorder = phoneMicRecorder == null,
       _phoneMicRecorder = phoneMicRecorder ?? PhoneMicRecorder(),
       _liveActivityService = liveActivityService ?? LiveActivityService(),
       _localNotifications =
           localNotifications ?? LocalNotificationService(),
       _backgroundReconnectDelays =
           backgroundReconnectDelays ?? _defaultBackgroundReconnectDelays,
       _ownsLegacyUpgrade = legacyUpgrade == null,
       _stateStore = stateStore,
       _agentConfig = agentConfig,
       _wifiCredentialStore =
           wifiCredentialStore ??
           ((!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST'))
               ? InMemorySecureStore()
               : KeychainSecureStore()),
       _oledRenderer = oledRenderer ?? const FlutterOledBitmapRenderer(),
       _oledHardwareEventDelay =
           oledHardwareEventDelay ??
           (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')
               ? Duration.zero
               : const Duration(milliseconds: 350)),
       _restartReconnectDelay =
           restartReconnectDelay ??
           (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')
               ? Duration.zero
               : const Duration(seconds: 3)),
       _wifiIdleCloseTimeout = wifiIdleCloseTimeout,
       _now = now ?? DateTime.now {
    _omiLinkEnabled = initialOmiLinkEnabled;
    _feishuLinkEnabled = initialFeishuLinkEnabled;
    _iflytekA1LinkEnabled = initialIflytekA1LinkEnabled;
    _bindDownloadProgressActivity(_bleGateway);
    _gateway = WatchCompositeCardGateway(
      bleGateway: _bleGateway,
      watchService: _watchHardware,
    );
    this.legacyUpgrade = legacyUpgrade ??
        LegacyUpgradeController(
          gateway: BridgeLegacyUpgradeGateway(_gw),
          onAutoReconnect: _autoReconnectAfterLegacyUpgrade,
        );
    final backend = _phoneMicBackend;
    if (backend is PlatformPhoneMicBackend) {
      backend.onAppBecameActive = handleAppResumed;
      backend.onAudioInterruptionEnded = _retryPendingFailoverOnAudioReady;
    }
    _watchHardware.addListener(_onWatchHardwareChanged);
    if (initialWatchLinkEnabled && !deferInitialRestore) {
      unawaited(_watchHardware.setLinkEnabled(true));
    }
    if (autoStart) {
      if (!deferInitialRestore) {
        unawaited(restoreLink());
      }
      _startHeartbeat();
    }
  }

  static const String _lastDeviceStoreKey = 'last_device';
  static const Duration _resumeReconcileCooldown = Duration(seconds: 3);

  final JsonStore? _stateStore;
  int _persistGen = 0;
  bool _restoreInFlight = false;
  DateTime? _lastResumeReconcileAt;
  bool _autoMissedSyncInFlight = false;
  bool _scanInFlight = false;

  /// 是否正在执行启动/回前台设备状态恢复。
  bool get isRestoreInFlight => _restoreInFlight;

  /// 恢复连接且检测到后台停录或存在漏传数据时触发自动补传/冲刷回调。
  Future<String?> Function()? onAutoSyncMissedData;

  /// 生产环境在启动时开启心跳；widget 测试传 false，避免悬挂定时器。
  final bool _autoStart;
  final DateTime Function() _now;
  bool _disposed = false;

  CardGateway _bleGateway;
  final bool _allowNativeBridgeRecovery;
  final Future<CardGateway?> Function()? _nativeBridgeRecovery;
  Future<void>? _bridgeRecoveryInFlight;
  final bool _ownsWatchHardware;
  final WatchHardwareService _watchHardware;
  late final WatchCompositeCardGateway _gateway;
  final PhoneMicBackend _phoneMicBackend;
  final bool _ownsPhoneMicRecorder;
  final PhoneMicRecorder _phoneMicRecorder;
  final LiveActivityService _liveActivityService;
  final LocalNotificationService _localNotifications;
  final List<Duration> _backgroundReconnectDelays;
  final bool _ownsLegacyUpgrade;
  late final LegacyUpgradeController legacyUpgrade;
  AgentConfigStore? _agentConfig;
  final SecureStore _wifiCredentialStore;
  final OledBitmapRenderer _oledRenderer;
  final Duration _oledHardwareEventDelay;
  final Duration _restartReconnectDelay;
  final Duration? _wifiIdleCloseTimeout;
  Timer? _oledDelayTimer;
  int _syncedControlsEpoch = -1;
  bool _controlsSyncInFlight = false;
  int _controlsSyncSeq = 0;
  int _shownConnectOledEpoch = -1;
  DateTime? _lastHardwareRecordOledAt;

  /// 录音卡 V2（CardV2）按键/拨杆 KV 配置写入状态（在「按键行为设置」页内就地展示）。
  bool cardControlsSyncing = false;
  String? cardControlsError;

  /// 硬件远程重启/关机命令执行状态（「更多」二级页内展示）。
  String? _connectedDeviceId;
  bool devicePowerBusy = false;
  String? devicePowerError;
  String _powerStatusText = '';

  bool get hasRecentHardwareRecordOledPrompt =>
      _oledDelayTimer != null ||
      (_lastHardwareRecordOledAt != null &&
          _now().difference(_lastHardwareRecordOledAt!).abs() <
              const Duration(seconds: 2));

  /// 挂载 AgentConfigStore：连接录音卡时读取/初始化默认按键与拨杆绑定。
  void attachAgentConfig(AgentConfigStore config) {
    if (identical(_agentConfig, config)) return;
    _agentConfig = config;
    if (isConnected) {
      unawaited(_syncCardControlsAndDisplayOnConnect(_epoch));
    }
  }

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

  /// 蓝牙授权状态（iOS 在扫描时由系统弹窗；Android 扫描前需动态请求 BLUETOOTH_SCAN / CONNECT）。
  BluetoothAuthorization bleAuth = BluetoothAuthorization.unknown;
  final BluetoothPermission _permission;

  /// 连接代次：异步结果回来时比对，过期丢弃。
  int _epoch = 0;

  bool get isConnected => linkState == LinkState.connected;

  /// 看门狗判掉线、正在自动重连（胶囊蓝点）。
  bool get isReconnecting => linkState == LinkState.reconnecting;
  bool get isLinkBusy =>
      linkState == LinkState.scanning ||
      linkState == LinkState.connecting ||
      linkState == LinkState.reconnecting;

  void _bindDownloadProgressActivity(CardGateway gw) {
    if (gw is RealCardGateway) {
      gw.onDownloadProgressActivity = _markLinkActivity;
    }
  }

  Future<void> _recoverNativeBridgeIfNeeded() {
    if (_bleGateway.available || !_allowNativeBridgeRecovery) {
      return Future<void>.value();
    }
    final existing = _bridgeRecoveryInFlight;
    if (existing != null) return existing;
    final task = () async {
      try {
        final recovered = _nativeBridgeRecovery != null
            ? await _nativeBridgeRecovery()
            : (RealCardGateway.maybe() ??
                  await RealCardGateway.tryBindFromPlatformChannel());
        if (recovered != null && recovered.available) {
          _bleGateway = recovered;
          _bindDownloadProgressActivity(recovered);
          _gateway.rebindBleGateway(recovered);
        }
      } on Object {
        // 保底重绑失败时维持显式 Unsupported 状态
      } finally {
        _bridgeRecoveryInFlight = null;
      }
    }();
    _bridgeRecoveryInFlight = task;
    return task;
  }

  /// 启动或回前台时核对链路：优先恢复上次连接硬件与灵动岛/手表活跃录音态，失败再按未连接呈现。
  Future<void> restoreLink({bool fromResume = false}) async {
    if (_restoreInFlight || isLinkBusy) return;
    _restoreInFlight = true;
    try {
      final epoch = ++_epoch;
      bleAuth = await _permission.status();
      if (epoch != _epoch) return;
      if (!_bleGateway.available && _allowNativeBridgeRecovery) {
        await _recoverNativeBridgeIfNeeded();
        if (epoch != _epoch) return;
      }
      if (!_gateway.available) {
        linkState = LinkState.unsupported;
        linkError = '此设备不支持连接录音卡';
        notifyListeners();
        return;
      }

      final persisted = _stateStore != null
          ? await _loadPersistedLastDevice()
          : null;
      final liveActivity = await _liveActivityService.queryActiveActivity();
      if (_watchHardware.linkEnabled) {
        try {
          await _watchHardware.refreshStatus();
        } on Object {
          // 忽略 Watch 临时查询失败，继续后续检查
        }
      }
      if (epoch != _epoch) return;

      try {
        final snapshot = await _gw.snapshot().timeout(_snapshotTimeout);
        if (epoch != _epoch) return;
        _stopScanExpiryTimer();
        _autoReconnectTarget = null;
        _stopBackgroundAutoReconnect();
        _disconnectNotice = null;
        _pendingPhoneFailover = false;
        linkState = LinkState.connected;
        linkError = null;
        if (_stateStore != null &&
            _lastDevice == null &&
            (snapshot.deviceId.isNotEmpty ||
                snapshot.effectiveKind == DeviceKind.appleWatch)) {
          final id = snapshot.deviceId.isNotEmpty
              ? snapshot.deviceId
              : WatchHardwareService.watchDeviceId;
          final name = snapshot.deviceName.isNotEmpty
              ? snapshot.deviceName
              : snapshot.modelLabel;
          _lastDevice = CardDevice(
            id: id,
            name: name,
            kind: snapshot.effectiveKind,
            displayModel: snapshot.modelLabel,
            capabilities: snapshot.resolvedCapabilities,
          );
          connectedName ??= name;
        } else if (connectedName == null && snapshot.deviceName.isNotEmpty) {
          connectedName = snapshot.deviceName;
        }
        _connectedDeviceId =
            _lastDevice?.id ??
            (snapshot.deviceId.isNotEmpty ? snapshot.deviceId : null);
        final startedAtHint = _resolveRecordingStartedAtHint(
          snapshot: snapshot,
          persisted: persisted,
          liveActivity: liveActivity,
        );
        _applySnapshot(snapshot, recordingStartedAtHint: startedAtHint);
        await _reconcileRecordingOnConnect();
        if (epoch != _epoch) return;
        await _postRestoreSync(
          snapshot: snapshot,
          persisted: persisted,
          liveActivity: liveActivity,
          reconnected: false,
        );
        if (epoch != _epoch) return;
        if (!hasActiveRecording) {
          _stopLiveActivity();
        }
        _persistCurrentDeviceState();
        _startHeartbeat();
        if (sheetOpen) {
          _startSheetWatch();
        }
        unawaited(
          _afterConnect(
            epoch,
            includeRefresh: false,
            includePrefetch: sheetOpen || _autoStart,
          ),
        );
        notifyListeners();
        return;
      } on CardException catch (e) {
        if (epoch != _epoch) return;
        if (e.kind != CardErrorKind.disconnected) {
          linkState = LinkState.disconnected;
          linkError = e.message;
          notifyListeners();
          return;
        }
      } on TimeoutException {
        if (epoch != _epoch) return;
      }

      final target = _resolveRestoreTarget(
        persisted: persisted,
        liveActivity: liveActivity,
      );
      if (target != null) {
        final bleBlocked =
            target.deviceKind != DeviceKind.appleWatch &&
            (bleAuth == BluetoothAuthorization.denied ||
                bleAuth == BluetoothAuthorization.restricted);
        if (!bleBlocked) {
          await _reconnectCachedTarget(
            target,
            epoch: epoch,
            persisted: persisted,
            liveActivity: liveActivity,
          );
          return;
        }
      }

      linkState = LinkState.disconnected;
      linkError = null;
      if (liveActivity.active &&
          !hasActiveRecording &&
          !_pendingPhoneFailover) {
        _stopLiveActivity(force: true);
      }
      if (fromResume) {
        _handleScanExpiryOnResume();
      }
      notifyListeners();
    } finally {
      _restoreInFlight = false;
    }
  }

  bool _isKindAllowedForRestore(DeviceKind kind) => switch (kind) {
    DeviceKind.appleWatch => _watchHardware.linkEnabled,
    DeviceKind.omiCv1 => _omiLinkEnabled,
    DeviceKind.feishuD3200 => _feishuLinkEnabled,
    DeviceKind.iflytekA1 => _iflytekA1LinkEnabled,
    DeviceKind.cardV2 || DeviceKind.dyjV1 || DeviceKind.boardV21 => true,
  };

  Future<PersistedLastDevice?> _loadPersistedLastDevice() async {
    final store = _stateStore;
    if (store == null) return null;
    try {
      final raw = await store.read(_lastDeviceStoreKey);
      return PersistedLastDevice.fromJson(raw);
    } on Object catch (e) {
      debugPrint('[device] 读取持久化设备失败：$e');
      return null;
    }
  }

  void _persistCurrentDeviceState({
    CardDevice? overrideDevice,
    bool? recordingOverride,
  }) {
    final store = _stateStore;
    if (store == null) return;
    final dev = overrideDevice ?? _lastDevice;
    if (dev == null || dev.id.trim().isEmpty) return;
    final rec = recordingOverride ?? isRecording;
    final startedAtMs = rec
        ? (_hwRecordingStartedAt ??
                  _now().subtract(Duration(seconds: _clockTicks)))
              .millisecondsSinceEpoch
        : null;
    final record = PersistedLastDevice(
      id: dev.id,
      name: dev.name.isNotEmpty ? dev.name : dev.modelLabel,
      deviceKind: dev.deviceKind,
      displayModel: dev.modelLabel,
      wasRecording: rec,
      recordingStartedAtMs: startedAtMs,
      savedAtMs: _now().millisecondsSinceEpoch,
    );
    _persistGen++;
    unawaited(
      store.write(_lastDeviceStoreKey, record.toJson()).catchError((Object e) {
        debugPrint('[device] 持久化设备状态失败：$e');
      }),
    );
  }

  void _clearPersistedLastDevice() {
    final store = _stateStore;
    if (store == null) return;
    _persistGen++;
    unawaited(
      store.remove(_lastDeviceStoreKey).catchError((Object e) {
        debugPrint('[device] 清理持久化设备失败：$e');
      }),
    );
  }

  Future<void> _clearPersistedIfMatching(DeviceKind kind) async {
    final clearMem = _lastDevice?.deviceKind == kind;
    if (clearMem) {
      _lastDevice = null;
    }
    final store = _stateStore;
    if (store == null) return;
    final genBefore = _persistGen;
    final existing = await _loadPersistedLastDevice();
    if (genBefore != _persistGen) return;
    if (clearMem || existing?.deviceKind == kind) {
      _persistGen++;
      await store.remove(_lastDeviceStoreKey);
    }
  }

  CardDevice? _resolveRestoreTarget({
    required PersistedLastDevice? persisted,
    required ActiveLiveActivityState liveActivity,
  }) {
    final mem = _lastDevice;
    if (mem != null && _isKindAllowedForRestore(mem.deviceKind)) {
      return mem;
    }
    if (persisted != null && _isKindAllowedForRestore(persisted.deviceKind)) {
      if (persisted.deviceKind == DeviceKind.appleWatch) {
        return _watchHardware.asCardDevice ?? persisted.toCardDevice();
      }
      return persisted.toCardDevice();
    }
    if (liveActivity.isAppleWatch &&
        _watchHardware.linkEnabled &&
        _watchHardware.availableForScan) {
      return _watchHardware.asCardDevice;
    }
    if (_watchHardware.linkEnabled &&
        _watchHardware.availableForScan &&
        (_watchHardware.currentStatus.isRecording ||
            _watchHardware.currentStatus.pendingCount > 0)) {
      return _watchHardware.asCardDevice;
    }
    return null;
  }

  DateTime? _resolveRecordingStartedAtHint({
    required CardSnapshot snapshot,
    required PersistedLastDevice? persisted,
    required ActiveLiveActivityState liveActivity,
  }) {
    if (!snapshot.recording) return null;
    if (liveActivity.active &&
        liveActivity.isHardwareRecording &&
        liveActivity.startedAt != null) {
      return liveActivity.startedAt;
    }
    if (snapshot.effectiveKind == DeviceKind.appleWatch &&
        _watchHardware.currentStatus.startedAtMs > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        _watchHardware.currentStatus.startedAtMs,
      );
    }
    if (persisted != null &&
        persisted.wasRecording &&
        persisted.recordingStartedAtMs != null &&
        persisted.recordingStartedAtMs! > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        persisted.recordingStartedAtMs!,
      );
    }
    return null;
  }

  Future<void> _reconnectCachedTarget(
    CardDevice target, {
    required int epoch,
    required PersistedLastDevice? persisted,
    required ActiveLiveActivityState liveActivity,
  }) async {
    _stopScanExpiryTimer();
    linkState = LinkState.reconnecting;
    linkError = null;
    notifyListeners();
    _markLinkActivity();

    try {
      var snapshot = await _gateway
          .connect(
            target.id,
            name: target.name,
            deviceKind: target.deviceKind.code,
          )
          .timeout(_retryConnectTimeout);
      if (epoch != _epoch) return;
      snapshot ??= await _gw.snapshot().timeout(_snapshotTimeout);
      if (epoch != _epoch) return;

      _markLinkActivity();
      activeKind = target.deviceKind;
      activeCapabilities = target.resolvedCapabilities;
      activeModelLabel = target.modelLabel;
      connectedName = target.name;
      _lastDevice = target;
      _connectedDeviceId = target.id;
      _autoReconnectTarget = null;
      _stopBackgroundAutoReconnect();
      _disconnectNotice = null;
      _pendingPhoneFailover = false;
      linkState = LinkState.connected;
      linkError = null;

      final startedAtHint = _resolveRecordingStartedAtHint(
        snapshot: snapshot,
        persisted: persisted,
        liveActivity: liveActivity,
      );
      _applySnapshot(snapshot, recordingStartedAtHint: startedAtHint);
      await _reconcileRecordingOnConnect();
      if (epoch != _epoch) return;
      await _postRestoreSync(
        snapshot: snapshot,
        persisted: persisted,
        liveActivity: liveActivity,
        reconnected: true,
      );
      if (epoch != _epoch) return;
      _persistCurrentDeviceState(overrideDevice: target);
      _eventSeq = 0;
      _startHeartbeat();
      if (sheetOpen) {
        _startSheetWatch();
      }
      unawaited(
        _afterConnect(
          epoch,
          includeRefresh: false,
          includePrefetch: sheetOpen || _autoStart,
        ),
      );
    } on Object catch (e) {
      if (epoch != _epoch) return;
      debugPrint('[device] 恢复上次设备 ${target.id} 失败：$e');
      linkState = LinkState.disconnected;
      linkError = null;
      if (liveActivity.active &&
          !hasActiveRecording &&
          !_pendingPhoneFailover) {
        _stopLiveActivity(force: true);
      }
    }
    notifyListeners();
  }

  Future<void> _postRestoreSync({
    required CardSnapshot snapshot,
    required PersistedLastDevice? persisted,
    required ActiveLiveActivityState liveActivity,
    required bool reconnected,
  }) async {
    if (snapshot.effectiveKind == DeviceKind.appleWatch) {
      final status = _watchHardware.currentStatus;
      final expectedWatchActive =
          status.pendingCount > 0 ||
          status.isRecording ||
          snapshot.recording ||
          (persisted?.deviceKind == DeviceKind.appleWatch &&
              persisted?.wasRecording == true) ||
          liveActivity.isAppleWatch;
      if (expectedWatchActive) {
        unawaited(_watchHardware.flushAndDrain());
      } else {
        unawaited(_watchHardware.drainPendingSlices());
      }
      if (!snapshot.recording &&
          liveActivity.active &&
          !hasActiveRecording &&
          !_pendingPhoneFailover) {
        _stopLiveActivity(force: true);
      }
      return;
    }

    final currentId = _lastDevice?.id ?? snapshot.deviceId;
    final persistedMatches =
        persisted != null &&
        persisted.wasRecording &&
        (persisted.id == currentId || currentId.isEmpty);
    final expectedRecording =
        persistedMatches || liveActivity.isHardwareRecording;

    if (expectedRecording && !snapshot.recording) {
      if (liveActivity.active &&
          !hasActiveRecording &&
          !_pendingPhoneFailover) {
        _stopLiveActivity(force: true);
      }
      _triggerAutoSyncMissedData();
    } else if (expectedRecording &&
        snapshot.recording &&
        activeCapabilities.hasFileSync &&
        (reconnected || !activeCapabilities.realtimeAudio)) {
      _triggerAutoSyncMissedData();
    } else if (!snapshot.recording &&
        liveActivity.active &&
        !hasActiveRecording &&
        !_pendingPhoneFailover) {
      _stopLiveActivity(force: true);
    }
  }

  void _triggerAutoSyncMissedData() {
    final cb = onAutoSyncMissedData;
    if (cb == null || _autoMissedSyncInFlight) return;
    _autoMissedSyncInFlight = true;
    unawaited(() async {
      try {
        final err = await cb();
        if (err == null) {
          noteSyncFinished(manual: false);
        }
      } on Object catch (e) {
        debugPrint('[device] 恢复后自动补传失败：$e');
      } finally {
        _autoMissedSyncInFlight = false;
      }
    }());
  }

  /// 支持的硬件蓝牙广播名前缀族：
  /// - `DYJV2_*`：录音卡 V2
  /// - `DYJ_*`：点一机 V1
  /// - `REAI_VB_*`：语音 AI 键盘 V2.1
  static const deviceNamePrefix = 'DYJ';

  bool _omiLinkEnabled = false;
  bool _feishuLinkEnabled = false;
  bool _iflytekA1LinkEnabled = false;

  bool get omiLinkEnabled => _omiLinkEnabled;
  bool get feishuLinkEnabled => _feishuLinkEnabled;
  bool get iflytekA1LinkEnabled => _iflytekA1LinkEnabled;

  /// 只展示我们自己的录音卡/点一机/键盘（按需含已开启的 Apple Watch 与第三方硬件）。
  ///
  /// [listAll] 仅供临时排障直通（2026-11-16 Omi 联调用过一次）：扫描列表无过滤列出全部
  /// BLE 设备，识别与开关过滤后置恢复——连接阶段仍按设备 kind 走对应驱动。
  static bool isOurDevice(
    CardDevice device, {
    bool allowWatch = true,
    bool allowOmi = false,
    bool allowFeishu = false,
    bool allowIflytekA1 = false,
    bool listAll = false,
  }) {
    if (listAll) return true;
    final kind = device.kind ?? DeviceKind.fromBleName(device.name);
    if (kind == null) return false;
    return switch (kind) {
      DeviceKind.cardV2 || DeviceKind.dyjV1 || DeviceKind.boardV21 => true,
      DeviceKind.appleWatch => allowWatch,
      DeviceKind.omiCv1 => allowOmi,
      DeviceKind.feishuD3200 => allowFeishu,
      DeviceKind.iflytekA1 => allowIflytekA1,
    };
  }

  Future<void> setExtHardwareEnabled({
    bool? omi,
    bool? feishu,
    bool? iflytekA1,
  }) async {
    final nextOmi = omi ?? _omiLinkEnabled;
    final nextFeishu = feishu ?? _feishuLinkEnabled;
    final nextIflytekA1 = iflytekA1 ?? _iflytekA1LinkEnabled;
    if (nextOmi == _omiLinkEnabled &&
        nextFeishu == _feishuLinkEnabled &&
        nextIflytekA1 == _iflytekA1LinkEnabled) {
      return;
    }
    _omiLinkEnabled = nextOmi;
    _feishuLinkEnabled = nextFeishu;
    _iflytekA1LinkEnabled = nextIflytekA1;
    if ((!nextOmi && isConnected && activeKind == DeviceKind.omiCv1) ||
        (!nextFeishu && isConnected && activeKind == DeviceKind.feishuD3200) ||
        (!nextIflytekA1 && isConnected && activeKind == DeviceKind.iflytekA1)) {
      await disconnectSafely();
    }
    if (!nextOmi) {
      await _clearPersistedIfMatching(DeviceKind.omiCv1);
    }
    if (!nextFeishu) {
      await _clearPersistedIfMatching(DeviceKind.feishuD3200);
    }
    if (!nextIflytekA1) {
      await _clearPersistedIfMatching(DeviceKind.iflytekA1);
    }
    if (discovered.isNotEmpty) {
      discovered = discovered
          .where(
            (d) => isOurDevice(
              d,
              allowWatch: watchHardware.linkEnabled,
              allowOmi: _omiLinkEnabled,
              allowFeishu: _feishuLinkEnabled,
              allowIflytekA1: _iflytekA1LinkEnabled,
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
    if (!enabled) {
      if (isConnected && activeKind == DeviceKind.appleWatch) {
        await disconnectSafely();
      } else {
        await _clearPersistedIfMatching(DeviceKind.appleWatch);
        notifyListeners();
      }
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
            unawaited(
              _triggerCompanionFailover(
                reason: faultMsg,
                carrySecOverride: prevClock,
              ),
            );
          }
        } else {
          _phoneStandbyArmed = false;
        }
      }
    } else if (_watchFailoverRecording) {
      final lost = _watchHardware.consumeUnexpectedDisconnect() ||
          _watchHardware.isOutOfRangeDisconnected;
      final s = _watchHardware.currentStatus;
      final faultMsg = s.lastError?.trim() ?? '';
      if (lost || s.linkLost || !s.paired || !s.watchAppInstalled) {
        final carrySec = _watchFailoverRecSec;
        _stopWatchFailoverStateOnly();
        if (_phoneStandbyArmed) {
          unawaited(
            _triggerPhoneFailover(
              carrySecOverride: carrySec,
              reason: s.linkLost
                  ? 'Apple Watch 断开连接'
                  : 'Apple Watch 暂不可用',
            ),
          );
        }
      } else if (!s.isRecording) {
        final carrySec = _watchFailoverRecSec;
        _stopWatchFailoverStateOnly();
        if (faultMsg.isNotEmpty && _phoneStandbyArmed) {
          recordingError = faultMsg;
          unawaited(
            _triggerPhoneFailover(
              carrySecOverride: carrySec,
              reason: faultMsg,
            ),
          );
        } else {
          // 用户在手表侧主动正常停录：尊重用户主动意图，解除待命兜底
          _phoneStandbyArmed = false;
          if (!hasActiveRecording) {
            _stopLiveActivity(force: true);
          }
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
  Future<void> startScan({bool userInitiated = false}) async {
    if (_scanInFlight ||
        linkState == LinkState.scanning ||
        linkState == LinkState.connecting) {
      return; // 防重入：扫描或建连中再点不重复发起（SDK 要求串行）
    }
    _scanInFlight = true;
    try {
      if (!_bleGateway.available && _allowNativeBridgeRecovery) {
        await _recoverNativeBridgeIfNeeded();
      }
      if (!_gateway.available) {
        linkState = LinkState.unsupported;
        linkError = '此设备不支持连接录音卡';
        notifyListeners();
        return;
      }
      final interruptReconnect = linkState == LinkState.reconnecting;
      if (interruptReconnect && !userInitiated) {
        return;
      }

      final epoch = ++_epoch;
      if (interruptReconnect) {
        _stopScanExpiryTimer();
        _bleScanSeenAt = null;
        _scanExpiredByTimer = false;
        linkState = LinkState.scanning;
        linkError = null;
        discovered = const [];
        notifyListeners();
        await _releaseLink();
        if (epoch != _epoch) return;
      }

      // iOS 底层（Rust/CoreBluetooth）在扫描时会自己触发系统对话框，这里不阻塞等待；
      // Android 底层（droidplug / BluetoothLeScanner）不会自动申请运行时权限，若为 notDetermined
      // 必须先主动调用 request()，否则 startScan() 会直接抛 SecurityException。
      bleAuth = await _permission.status();
      if (epoch != _epoch || _disposed) return;
      if (bleAuth == BluetoothAuthorization.notDetermined &&
          defaultTargetPlatform == TargetPlatform.android) {
        bleAuth = await _permission.request();
        if (epoch != _epoch || _disposed) return;
      }
      if (!_watchHardware.availableForScan &&
          (bleAuth == BluetoothAuthorization.denied ||
              bleAuth == BluetoothAuthorization.restricted ||
              (defaultTargetPlatform == TargetPlatform.android &&
                  !bleAuth.canScan))) {
        linkState = LinkState.disconnected;
        linkError = bleAuth.hint;
        notifyListeners();
        return;
      }

      _stopScanExpiryTimer();
      _bleScanSeenAt = null;
      _scanExpiredByTimer = false;
      linkState = LinkState.scanning;
      linkError = null;
      discovered = const [];
      notifyListeners();
      final scanStartedAt = DateTime.now();
      try {
        final list = await _gw.scan();
        if (epoch != _epoch) return;
        // 近的设备排前面：RSSI 越大信号越强（-50 比 -80 近）。无 RSSI 的排最后。
        discovered = [
          for (final device in list)
            if (isOurDevice(
              device,
              allowWatch: watchHardware.linkEnabled,
              allowOmi: _omiLinkEnabled,
              allowFeishu: _feishuLinkEnabled,
              allowIflytekA1: _iflytekA1LinkEnabled,
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
        final ble = _bleGateway;
        if (ble is RealCardGateway && ble.isNativeFfi) {
          final elapsed = DateTime.now().difference(scanStartedAt);
          const minFeedback = Duration(milliseconds: 280);
          if (elapsed < minFeedback) {
            await Future<void>.delayed(minFeedback - elapsed);
            if (epoch != _epoch) return;
          }
        }
        _stopScanExpiryTimer();
        _bleScanSeenAt = null;
        _scanExpiredByTimer = false;
        discovered = const [];
        linkState = LinkState.disconnected;
        linkError = e.message;
      }
      notifyListeners();
    } finally {
      _scanInFlight = false;
    }
  }

  Future<void> connectTo(CardDevice device) async {
    if (linkState == LinkState.connecting) return;
    if (isDeviceScanExpired(device)) {
      linkError = '蓝牙设备列表已过期，请重新扫描';
      notifyListeners();
      return;
    }
    final epoch = ++_epoch;
    _autoReconnectTarget = null;
    _stopBackgroundAutoReconnect();
    _stopScanExpiryTimer();
    linkState = LinkState.connecting;
    linkError = null;
    _powerStatusText = '';
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
      _connectedDeviceId = device.id;
      _autoReconnectTarget = null;
      _stopBackgroundAutoReconnect();
      _disconnectNotice = null;
      if (!_isDfuBootloaderName(device.name)) {
        _lastKnownNormalCardV2Name = device.deviceKind == DeviceKind.cardV2
            ? device.name
            : null;
      }
      linkState = LinkState.connected;
      linkError = null;
      _applySnapshot(snapshot);
      await _reconcileRecordingOnConnect();
      if (epoch != _epoch) return;
      _persistCurrentDeviceState(overrideDevice: device);
      _pendingPhoneFailover = false;
      _pendingFailoverCarrySec = 0;
      if (!hasActiveRecording) {
        _stopLiveActivity();
      }
      _eventSeq = 0;
      _startHeartbeat();
      if (sheetOpen) {
        _startSheetWatch();
      }
      unawaited(_afterConnect(epoch));
      unawaited(_localNotifications.cancelDeviceAlert());
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

  /// 连上后的收尾：若快照缺失关键状态则补拉一次，再串行同步按键配置，最后预取概要与版本检查。
  Future<void> _afterConnect(
    int epoch, {
    bool includeRefresh = true,
    bool includePrefetch = true,
  }) async {
    if (epoch != _epoch || !isConnected) return;
    if (includeRefresh && (_fwVersionCode == 0 || _liveBattery == null)) {
      await refreshFromDevice();
      if (epoch != _epoch || !isConnected) return;
    }
    if (isCardV2WifiOtaOnly &&
        deviceWifiOpen == true &&
        !fwUpdating &&
        !_wifiScanInFlight &&
        !wifiJoining &&
        !_shouldKeepCardV2WifiOpen()) {
      await _closeWifiQuietly();
      if (epoch != _epoch || !isConnected) return;
    }
    await _syncCardControlsAndDisplayOnConnect(epoch);
    if (epoch != _epoch || !isConnected) return;
    if (includePrefetch) {
      await prefetchSummaryInfo();
    }
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
  Future<void> _prepareForHardwareTeardown() async {
    _cancelWifiIdleCloseTimer();
    _wifiClosePending = false;
    _phoneStandbyArmed = false;
    _pendingPhoneFailover = false;
    _autoReconnectTarget = null;
    _stopBackgroundAutoReconnect();
    _disconnectNotice = null;
    _pendingPostReconnectSync = false;
    _hwRecordingStartedAt = null;
    _clearPersistedLastDevice();
    if (isRecording) {
      try {
        await _gw.stopRecording().timeout(const Duration(seconds: 5));
      } on Object {
        // 停不下来也要继续后续释放/电源命令，不能把用户卡在当前状态
      }
      _liveRecording = false;
    }
    try {
      await _gw.closeRealtime().timeout(const Duration(seconds: 3));
    } on Object {
      // 同上
    }
    if (isCardV2WifiOtaOnly && deviceWifiOpen == true) {
      try {
        await _gw.closeWifi().timeout(const Duration(seconds: 4));
        deviceWifiOpen = false;
      } on Object {
        // 断开/重启/关机前尽力关闭 Wi-Fi，不阻断后续释放
      }
    }
  }

  Future<String?> _sendPowerCommand(
    String command, {
    required String timeoutMessage,
  }) async {
    try {
      await _gw
          .invokeBridgeCommand(
            command,
            const <String, dynamic>{},
            const Duration(seconds: 10),
          )
          .timeout(const Duration(seconds: 10));
      return null;
    } on CardException catch (e) {
      if (e.kind == CardErrorKind.disconnected) return null;
      devicePowerError = e.message;
      notifyListeners();
      return devicePowerError;
    } on TimeoutException {
      devicePowerError = timeoutMessage;
      notifyListeners();
      return devicePowerError;
    } on Object catch (e) {
      devicePowerError = '$e';
      notifyListeners();
      return devicePowerError;
    }
  }

  Future<void> disconnectSafely() async {
    await _prepareForHardwareTeardown();
    await disconnectDevice();
  }

  /// 远程重启已连接硬件，并在重启后自动尝试重连回同一台设备。
  Future<String?> restartDevice() async {
    if (!isConnected) {
      return '当前未连接设备';
    }
    if (!activeCapabilities.hasDeviceRestart) {
      return '当前硬件不支持远程重启';
    }
    if (devicePowerBusy) {
      return '正在执行上一条电源命令，请稍候';
    }
    final targetId = _lastDevice?.id ?? _connectedDeviceId ?? '';
    final targetName =
        _lastDevice?.name ?? connectedName ?? activeModelLabel;
    final targetKind = _lastDevice?.deviceKind ?? activeKind;
    final targetCaps = _lastDevice?.capabilities ?? activeCapabilities;
    final fallbackTarget =
        _lastDevice ??
        (targetId.isNotEmpty
            ? CardDevice(
                id: targetId,
                name: targetName,
                kind: targetKind,
                capabilities: targetCaps,
              )
            : null);

    devicePowerBusy = true;
    devicePowerError = null;
    notifyListeners();
    try {
      await _prepareForHardwareTeardown();
      if (!_phoneRecording && !_watchFailoverRecording) {
        _stopLiveActivity(force: true);
      }
      final cmdError = await _sendPowerCommand(
        'device.restart',
        timeoutMessage: '重启命令超时，请重试',
      );
      if (cmdError != null) return cmdError;

      final epoch = ++_epoch;
      _oledDelayTimer?.cancel();
      _oledDelayTimer = null;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _eventWatch?.cancel();
      _eventWatch = null;
      _stopSheetWatch();
      try {
        await _gw.disconnect().timeout(const Duration(seconds: 5));
      } on Object {
        // 忽略旧链路释放异常，继续进入自动重连
      }
      if (epoch != _epoch || _disposed) return null;

      _resetLiveState();
      recordingError = null;
      view = DeviceView.main;
      connectedName = targetName;
      linkState = LinkState.reconnecting;
      linkError = null;
      _powerStatusText = '设备正在重启，等待自动重连…';
      notifyListeners();

      if (_restartReconnectDelay > Duration.zero) {
        await Future<void>.delayed(_restartReconnectDelay);
        if (epoch != _epoch || _disposed) return null;
      }

      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          final retryWait = _restartReconnectDelay > Duration.zero
              ? const Duration(seconds: 2)
              : Duration.zero;
          if (retryWait > Duration.zero) {
            await Future<void>.delayed(retryWait);
            if (epoch != _epoch || _disposed) return null;
          }
        }
        var scanned = const <CardDevice>[];
        try {
          scanned = await _gw.scan();
        } on Object {
          scanned = const <CardDevice>[];
        }
        if (epoch != _epoch || _disposed) return null;

        CardDevice? candidate;
        if (targetId.isNotEmpty) {
          candidate = scanned.where((d) => d.id == targetId).firstOrNull;
        }
        candidate ??= targetName.isNotEmpty
            ? scanned
                  .where((d) => d.name == targetName && d.deviceKind == targetKind)
                  .firstOrNull
            : null;
        candidate ??= fallbackTarget;
        if (candidate == null) continue;

        try {
          _markLinkActivity();
          var snap = await _gw
              .connect(
                candidate.id,
                name: candidate.name,
                deviceKind: candidate.deviceKind.code,
              )
              .timeout(_retryConnectTimeout);
          if (epoch != _epoch || _disposed) return null;
          snap ??= await _gw.snapshot().timeout(_snapshotTimeout);
          if (epoch != _epoch || _disposed) return null;

          _markLinkActivity();
          activeKind = candidate.deviceKind;
          activeCapabilities = candidate.resolvedCapabilities;
          activeModelLabel = candidate.modelLabel;
          connectedName = candidate.name;
          _lastDevice = candidate;
          _connectedDeviceId = candidate.id;
          if (!_isDfuBootloaderName(candidate.name)) {
            _lastKnownNormalCardV2Name = candidate.deviceKind == DeviceKind.cardV2
                ? candidate.name
                : null;
          }
          linkState = LinkState.connected;
          linkError = null;
          recordingError = null;
          devicePowerError = null;
          _applySnapshot(snap);
          await _reconcileRecordingOnConnect();
          if (epoch != _epoch || _disposed) return null;
          _eventSeq = 0;
          _startHeartbeat();
          if (sheetOpen) {
            _startSheetWatch();
          }
          unawaited(_afterConnect(epoch));
          _powerStatusText = '设备已重启并重新连接';
          notifyListeners();
          return null;
        } on Object {
          await _releaseLink();
          if (epoch != _epoch || _disposed) return null;
        }
      }

      if (epoch == _epoch && !_disposed) {
        linkState = LinkState.disconnected;
        connectedName = null;
        _powerStatusText = '';
        linkError = '设备已重启，请点击重新连接';
        notifyListeners();
        return linkError;
      }
      return null;
    } finally {
      devicePowerBusy = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// 远程关闭硬件电源并安全断开蓝牙连接。
  Future<String?> shutdownDevice() async {
    if (!isConnected) {
      return '当前未连接设备';
    }
    if (!activeCapabilities.hasDeviceShutdown) {
      return '当前硬件不支持远程关机';
    }
    if (devicePowerBusy) {
      return '正在执行上一条电源命令，请稍候';
    }

    devicePowerBusy = true;
    devicePowerError = null;
    notifyListeners();
    try {
      await _prepareForHardwareTeardown();
      final cmdError = await _sendPowerCommand(
        'device.shutdown',
        timeoutMessage: '关机命令超时，请重试',
      );
      if (cmdError != null) return cmdError;

      view = DeviceView.main;
      recordingError = null;
      await disconnectDevice();
      if (!_disposed) {
        linkError = null;
        _powerStatusText = '';
        notifyListeners();
      }
      return null;
    } finally {
      devicePowerBusy = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> disconnectDevice() async {
    final epoch = ++_epoch;
    _phoneStandbyArmed = false;
    _pendingPhoneFailover = false;
    _autoReconnectTarget = null;
    _stopBackgroundAutoReconnect();
    _disconnectNotice = null;
    _pendingPostReconnectSync = false;
    _hwRecordingStartedAt = null;
    _oledDelayTimer?.cancel();
    _oledDelayTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _eventWatch?.cancel();
    _eventWatch = null;
    _stopSheetWatch();
    _lastDevice = null;
    _clearPersistedLastDevice();
    _lastKnownNormalCardV2Name = null;
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
    if (!_phoneRecording && !_watchFailoverRecording) {
      _stopLiveActivity(force: true);
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
    _oledDelayTimer?.cancel();
    _oledDelayTimer = null;
    _syncedControlsEpoch = -1;
    _controlsSyncInFlight = false;
    _controlsSyncSeq++;
    _shownConnectOledEpoch = -1;
    _lastHardwareRecordOledAt = null;
    cardControlsSyncing = false;
    cardControlsError = null;
    _connectedDeviceId = null;
    devicePowerError = null;
    _powerStatusText = '';
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
    _cancelWifiIdleCloseTimer();
    _wifiScanInFlight = false;
    _wifiClosePending = false;
    _wifiClosingInFlight = false;
    _wifiReturnView = DeviceView.main;
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
        if (!hasActiveRecording && !_pendingPhoneFailover) {
          _stopLiveActivity();
        }
      }
      return;
    }
    _liveRecording = recording;
    final carrySec = _clockTicks;
    _clockTicks = 0;
    final reason = status['reason']?.toString().trim().toLowerCase() ?? '';
    if (!recording) {
      _stopClock();
      _hwRecordingStartedAt = null;
      _persistCurrentDeviceState(recordingOverride: false);
      if (hasDeviceFault && _phoneStandbyArmed) {
        // 硬件因故障/存储满意外停止录音（非用户主动停录）：按 Watch 优先 → 手机本机 顺序接力兜底
        unawaited(
          _triggerCompanionFailover(
            reason: recordingError ?? '设备录音异常中断',
            carrySecOverride: carrySec,
          ),
        );
      } else {
        // 用户在硬件机身拨杆/按键主动停止录音：解除待命并关闭灵动岛实况
        _phoneStandbyArmed = false;
        _pendingPhoneFailover = false;
        if (!hasActiveRecording) {
          _stopLiveActivity(force: true);
        }
        if (activeCapabilities.hasOledDisplay &&
            (reason == 'switch' || reason == 'button')) {
          _scheduleHardwareRecordOledPrompt(recording: false, reason: reason);
        }
      }
      return;
    }
    _hwRecordingStartedAt = _now();
    _phoneStandbyArmed = true;
    _persistCurrentDeviceState(recordingOverride: true);
    if (_clockUsers > 0) _startClock();
    if (_phoneRecording && !_otaHandoverPhoneRecording) {
      unawaited(
        stopPhoneRecording(keepStandbyArmed: true, stopLiveActivity: false),
      );
    }
    _syncLiveActivity();
    if (activeCapabilities.hasOledDisplay &&
        (reason == 'switch' || reason == 'button')) {
      _scheduleHardwareRecordOledPrompt(recording: true, reason: reason);
    }
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
  static const List<Duration> _defaultBackgroundReconnectDelays = [
    Duration(seconds: 15),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 45),
    Duration(seconds: 60),
  ];

  /// 重连只发 connect（不再预拉快照），但桥内要先扫描再建链路，
  /// 上限给到 32s（覆盖原生扫描 + 握手最坏耗时），避免把"正在重连"误判成失败。
  static const _retryConnectTimeout = Duration(seconds: 32);

  Timer? _heartbeatTimer;
  bool _watchdogProbing = false;

  CardDevice? _autoReconnectTarget;
  Timer? _autoReconnectTimer;
  int _autoReconnectAttempt = 0;
  bool _backgroundReconnecting = false;
  bool _pendingPostReconnectSync = false;
  String? _disconnectNotice;

  /// 外部 BLE 同步管线（例如 RecordingPipeline.sync）是否正在忙，忙时顺延心跳探测避免误判断连。
  bool Function()? isExternalBleSyncBusy;

  /// 蓝牙设备后台自动重连恢复后触发（用于冲刷伴随路并补拉离线切片与多路比对合并）。
  Future<void> Function(CardDevice device)? onBleReconnectedNeedSync;

  bool get isBackgroundReconnectArmed => _autoReconnectTarget != null;
  CardDevice? get autoReconnectTarget => _autoReconnectTarget;
  String? get disconnectNotice => _disconnectNotice;

  void dismissDisconnectNotice() {
    final clearPending = _pendingPhoneFailover && !hasActiveRecording;
    if (_disconnectNotice == null && !clearPending) return;
    _disconnectNotice = null;
    if (clearPending) {
      _pendingPhoneFailover = false;
      _pendingFailoverCarrySec = 0;
      _phoneStandbyArmed = false;
      _stopLiveActivity(force: true);
    }
    notifyListeners();
  }

  bool consumePendingPostReconnectSync() {
    final v = _pendingPostReconnectSync;
    _pendingPostReconnectSync = false;
    return v;
  }

  /// 标记下一次空闲/重连恢复后补拉设备离线切片（例如现场开录打断离线同步时）。
  void markPendingPostReconnectSync() {
    _pendingPostReconnectSync = true;
  }

  String _disconnectTargetLabel(CardDevice? target) {
    final tName = target?.name.trim() ?? '';
    if (tName.isNotEmpty) return tName;
    final cName = connectedName?.trim() ?? '';
    if (cName.isNotEmpty) return cName;
    final model = activeModelLabel.trim();
    if (model.isNotEmpty) return model;
    return '录音卡';
  }

  String _inferUnexpectedDisconnectReason(String? detail) {
    if (_liveBattery != null && _liveBattery! <= 10 && _liveCharging != true) {
      return '设备电量耗尽或过低';
    }
    final raw = detail?.trim() ?? '';
    if (raw.contains('超时') || raw.toLowerCase().contains('timeout')) {
      return '设备超出蓝牙距离或无响应';
    }
    if (raw.contains('存储')) {
      return raw;
    }
    return '设备蓝牙连接意外中断（可能没电或超出距离）';
  }

  void _notifyDisconnectBannerAndAlert({
    CardDevice? target,
    required String reason,
  }) {
    final label = _disconnectTargetLabel(target);
    _disconnectNotice ??= '$label 已断开（$reason），正在后台等待设备回到附近自动重连';
    if (!_phoneStandbyArmed) {
      unawaited(
        _localNotifications.notifyBleDisconnected(
          deviceName: label,
          body: '$reason · 回到附近后将自动重连并拉取数据',
        ),
      );
    }
  }

  void _stopBackgroundAutoReconnect() {
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _backgroundReconnecting = false;
    _autoReconnectAttempt = 0;
  }

  void _scheduleNextBackgroundReconnect() {
    if (!_autoStart || _autoReconnectTarget == null || isConnected || fwUpdating) {
      return;
    }
    _autoReconnectTimer?.cancel();
    final delays = _backgroundReconnectDelays.isNotEmpty
        ? _backgroundReconnectDelays
        : _defaultBackgroundReconnectDelays;
    final delayIdx = _autoReconnectAttempt.clamp(0, delays.length - 1);
    final delay = delays[delayIdx];
    _autoReconnectAttempt++;
    _autoReconnectTimer = Timer(delay, () {
      _autoReconnectTimer = null;
      unawaited(_attemptBackgroundReconnect());
    });
  }

  Future<void> _attemptBackgroundReconnect() async {
    final target = _autoReconnectTarget;
    if (target == null ||
        isConnected ||
        fwUpdating ||
        _backgroundReconnecting ||
        !_gateway.available) {
      return;
    }
    if (linkState == LinkState.scanning ||
        linkState == LinkState.connecting ||
        linkState == LinkState.reconnecting) {
      _scheduleNextBackgroundReconnect();
      return;
    }
    _backgroundReconnecting = true;
    final epoch = _epoch;
    try {
      var snapshot = await _gateway
          .connect(
            target.id,
            name: target.name,
            deviceKind: target.deviceKind.code,
          )
          .timeout(_retryConnectTimeout);
      if (epoch != _epoch) return;
      snapshot ??= await _gw.snapshot().timeout(_snapshotTimeout);
      if (epoch != _epoch) return;
      _markLinkActivity();
      await _completeBleReconnectSuccess(target, snapshot, epoch);
    } on Object catch (e) {
      if (epoch != _epoch) return;
      debugPrint('[auto-reconnect] attempt failed: $e');
      await _releaseLink();
      if (epoch != _epoch) return;
      _backgroundReconnecting = false;
      _scheduleNextBackgroundReconnect();
    } finally {
      _backgroundReconnecting = false;
    }
  }

  Future<void> _completeBleReconnectSuccess(
    CardDevice device,
    CardSnapshot snapshot,
    int epoch,
  ) async {
    _stopBackgroundAutoReconnect();
    _autoReconnectTarget = null;
    _disconnectNotice = null;

    activeKind = device.deviceKind;
    activeCapabilities = device.resolvedCapabilities;
    activeModelLabel = device.modelLabel;
    connectedName = device.name;
    _lastDevice = device;
    _connectedDeviceId = device.id;
    if (!_isDfuBootloaderName(device.name)) {
      _lastKnownNormalCardV2Name = device.deviceKind == DeviceKind.cardV2
          ? device.name
          : null;
    }
    linkState = LinkState.connected;
    linkError = null;
    _applySnapshot(snapshot);
    await _reconcileRecordingOnConnect();
    if (epoch != _epoch) return;
    _persistCurrentDeviceState(overrideDevice: device);
    _pendingPhoneFailover = false;
    _pendingFailoverCarrySec = 0;
    if (!hasActiveRecording) {
      _stopLiveActivity();
    }
    _startHeartbeat();
    if (sheetOpen) {
      _startSheetWatch();
    }
    unawaited(_afterConnect(epoch));
    unawaited(
      _localNotifications.notifyBleReconnected(
        deviceName: _hardwareActivityLabel,
        body: isRecording && activeCapabilities.realtimeAudio
            ? '已恢复硬件录音并退回零功耗待命，停录后将自动合并离线数据'
            : '正在自动拉取设备离线录音并比对合并…',
      ),
    );
    if (!isRecording || !activeCapabilities.realtimeAudio) {
      _pendingPostReconnectSync = false;
      final cb = onBleReconnectedNeedSync;
      if (cb != null) {
        unawaited(cb(device));
      }
    } else {
      _pendingPostReconnectSync = true;
    }
    notifyListeners();
  }

  /// 距离最近一次蓝牙传输过去了多久（由看门狗自己的节拍累加，用单调时钟）。
  ///
  /// 刻意不用 DateTime.now() 之差：测试环境是假时钟、不随 pump 推进，
  /// 而真机上又可能被系统休眠拉长间隔；用定时器累加两边行为才一致。
  Duration _sinceLinkActivity = Duration.zero;

  /// 上一次连接用的设备：掉线时直接拿它的 id 重连，不靠扫描。
  CardDevice? _lastDevice;

  /// 最近一次在正常模式下确认过的 V2 广播名（即使中途掉入 DFU_DYJ 恢复模式也保留，防止多卡同场回连串卡）。
  String? _lastKnownNormalCardV2Name;

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
    _refreshEventWatch();
  }

  /// 按当前硬件能力刷新后台事件轮询节拍：具备按键/打点能力时采用 200ms 保证 iOS Omi 物理按键即时响应。
  void _refreshEventWatch() {
    _eventWatch?.cancel();
    _eventWatch = null;
    if (!_autoStart || !isConnected) return;
    final fastButtons =
        activeCapabilities.hasConfigurableButtons ||
        activeCapabilities.hasMarkButton;
    final eventInterval = fastButtons
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
    // 固件升级/同步/外部下载管线/录音命令链路忙：不插队，且这些动作本身已算活动
    if (fwUpdating ||
        syncing ||
        _linkBusy ||
        (isExternalBleSyncBusy?.call() ?? false)) {
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
    final disconnectReason = _inferUnexpectedDisconnectReason(detail);
    // 若录音待命保底已武装，立即按 Watch 优先 → 手机本机 顺序无缝接力，不等待旧链路释放超时
    if (_phoneStandbyArmed &&
        !_phoneRecording &&
        !_phoneRecordingBusy &&
        !_watchFailoverRecording) {
      final carrySec = _clockTicks;
      _liveRecording = false;
      _stopClock();
      unawaited(
        _triggerCompanionFailover(
          reason: disconnectReason,
          carrySecOverride: carrySec,
        ),
      );
    }
    // 判定掉线后先让桥真正释放旧链路，再重连。
    // 只换 UI 状态不释放链路（以前的"假断开"）会让设备端继续认为已连接、
    // 停止对外广播，重连也就扫不到它。
    await _releaseLink();
    if (epoch != _epoch) return;
    unawaited(_retryReconnect(disconnectReason: disconnectReason));
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

  /// 掉线自动重连：蓝点 → 直连上次设备；失败后挂起后台自动重连并在期间保持伴随路兜底。
  Future<void> _retryReconnect({String? disconnectReason}) async {
    if (linkState == LinkState.reconnecting) return; // 已在重试中，不重复
    if (!isConnected) return;
    final targetDevice = _lastDevice;
    final reason = disconnectReason ?? _inferUnexpectedDisconnectReason(null);
    final carrySec = _clockTicks;
    // 探测失败或收到断连事件说明链路已中断：若录音保底已待命，立即按优先级拉起伴随兜底（Watch > 手机）
    if (_phoneStandbyArmed &&
        !_phoneRecording &&
        !_phoneRecordingBusy &&
        !_watchFailoverRecording) {
      _liveRecording = false;
      _stopClock();
      unawaited(
        _triggerCompanionFailover(
          reason: reason,
          carrySecOverride: carrySec,
        ),
      );
    }
    // 先立刻转蓝点，别让用户看到「已连接」再闪断
    linkState = LinkState.reconnecting;
    linkError = null;
    notifyListeners();
    final device = targetDevice;
    if (device == null || !_gateway.available) {
      // 连设备 id 都没有，重连无从谈起：立刻回到灰点，别让用户干等几秒蓝点。
      // 桥里的旧句柄仍要清掉（后台尽力而为），否则设备端可能保持连接、不重新广播。
      _dropToDisconnected(
        '与录音卡的连接已断开',
        lostDevice: device,
        reason: reason,
      );
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
      await _completeBleReconnectSuccess(device, snapshot, epoch);
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
      _dropToDisconnected(
        '与录音卡的连接已断开，请重新连接',
        lostDevice: device,
        reason: reason,
      );
    }
    notifyListeners();
  }

  void _dropToDisconnected(
    String message, {
    CardDevice? lostDevice,
    String? reason,
  }) {
    final carrySec = _clockTicks;
    _oledDelayTimer?.cancel();
    _oledDelayTimer = null;
    _syncedControlsEpoch = -1;
    _controlsSyncInFlight = false;
    _controlsSyncSeq++;
    _shownConnectOledEpoch = -1;
    _lastHardwareRecordOledAt = null;
    cardControlsSyncing = false;
    cardControlsError = null;
    _connectedDeviceId = null;
    devicePowerError = null;
    _powerStatusText = '';
    final target = lostDevice ?? _lastDevice;
    final dropReason = reason ?? _inferUnexpectedDisconnectReason(message);
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
    if (target != null && target.deviceKind != DeviceKind.appleWatch) {
      _autoReconnectTarget = target;
      _autoReconnectAttempt = 0;
      _scheduleNextBackgroundReconnect();
    }
    _notifyDisconnectBannerAndAlert(target: target, reason: dropReason);
    if (_phoneStandbyArmed &&
        !_phoneRecording &&
        !_phoneRecordingBusy &&
        !_watchFailoverRecording) {
      unawaited(
        _triggerCompanionFailover(
          reason: dropReason,
          carrySecOverride: carrySec,
        ),
      );
    } else if (!hasActiveRecording && !_pendingPhoneFailover) {
      _stopLiveActivity();
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

  void _applySnapshot(CardSnapshot s, {DateTime? recordingStartedAtHint}) {
    final prevCaps = activeCapabilities;
    activeKind = s.effectiveKind;
    activeCapabilities = s.resolvedCapabilities;
    activeModelLabel = s.modelLabel;
    if (prevCaps.hasConfigurableButtons !=
            activeCapabilities.hasConfigurableButtons ||
        prevCaps.hasMarkButton != activeCapabilities.hasMarkButton) {
      _refreshEventWatch();
    }
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
    if (s.deviceId.isNotEmpty) {
      _connectedDeviceId = s.deviceId;
    }
    if ((connectedName == null || connectedName!.isEmpty) &&
        s.deviceName.isNotEmpty) {
      connectedName = s.deviceName;
    }
    if (s.effectiveKind == DeviceKind.cardV2 &&
        s.deviceName.isNotEmpty &&
        !_isDfuBootloaderName(s.deviceName)) {
      _lastKnownNormalCardV2Name = s.deviceName;
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
    final hintElapsed = recordingStartedAtHint != null
        ? _now().difference(recordingStartedAtHint).inSeconds
        : 0;
    if (s.recording != prevRecording) {
      _liveRecording = s.recording;
      _clockTicks = (s.recording && hintElapsed > 0) ? hintElapsed : 0;
      // 录音计时跨页面持续走：Timeline 顶部状态块与弹层用的是同一个时钟。
      // 只有 UI 持有（retainClock）时才真正起表；停止录音/断开立即停表。
      if (s.recording) {
        _hwRecordingStartedAt =
            recordingStartedAtHint ?? _phoneRecordingStartedAt ?? _now();
        _phoneStandbyArmed = true;
      } else {
        _hwRecordingStartedAt = null;
        _stopClock();
      }
      if (isConnected) {
        _persistCurrentDeviceState(recordingOverride: s.recording);
      }
    } else if (s.recording) {
      _phoneStandbyArmed = true;
      if (recordingStartedAtHint != null) {
        _hwRecordingStartedAt = recordingStartedAtHint;
        if (hintElapsed > _clockTicks) {
          _clockTicks = hintElapsed;
        }
      } else {
        _hwRecordingStartedAt ??= _now();
      }
    }
    if (s.recording && _clockUsers > 0) _startClock();
    if (isConnected) {
      if (s.recording) {
        if (_watchFailoverRecording) {
          unawaited(
            stopWatchFailoverRecording(
              keepStandbyArmed: true,
              stopLiveActivity: false,
            ),
          );
        }
        if (_phoneRecording && !_otaHandoverPhoneRecording) {
          unawaited(
            stopPhoneRecording(keepStandbyArmed: true, stopLiveActivity: false),
          );
        }
        _syncLiveActivity();
      } else if (!hasActiveRecording &&
          !_pendingPhoneFailover &&
          (prevRecording || _liveActivityActive)) {
        _stopLiveActivity(force: true);
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
      _syncCardV2WifiAutoClose();
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
  Future<String?> toggleRecording() => setRecordingState(!isRecording);

  /// 明确设置硬件录音开关状态：软件蓝牙开关优先于物理拨杆，保证操作一定成功。
  Future<String?> setRecordingState(bool wantStart) async {
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
    _powerStatusText = '';
    if (!wantStart) {
      // 用户主动关闭硬件录音：先解除本机待命保底，防止误判为异常停录触发保底
      _phoneStandbyArmed = false;
      _pendingPhoneFailover = false;
    }
    notifyListeners();
    try {
      if (wantStart && _watchFailoverRecording) {
        await stopWatchFailoverRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
      }
      if (wantStart && _phoneRecording) {
        await stopPhoneRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
      }
      if (wantStart) {
        _pendingPhoneFailover = false;
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
        _hwRecordingStartedAt ??= _now();
        _syncLiveActivity();
        unawaited(_prewarmStandbyMicPermission());
        if (activeCapabilities.hasOledDisplay) {
          unawaited(
            showCardDisplayPrompt(
              line1: '开始录音',
              line2: '蓝牙开启',
              timeoutMs: 3500,
            ),
          );
        }
      } else if (!wantStart && !isRecording) {
        _phoneStandbyArmed = false;
        _hwRecordingStartedAt = null;
        if (!hasActiveRecording) {
          _stopLiveActivity(force: true);
        }
        if (activeCapabilities.hasOledDisplay) {
          unawaited(
            showCardDisplayPrompt(
              line1: '停止录音',
              line2: '已保存',
              timeoutMs: 3500,
            ),
          );
        }
      } else if (!wantStart) {
        _phoneStandbyArmed = false;
        _hwRecordingStartedAt = null;
        if (!hasActiveRecording) {
          _stopLiveActivity(force: true);
        }
      }
      _persistCurrentDeviceState();
      return null;
    } on TimeoutException {
      if (wantStart && !isRecording) _phoneStandbyArmed = false;
      if (!wantStart && !hasActiveRecording) _stopLiveActivity();
      recordingError = '录音命令超时，请重试';
      return recordingError;
    } on CardException catch (e) {
      if (wantStart && !isRecording) _phoneStandbyArmed = false;
      if (!wantStart && !hasActiveRecording) _stopLiveActivity();
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
    if (!isConnected || activeKind != DeviceKind.dyjV1) return;
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

  /// 在录音卡 72×40 OLED 屏幕上展示中文提示（best-effort，不阻塞主链路）。
  Future<void> showCardDisplayPrompt({
    required String line1,
    String? line2,
    int timeoutMs = 4000,
    bool persistent = false,
  }) async {
    if (!isConnected || !activeCapabilities.hasOledDisplay) return;
    final clean1 = line1.trim();
    if (clean1.isEmpty) return;
    final clean2 = line2?.trim() ?? '';
    try {
      final bitmap = await _oledRenderer.renderText(
        line1: clean1,
        line2: clean2.isEmpty ? null : clean2,
      );
      final lines = <String>[clean1, if (clean2.isNotEmpty) clean2];
      await _gw
          .invokeBridgeCommand(
            'card_display.show',
            <String, dynamic>{
              'bitmapBase64': base64Encode(bitmap),
              'lines': lines,
              'persistent': persistent,
              'timeoutMs': timeoutMs,
            },
            const Duration(seconds: 4),
          )
          .timeout(const Duration(seconds: 4));
    } on Object {
      // 固件未支持或链路忙时静默跳过
    }
  }

  /// 清除录音卡 OLED 屏幕临时提示（恢复固件默认界面）。
  Future<void> clearCardDisplay() async {
    if (!isConnected || !activeCapabilities.hasOledDisplay) return;
    try {
      await _gw
          .invokeBridgeCommand(
            'card_display.clear',
            const <String, dynamic>{},
            const Duration(seconds: 3),
          )
          .timeout(const Duration(seconds: 3));
    } on Object {
      // 固件未支持或链路忙时静默跳过
    }
  }

  void _scheduleHardwareRecordOledPrompt({
    required bool recording,
    required String reason,
  }) {
    final line1 = recording ? '开始录音' : '停止录音';
    final line2 = reason == 'switch'
        ? (recording ? '拨杆开启' : '拨杆关闭')
        : (recording ? '按键开启' : '按键关闭');
    _lastHardwareRecordOledAt = _now();
    _oledDelayTimer?.cancel();
    _oledDelayTimer = null;
    if (_oledHardwareEventDelay <= Duration.zero) {
      unawaited(
        showCardDisplayPrompt(line1: line1, line2: line2, timeoutMs: 3500),
      );
      return;
    }
    _oledDelayTimer = Timer(_oledHardwareEventDelay, () {
      _oledDelayTimer = null;
      if (!isConnected) return;
      unawaited(
        showCardDisplayPrompt(line1: line1, line2: line2, timeoutMs: 3500),
      );
    });
  }

  /// 重新向录音卡同步当前按键与拨杆行为配置（失败后手动一键重试入口）。
  Future<void> retryCardControlsSync() async {
    if (!isConnected || !activeCapabilities.hasConfigurableSwitch) return;
    await _syncCardControlsAndDisplayOnConnect(_epoch, force: true);
  }

  Future<void> _syncCardControlsAndDisplayOnConnect(
    int epoch, {
    bool force = false,
  }) async {
    if (epoch != _epoch || !isConnected) return;
    if (activeCapabilities.hasOledDisplay && _shownConnectOledEpoch != epoch) {
      _shownConnectOledEpoch = epoch;
      final shortId = connectedDisplayName.trim();
      final line2 =
          (shortId.isNotEmpty && shortId != '录音卡') ? shortId : null;
      await showCardDisplayPrompt(
        line1: '已连接',
        line2: line2,
        timeoutMs: 4000,
      );
      if (epoch != _epoch || !isConnected) return;
    }
    if (!activeCapabilities.hasConfigurableSwitch || _agentConfig == null) {
      return;
    }
    if ((!force && _syncedControlsEpoch == epoch) || _controlsSyncInFlight) {
      return;
    }
    _controlsSyncInFlight = true;
    final syncToken = ++_controlsSyncSeq;
    cardControlsSyncing = true;
    cardControlsError = null;
    notifyListeners();
    try {
      final res = await _gw.invokeBridgeCommand(
        'card_controls.get',
        const <String, dynamic>{},
        const Duration(seconds: 8),
      );
      if (epoch != _epoch || !isConnected) return;
      if (res['supported'] == false) {
        _syncedControlsEpoch = epoch;
        cardControlsError = null;
        return;
      }
      const controlKeys = [
        'btnSingle',
        'btnDouble',
        'btnLongPress',
        'btnLongRelease',
        'switchOn',
        'switchOff',
      ];
      final deviceHasAny = controlKeys.any((k) {
        final v = res[k]?.toString().trim().toLowerCase() ?? '';
        return v.isNotEmpty && v != 'none';
      });
      final config = _agentConfig!;
      if (!deviceHasAny || config.cardControlsUserConfigured) {
        final diff = config.cardFirmwareBindingsDiff(res);
        if (diff.isNotEmpty) {
          await _gw.invokeBridgeCommand(
            'card_controls.set',
            Map<String, dynamic>.from(diff),
            const Duration(seconds: 20),
          );
          if (epoch != _epoch || !isConnected) return;
        }
      } else {
        await config.syncCardBindingsFromDevice(res);
        if (epoch != _epoch || !isConnected) return;
      }
      _syncedControlsEpoch = epoch;
      cardControlsError = null;
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      cardControlsError = '读取/同步按键配置失败：${e.message}';
    } on TimeoutException {
      if (epoch != _epoch) return;
      cardControlsError = '同步按键配置超时，可点击重置或重试同步';
    } finally {
      if (syncToken == _controlsSyncSeq) {
        _controlsSyncInFlight = false;
      }
      if (epoch == _epoch && syncToken == _controlsSyncSeq) {
        cardControlsSyncing = false;
        notifyListeners();
      }
    }
  }

  /// 修改录音卡 V2 的单个物理按键/拨杆动作，先持久化本地偏好，连卡状态下立即写入固件。
  Future<String?> applyCardControlAction(
    AgentConfigStore config,
    String input,
    HardwareButtonAction action,
  ) async {
    await config.setCardControlAction(input, action);
    if (!isConnected || !activeCapabilities.hasConfigurableSwitch) {
      return null;
    }
    cardControlsSyncing = true;
    cardControlsError = null;
    notifyListeners();
    try {
      final payload = config.cardFirmwareSinglePayload(input, action);
      if (payload.isNotEmpty) {
        await _gw.invokeBridgeCommand(
          'card_controls.set',
          Map<String, dynamic>.from(payload),
          const Duration(seconds: 12),
        );
      }
      if (activeCapabilities.hasOledDisplay) {
        unawaited(
          showCardDisplayPrompt(
            line1: '按键已设置',
            line2: action.shortLabel,
            timeoutMs: 2500,
          ),
        );
      }
      cardControlsError = null;
      return null;
    } on TimeoutException {
      cardControlsError = '写入硬件按键设置超时，请重试';
      return cardControlsError;
    } on CardException catch (e) {
      cardControlsError = '写入硬件失败：${e.message}';
      return cardControlsError;
    } finally {
      cardControlsSyncing = false;
      notifyListeners();
    }
  }

  /// 将录音卡 V2 的按键与拨杆恢复为出厂推荐默认行为，并在已连接时下发到硬件。
  Future<String?> resetCardControlsToDefaults(AgentConfigStore config) async {
    await config.resetCardControlDefaults();
    if (!isConnected || !activeCapabilities.hasConfigurableSwitch) {
      return null;
    }
    cardControlsSyncing = true;
    cardControlsError = null;
    notifyListeners();
    try {
      await _gw.invokeBridgeCommand(
        'card_controls.set',
        Map<String, dynamic>.from(config.cardFirmwareBindingsPayload()),
        const Duration(seconds: 20),
      );
      if (activeCapabilities.hasOledDisplay) {
        unawaited(
          showCardDisplayPrompt(
            line1: '按键已重置',
            line2: '已恢复默认',
            timeoutMs: 2500,
          ),
        );
      }
      _syncedControlsEpoch = _epoch;
      cardControlsError = null;
      return null;
    } on TimeoutException {
      cardControlsError = '重置硬件按键超时，请重试';
      return cardControlsError;
    } on CardException catch (e) {
      cardControlsError = '重置硬件失败：${e.message}';
      return cardControlsError;
    } finally {
      cardControlsSyncing = false;
      notifyListeners();
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

  // ── 本机录音 / Apple Watch 级联保底 / OTA 接力 + 统一灵动岛实况 ──
  bool _islandEnabled = true;
  bool _liveActivityActive = false;
  bool _backgroundLiveActivityCleaned = false;
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

  bool _watchFailoverRecording = false;
  DateTime? _watchFailoverStartedAt;
  int _watchFailoverRecSec = 0;
  Timer? _watchFailoverClockTimer;

  bool _pendingPhoneFailover = false;
  int _pendingFailoverCarrySec = 0;

  bool get islandEnabled => _islandEnabled;
  bool get isPhoneStandbyArmed => _phoneStandbyArmed;
  bool get isFailoverPhoneRecording => _failoverPhoneRecording;
  bool get isPhoneRecording => _phoneRecording;
  bool get phoneRecordingBusy => _phoneRecordingBusy;
  int get phoneRecSeconds => _phoneRecSec;
  String? get phoneRecordingError => _phoneRecordingError;
  DateTime? get phoneRecordingStartedAt => _phoneRecordingStartedAt;
  bool get isBleRecording =>
      isConnected && activeKind != DeviceKind.appleWatch && isRecording;
  bool get isWatchFallbackRecording => _watchFailoverRecording;
  bool get isWatchRecording =>
      _watchFailoverRecording ||
      (isConnected && activeKind == DeviceKind.appleWatch && isRecording);
  bool get isCompanionRecording => _watchFailoverRecording || _phoneRecording;
  bool get isFailoverRecording =>
      _watchFailoverRecording || _failoverPhoneRecording;
  bool get isPendingForegroundPhoneFailover => _pendingPhoneFailover;
  int get watchFailoverRecSeconds => _watchFailoverRecSec;
  DateTime? get watchFailoverStartedAt => _watchFailoverStartedAt;

  /// 当前活跃录音通道数量（硬件 BLE 一路 + 伴随 Watch/手机 一路，严格 ≤ 2）。
  int get activeRecordingLaneCount {
    final bleLane = isBleRecording ? 1 : 0;
    final companionLane = (isWatchRecording || _phoneRecording) ? 1 : 0;
    return bleLane + companionLane;
  }

  /// 当前正在写入切片的设备显示名称（多路比对/分叉双列时标明来源 A/B）。
  String get activeRecordingDeviceLabel {
    if (isConnected && isRecording) return _hardwareActivityLabel;
    if (_watchFailoverRecording) {
      final wn = _watchHardware.currentStatus.watchName.trim();
      return (wn.isEmpty || wn == '我的手表') ? 'Apple Watch' : wn;
    }
    if (_phoneRecording) return '手机本机';
    return _hardwareActivityLabel;
  }

  String get watchFailoverClockText {
    final s = _watchFailoverRecSec;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  Stream<LiveAudioSlice> get phoneAudioSlices => _phoneMicRecorder.slices;
  PcmRingBuffer get phoneRingBuffer => _phoneMicRecorder.ringBuffer;
  LiveActivityService get liveActivityService => _liveActivityService;
  Duration get recordingSliceDuration => _phoneMicRecorder.sliceDuration;

  /// 同步调整本机保底麦克风实时切片窗口；蓝牙实时流切片窗口由 [AppShell] 中的 [LiveAudioRecorder] 同步。
  void setRecordingSliceDuration(Duration duration) {
    _phoneMicRecorder.setSliceDuration(duration);
  }

  /// 向当前本机录音切片追加重点标记（毫秒时间偏移）。
  void recordPhoneMark({int? timestampMs}) =>
      _phoneMicRecorder.recordMark(timestampMs: timestampMs);

  void _markLiveActivityStarted() {
    _liveActivityActive = true;
    _backgroundLiveActivityCleaned = false;
  }

  void _stopLiveActivity({bool force = false}) {
    if (!force && !_liveActivityActive) return;
    _liveActivityActive = false;
    unawaited(_liveActivityService.stopLocalRecordingActivity());
  }

  void setIslandEnabled(bool enabled) {
    if (_islandEnabled == enabled) return;
    _islandEnabled = enabled;
    if (!enabled) {
      _stopLiveActivity(force: true);
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
    if (!_islandEnabled) {
      _stopLiveActivity(force: true);
      return;
    }
    if (isConnected && isRecording) {
      final startedAt =
          _hwRecordingStartedAt ??
          _now().subtract(Duration(seconds: _clockTicks));
      _hwRecordingStartedAt = startedAt;
      _markLiveActivityStarted();
      unawaited(
        _liveActivityService.startHardwareRecordingActivity(
          startedAt: startedAt,
          deviceLabel: _hardwareActivityLabel,
        ),
      );
      return;
    }
    if (_watchFailoverRecording) {
      final startedAt =
          _watchFailoverStartedAt ??
          DateTime.now().subtract(Duration(seconds: _watchFailoverRecSec));
      _markLiveActivityStarted();
      unawaited(
        _liveActivityService.startWatchFailoverRecordingActivity(
          startedAt: startedAt,
        ),
      );
      return;
    }
    if (_phoneRecording) {
      final activityStartedAt = _now().subtract(
        Duration(seconds: _phoneRecSec),
      );
      _markLiveActivityStarted();
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
      return;
    }
    if (_pendingPhoneFailover && _phoneStandbyArmed) {
      _markLiveActivityStarted();
      unawaited(
        _liveActivityService.startPendingFailoverRecordingActivity(
          startedAt: DateTime.now().subtract(
            Duration(seconds: _pendingFailoverCarrySec),
          ),
        ),
      );
      return;
    }
    _stopLiveActivity();
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

  bool _canUseWatchForFailover() {
    if ((isConnected && activeKind == DeviceKind.appleWatch) ||
        _lastDevice?.id == WatchHardwareService.watchDeviceId) {
      return false;
    }
    if (!_watchHardware.linkEnabled) return false;
    final s = _watchHardware.currentStatus;
    return s.supported &&
        s.paired &&
        s.watchAppInstalled &&
        !s.linkLost &&
        !_watchHardware.isOutOfRangeDisconnected &&
        (s.reachable || s.isRecording);
  }

  void _stopWatchFailoverStateOnly() {
    _watchFailoverClockTimer?.cancel();
    _watchFailoverClockTimer = null;
    _watchFailoverRecording = false;
    _watchFailoverStartedAt = null;
    _watchFailoverRecSec = 0;
  }

  Future<void> stopWatchFailoverRecording({
    bool keepStandbyArmed = false,
    bool stopLiveActivity = true,
  }) async {
    if (!_watchFailoverRecording) {
      if (!keepStandbyArmed) _phoneStandbyArmed = false;
      return;
    }
    // 先清本地接力标志再向表端发 stop，避免 status 推送重入 _onWatchHardwareChanged 误清 _phoneStandbyArmed
    _stopWatchFailoverStateOnly();
    if (!keepStandbyArmed) {
      _phoneStandbyArmed = false;
    }
    try {
      await _watchHardware.stopRecording().timeout(const Duration(seconds: 6));
    } on Object catch (e) {
      debugPrint('[device] stopWatchFailoverRecording failed: $e');
    }
    if (stopLiveActivity && !hasActiveRecording) {
      _stopLiveActivity(force: true);
    }
    notifyListeners();
  }

  /// 蓝牙硬件意外断连或异常停录时的级联兜底：
  /// Apple Watch 在场优先由 Watch 接力；否则由手机本机麦克风接力（Watch/手机互斥占伴随路）。
  Future<void> _triggerCompanionFailover({
    required String reason,
    int carrySecOverride = 0,
  }) async {
    if (!_phoneStandbyArmed ||
        _phoneRecording ||
        _phoneRecordingBusy ||
        _watchFailoverRecording) {
      return;
    }
    if (_canUseWatchForFailover()) {
      try {
        if (!_watchHardware.currentStatus.isRecording) {
          await _watchHardware
              .startRecording()
              .timeout(const Duration(seconds: 6));
        }
        if (_watchHardware.currentStatus.isRecording) {
          final safeCarry = carrySecOverride < 0 ? 0 : carrySecOverride;
          _watchFailoverRecording = true;
          _watchFailoverStartedAt = DateTime.now();
          _watchFailoverRecSec = safeCarry;
          _pendingPhoneFailover = false;
          _pendingFailoverCarrySec = 0;
          _phoneRecordingError = null;
          _watchFailoverClockTimer?.cancel();
          _watchFailoverClockTimer = Timer.periodic(
            const Duration(seconds: 1),
            (_) {
              _watchFailoverRecSec++;
              notifyListeners();
            },
          );
          final targetLabel = _disconnectTargetLabel(
            _autoReconnectTarget ?? _lastDevice,
          );
          _disconnectNotice =
              '$targetLabel 已断开（$reason），已自动切换 Apple Watch 继续录音';
          _syncLiveActivity();
          unawaited(
            _localNotifications.notifyBleDisconnected(
              deviceName: targetLabel,
              body: '$reason · 已自动切换 Apple Watch 接力录音，蓝牙恢复后将自动重连并合并数据',
            ),
          );
          notifyListeners();
          return;
        }
      } on Object catch (e) {
        debugPrint('[failover] watch start failed, falling back to phone: $e');
      }
    }
    await _triggerPhoneFailover(
      carrySecOverride: carrySecOverride,
      reason: reason,
    );
  }

  void _retryPendingFailoverOnAudioReady() {
    if (_pendingPhoneFailover &&
        _phoneStandbyArmed &&
        !_phoneRecording &&
        !_phoneRecordingBusy &&
        !_watchFailoverRecording &&
        !isConnected) {
      unawaited(
        _triggerCompanionFailover(
          reason: '音频会话恢复',
          carrySecOverride: _pendingFailoverCarrySec,
        ),
      );
    }
  }

  /// 蓝牙设备意外断连或手表失效时自动拉起手机「本机录音」作为保底。
  Future<void> _triggerPhoneFailover({
    int carrySecOverride = 0,
    String? reason,
  }) async {
    if (!_phoneStandbyArmed || _phoneRecording || _phoneRecordingBusy) return;
    if (_watchFailoverRecording) {
      await stopWatchFailoverRecording(
        keepStandbyArmed: true,
        stopLiveActivity: false,
      );
    }
    final ok = await startPhoneRecording(
      forFailover: true,
      islandEnabled: _islandEnabled,
      initialElapsedSec: carrySecOverride,
      failoverReason: reason,
    );
    if (ok) {
      final targetLabel = _disconnectTargetLabel(
        _autoReconnectTarget ?? _lastDevice,
      );
      final reasonSeg =
          (reason != null && reason.isNotEmpty) ? '（$reason）' : '';
      _disconnectNotice =
          '$targetLabel 已断开$reasonSeg，已自动切换手机本机继续录音';
      unawaited(
        _localNotifications.notifyBleDisconnected(
          deviceName: targetLabel,
          body:
              '${(reason != null && reason.isNotEmpty) ? reason : '蓝牙连接已断开'} · 已自动切换手机本机接力录音，蓝牙恢复后将自动重连并合并数据',
        ),
      );
      notifyListeners();
    }
  }

  /// 硬件连接/重连完成后的录音状态收口：
  /// 1. 若硬件本身已在录音：关闭可能正在运行的 Watch/手机保底伴随路，退回零功耗待命并同步硬件实况；
  /// 2. 若此前 Watch/手机正在伴随路录音或等待前台恢复且非固件升级中：
  ///    若硬件支持远程控录则尝试将录音交接给硬件；仅在非保底模式时关闭独立手机录音，保底期间若硬件未开录则保留伴随兜底。
  Future<void> _reconcileRecordingOnConnect() async {
    if (!isConnected) return;
    if (isRecording) {
      _phoneStandbyArmed = true;
      _pendingPhoneFailover = false;
      _pendingFailoverCarrySec = 0;
      _hwRecordingStartedAt ??= DateTime.now();
      if (_watchFailoverRecording) {
        await stopWatchFailoverRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
      }
      if (_phoneRecording && !_otaHandoverPhoneRecording) {
        await stopPhoneRecording(
          keepStandbyArmed: true,
          stopLiveActivity: false,
        );
      }
      _syncLiveActivity();
      return;
    }
    if ((_phoneRecording ||
            _watchFailoverRecording ||
            _pendingPhoneFailover) &&
        !_otaHandoverPhoneRecording &&
        !fwUpdating) {
      if (!activeCapabilities.hasRemoteRecordControl) {
        return;
      }
      final carrySec = _watchFailoverRecording
          ? _watchFailoverRecSec
          : (_phoneRecording ? _phoneRecSec : _pendingFailoverCarrySec);
      try {
        await _gw.startRecording().timeout(const Duration(seconds: 10));
        final refreshed = await _gw.snapshot().timeout(_snapshotTimeout);
        _applySnapshot(refreshed);
      } on Object catch (e) {
        debugPrint('[device] handover companion->hardware failed: $e');
      }
      if (isRecording) {
        _clockTicks = carrySec;
        _hwRecordingStartedAt = DateTime.now().subtract(
          Duration(seconds: carrySec),
        );
        _phoneStandbyArmed = true;
        _pendingPhoneFailover = false;
        _pendingFailoverCarrySec = 0;
        if (_watchFailoverRecording) {
          await stopWatchFailoverRecording(
            keepStandbyArmed: true,
            stopLiveActivity: false,
          );
        }
        if (_phoneRecording) {
          await stopPhoneRecording(
            keepStandbyArmed: true,
            stopLiveActivity: false,
          );
        }
        _syncLiveActivity();
      } else if (_phoneRecording && !_failoverPhoneRecording) {
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
    String? failoverReason,
  }) async {
    if (_phoneRecording) return true;
    if (_phoneRecordingBusy) return false;
    _phoneRecordingBusy = true;
    _phoneRecordingError = null;
    notifyListeners();
    try {
      if (_watchFailoverRecording) {
        await stopWatchFailoverRecording(
          keepStandbyArmed: forFailover,
          stopLiveActivity: false,
        );
      }
      var perm = await _phoneMicBackend.checkPermission();
      if (perm == PhoneMicPermission.notDetermined) {
        perm = await _phoneMicBackend.requestPermission();
      }
      if (perm != PhoneMicPermission.granted) {
        _phoneRecordingError = '需要开启麦克风权限才能使用本机录音';
        if (forFailover) {
          _phoneStandbyArmed = true;
          _pendingPhoneFailover = true;
          _pendingFailoverCarrySec = initialElapsedSec < 0 ? 0 : initialElapsedSec;
          final targetLabel = _disconnectTargetLabel(
            _autoReconnectTarget ?? _lastDevice,
          );
          _disconnectNotice =
              '$targetLabel 已断开，需开启手机麦克风权限后恢复本机保底录音';
          if (islandEnabled) {
            _markLiveActivityStarted();
            unawaited(
              _liveActivityService.startPendingFailoverRecordingActivity(
                startedAt: DateTime.now().subtract(
                  Duration(seconds: _pendingFailoverCarrySec),
                ),
              ),
            );
          }
          unawaited(
            _localNotifications.notifyBleDisconnected(
              deviceName: targetLabel,
              body: '请轻点打开应用并允许麦克风权限，立即恢复本机保底录音',
              urgent: true,
            ),
          );
        } else if (!hasActiveRecording) {
          _stopLiveActivity();
        }
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
      _pendingPhoneFailover = false;
      _pendingFailoverCarrySec = 0;
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
        _markLiveActivityStarted();
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
      final parsed = PhoneMicStartException.tryParse(e);
      if (parsed != null &&
          (parsed.kind == PhoneMicErrorKind.backgroundRestricted ||
              parsed.kind == PhoneMicErrorKind.audioBusy)) {
        _phoneRecordingError = parsed.userMessage;
        if (forFailover) {
          _phoneStandbyArmed = true;
          _pendingPhoneFailover = true;
          _pendingFailoverCarrySec = initialElapsedSec < 0 ? 0 : initialElapsedSec;
          final targetLabel = _disconnectTargetLabel(
            _autoReconnectTarget ?? _lastDevice,
          );
          _disconnectNotice =
              '$targetLabel 已断开，iOS 后台限制暂无法启动麦克风，轻点打开 App 即可自动继续录音';
          if (islandEnabled) {
            _markLiveActivityStarted();
            unawaited(
              _liveActivityService.startPendingFailoverRecordingActivity(
                startedAt: DateTime.now().subtract(
                  Duration(seconds: _pendingFailoverCarrySec),
                ),
              ),
            );
          }
          unawaited(
            _localNotifications.notifyBleDisconnected(
              deviceName: targetLabel,
              body:
                  '${(failoverReason != null && failoverReason.isNotEmpty) ? '$failoverReason · ' : ''}轻点打开 App 立即自动开启手机本机保底录音',
              urgent: true,
            ),
          );
        }
      } else if (parsed != null) {
        _phoneRecordingError = parsed.userMessage;
      } else {
        _phoneRecordingError = '本机录音暂未启动，请稍后重试';
      }
      if (!_pendingPhoneFailover && !hasActiveRecording) {
        _stopLiveActivity();
      }
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
      if (!keepStandbyArmed) {
        _phoneStandbyArmed = false;
        _pendingPhoneFailover = false;
        _pendingFailoverCarrySec = 0;
      }
      if (stopLiveActivity && !hasActiveRecording && !_pendingPhoneFailover) {
        _stopLiveActivity();
      }
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
        _pendingPhoneFailover = false;
        _pendingFailoverCarrySec = 0;
      }
      _phoneRecordingStartedAt = null;
      _phoneRecordingBusy = false;
      if (stopLiveActivity && !hasActiveRecording) {
        _stopLiveActivity(force: true);
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

  /// 当前是否存在本机、手表保底或硬件录音。
  bool get hasActiveRecording =>
      _phoneRecording ||
      _watchFailoverRecording ||
      (isConnected && isRecording);

  /// 退出登录前安全关闭硬件录音（异常不阻塞退出登录流程）。
  Future<void> stopHardwareRecordingIfActive() async {
    _phoneStandbyArmed = false;
    _pendingPhoneFailover = false;
    _hwRecordingStartedAt = null;
    if (!isConnected || !isRecording) return;
    if (recordingBusy) return;
    recordingBusy = true;
    recordingError = null;
    _powerStatusText = '';
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

  /// 退出登录或会话失效时统一关闭本机/手表/硬件录音与灵动岛，防止数据归属跨账号泄漏。
  Future<void> stopAllRecordingsForSignOut() async {
    _phoneStandbyArmed = false;
    _pendingPhoneFailover = false;
    _pendingFailoverCarrySec = 0;
    _autoReconnectTarget = null;
    _stopBackgroundAutoReconnect();
    _disconnectNotice = null;
    _pendingPostReconnectSync = false;
    _hwRecordingStartedAt = null;
    _lastDevice = null;
    _clearPersistedLastDevice();
    if (_watchFailoverRecording) {
      await stopWatchFailoverRecording();
    }
    if (_phoneRecording || _phoneRecordingBusy) {
      await stopPhoneRecording();
    }
    if (isConnected && isRecording) {
      await stopHardwareRecordingIfActive();
    }
    _stopLiveActivity(force: true);
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
  DeviceView _wifiReturnView = DeviceView.main;
  DeviceView get wifiReturnView => _wifiReturnView;

  /// 录音卡 V2（双芯片 OTA + Wi-Fi 模组）现阶段无日常 Wi-Fi 场景：仅在 Wi-Fi 芯片升级时按需开启并随后自动关闭。
  bool get isCardV2WifiOtaOnly =>
      activeCapabilities.hasDualChipOta && activeCapabilities.hasWifiConfig;

  /// 状态弹层主视图是否展示 Wi-Fi 行：录音卡 V2 默认隐藏，点一机 V1 等继续展示。
  bool get showMainWifiRow =>
      activeCapabilities.hasWifiConfig && !isCardV2WifiOtaOnly;

  /// 固件更新页是否展示「Wi-Fi 设置」行：录音卡 V2 仅在 Wi-Fi 芯片有可用更新时显示。
  bool get showFirmwareWifiRow =>
      isCardV2WifiOtaOnly && wifiNeedsUpdate && !fwUpdating;

  static const Duration _wifiViewIdleTimeout = Duration(minutes: 3);
  static const Duration _wifiUpgIdleTimeout = Duration(seconds: 90);
  Timer? _wifiIdleCloseTimer;
  bool _wifiScanInFlight = false;
  bool _wifiClosePending = false;
  bool _wifiClosingInFlight = false;

  bool _shouldKeepCardV2WifiOpen() {
    if (!isCardV2WifiOtaOnly || !isConnected) return false;
    if (fwUpdating) return true;
    if (!sheetOpen) return false;
    if (view == DeviceView.wifi) return true;
    if (view == DeviceView.upg && wifiNeedsUpdate && wifiLast != null) {
      return true;
    }
    return false;
  }

  void _cancelWifiIdleCloseTimer() {
    _wifiIdleCloseTimer?.cancel();
    _wifiIdleCloseTimer = null;
  }

  void _syncCardV2WifiAutoClose() {
    if (!isCardV2WifiOtaOnly || !isConnected || fwUpdating) {
      _cancelWifiIdleCloseTimer();
      return;
    }
    final wifiActive = deviceWifiOpen == true || _wifiScanInFlight || wifiJoining;
    if (_shouldKeepCardV2WifiOpen()) {
      _wifiClosePending = false;
      if (!wifiActive) {
        _cancelWifiIdleCloseTimer();
        return;
      }
      if (!_sheetAttached && _wifiIdleCloseTimeout == null && !_autoStart) {
        return;
      }
      _cancelWifiIdleCloseTimer();
      final timeout = _wifiIdleCloseTimeout ??
          (view == DeviceView.upg ? _wifiUpgIdleTimeout : _wifiViewIdleTimeout);
      _wifiIdleCloseTimer = Timer(timeout, _onWifiIdleCloseTimeout);
      return;
    }
    _cancelWifiIdleCloseTimer();
    if (wifiActive) {
      _requestCardV2WifiClose();
    }
  }

  void _onWifiIdleCloseTimeout() {
    _wifiIdleCloseTimer = null;
    if (_disposed || !isCardV2WifiOtaOnly || !isConnected || fwUpdating) {
      return;
    }
    if (deviceWifiOpen != true && !_wifiScanInFlight && !wifiJoining) {
      return;
    }
    _requestCardV2WifiClose();
    if (view == DeviceView.wifi) {
      wifiStateText = '长时间未操作，已自动关闭设备 Wi-Fi 以省电';
      notifyListeners();
    }
  }

  void _requestCardV2WifiClose() {
    if (!isCardV2WifiOtaOnly || !isConnected || fwUpdating) return;
    if (_wifiScanInFlight || wifiJoining) {
      _wifiClosePending = true;
      return;
    }
    if (deviceWifiOpen == true && !_wifiClosingInFlight) {
      _wifiClosePending = false;
      unawaited(_closeWifiQuietly());
    }
  }

  void openSheet() {
    sheetOpen = true;
    view = DeviceView.main;
    _wifiReturnView = DeviceView.main;
    if (isConnected) {
      unawaited(refreshFromDevice());
      unawaited(prefetchSummaryInfo());
      if (fwStage == FwStage.failed) {
        unawaited(checkFirmware());
      }
      // 弹层开着时盯住设备侧按钮/开关的录音变化：卡上按了开始，这里要马上跟上，
      // 而不是等 30 秒看门狗或用户再点一次。
      _startSheetWatch();
      _syncCardV2WifiAutoClose();
    } else if (linkState == LinkState.unknown) {
      unawaited(restoreLink());
    } else if (isLinkBusy || _restoreInFlight || _scanInFlight) {
      // 正在执行自动重连或扫描：打开弹层直接展示重连中/扫描中状态，不中断打断成二次扫描
    } else {
      unawaited(startScan());
    }
    notifyListeners();
  }

  void closeSheet() {
    if (fwUpdating) return; // 更新中弹层锁定
    sheetOpen = false;
    _stopSheetWatch();
    _stopScanExpiryTimer();
    if (isCardV2WifiOtaOnly) {
      _syncCardV2WifiAutoClose();
    } else if (activeCapabilities.hasDualChipOta &&
        view == DeviceView.wifi &&
        deviceWifiOpen == true &&
        !wifiJoining) {
      unawaited(_closeWifiQuietly());
    }
    // 不停录音时钟：录音还在继续，Timeline 顶部状态块要继续计时
    notifyListeners();
  }

  /// App 切至后台/息屏：
  /// 1. 未处于任何真实录音态时，强制收口灵动岛与锁屏实况，防止残留或孤儿计时；
  /// 2. 若录音卡 V2 的 Wi-Fi 模块处于开启或配网在途，立刻自动关闭（升级期间除外）。
  void handleAppBackgrounded() {
    if (!hasActiveRecording &&
        (_liveActivityActive || !_backgroundLiveActivityCleaned)) {
      _backgroundLiveActivityCleaned = true;
      _stopLiveActivity(force: true);
    }
    if (!isCardV2WifiOtaOnly || !isConnected || fwUpdating) return;
    if (deviceWifiOpen != true && !_wifiScanInFlight && !wifiJoining) {
      return;
    }
    _cancelWifiIdleCloseTimer();
    _requestCardV2WifiClose();
    if (view == DeviceView.wifi) {
      wifiStateText = '应用切至后台，已自动关闭设备 Wi-Fi 以省电';
      notifyListeners();
    }
  }

  void _resyncWallClockIfRecording() {
    var changed = false;
    if (isConnected && isRecording && _hwRecordingStartedAt != null) {
      final elapsed = _now().difference(_hwRecordingStartedAt!).inSeconds;
      if (elapsed > _clockTicks) {
        _clockTicks = elapsed;
        changed = true;
      }
    }
    if (_phoneRecording && _phoneRecordingStartedAt != null) {
      final elapsed = _now().difference(_phoneRecordingStartedAt!).inSeconds;
      if (elapsed > _phoneRecSec) {
        _phoneRecSec = elapsed;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> _reconcileConnectedOnResume() async {
    if (!isConnected || isLinkBusy || _restoreInFlight) return;
    final epoch = _epoch;
    if (activeKind == DeviceKind.appleWatch) {
      try {
        await _watchHardware.refreshStatus();
        if (epoch != _epoch) return;
        if (_watchHardware.consumeUnexpectedDisconnect()) {
          unawaited(_retryReconnect());
          return;
        }
        final snap = _watchHardware.toSnapshot();
        final wasRecording = _liveRecording == true;
        final status = _watchHardware.currentStatus;
        final watchStartedAt = status.startedAtMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(status.startedAtMs)
            : _hwRecordingStartedAt;
        _applySnapshot(snap, recordingStartedAtHint: watchStartedAt);
        _persistCurrentDeviceState();
        if (status.pendingCount > 0 || status.isRecording || wasRecording) {
          unawaited(_watchHardware.flushAndDrain());
        }
        if (wasRecording && !snap.recording && !hasActiveRecording) {
          _stopLiveActivity(force: true);
        }
        notifyListeners();
      } on Object catch (e) {
        debugPrint('[resume] 刷新 Watch 状态失败：$e');
      }
      return;
    }

    try {
      final snapshot = await _gw.snapshot().timeout(_snapshotTimeout);
      if (epoch != _epoch) return;
      final wasRecording = _liveRecording == true;
      _markLinkActivity();
      _applySnapshot(snapshot, recordingStartedAtHint: _hwRecordingStartedAt);
      _persistCurrentDeviceState();
      if (wasRecording && !snapshot.recording) {
        if (!hasActiveRecording) {
          _stopLiveActivity(force: true);
        }
        _triggerAutoSyncMissedData();
      }
      _startHeartbeat();
      notifyListeners();
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      if (e.kind == CardErrorKind.disconnected) {
        unawaited(_retryReconnect());
      }
    } on TimeoutException {
      // 链路被同步占用时跳过本次对账
    }
  }

  void _handleScanExpiryOnResume() {
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

  /// App 切回前台时：
  /// 1. 同步正在进行的录音耗时计时器；
  /// 2. 若有因 iOS 后台 `560557684` 受限而挂起的保底本机录音，回到前台立即零点击自动恢复；
  /// 3. 若已挂载后台重连目标，探测直连；若仍处于已连接或有缓存历史设备，单次对账并恢复连接；
  /// 4. 对「连接设备」弹窗内的蓝牙扫描列表做真实墙钟过期校准。
  void handleAppResumed() {
    _backgroundLiveActivityCleaned = false;
    _resyncWallClockIfRecording();
    if (!hasActiveRecording && !_pendingPhoneFailover && _liveActivityActive) {
      _stopLiveActivity(force: true);
    }
    if (_pendingPhoneFailover &&
        _phoneStandbyArmed &&
        !_phoneRecording &&
        !_phoneRecordingBusy &&
        !_watchFailoverRecording &&
        !isConnected) {
      unawaited(
        _triggerCompanionFailover(
          reason: '回到前台自动恢复录音',
          carrySecOverride: _pendingFailoverCarrySec,
        ),
      );
    }
    if (isLinkBusy ||
        _restoreInFlight ||
        _scanInFlight ||
        _backgroundReconnecting) {
      return;
    }
    if (_autoReconnectTarget != null && !isConnected) {
      unawaited(_attemptBackgroundReconnect());
      return;
    }
    if (isConnected) {
      final now = _now();
      if (_lastResumeReconcileAt == null ||
          now.difference(_lastResumeReconcileAt!) >= _resumeReconcileCooldown) {
        _lastResumeReconcileAt = now;
        unawaited(_reconcileConnectedOnResume());
      }
      return;
    }
    final hasRestoreSource =
        _lastDevice != null || _stateStore != null || _watchHardware.linkEnabled;
    if (!hasRestoreSource) {
      _handleScanExpiryOnResume();
      return;
    }
    final now = _now();
    if (_lastResumeReconcileAt != null &&
        now.difference(_lastResumeReconcileAt!) < _resumeReconcileCooldown) {
      _handleScanExpiryOnResume();
      return;
    }
    _lastResumeReconcileAt = now;
    unawaited(restoreLink(fromResume: true));
  }

  void showView(DeviceView v, {DeviceView? wifiReturnTo}) {
    final prev = view;
    if (v == DeviceView.wifi) {
      _wifiReturnView = wifiReturnTo ??
          (prev == DeviceView.upg
              ? DeviceView.upg
              : (isCardV2WifiOtaOnly ? DeviceView.upg : DeviceView.main));
    }
    view = v;
    if (isCardV2WifiOtaOnly) {
      _syncCardV2WifiAutoClose();
    } else if (activeCapabilities.hasDualChipOta &&
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
    if (v == DeviceView.more) {
      devicePowerError = null;
    }
    if (v == DeviceView.btn &&
        isConnected &&
        activeCapabilities.hasConfigurableSwitch &&
        (cardControlsError != null || _syncedControlsEpoch != _epoch)) {
      unawaited(_syncCardControlsAndDisplayOnConnect(_epoch, force: true));
    }
    notifyListeners();
  }

  void closeWifiView() {
    showView(_wifiReturnView);
  }

  Future<void> _closeWifiQuietly() async {
    _cancelWifiIdleCloseTimer();
    if (_wifiClosingInFlight || !isConnected) return;
    _wifiClosingInFlight = true;
    try {
      await _gw.closeWifi().timeout(const Duration(seconds: 6));
      deviceWifiOpen = false;
      _wifiClosePending = false;
      notifyListeners();
    } on Object {
      // 忽略关闭失败，后续读文件前管线还会兜底再关一次
    } finally {
      _wifiClosingInFlight = false;
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

  /// 升级完成后的设备状态行（无更新时为空，不占位；若有重启状态提示优先展示）。
  String get devStateText {
    if (_powerStatusText.isNotEmpty) return _powerStatusText;
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

    // 录音卡 V2 现阶段无日常 Wi-Fi 场景：升级完成/中止后一律确保关闭 Wi-Fi；
    // 其它可能存在的非 OTA-only 设备才沿用升级前开关状态。
    final cardV2OtaOnly = isCardV2WifiOtaOnly;
    final priorWifiOpen = !cardV2OtaOnly && deviceWifiOpen == true;

    _cancelWifiIdleCloseTimer();
    _wifiClosePending = false;
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
            if (!_isDfuBootloaderName(target.name) &&
                target.deviceKind == DeviceKind.cardV2) {
              _lastKnownNormalCardV2Name = target.name;
            }
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
      if (!doWifi) {
        if (cardV2OtaOnly) {
          if (deviceWifiOpen == true) {
            await _closeWifiQuietly();
          }
        } else if (priorWifiOpen && deviceWifiOpen != true) {
          try {
            await _gw.openWifi();
            await refreshFromDevice();
          } on CardException {
            // 恢复开启失败不覆盖已完成的主控升级结果
          }
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
        await for (final p in _gw.otaWifi(
          restoreWifiOpen: cardV2OtaOnly ? false : priorWifiOpen,
        )) {
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
        if (cardV2OtaOnly && deviceWifiOpen == true) {
          await _closeWifiQuietly();
        }
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
    if (cardV2OtaOnly && deviceWifiOpen == true) {
      await _closeWifiQuietly();
    }
    _syncCardV2WifiAutoClose();
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
    final expectedNormalName = [
      connectedName,
      _lastDevice?.name,
      _lastKnownNormalCardV2Name,
    ].whereType<String>().map((s) => s.trim()).firstWhere(
      (s) => s.isNotEmpty && !_isDfuBootloaderName(s),
      orElse: () => '',
    );
    if (expectedNormalName.isNotEmpty) {
      final hit = normal
          .where((d) => d.name == expectedNormalName)
          .firstOrNull;
      if (hit != null) return hit;
      // 多卡同场环境下绝不串连旁边其它 DYJV2 卡：正常重连循环等待本卡重启完成，
      // 失败恢复态则只允许回连 DFU_DYJ Bootloader。
      if (!allowDfuFallback) return null;
      return list.where((d) => _isDfuBootloaderName(d.name)).firstOrNull;
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
        if (!_isDfuBootloaderName(target.name) &&
            target.deviceKind == DeviceKind.cardV2) {
          _lastKnownNormalCardV2Name = target.name;
        }
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
    _syncCardV2WifiAutoClose();
    notifyListeners();
  }

  // ── Wi-Fi：设备扫描 + 设备凭据 + 真实连接 ──────────────────
  static const String _wifiPasswordsStorageKey = 'rc_wifi_passwords_v1';
  Map<String, String>? _wifiPasswordsCache;

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

  Future<Map<String, String>> _ensureWifiPasswordsLoaded() async {
    final cached = _wifiPasswordsCache;
    if (cached != null) return cached;
    final raw = await _wifiCredentialStore.readJson(_wifiPasswordsStorageKey);
    final loaded = <String, String>{};
    if (raw != null) {
      for (final entry in raw.entries) {
        final ssid = entry.key.trim();
        final pwd = entry.value is String ? entry.value as String : '';
        if (ssid.isNotEmpty && pwd.isNotEmpty) {
          loaded[ssid] = pwd;
        }
      }
    }
    return _wifiPasswordsCache = loaded;
  }

  Future<void> _saveWifiPassword(String ssid, String password) async {
    final cleanSsid = ssid.trim();
    if (cleanSsid.isEmpty || password.isEmpty) return;
    final cache = Map<String, String>.from(await _ensureWifiPasswordsLoaded());
    if (cache[cleanSsid] == password) return;
    cache[cleanSsid] = password;
    _wifiPasswordsCache = cache;
    await _wifiCredentialStore.writeJson(_wifiPasswordsStorageKey, cache);
  }

  Future<void> _removeSavedWifiPassword(String ssid) async {
    final cleanSsid = ssid.trim();
    if (cleanSsid.isEmpty) return;
    final cache = Map<String, String>.from(await _ensureWifiPasswordsLoaded());
    if (!cache.containsKey(cleanSsid)) return;
    cache.remove(cleanSsid);
    _wifiPasswordsCache = cache;
    if (cache.isEmpty) {
      await _wifiCredentialStore.delete(_wifiPasswordsStorageKey);
    } else {
      await _wifiCredentialStore.writeJson(_wifiPasswordsStorageKey, cache);
    }
  }

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
    _wifiScanInFlight = true;
    _wifiClosePending = false;
    _cancelWifiIdleCloseTimer();
    wifiSelName = null;
    wifiJoining = false;
    wifiJoinName = '';
    wifiScanDone = false;
    wifiError = null;
    wifiStateText = '正在扫描附近网络…';
    notifyListeners();
    try {
      await _ensureWifiPasswordsLoaded();
      if (isCardV2WifiOtaOnly && _wifiClosePending) return;
      // 设备侧 Wi-Fi 模块需先开启
      if (deviceWifiOpen != true) {
        await _gw.openWifi();
        deviceWifiOpen = true;
      }
      if (isCardV2WifiOtaOnly && _wifiClosePending) return;
      final creds = await _gw.wifiCredentials();
      if (isCardV2WifiOtaOnly && _wifiClosePending) return;
      final nets = await _gw.scanWifi();
      if (isCardV2WifiOtaOnly && _wifiClosePending) return;
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
    } finally {
      _wifiScanInFlight = false;
      if (isCardV2WifiOtaOnly &&
          deviceWifiOpen == true &&
          (_wifiClosePending || !_shouldKeepCardV2WifiOpen())) {
        _wifiClosePending = false;
        await _closeWifiQuietly();
      } else {
        _syncCardV2WifiAutoClose();
      }
      notifyListeners();
    }
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

  /// 连接已保存网络：优先读取本机 Keychain 缓存的密码，否则由底层走设备已保存凭据自动连接；失败时展开密码输入框便于重输。
  Future<void> wifiConnectSaved(String n) async {
    if (wifiJoining || !wifiInRange(n)) return;
    wifiJoining = true;
    wifiJoinName = n;
    wifiError = null;
    _wifiClosePending = false;
    _cancelWifiIdleCloseTimer();
    notifyListeners();
    var usedPwd = '';
    try {
      final cache = _wifiPasswordsCache ?? await _ensureWifiPasswordsLoaded();
      usedPwd = cache[n.trim()] ?? cache[n] ?? '';
      await _gw.connectWifi(n, usedPwd);
      if (isCardV2WifiOtaOnly) {
        deviceWifiOpen = true;
      }
      wifiLast = n;
      wifiStateText = '$n 连接成功';
      wifiSelName = null;
    } on CardException catch (e) {
      final rawMsg = e.message;
      const savedPrefix = 'WIFI_SAVED_PASSWORD_REQUIRED|';
      if (rawMsg.startsWith(savedPrefix)) {
        final parts = rawMsg.split('|');
        final friendly = parts.length >= 3
            ? parts.sublist(2).join('|')
            : '无法通过录音卡已保存凭据自动连上「$n」，请重新输入密码连接';
        wifiSelName = n;
        wifiError = friendly;
        wifiStateText = '请输入 $n 的密码后连接';
      } else if (usedPwd.isEmpty && rawMsg.contains('设备错误码 1')) {
        wifiSelName = n;
        wifiError = '无法通过已保存凭据自动连接「$n」，请重新输入密码连接（设备错误码 1）';
        wifiStateText = '请输入 $n 的密码后连接';
      } else {
        wifiError = rawMsg;
        wifiStateText = '连接 $n 失败：$rawMsg';
      }
    } finally {
      wifiJoining = false;
      wifiJoinName = '';
      if (isCardV2WifiOtaOnly &&
          deviceWifiOpen == true &&
          (_wifiClosePending || !_shouldKeepCardV2WifiOpen())) {
        _wifiClosePending = false;
        await _closeWifiQuietly();
      } else {
        _syncCardV2WifiAutoClose();
      }
      notifyListeners();
    }
  }

  void wifiPick(String n) {
    if (wifiJoining) return;
    wifiSelName = n;
    wifiError = null;
    _syncCardV2WifiAutoClose();
    notifyListeners();
  }

  void wifiCancelPick() {
    wifiSelName = null;
    wifiError = null;
    notifyListeners();
  }

  /// 连接新网络：密码留空视为失败（设备侧会拒绝），成功后把密码安全写入本机 Keychain 供下次一键直连。
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
    _wifiClosePending = false;
    _cancelWifiIdleCloseTimer();
    notifyListeners();
    try {
      await _gw.connectWifi(sel, pwd);
      if (isCardV2WifiOtaOnly) {
        deviceWifiOpen = true;
      }
      await _saveWifiPassword(sel, pwd);
      wifiLast = sel;
      wifiStateText = '$sel 连接成功';
      wifiSelName = null;
      // 刷新凭据清单（若用户已经离开配网流程则跳过扫描，交由 finally 立即关闭设备 Wi-Fi）
      if (!(isCardV2WifiOtaOnly && _wifiClosePending)) {
        await wifiScan();
      }
    } on CardException catch (e) {
      wifiError = e.message;
    } finally {
      wifiJoining = false;
      wifiJoinName = '';
      if (isCardV2WifiOtaOnly &&
          deviceWifiOpen == true &&
          (_wifiClosePending || !_shouldKeepCardV2WifiOpen())) {
        _wifiClosePending = false;
        await _closeWifiQuietly();
      } else {
        _syncCardV2WifiAutoClose();
      }
      notifyListeners();
    }
  }

  /// 忘记一个已保存网络（设备端删除 + 本机 Keychain 清除）。
  Future<void> wifiForget(String ssid) async {
    try {
      await _gw.forgetWifi(ssid);
      await _removeSavedWifiPassword(ssid);
      wifiSaved = wifiSaved.where((w) => w.name != ssid).toList();
      if (wifiLast == ssid) wifiLast = null;
      notifyListeners();
    } on CardException catch (e) {
      wifiError = e.message;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    if (fwUpdating) {
      unawaited(_setKeepScreenOn(false));
    }
    final backend = _phoneMicBackend;
    if (backend is PlatformPhoneMicBackend) {
      backend.onAppBecameActive = null;
      backend.onAudioInterruptionEnded = null;
    }
    _watchHardware.removeListener(_onWatchHardwareChanged);
    if (_ownsWatchHardware) {
      _watchHardware.dispose();
    }
    _clockTimer?.cancel();
    _phoneClockTimer?.cancel();
    _watchFailoverClockTimer?.cancel();
    _autoReconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _oledDelayTimer?.cancel();
    _oledDelayTimer = null;
    _eventWatch?.cancel();
    _stopSheetWatch();
    _stopScanExpiryTimer();
    _cancelWifiIdleCloseTimer();
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

/// 持久化保存的最近一次已连接硬件及录音上下文，用于重启或回前台时无扫描直连恢复。
@immutable
class PersistedLastDevice {
  const PersistedLastDevice({
    required this.id,
    required this.name,
    required this.deviceKind,
    this.displayModel,
    this.wasRecording = false,
    this.recordingStartedAtMs,
    this.savedAtMs = 0,
  });

  final String id;
  final String name;
  final DeviceKind deviceKind;
  final String? displayModel;
  final bool wasRecording;
  final int? recordingStartedAtMs;
  final int savedAtMs;

  static PersistedLastDevice? fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return null;
    final id = (json['id'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final kind = DeviceKind.fromCode(
      json['deviceKind'] as String?,
      fallbackName: name,
    );
    final rawStart = json['recordingStartedAtMs'];
    final rawSaved = json['savedAtMs'];
    return PersistedLastDevice(
      id: id,
      name: name.isNotEmpty
          ? name
          : (json['displayModel'] as String? ?? kind.displayModel),
      deviceKind: kind,
      displayModel: json['displayModel'] as String?,
      wasRecording: json['wasRecording'] == true,
      recordingStartedAtMs: rawStart is num ? rawStart.toInt() : null,
      savedAtMs: rawSaved is num ? rawSaved.toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'deviceKind': deviceKind.code,
    if (displayModel != null && displayModel!.isNotEmpty)
      'displayModel': displayModel,
    'wasRecording': wasRecording,
    if (recordingStartedAtMs != null && recordingStartedAtMs! > 0)
      'recordingStartedAtMs': recordingStartedAtMs,
    'savedAtMs': savedAtMs,
  };

  CardDevice toCardDevice() => CardDevice(
    id: id,
    name: name,
    kind: deviceKind,
    displayModel: displayModel,
  );
}
