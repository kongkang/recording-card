// 测试用卡片网关：把「已连接 / 未连接可扫描」两种硬件形态做成可注入的确定性桩。
// 真机走 RealCardGateway（FFI），这里只服务 widget 测试，不参与生产路径。
library;

import 'dart:async';

import 'package:recording_card/core/device/card_gateway.dart';

const defaultSnapshot = CardSnapshot(
  batteryLevel: 82,
  isCharging: false,
  wifiOpen: false,
  recording: true,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_TEST',
  deviceId: 'test-device',
);

class FakeCardGateway implements CardGateway {
  FakeCardGateway({
    CardSnapshot? initialSnapshot,
    this.devices = const [],
    this.connectResult,
    this.wifiNetworks = const [],
    List<CardWifiCredential> wifiCredentials = const [],
    this.available = true,
    this.mainOta = const CardOtaInfo(version: '', versionCode: 0, url: ''),
    this.wifiOta = const CardOtaInfo(version: '', versionCode: 0, url: ''),
    this.mainProgress = const [],
    this.wifiProgress = const [],
    this.progressDelay = const Duration(milliseconds: 300),
    this.wifiConnectDelay = Duration.zero,
    this.syncStatusResult = const CardSyncStatus(
      pending: 0,
      uploaded: 1,
      running: false,
    ),
  }) : current = initialSnapshot,
       savedCredentials = List<CardWifiCredential>.of(wifiCredentials);

  /// 当前设备快照；null = 未连接。
  CardSnapshot? current;

  /// scan() 返回的设备列表。
  List<CardDevice> devices;

  /// connect() 的返回；null 表示连上并复用 [current]（或默认快照）。
  CardSnapshot? connectResult;

  List<CardWifiNetwork> wifiNetworks;

  /// 设备端已保存凭据（可变，forgetWifi 会删除；connectWifi 成功会新增）。
  List<CardWifiCredential> savedCredentials;

  /// 服务器固件信息（默认 versionCode 0 = 不比设备新 → 「已是最新」）。
  CardOtaInfo mainOta;
  CardOtaInfo wifiOta;

  /// 两阶段 OTA 的进度事件（每条间隔 [progressDelay] 推一次）。
  List<CardProgress> mainProgress;
  List<CardProgress> wifiProgress;
  Duration progressDelay;

  /// 配网连接耗时：> 0 时能在测试里断言「正在连接…」这一帧。
  Duration wifiConnectDelay;

  /// syncStatus() 的回报（默认立即 running=false → 同步一次轮询即完成）。
  CardSyncStatus syncStatusResult;

  @override
  final bool available;

  int scanCalls = 0;
  int connectCalls = 0;
  int snapshotCalls = 0;
  int syncStatusCalls = 0;
  bool disconnectCalled = false;
  String? lastConnectedId;
  String? lastWifiSsid;
  String? lastWifiPassword;
  String? lastForgottenWifi;
  bool startSyncCalled = false;

  /// 每个能力的错误注入点：非 null 时对应调用抛该异常。
  CardException? failSnapshot;
  CardException? failConnect;
  CardException? failWifiScan;
  CardException? failWifiConnect;
  CardException? failSyncStatus;

  @override
  Future<CardSnapshot> snapshot() async {
    snapshotCalls++;
    if (failSnapshot != null) throw failSnapshot!;
    final snap = current;
    if (snap == null) throw CardException.disconnected();
    return snap;
  }

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async {
    scanCalls++;
    return devices;
  }

  @override
  Future<CardSnapshot> connect(String deviceId) async {
    connectCalls++;
    lastConnectedId = deviceId;
    if (failConnect != null) throw failConnect!;
    final result = connectResult ?? current ?? defaultSnapshot;
    current = result;
    return result;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    current = null;
  }

  @override
  Future<void> record(String action) async {}

  @override
  Future<void> mark() async {}

  @override
  Future<List<CardFile>> files() async => const [];

  @override
  Future<CardDownload> download(String name, String dir) async =>
      CardDownload(path: '$dir/$name', bytesWritten: 0, originalName: name);

  @override
  Future<void> deleteFile(String name) async {}

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async =>
      CardAudio(path: wavPath, samples: 0, durationSecs: 0);

  @override
  Future<List<CardWifiNetwork>> scanWifi() async {
    if (failWifiScan != null) throw failWifiScan!;
    return wifiNetworks;
  }

  @override
  Future<void> connectWifi(String ssid, String password) async {
    lastWifiSsid = ssid;
    lastWifiPassword = password;
    if (wifiConnectDelay > Duration.zero) {
      await Future<void>.delayed(wifiConnectDelay);
    }
    if (failWifiConnect != null) throw failWifiConnect!;
    // 真实固件会把成功的网络存进自己的凭据表，这里保持同样的可观察结果
    if (!savedCredentials.any((c) => c.ssid == ssid)) {
      savedCredentials = [...savedCredentials, CardWifiCredential(ssid: ssid)];
    }
    current = CardSnapshot(
      batteryLevel: current?.batteryLevel ?? 82,
      isCharging: current?.isCharging ?? false,
      wifiOpen: true,
      recording: current?.recording ?? false,
      fwVersion: current?.fwVersion ?? '2.2.0',
      fwVersionCode: current?.fwVersionCode ?? 22,
      wifiVersion: current?.wifiVersion ?? '1.5.0',
      wifiVersionCode: current?.wifiVersionCode ?? 15,
      deviceName: current?.deviceName ?? 'DYJV2_TEST',
      deviceId: current?.deviceId ?? 'test-device',
    );
  }

  @override
  Future<void> openWifi() async {}

  @override
  Future<void> closeWifi() async {}

  @override
  Future<List<CardWifiCredential>> wifiCredentials() async => savedCredentials;

  @override
  Future<void> forgetWifi(String ssid) async {
    lastForgottenWifi = ssid;
    savedCredentials = savedCredentials.where((c) => c.ssid != ssid).toList();
  }

  @override
  Future<void> startSync() async {
    startSyncCalled = true;
  }

  @override
  Future<CardSyncStatus> syncStatus() async {
    syncStatusCalls++;
    if (failSyncStatus != null) throw failSyncStatus!;
    return syncStatusResult;
  }

  @override
  Future<void> setUploadUrl(String url) async {}

  @override
  Future<CardOtaInfo> otaInfo(String module) async =>
      module == 'wifi' ? wifiOta : mainOta;

  /// 按 [progressDelay] 逐条推进度；事件推完即流关闭（等价于设备侧 final:true）。
  Stream<CardProgress> _progress(List<CardProgress> events) async* {
    for (final p in events) {
      if (progressDelay > Duration.zero) {
        await Future<void>.delayed(progressDelay);
      }
      yield p;
    }
  }

  @override
  Stream<CardProgress> otaMain() => _progress(mainProgress);

  @override
  Stream<CardProgress> otaWifi() => _progress(wifiProgress);

  @override
  Future<void> syncTime() async {}

  @override
  Future<void> dispose() async {}
}
