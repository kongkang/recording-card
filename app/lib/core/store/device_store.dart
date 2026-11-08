/// 录音卡设备状态机 —— 对应 prototype 状态胶囊弹层全部逻辑。
/// 时序常量与原型一致（测试对齐依赖）：同步 busy 900ms + 冷却 10s；Wi-Fi 扫描 1200ms、
/// 直连 1200ms、新网络 1400ms；固件两阶段共 6000ms。
///
/// 真实数据：经 [CardGateway]（card_bridge FFI → reai-card-sdk BLE）刷新；
/// 网关不可用/无硬件时回退预置数据，界面语义不变。
library;
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../device/card_gateway.dart';

enum SyncState { idle, busy, done }
enum DeviceView { main, upg, wifi }

class WifiNet {
  final String name;
  final int signal; // 1-3
  final bool lock;
  const WifiNet(this.name, this.signal, {this.lock = false});
}

class SavedWifi {
  final String name;
  final String pwd;
  const SavedWifi(this.name, this.pwd);
}

class DeviceStore extends ChangeNotifier {
  DeviceStore({CardGateway? gateway})
      : _gateway = gateway ??
            RealCardGateway.maybe() ??
            const MockCardGateway();

  final CardGateway _gateway;

  /// 真实桥是否就绪（真机+硬件时可观测）
  bool get liveDeviceAvailable => _gateway.available;

  // ── 录音时钟：起始 3:12:15，每秒跳动；定时器随弹层开关启停 ──
  static const _clockBase = 3 * 3600 + 12 * 60 + 15;
  int _clockTicks = 0;
  Timer? _clockTimer;

  int get recSeconds => _clockBase + _clockTicks;

