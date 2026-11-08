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

import '../device/card_gateway.dart';

enum SyncState { idle, busy, done }

enum DeviceView { main, upg, wifi }

/// 与录音卡的蓝牙连接状态：未连接时顶栏胶囊变灰，点开进扫描流程。
enum LinkState {
  unknown,
  unsupported,
  disconnected,
  scanning,
  connecting,
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
  DeviceStore({CardGateway? gateway, bool autoStart = false})
    : _gateway = gateway ?? realOrUnsupported(),
      _autoStart = autoStart {
    if (autoStart) {
      unawaited(restoreLink());
      _startHeartbeat();
    }
  }

  /// 生产环境在启动时开启心跳；widget 测试传 false，避免悬挂定时器。
  final bool _autoStart;

  final CardGateway _gateway;

  /// 供其它服务复用同一条硬件链路（录音同步、诊断）。
  CardGateway get gateway => _gateway;

  /// 真实桥是否就绪。
  bool get liveDeviceAvailable => _gateway.available;
  bool get canScan => _gateway.available;

  /// 桥版本串（含 SDK 版本），排障与「关于」页使用。
  String? get bridgeVersion {
    final gateway = _gateway;
    return gateway is RealCardGateway ? gateway.bridgeVersion : null;
  }

  // ── 蓝牙连接状态 ───────────────────────────────────────────
  LinkState linkState = LinkState.unknown;
  List<CardDevice> discovered = const [];
  String? linkError;
  String? connectedName;

  /// 连接代次：异步结果回来时比对，过期丢弃。
  int _epoch = 0;
  Timer? _heartbeatTimer;
  int _heartbeatFailures = 0;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  bool get isConnected => linkState == LinkState.connected;
  bool get isLinkBusy =>
      linkState == LinkState.scanning || linkState == LinkState.connecting;

  /// 启动时核对一次：桥可用且已连着卡 → 已连接；否则未连接。
  Future<void> restoreLink() async {
    final epoch = ++_epoch;
    if (!_gateway.available) {
      linkState = LinkState.unsupported;
      linkError = '此设备不支持连接录音卡';
      notifyListeners();
      return;
    }
    try {
      final snapshot = await _gateway.snapshot();
      if (epoch != _epoch) return;
      _applySnapshot(snapshot);
      linkState = LinkState.connected;
      linkError = null;
      _reconnectAttempts = 0;
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      // 未连接是正常初始态，不算错误；其它错误如实呈现
      linkState = LinkState.disconnected;
      linkError = e.kind == CardErrorKind.disconnected ? null : e.message;
    }
    notifyListeners();
  }

  /// 扫描附近录音卡（DYJ 前缀 + NUS 广播，过滤在 SDK 侧完成）。
  Future<void> startScan() async {
    if (isLinkBusy || !_gateway.available) {
      if (!_gateway.available) {
        linkState = LinkState.unsupported;
        linkError = '此设备不支持连接录音卡';
        notifyListeners();
      }
      return; // 防重入：扫描中再点不重复发起（SDK 要求串行）
    }
    final epoch = ++_epoch;
    linkState = LinkState.scanning;
    linkError = null;
    discovered = const [];
    notifyListeners();
    try {
      final list = await _gateway.scan();
      if (epoch != _epoch) return;
      discovered = list;
      linkState = LinkState.disconnected;
      linkError = list.isEmpty ? '没有找到附近的录音卡' : null;
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      discovered = const [];
      linkState = LinkState.disconnected;
      linkError = e.message;
    }
    notifyListeners();
  }

  Future<void> connectTo(CardDevice device) async {
    if (linkState == LinkState.connecting) return;
    final epoch = ++_epoch;
    linkState = LinkState.connecting;
    linkError = null;
    notifyListeners();
    try {
      final snapshot = await _gateway.connect(device.id);
      if (epoch != _epoch) return;
      _applySnapshot(snapshot);
      connectedName = device.name;
      linkState = LinkState.connected;
      linkError = null;
      _reconnectAttempts = 0;
      _heartbeatFailures = 0;
      if (_autoStart) _startHeartbeat();
      unawaited(_afterConnect());
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      linkState = LinkState.disconnected;
      linkError = e.message;
    }
    notifyListeners();
  }

  /// 连上后的收尾：时间同步 + 拉一次录音状态。
  Future<void> _afterConnect() async {
    try {
      await _gateway.syncTime();
    } on CardException {
      // 时间同步失败不致命
    }
    await refreshFromDevice();
  }

