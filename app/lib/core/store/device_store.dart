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
import '../platform/bluetooth_permission.dart';

enum SyncState { idle, busy, done }

/// 最近一次同步是谁触发的：自动（停止录音/后台）还是用户点同步行。
enum SyncTrigger { auto, manual }

enum DeviceView { main, upg, wifi }

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

  /// 全部真实命令都经它转发：发出与返回都视为"蓝牙传输"，供看门狗顺延。
  late final CardGateway _gw = ActivityGateway(_gateway, _markLinkActivity);

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
      _applySnapshot(snapshot);
      linkState = LinkState.connected;
      linkError = null;
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      // 未连接是正常初始态，不算错误；其它错误如实呈现
      linkState = LinkState.disconnected;
      linkError = e.kind == CardErrorKind.disconnected ? null : e.message;
    }
    notifyListeners();
  }

  /// 我们这一系列录音卡的蓝牙名前缀（如 `DYJV2_T4W25T`）。
  ///
  /// SDK 扫描侧已按 DYJ + NUS 广播过滤；这里再兜一层，避免个别固件不广播
  /// NUS、或系统缓存里混入其它设备时把无关设备列给用户。
  static const deviceNamePrefix = 'DYJ';

  static bool isOurDevice(CardDevice device) =>
      device.name.toUpperCase().startsWith(deviceNamePrefix);

  /// RSSI → 1~3 格信号（与 Wi-Fi 列表同一套阈值，UI 直接复用）。
  static int signalOf(int? rssi) => _signalOf(rssi ?? -100);

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
    // 读一次授权状态用于解释失败原因。**不在这里阻塞等待用户点弹窗**：
    // 底层（Rust/CoreBluetooth）在扫描时会自己触发同一个系统对话框，
    // 这里若同步等 30 秒，用户看到的会是"点了扫描没反应"。
    bleAuth = await _permission.status();
    if (bleAuth == BluetoothAuthorization.denied ||
        bleAuth == BluetoothAuthorization.restricted) {
      linkState = LinkState.disconnected;
      linkError = bleAuth.hint;
      notifyListeners();
      return;
    }

    final epoch = ++_epoch;
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
          if (isOurDevice(device)) device,
      ]..sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
      linkState = LinkState.disconnected;
      linkError = discovered.isEmpty
          ? (bleAuth == BluetoothAuthorization.notDetermined
              ? '请允许「录音卡」使用蓝牙后重试'
              : '没有找到附近的录音卡，请确认录音卡已开机')
          : null;
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
    _markLinkActivity();
    try {
      final snapshot = await _gw.connect(device.id);
      if (epoch != _epoch) return;
      _markLinkActivity();
      // 桥只确认「连上」时没有快照：不要拿空数据覆盖旧状态，交给 _afterConnect 刷新。
      if (snapshot != null) _applySnapshot(snapshot);
      connectedName = device.name;
      // 记住这台设备：掉线重连直接拿 id 直连，不靠扫描（已连接设备不广播）
      _lastDevice = device;
      linkState = LinkState.connected;
      linkError = null;
      _eventSeq = 0;
      _startHeartbeat();
      unawaited(_afterConnect());
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      linkState = LinkState.disconnected;
      linkError = e.message;
    }
    notifyListeners();
  }

  /// 连上后的收尾：拉一次真实状态。
  ///
  /// 时间同步不在这里做：SDK 的 connect 内部已经 `sync_time_now()`，
  /// 再做一次只会让首屏状态多等一个命令周期（参考实现的 connect 也不做）。
  Future<void> _afterConnect() async {
    await refreshFromDevice();
  }

  /// 用户主动断开：先把会占用链路的状态收干净，再断。
  ///
  /// 顺序：停录音 → 关实时流 → 停同步 → 断开。跳过任一步都可能留下半截会话，
  /// 下次连接时设备状态与 App 对不上（这次 code -2 就吃过这个亏）。
  Future<void> disconnectSafely() async {
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
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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
    linkError = failure ??
        (report != null && !report.released
            ? '蓝牙链路未确认释放，请重试连接后再断开'
            : null);
    if (linkError != null) debugPrint('[disconnect] $linkError');
    notifyListeners();
  }

  void _resetLiveState() {
    _stopClock();
    _liveBattery = null;
    _liveCharging = null;
    _liveRecording = null;
    _recordSession = null;
    _clockTicks = 0;
    _fwVersion = '';
    _wifiVersion = '';
    _fwVersionCode = 0;
    _wifiVersionCode = 0;
    _storageFreeMb = null;
    _storageTotalMb = null;
    deviceWifiOpen = null;
  }

  // ── 弹层期间的状态跟随 ─────────────────────────────────────
  Timer? _sheetWatch;

  /// 弹层打开期间每 2 秒拉一次快照：设备侧按键/开关改变录音状态时界面立刻跟上。
  /// 只在弹层可见时跑，关掉即停，不额外耗电。
  void _startSheetWatch() {
    _sheetWatch?.cancel();
    // 200ms 拉一次**本地事件队列**（不访问设备，零蓝牙开销）：
    // 设备侧拨杆/按键的状态变化是主动推上来的，这里只负责快速取走。
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

  /// 取走设备主动推送的事件并应用到状态。
  Future<void> _pullDeviceEvents() async {
    try {
      final batch = await _gw.pullEvents(after: _eventSeq);
      if (batch.seq == _eventSeq && batch.events.isEmpty) return;
      _eventSeq = batch.seq;

      // 录音状态变化（拨杆 / 按键 / 固件自停）：直接改状态，不等下次查设备
      for (final item in batch.recordEvents) {
        final status = item['event']?['status'];
        if (status is! Map<String, dynamic>) continue;
        _applyRecordStatus(status);
      }
      if (batch.recordEvents.isNotEmpty) notifyListeners();
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
    // 固件自停时会带 error 码（如存储异常）：必须让用户看见原因，
    // 不能只是把开关悄悄关掉。参考实现会把整条 RECORD_STATUS 原样展示。
    final error = status['error'];
    if (error is num) {
      recordingError = '录音中断（设备错误码 ${error.toInt()}）';
    } else if (recording) {
      recordingError = null; // 新一轮录音开始，清掉上次的失败
    }
    if (recording == (_liveRecording ?? false)) return;
    _liveRecording = recording;
    _clockTicks = 0;
    if (!recording) _stopClock();
    if (recording && _clockUsers > 0) _startClock();
  }



  /// 宿主被卸载（页面销毁/热重载）：登记弹层已关并停掉轮询，不发通知。
  void markSheetDetached() {
    sheetOpen = false;
    _stopSheetWatch();
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
  static const _reconnectDelay = Duration(milliseconds: 400);

  /// 重连只发 connect（不再预拉快照），但桥内要先扫描（4s→6s 两档）再建链路，
  /// 上限给到 20s，避免把"正在重连"误判成失败。
  static const _retryConnectTimeout = Duration(seconds: 20);

  Timer? _heartbeatTimer;

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

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // widget 测试里 autoStart:false 不启，避免悬挂定时器
    if (!_autoStart) return;
    _sinceLinkActivity = Duration.zero;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _heartbeatTick();
    });
  }

  /// 每 5 秒醒一次只为累计"空闲时长"；满 30 秒才真正探一次。
  void _heartbeatTick() {
    if (linkState != LinkState.connected) return;
    // 固件升级/同步/录音命令链路忙：不插队，且这些动作本身已算活动
    if (fwUpdating || syncing || _linkBusy) {
      _markLinkActivity();
      return;
    }
    _sinceLinkActivity += const Duration(seconds: 5);
    if (_sinceLinkActivity < heartbeatIdle) return;
    unawaited(_watchdogProbe());
  }

  Future<void> _watchdogProbe() async {
    final epoch = _epoch;
    // 先占位再发命令：探测期间又一步 tick 不该叠第二次探测
    _sinceLinkActivity = Duration.zero;
    try {
      final snapshot = await _gw.snapshot();
      if (epoch != _epoch) return;
      _markLinkActivity();
      _applySnapshot(snapshot);
      notifyListeners();
    } on CardException catch (e) {
      if (epoch != _epoch) return;
      debugPrint('[watchdog] 探测失败（${e.kind}）：${e.message}');
      // 先停表：重连只许试一次，不能被后续 tick 叠成无限重试
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      // 判定掉线后先让桥真正释放旧链路，再重连。
      // 只换 UI 状态不释放链路（以前的"假断开"）会让设备端继续认为已连接、
      // 停止对外广播，重连也就扫不到它。
      await _releaseLink();
      if (epoch != _epoch) return;
      unawaited(_retryReconnect());
    }
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
  Future<void> _retryReconnect() async {
    if (linkState == LinkState.reconnecting) return; // 已在重试中，不重复
    if (!isConnected) return;
    // 探测失败已经说明链路不通：先立刻转蓝点，别让用户看到「已连接」再闪断
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
      final snapshot = await _gateway
          .connect(device.id)
          .timeout(_retryConnectTimeout);
      if (epoch != _epoch) return;
      _markLinkActivity();
      if (snapshot != null) _applySnapshot(snapshot);
      linkState = LinkState.connected;
      linkError = null;
      // 重连成功后必须把看门狗重新挂上：只在首次 connect 启表的话，
      // 一次掉线重连之后就再也没人探测了。
      _startHeartbeat();
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
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _stopClock();
    linkState = LinkState.disconnected;
    linkError = message;
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

  /// 设备管理层副标题：展示蓝牙连接态 + 固件版本 + 可用存储等设备基本信息。
  String get deviceSubtitleText {
    final parts = <String>['已连接 · 蓝牙'];
    if (_fwVersion.isNotEmpty) {
      parts.add('固件 $_fwVersion');
    }
    final freeMb = _storageFreeMb;
    if (freeMb != null && freeMb >= 0) {
      if (freeMb >= 1024) {
        parts.add('可用 ${(freeMb / 1024).toStringAsFixed(1)} GB');
      } else {
        parts.add('可用 $freeMb MB');
      }
    }
    return parts.join(' · ');
  }

  /// 设备端 Wi-Fi 模块是否开启（null = 未知，不冒充"已关闭"）。
  bool? deviceWifiOpen;

  void _applySnapshot(CardSnapshot s) {
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
    if (s.recording != (_liveRecording ?? false)) {
      _liveRecording = s.recording;
      _clockTicks = 0;
      // 录音计时跨页面持续走：Timeline 顶部状态块与弹层用的是同一个时钟。
      // 只有 UI 持有（retainClock）时才真正起表；停止录音/断开立即停表。
      if (!s.recording) _stopClock();
    }
    if (s.recording && _clockUsers > 0) _startClock();
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
  /// 「未录音」；计时从本次连接后的第一次开始录音算起（设备不回传起点）。
  Future<String?> toggleRecording() async {
    if (!isConnected) return '录音卡未连接';
    if (recordingBusy) {
      // 上一条命令还没回来：不静默丢弃点击，明确告诉用户在等什么。
      recordingError = '正在执行上一条命令，请稍候';
      notifyListeners();
      return null;
    }
    recordingBusy = true;
    recordingError = null;
    notifyListeners();
    try {
      // 用**明确的开始/停止**而不是 toggle：
      // toggle 依赖"App 认为的状态"与设备实际一致，一旦不一致（比如设备侧拨杆
      // 已开录、或状态推送丢失），再切就变成"停一条没在录的音" → 设备回 code -1/-2。
      // 硬超时也要有：设备无响应时必须给出明确结果，不能让开关永远停在"忙"。
      final wantStart = !isRecording;
      final action = wantStart ? _gw.startRecording() : _gw.stopRecording();
      await action.timeout(const Duration(seconds: 15));
      await refreshFromDevice();
      return null;
    } on TimeoutException {
      recordingError = '录音命令超时，请重试';
      return recordingError;
    } on CardException catch (e) {
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

  /// 预取弹层首屏要展示的概要信息（Wi-Fi 已配置数量、固件是否有更新）。
  ///
  /// 不做的话，用户不点进二级页就永远看到"0 个网络 / 已是最新"——那是假信息。
  Future<void> prefetchSummaryInfo() async {
    if (!isConnected) return;
    final epoch = _epoch;
    if (wifiSaved.isEmpty) {
      try {
        final creds = await _gw.wifiCredentials();
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
      unawaited(refreshFromDevice());
      unawaited(prefetchSummaryInfo());
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
    if (view == DeviceView.wifi && deviceWifiOpen == true && !wifiJoining) {
      unawaited(_closeWifiQuietly());
    }
    sheetOpen = false;
    _stopSheetWatch();
    // 不停录音时钟：录音还在继续，Timeline 顶部状态块要继续计时
    notifyListeners();
  }

  void showView(DeviceView v) {
    final prev = view;
    view = v;
    if (prev == DeviceView.wifi &&
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
    if (isRecording) {
      // 参考实现在 DFU 前会先停掉录音会话；对用户而言"升级悄悄掐断录音"
      // 是破坏性的（可能正在录会议），明确拒绝、让用户自己停更安全。
      // 停止录音会走正常的自动同步，之后再升级不丢数据。
      fwError = '正在录音，请先停止录音后再升级固件';
      fwStateText = fwError!;
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
      await for (final p in _gw.otaMain()) {
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
    // DFU 后原连接已失效：扫描到设备后必须重新 connect，不能只 snapshot——
    // 桥里的设备句柄在 DFU 前已被取走，直接 snapshot 只会一直报「未连接」。
    var reconnected = false;
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final list = await _gw.scan();
        final target =
            list.where((d) => d.name == connectedName).firstOrNull ??
            list.firstOrNull;
        if (target != null) {
          final snap = await _gw.connect(target.id);
          _lastDevice = target;
          if (snap != null) _applySnapshot(snap);
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
      await for (final p in _gw.otaWifi()) {
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
    _clockTimer?.cancel();
    _heartbeatTimer?.cancel();
    _stopSheetWatch();

    super.dispose();
  }
}