  void _startClock() {
    _clockTimer?.cancel();
    // tick 计数驱动（虚拟时间下确定），不用墙钟差值
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
    return '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // ── 电量：默认 82%（高）；有真实桥时以设备回报为准，可录至时点保守估算 ──
  static const batteryLevel = 82; // ≥40 绿（预置/回退值）
  int? _liveBattery;
  bool? _liveCharging;

  /// 当前展示电量：真实回报优先，否则预置值
  int get battery => _liveBattery ?? DeviceStore.batteryLevel;
  String get batteryLevelText {
    final level = battery;
    if (_liveCharging == true) return '充电中';
    return level < 20 ? '电量低' : level < 40 ? '电量中' : '电量高';
  }

  String get batteryEtaText {
    final level = battery;
    final hours = (level * 0.24 * 0.7).floor().clamp(1, 24);
    final end = DateTime.now().add(Duration(hours: hours));
    final hm =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    final day = end.day == DateTime.now().day ? '今天' : '明天';
    return '$day $hm';
  }

  /// 弹层打开时尝试刷新真实设备数据（无桥/无硬件静默回退预置值）
  Future<void> refreshFromDevice() async {
    if (!_gateway.available) return;
    final snapshot = await _gateway.status();
    if (snapshot == null) return;
    _liveBattery = snapshot.batteryLevel.clamp(1, 100);
    _liveCharging = snapshot.isCharging;
    notifyListeners();
  }

  // ── 同步：idle → busy(900ms) → done(冷却 10s) → idle ──
  SyncState syncState = SyncState.idle;
  DateTime lastSync = DateTime.now().subtract(const Duration(seconds: 50));

  String get syncRelText {
    final s = DateTime.now().difference(lastSync).inSeconds;
    if (s < 30) return '刚刚';
    if (s < 60) return '30 秒前';
    return '${s ~/ 60} 分钟前';
  }

  String get syncText => switch (syncState) {
        SyncState.busy => '正在同步…',
        SyncState.done => '同步成功 · 刚刚',
        SyncState.idle => '最近同步 · $syncRelText',
      };

  void syncNow() {
    if (syncState != SyncState.idle) return;
    syncState = SyncState.busy;
    notifyListeners();
    Timer(const Duration(milliseconds: 900), () {
      lastSync = DateTime.now();
      syncState = SyncState.done;
      notifyListeners();
      Timer(const Duration(seconds: 10), () {
        syncState = SyncState.idle;
        notifyListeners();
      });
    });
  }

  // ── 弹层视图 ──
  bool sheetOpen = false;
  DeviceView view = DeviceView.main;

  void openSheet() {
    sheetOpen = true;
    view = DeviceView.main;
    _startClock();
    unawaited(refreshFromDevice()); // 真实电量/状态异步刷新，回退路径不阻塞 UI
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
    if (v == DeviceView.wifi) wifiScan();
    notifyListeners();
  }

  // ── 固件：两阶段（主控 / Wi-Fi 芯片），共 6s ──
  static const fwTotalMs = 6000;
  bool fwUpdating = false;
  bool fwDone = false;
  double fwProgress = 0;
  String fwValText = '有可用更新';
  String devStateText = '';

  String get fwStageText => fwProgress < 50 ? '阶段 1/2 · 主控芯片' : '阶段 2/2 · Wi-Fi 芯片';
  String get fwPctText => '${fwProgress.round()}%';
  String get fwStateText {
    final pc = fwProgress;
    if (pc < 25) return '正在下载固件…';
    if (pc < 50) return '通过蓝牙传输到设备…';
    if (pc < 75) return '主控写入中，请保持连接…';
    return 'Wi-Fi 模组写入中，请保持连接…';
  }

  // TODO(SDK-OTA)：固件 OTA 接口在 reai-card-sdk v0.0.5 无记录（docs/SDK-CAPABILITY.md），
  // 当前按设计稿交互形态实现，真实接口落地后替换本模拟进程。
  void startFwUpdate() {
    if (fwUpdating) return;
    fwUpdating = true;
    fwProgress = 0;
    notifyListeners();
    var ticks = 0;
    Timer.periodic(const Duration(milliseconds: 150), (t) {
      ticks++;
      final ms = ticks * 150;
      fwProgress = (ms / fwTotalMs * 100).clamp(0, 100);
      if (fwProgress >= 100) {
        t.cancel();
        fwUpdating = false;
        fwDone = true;
        view = DeviceView.main;
        fwValText = '已是最新';
        devStateText = '已更新到 主控 2.2.0 / Wi-Fi 1.5.0';
      }
      notifyListeners();
    });
  }

  // ── Wi-Fi：已保存置顶 + 扫描可用；仅 2.4GHz ──
  List<SavedWifi> wifiSaved = const [
    SavedWifi('HomeWiFi', 'saved-pwd'),
    SavedWifi('Studio-2.4G', 'saved-pwd'),
    SavedWifi('Bedroom-2.4G', 'saved-pwd'),
    SavedWifi('Old-2.4G', 'saved-pwd'),
  ];
  String wifiLast = 'HomeWiFi';
  bool wifiMore = false;
  bool wifiScanDone = false;
  bool wifiJoining = false;
  String wifiJoinName = '';
  String? wifiSelName;
  String wifiStateText = '';
  List<WifiNet> wifiScanRes = const [];
  final Set<String> _wifiInRange = {};
  int wifiCountShown = 2; // 与原型一致：打开 Wi-Fi 页后才刷新为实际数量

  bool wifiInRange(String n) => _wifiInRange.contains(n);

  void wifiScan() {
    wifiSelName = null;
    wifiJoining = false;
    wifiJoinName = '';
    wifiScanDone = false;
    wifiStateText = '硬件 Wi-Fi 已开启，正在扫描附近网络…';
    notifyListeners();
    Timer(const Duration(milliseconds: 1200), () {
      wifiScanRes = const [
        WifiNet('HomeWiFi', 3),
        WifiNet('Office-2.4G', 2, lock: true),
        WifiNet('Cafe_Guest', 1, lock: true),
      ];
      _wifiInRange
        ..clear()
        ..addAll(wifiScanRes.map((r) => r.name));
      wifiScanDone = true;
      wifiCountShown = wifiSaved.length;
      wifiStateText = '扫描完成 · 附近可见 ${wifiScanRes.length} 个 2.4GHz 网络';
      notifyListeners();
    });
  }

  void wifiMoreToggle() {
    wifiMore = !wifiMore;
    notifyListeners();
  }

  bool get wifiIsJoiningSaved =>
      wifiJoining && wifiSaved.any((w) => w.name == wifiJoinName);

  void wifiConnectSaved(String n) {
    if (wifiJoining || !wifiInRange(n)) return;
    wifiJoining = true;
    wifiJoinName = n;
    notifyListeners();
    Timer(const Duration(milliseconds: 1200), () {
      wifiLast = n;
      wifiJoining = false;
      wifiJoinName = '';
      wifiStateText = '$n 连接成功';
      notifyListeners();
    });
  }

  void wifiPick(String n) {
    if (wifiJoining) return;
    wifiSelName = n;
    notifyListeners();
  }

  void wifiCancelPick() {
    wifiSelName = null;
    notifyListeners();
  }

  void wifiJoinNew(String pwd) {
    final r = wifiScanRes.where((x) => x.name == wifiSelName).firstOrNull;
    if (r == null) return;
    wifiJoining = true;
    wifiJoinName = r.name;
    notifyListeners();
    Timer(const Duration(milliseconds: 1400), () {
      wifiSaved = [...wifiSaved, SavedWifi(r.name, pwd)];
      wifiLast = r.name;
      wifiJoining = false;
      wifiJoinName = '';
      wifiSelName = null;
      wifiCountShown = wifiSaved.length;
      wifiStateText = '$wifiLast 连接成功';
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }
}