  Future<void> disconnectDevice() async {
    final epoch = ++_epoch;
    _reconnectTimer?.cancel();
    try {
      await _gateway.disconnect();
    } on CardException {
      // 已经断了也算成功
    }
    if (epoch != _epoch) return;
    _resetLiveState();
    linkState = LinkState.disconnected;
    connectedName = null;
    notifyListeners();
  }

  void _resetLiveState() {
    _liveBattery = null;
    _liveCharging = null;
    _liveRecording = null;
    _clockTicks = 0;
    _fwVersion = '';
    _wifiVersion = '';
    _fwVersionCode = 0;
    _wifiVersionCode = 0;
    _storageFreeMb = null;
    deviceWifiOpen = null;
  }

  // ── 心跳与重连 ─────────────────────────────────────────────
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 只在已连接时真正发命令；widget 测试里 autoStart:false 不启
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!isConnected || fwUpdating || syncing) return;
      unawaited(_heartbeat());
    });
  }

  Future<void> _heartbeat() async {
    final epoch = _epoch;
    try {
      final snapshot = await _gateway.snapshot();
      if (epoch != _epoch) return;
      _heartbeatFailures = 0;
      _applySnapshot(snapshot);
      notifyListeners();
    } on CardException {
      if (epoch != _epoch) return;
      _heartbeatFailures++;
      if (_heartbeatFailures >= 2) {
        // 连续两次拿不到状态：判掉线，进入重连
        linkState = LinkState.disconnected;
        linkError = '与录音卡的连接已断开';
        notifyListeners();
        _scheduleReconnect();
      }
    }
  }

  void _scheduleReconnect() {
    if (!_gateway.available || _reconnectTimer != null) return;
    if (connectedName == null) return;
    if (_reconnectAttempts >= 5) return;
    final delay = Duration(
      seconds: (2 * (1 << _reconnectAttempts)).clamp(2, 30),
    );
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      if (!_gateway.available) return;
      linkState = LinkState.connecting;
      notifyListeners();
      try {
        final list = await _gateway.scan();
        final target = list.where((d) => d.name == connectedName).firstOrNull;
        if (target == null) {
          linkState = LinkState.disconnected;
          notifyListeners();
          return;
        }
        final snapshot = await _gateway.connect(target.id);
        _applySnapshot(snapshot);
        linkState = LinkState.connected;
        linkError = null;
        _heartbeatFailures = 0;
        _reconnectAttempts = 0;
      } on CardException {
        linkState = LinkState.disconnected;
        _scheduleReconnect();
      }
      notifyListeners();
    });
  }

  // ── 快照应用 ───────────────────────────────────────────────
  int? _liveBattery;
  bool? _liveCharging;
  bool? _liveRecording;
  String _fwVersion = '';
  String _wifiVersion = '';
  int _fwVersionCode = 0;
  int _wifiVersionCode = 0;
  int? _storageFreeMb;

  /// 设备端 Wi-Fi 模块是否开启（null = 未知，不冒充"已关闭"）。
  bool? deviceWifiOpen;

  void _applySnapshot(CardSnapshot s) {
    _liveBattery = s.batteryLevel.clamp(1, 100);
    _liveCharging = s.isCharging;
    _fwVersion = s.fwVersion;
    _wifiVersion = s.wifiVersion;
    _fwVersionCode = s.fwVersionCode;
    _wifiVersionCode = s.wifiVersionCode;
    _storageFreeMb = s.storageFreeMb;
    deviceWifiOpen = s.wifiOpen;
    if (s.recording != (_liveRecording ?? false)) {
      _liveRecording = s.recording;
      _clockTicks = 0;
      // 时钟只在弹层打开时跳（省电 + 测试里定时器不悬挂）
      if (s.recording && sheetOpen) {
        _startClock();
      } else if (!s.recording) {
        _stopClock();
      }
    }
  }

  /// 弹层打开时刷新真实设备数据。
  Future<void> refreshFromDevice() async {
    if (!_gateway.available) return;
    final epoch = _epoch;
    try {
      final snapshot = await _gateway.snapshot();
      if (epoch != _epoch) return;
      _applySnapshot(snapshot);
      if (linkState != LinkState.connected) {
        linkState = LinkState.connected;
      }
      linkError = null;
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      if (e.kind == CardErrorKind.disconnected) {
        linkState = LinkState.disconnected;
        linkError = '与录音卡的连接已断开';
      }
      // 超时/单次查询失败：保留上次状态，不把状态页突然翻成扫描页
    }
    notifyListeners();
  }

  // ── 录音时钟：以设备真实录音起点为准 ───────────────────────
  int _clockTicks = 0;
  Timer? _clockTimer;

  /// 兼容旧接口：无设备时返回 0，界面不显示假时长。
  int get recSeconds => _clockTicks;

  bool get isRecording => _liveRecording ?? false;

  void _startClock() {
    _clockTimer?.cancel();
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

  /// 开始/停止录音（真实命令）。
  Future<String?> toggleRecording() async {
    if (!isConnected) return '录音卡未连接';
    try {
      await _gateway.record('toggle');
      await refreshFromDevice();
      return null;
    } on CardException catch (e) {
      return e.message;
    }
  }

  /// 手动打点（重要对话标记）。
  Future<String?> markNow() async {
    if (!isConnected) return '录音卡未连接';
    try {
      await _gateway.mark();
      return null;
    } on CardException catch (e) {
      return e.message;
    }
  }

  // ── 电量 ───────────────────────────────────────────────────
  int get battery => _liveBattery ?? 0;
  bool get batteryKnown => _liveBattery != null;

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

  // ── 同步：真实 sync.start + 冷却 10s ───────────────────────
  SyncState syncState = SyncState.idle;
  DateTime? lastSyncAt;
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
    SyncState.idle => '最近同步 · $syncRelText',
  };

  bool get canSync =>
      isConnected &&
      syncState == SyncState.idle &&
      !_syncCooldown &&
      !fwUpdating;

  Future<void> syncNow() async {
    if (!canSync) return;
    syncState = SyncState.busy;
    syncError = null;
    notifyListeners();
    final epoch = _epoch;
    try {
      await _gateway.startSync();
      // 跟进设备回报的 Sync 事件；设备不实现轮询时也能在超时后给出结论
      final ok = await _waitSyncComplete(epoch);
      if (epoch != _epoch) return;
      if (!ok) {
        syncState = SyncState.idle;
        syncError = '同步未完成，请稍后重试';
        notifyListeners();
        return;
      }
      lastSyncAt = DateTime.now();
      syncState = SyncState.done;
      notifyListeners();
      _syncCooldown = true;
      Timer(const Duration(seconds: 10), () {
        _syncCooldown = false;
        syncState = SyncState.idle;
        notifyListeners();
      });
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      syncState = SyncState.idle;
      syncError = e.message;
      notifyListeners();
    }
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
        final status = await _gateway.syncStatus();
        if (!status.running) return true;
      } on CardException {
        return false;
      }
    }
    return false;
  }

  /// 预取弹层首屏要展示的概要信息（Wi-Fi 已配置数量、固件是否有更新）。
  ///
  /// 不做的话，用户不点进二级页就永远看到"0 个网络 / 已是最新"——那是假信息。
  Future<void> prefetchSummaryInfo() async {
    if (!isConnected) return;
    final epoch = _epoch;
    if (wifiSaved.isEmpty) {
      try {
        final creds = await _gateway.wifiCredentials();
        if (epoch != _epoch) return;
        wifiSaved = creds.map((c) => SavedWifi(c.ssid)).toList();
        notifyListeners();
      } on CardException {
        // Wi-Fi 模块未开启/不支持时保持空，界面显示"未配置"
      }
    }
    if (_otaMainInfo == null && _otaWifiInfo == null) {
      await checkFirmware();
    }
  }

  // ── 弹层视图 ───────────────────────────────────────────────
  bool sheetOpen = false;
  DeviceView view = DeviceView.main;

  void openSheet() {
    sheetOpen = true;
    view = DeviceView.main;
    if (isConnected) {
      if (isRecording) _startClock();
      unawaited(refreshFromDevice());
      unawaited(prefetchSummaryInfo());
    } else if (linkState == LinkState.unknown) {
      unawaited(restoreLink());
    } else {
      unawaited(startScan());
    }
    notifyListeners();
  }

  void closeSheet() {
    if (fwUpdating) return; // 更新中弹层锁定
    sheetOpen = false;
    _stopClock();
    notifyListeners();
  }

  void showView(DeviceView v) {
    view = v;
    if (v == DeviceView.wifi) {
      unawaited(wifiScan());
    }
    if (v == DeviceView.upg) {
      unawaited(checkFirmware());
    }
    notifyListeners();
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

  bool get fwAvailable =>
      _otaMainInfo?.isNewerThan(_fwVersionCode) == true ||
      _otaWifiInfo?.isNewerThan(_wifiVersionCode) == true;

  /// 固件行右侧文案：有更新才提示，否则"已是最新"。
  String get fwValText {
    if (fwStage == FwStage.failed) return '检查失败';
    if (fwUpdating) return fwPctText;
    return fwAvailable ? '有可用更新' : '已是最新';
  }

  /// 升级完成后的设备状态行（无更新时为空，不占位）。
  String get devStateText {
    if (fwStage != FwStage.done) return '';
    return '已更新到 $fwVersionText';
  }

  String get fwVersionText => _fwVersion.isEmpty
      ? '—'
      : '主控 $_fwVersion / Wi-Fi ${_wifiVersion.isEmpty ? '—' : _wifiVersion}';

  String get fwPctText => '${fwProgress.round()}%';

  /// 固件更新页的版本对比行：设备当前版本 → 服务器最新版本（读不到就显示当前版本）。
  String get mainVersionCompare {
    final target = _otaMainInfo;
    final current = _fwVersion.isEmpty ? '—' : _fwVersion;
    if (target == null || target.version.isEmpty || !target.isNewerThan(_fwVersionCode)) {
      return current;
    }
    return '$current → ${target.version}';
  }

  String get wifiVersionCompare {
    final target = _otaWifiInfo;
    final current = _wifiVersion.isEmpty ? '—' : _wifiVersion;
    if (target == null || target.version.isEmpty || !target.isNewerThan(_wifiVersionCode)) {
      return current;
    }
    return '$current → ${target.version}';
  }

  /// 查服务器最新版本（只读，不写设备）。
  Future<void> checkFirmware() async {
    if (!isConnected) return;
    fwStage = FwStage.checking;
    fwError = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _gateway
            .otaInfo('main')
            .catchError(
              (Object _) =>
                  const CardOtaInfo(version: '', versionCode: 0, url: ''),
            ),
        _gateway
            .otaInfo('wifi')
            .catchError(
              (Object _) =>
                  const CardOtaInfo(version: '', versionCode: 0, url: ''),
            ),
      ]);
      _otaMainInfo = results[0];
      _otaWifiInfo = results[1];
      fwStage = FwStage.idle;
    } on CardException catch (e) {
      fwError = e.message;
      fwStage = FwStage.failed;
    }
    notifyListeners();
  }

  /// 执行升级：先主控（BLE DFU），再 Wi-Fi 模组（设备侧在线 OTA）。
  Future<void> startFwUpdate() async {
    if (fwUpdating) return;
    if (!isConnected) {
      fwError = '录音卡未连接';
      notifyListeners();
      return;
    }
    fwUpdating = true;
    fwError = null;
    fwProgress = 0;
    fwStage = FwStage.main;
    fwStageText = '阶段 1/2 · 主控芯片';
    fwStateText = '正在准备…';
    notifyListeners();

    // 阶段 1：主控
    try {
      await for (final p in _gateway.otaMain()) {
        fwProgress = p.percent.clamp(0, 50) * 1.0; // 主控占前 50%
        fwStageText = '阶段 1/2 · 主控芯片';
        fwStateText = p.text;
        notifyListeners();
      }
    } on CardException catch (e) {
      _failFw('主控固件升级失败：${e.message}');
      return;
    }

    // DFU 后原连接失效：重新连卡再来第二阶段
    fwProgress = 50;
    fwStageText = '阶段 2/2 · Wi-Fi 芯片';
    fwStateText = '正在重新连接录音卡…';
    notifyListeners();
    var reconnected = false;
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final list = await _gateway.scan();
        final target =
            list.where((d) => d.name == connectedName).firstOrNull ??
            list.firstOrNull;
        if (target != null) {
          final snap = await _gateway.snapshot();
          _applySnapshot(snap);
          reconnected = true;
          break;
        }
      } on CardException {
        continue;
      }
    }
    if (!reconnected) {
      _failFw('升级后未能重新连接录音卡，请手动重连');
      return;
    }

    // 阶段 2：Wi-Fi 模组
    fwStage = FwStage.wifi;
    try {
      await for (final p in _gateway.otaWifi()) {
        fwProgress = 50 + p.percent.clamp(0, 100) * 0.5;
        fwStageText = '阶段 2/2 · Wi-Fi 芯片';
        fwStateText = p.text;
        notifyListeners();
      }
    } on CardException catch (e) {
      _failFw('Wi-Fi 模组升级失败：${e.message}');
      return;
    }

    fwUpdating = false;
    fwProgress = 100;
    fwStage = FwStage.done;
    view = DeviceView.main;
    _otaMainInfo = null;
    _otaWifiInfo = null;
    await refreshFromDevice();
    notifyListeners();
  }

  void _failFw(String message) {
    fwUpdating = false;
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
        await _gateway.openWifi();
        deviceWifiOpen = true;
      }
      final creds = await _gateway.wifiCredentials();
      final nets = await _gateway.scanWifi();
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
      await _gateway.connectWifi(n, '');
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
      await _gateway.connectWifi(sel, pwd);
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
      await _gateway.forgetWifi(ssid);
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
    _clockTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
