// 测试用卡片网关：把「已连接 / 未连接可扫描」两种硬件形态做成可注入的确定性桩。
// 真机走 RealCardGateway（FFI），这里只服务 widget 测试，不参与生产路径。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

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

/// 设备侧按键/开关开始录音后的真实快照：recording=true。
/// 关键回归点：`state.recordRealtimeEnabled` 是实时流开关，不能当作"正在录音"。
const pressedOnDeviceSnapshot = CardSnapshot(
  batteryLevel: 76,
  isCharging: false,
  wifiOpen: false,
  recording: true,
  realtimeEnabled: false,
  recordReason: 'button',
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
    this.deviceFiles = const [],
    this.writeDownload = false,
    this.transcodeSeconds = 0,
    this.failDownload,
    this.failTranscode,
    this.failScan,
    this.disconnectReport,
    this.failDisconnect,
    this.connectReturnsSnapshot = true,
    this.clearAfterMainOta = false,
    this.postMainOtaSnapshot,
    this.postWifiOtaSnapshot,
    this.failMainOta,
    this.failWifiOta,
    this.cameraPhotos = const [],
    this.fakeCapturedPhotoBytes,
    Map<String, String>? initialCardControls,
  }) : _initialSnapshot = initialSnapshot,
       current = initialSnapshot,
       savedCredentials = List<CardWifiCredential>.of(wifiCredentials),
       cardControls = {
         'btnSingle': 'none',
         'btnDouble': 'none',
         'btnLongPress': 'none',
         'btnLongRelease': 'none',
         'switchOn': 'none',
         'switchOff': 'none',
         ...?initialCardControls,
       };

  final CardSnapshot? _initialSnapshot;

  /// files() 返回的设备文件；默认空（保持旧测试行为）。
  List<CardFile> deviceFiles;

  /// syncCameraPhotos() 返回的硬件抓拍照片。
  List<CameraSyncItem> cameraPhotos;
  int syncCameraCalls = 0;

  /// 测试用硬件抓拍字节（响应 `camera_capture_and_fetch`）。
  Uint8List? fakeCapturedPhotoBytes;

  /// 记录收到的 LED 提示模式（`dyj_led_hint`）。
  final List<String> ledHintModes = [];

  /// 记录通过点一机扬声器播报的文本（`dyj_tts_speak`）。
  final List<String> dyjTtsSpokenTexts = [];
  bool dyjTtsSupported = true;
  Object? failDyjTts;

  /// 录音卡 V2（CardV2）物理按键与拨杆 KV 绑定状态（`card_controls.get`/`set`）。
  final Map<String, String> cardControls;
  int cardControlsGetCalls = 0;
  final List<Map<String, dynamic>> cardControlsSetCalls = [];
  final Map<String, String> deviceConfigs = {};

  /// 录音卡 V2（CardV2）OLED 屏幕调用记录（`card_display.show`/`clear`）。
  final List<Map<String, dynamic>> displayShowCalls = [];
  int displayClearCalls = 0;

  /// mark() 调用次数。
  int markCalls = 0;

  /// download() 是否真的落盘（管线测试用）。
  bool writeDownload;

  /// transcode() 写出的 WAV 时长（秒）；0 表示沿用旧的空结果。
  int transcodeSeconds;

  CardException? failDownload;
  CardException? failTranscode;
  Set<String> failDownloadNames = {};
  final Map<String, CardDownload> downloadOverrides = {};
  final List<String> deletedFiles = [];
  Duration downloadDelay = Duration.zero;
  int downloadCalls = 0;
  int apFilesCalls = 0;
  int apDownloadCalls = 0;
  int transcodeCalls = 0;
  double? lastTranscodeSourceSampleRateHz;

  /// 当前设备快照；null = 未连接。
  CardSnapshot? current;

  /// scan() 返回的设备列表。
  List<CardDevice> devices;

  /// connect() 的返回；null 表示连上并复用 [current]（或默认快照）。
  CardSnapshot? connectResult;

  /// false = connect 只回「已连上」，不附带状态快照（真实桥的行为）。
  bool connectReturnsSnapshot;

  /// true = 主控 DFU 结束后设备复位，旧的 [current] 失效（要重新 connect）。
  bool clearAfterMainOta;

  /// 按调用顺序记录设备命令，用于断言时序（如先开实时流再发 RECORD_START）。
  final List<String> callLog = [];

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

  /// 扩展桥命令/流可注入桩（供独立旧固件引导升级等测试使用）。
  Future<Map<String, dynamic>> Function(String kind, Map<String, dynamic>? payload)?
  onBridgeCommand;
  Stream<CardProgress> Function(
    String kind,
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  )?
  onBridgeStream;
  Stream<CardProgress> Function()? otaMainOverride;
  Future<CardSnapshot?> Function(
    String deviceId, {
    String? name,
    String? deviceKind,
  })?
  connectOverride;

  /// syncStatus() 的回报（默认立即 running=false → 同步一次轮询即完成）。
  CardSyncStatus syncStatusResult;

  @override
  final bool available;

  int scanCalls = 0;
  int connectCalls = 0;
  int snapshotCalls = 0;
  int syncStatusCalls = 0;
  bool disconnectCalled = false;
  int disconnectCalls = 0;

  /// 每次 connect 时累计的 disconnect 次数：用来断言「先释放、再重连」的顺序。
  final List<int> disconnectCallsAtConnect = [];

  /// disconnect() 返回的桥结果；null = 已释放（旧测试默认）。
  CardDisconnectReport? disconnectReport;
  CardException? failDisconnect;
  String? lastConnectedId;
  String? lastConnectedName;
  String? lastConnectedKind;
  String? lastWifiSsid;
  String? lastWifiPassword;
  String? lastForgottenWifi;
  bool startSyncCalled = false;

  /// 每个能力的错误注入点：非 null 时对应调用抛该异常。
  CardException? failScan;
  CardException? failSnapshot;
  CardException? failConnect;
  CardException? failWifiScan;
  CardException? failWifiConnect;
  CardException? failSyncStatus;
  CardException? failMainOta;
  CardException? failWifiOta;
  CardException? failRestart;
  CardException? failShutdown;
  CardSnapshot? postMainOtaSnapshot;
  CardSnapshot? postWifiOtaSnapshot;
  int? lastStartDurationSecs;
  bool? lastOtaWifiRestoreOpen;
  int openWifiCalls = 0;
  int closeWifiCalls = 0;
  int restartCalls = 0;
  int shutdownCalls = 0;

  @override
  Future<CardSnapshot> snapshot() async {
    snapshotCalls++;
    callLog.add('snapshot');
    if (failSnapshot != null) throw failSnapshot!;
    final snap = current;
    if (snap == null) throw CardException.disconnected();
    return snap;
  }

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async {
    scanCalls++;
    callLog.add('scan');
    if (failScan != null) throw failScan!;
    return devices;
  }

  CardSnapshot _copySnapshot(
    CardSnapshot cur, {
    int? batteryLevel,
    bool? isCharging,
    bool? wifiOpen,
    bool? recording,
  }) {
    return CardSnapshot(
      batteryLevel: batteryLevel ?? cur.batteryLevel,
      isCharging: isCharging ?? cur.isCharging,
      wifiOpen: wifiOpen ?? cur.wifiOpen,
      recording: recording ?? cur.recording,
      fwVersion: cur.fwVersion,
      fwVersionCode: cur.fwVersionCode,
      wifiVersion: cur.wifiVersion,
      wifiVersionCode: cur.wifiVersionCode,
      deviceName: cur.deviceName,
      deviceId: cur.deviceId,
      storageTotalMb: cur.storageTotalMb,
      storageFreeMb: cur.storageFreeMb,
      hasBattery: cur.hasBattery,
      realtimeEnabled: cur.realtimeEnabled,
      recordSession: cur.recordSession,
      recordErrorCode: cur.recordErrorCode,
      recordReason: cur.recordReason,
      deviceKind: cur.deviceKind,
      displayModel: cur.displayModel,
      capabilities: cur.capabilities,
    );
  }

  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) async {
    connectCalls++;
    callLog.add('connect');
    disconnectCallsAtConnect.add(disconnectCalls);
    lastConnectedId = deviceId;
    lastConnectedName = name;
    lastConnectedKind = deviceKind;
    if (connectOverride != null) {
      return connectOverride!(deviceId, name: name, deviceKind: deviceKind);
    }
    if (failConnect != null) throw failConnect!;
    final source =
        current ?? postMainOtaSnapshot ?? _initialSnapshot ?? defaultSnapshot;
    CardSnapshot adapted = source;
    final matched = devices.where((d) => d.id == deviceId).firstOrNull;
    final resolvedName = name ?? matched?.name;
    final resolvedKind = deviceKind != null || resolvedName != null
        ? DeviceKind.fromCode(deviceKind, fallbackName: resolvedName ?? '')
        : matched?.deviceKind;
    if (resolvedKind != null &&
        (resolvedKind != source.effectiveKind ||
            (resolvedName != null && resolvedName != source.deviceName))) {
      adapted = CardSnapshot(
        batteryLevel: source.batteryLevel,
        isCharging: source.isCharging,
        wifiOpen: source.wifiOpen,
        recording: source.recording,
        fwVersion: source.fwVersion,
        fwVersionCode: source.fwVersionCode,
        wifiVersion: resolvedKind == DeviceKind.cardV2 ? source.wifiVersion : '',
        wifiVersionCode: resolvedKind == DeviceKind.cardV2
            ? source.wifiVersionCode
            : 0,
        deviceName: resolvedName ?? source.deviceName,
        deviceId: deviceId,
        storageTotalMb: source.storageTotalMb,
        storageFreeMb: source.storageFreeMb,
        hasBattery: source.hasBattery,
        realtimeEnabled: source.realtimeEnabled,
        recordSession: source.recordSession,
        recordErrorCode: source.recordErrorCode,
        recordReason: source.recordReason,
        deviceKind: resolvedKind,
        displayModel: resolvedKind.displayModel,
        capabilities: HardwareCapabilities.forKind(resolvedKind),
      );
    }
    if (!connectReturnsSnapshot) {
      // 真实桥只回 connected；状态由调用方随后刷新。
      current = connectResult ?? adapted;
      return null;
    }
    final result = connectResult ?? adapted;
    current = result;
    return result;
  }

  @override
  Future<CardDisconnectReport> disconnect() async {
    disconnectCalled = true;
    disconnectCalls++;
    callLog.add('disconnect');
    current = null;
    if (failDisconnect != null) throw failDisconnect!;
    return disconnectReport ?? CardDisconnectReport.alreadyReleased;
  }

  /// 录音命令记录（start/stop/toggle），供状态机测试断言。
  final List<String> recordCalls = [];

  @override
  Future<void> startRecording({int? durationSecs}) async {
    lastStartDurationSecs = durationSecs;
    recordCalls.add('start');
    callLog.add('record.start');
    final cur = current;
    if (cur == null) throw CardException.disconnected();
    current = _copySnapshot(cur, recording: true);
  }

  @override
  Future<void> stopRecording() async {
    recordCalls.add('stop');
    callLog.add('record.stop');
    final cur = current;
    if (cur == null) throw CardException.disconnected();
    current = _copySnapshot(cur, recording: false);
  }

  /// 实时音频流：测试可先塞入 [realtimeEvents]，订阅时按序吐出。
  final List<RealtimeAudioEvent> realtimeEvents = [];
  int realtimeOpenCalls = 0;
  int realtimeCloseCalls = 0;

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() async* {
    realtimeOpenCalls++;
    callLog.add('realtime.open');
    for (final event in realtimeEvents) {
      yield event;
    }
  }

  @override
  Future<void> closeRealtime() async {
    realtimeCloseCalls++;
    callLog.add('realtime.close');
  }

  /// 设备主动推送的事件队列（测试里手动 push 模拟拨杆/按键）。
  final List<Map<String, dynamic>> deviceEvents = [];
  int _eventSeq = 0;
  int pullEventCalls = 0;

  void pushRecordEvent({required bool recording, String reason = 'switch'}) {
    _eventSeq++;
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'record',
        'status': {
          'isRecording': recording,
          'realtimeEnabled': false,
          'reason': reason,
        },
      },
    });
  }

  /// 固件录音出错时主动推的状态：`isRecording=false` + `error` 码。
  void pushRecordError({required int code, String reason = 'app'}) {
    _eventSeq++;
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'record',
        'status': {
          'isRecording': false,
          'realtimeEnabled': false,
          'reason': reason,
          'error': code,
        },
      },
    });
  }

  /// 设备电源/电量变化主动推送。
  void pushPowerEvent({required int level, required bool charging}) {
    _eventSeq++;
    if (current != null) {
      current = _copySnapshot(
        current!,
        batteryLevel: level,
        isCharging: charging,
      );
    }
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'power',
        'battery': {
          'level': level,
          'isCharging': charging,
        },
      },
    });
  }

  /// 语音 AI 键盘物理语音键按下事件。
  void pushVoiceKeyEvent({bool pressed = true}) {
    _eventSeq++;
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'voice_key',
        'pressed': pressed,
      },
    });
  }

  /// 点一机 V1 硬件拍照通知事件。
  void pushCameraEvent({String? name}) {
    _eventSeq++;
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'camera',
        'name': ?name,
      },
    });
  }

  /// 物理按键手势事件（down / up / click / double_click / long_press_start / long_press_end）。
  void pushButtonEvent({
    String? gesture,
    String? type,
    int? durationMs,
    int deviceTs = 0,
    int? receivedAtMs,
    String? deviceAction,
    String? source,
  }) {
    _eventSeq++;
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'button',
        'gesture': gesture ?? type ?? 'click',
        'durationMs': durationMs,
        'deviceTs': deviceTs,
        'receivedAtMs': receivedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        'deviceAction': ?deviceAction,
        'source': ?source,
      },
    });
  }

  /// 录音卡 V2 侧边拨杆开关事件（`TOGGLE_SWITCH`）。
  void pushToggleSwitchEvent({
    required String position,
    String? deviceAction,
    int? receivedAtMs,
  }) {
    _eventSeq++;
    final pos = position.trim().toLowerCase() == 'off' ? 'off' : 'on';
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {
        'kind': 'toggle_switch',
        'position': pos,
        'gesture': 'switch_$pos',
        'deviceAction': deviceAction ?? 'none',
        'source': 'card_v2_switch',
        'receivedAtMs': receivedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      },
    });
  }

  /// 蓝牙被动断连事件。
  void pushDisconnectedEvent() {
    _eventSeq++;
    deviceEvents.add({
      'seq': _eventSeq,
      'event': {'kind': 'disconnected'},
    });
  }

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) async {
    pullEventCalls++;
    final fresh = deviceEvents
        .where((e) => ((e['seq'] as num?)?.toInt() ?? 0) > after)
        .toList();
    return DeviceEventBatch(seq: _eventSeq, events: fresh);
  }

  @override
  Future<void> record(String action) async {
    recordCalls.add(action);
    final cur = current;
    if (cur == null) throw CardException.disconnected();
    final recording = switch (action) {
      'start' => true,
      'stop' => false,
      'toggle' => !cur.recording,
      _ => cur.recording,
    };
    current = _copySnapshot(cur, recording: recording);
  }

  @override
  Future<void> mark() async {
    markCalls++;
    callLog.add('mark');
  }

  @override
  Future<List<CardFile>> files() async => deviceFiles;

  @override
  Future<CardDownload> download(String name, String dir) async {
    downloadCalls++;
    if (downloadDelay > Duration.zero) {
      await Future<void>.delayed(downloadDelay);
    }
    if (failDownload != null) throw failDownload!;
    if (failDownloadNames.contains(name)) {
      throw CardException(CardErrorKind.device, '注入失败：$name');
    }
    final override = downloadOverrides[name];
    if (override != null) {
      if (writeDownload) {
        if (override.path.isNotEmpty) {
          final f = File(override.path);
          await f.parent.create(recursive: true);
          if (!await f.exists()) {
            await f.writeAsBytes(Uint8List(64), flush: true);
          }
        }
        for (final part in override.parts) {
          if (part.path.isEmpty) continue;
          final f = File(part.path);
          await f.parent.create(recursive: true);
          if (!await f.exists()) {
            await f.writeAsBytes(Uint8List(64), flush: true);
          }
        }
      }
      return override;
    }
    final path = '$dir/$name';
    if (writeDownload) {
      await Directory(dir).create(recursive: true);
      await File(path).writeAsBytes(Uint8List(64), flush: true);
    }
    return CardDownload(path: path, bytesWritten: 64, originalName: name);
  }

  @override
  Future<CardDownload> takeOldestFile(String dir) async {
    callLog.add('file.takeOldest');
    final pending = deviceFiles.where((f) => f.isAudioRecording).toList();
    if (pending.isEmpty) {
      throw const CardException(CardErrorKind.device, '没有可取回的录音文件');
    }
    final oldest = pending.first;
    final res = await download(oldest.name, dir);
    deviceFiles = deviceFiles.where((f) => f.name != oldest.name).toList();
    return res;
  }

  @override
  Future<void> deleteFile(String name) async {
    deletedFiles.add(name);
    callLog.add('file.delete:$name');
  }

  @override
  Future<List<CardFile>> apFiles({
    String host = '192.168.4.1',
    int port = 80,
  }) async {
    apFilesCalls++;
    callLog.add('ap.files:$host:$port');
    return deviceFiles;
  }

  @override
  Future<CardDownload> apDownload(
    String name,
    String dir, {
    String host = '192.168.4.1',
    int port = 80,
    int? expectedSize,
    bool deleteAfterVerify = false,
  }) async {
    apDownloadCalls++;
    callLog.add('ap.download:$name');
    final dl = await download(name, dir);
    if (deleteAfterVerify) {
      await deleteFile(name);
    }
    return dl;
  }

  @override
  Future<CardAudio> transcode(
    String apmPath,
    String wavPath, {
    double? sourceSampleRateHz,
  }) async {
    transcodeCalls++;
    lastTranscodeSourceSampleRateHz = sourceSampleRateHz;
    if (failTranscode != null) throw failTranscode!;
    if (transcodeSeconds <= 0) {
      return CardAudio(path: wavPath, samples: 0, durationSecs: 0);
    }
    final samples = Float32List(transcodeSeconds * 16000);
    // 低幅正弦，避免全零被特殊处理；内容由 FakeSpeechEngine 决定
    for (var i = 0; i < samples.length; i++) {
      samples[i] = 0.01 * ((i % 160) - 80) / 80;
    }
    await Directory(File(wavPath).parent.path).create(recursive: true);
    await File(wavPath).writeAsBytes(encodeWav(samples), flush: true);
    return CardAudio(
      path: wavPath,
      samples: samples.length,
      durationSecs: transcodeSeconds.toDouble(),
    );
  }

  @override
  Future<List<CameraSyncItem>> syncCameraPhotos(
    String dir, {
    String? serverOrigin,
  }) async {
    syncCameraCalls++;
    callLog.add('camera.sync');
    return cameraPhotos;
  }

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
    if (current != null) {
      current = _copySnapshot(current!, wifiOpen: true);
    } else {
      current = _copySnapshot(defaultSnapshot, wifiOpen: true);
    }
  }

  @override
  Future<void> openWifi() async {
    openWifiCalls++;
    callLog.add('wifi.open');
    if (current != null) {
      current = _copySnapshot(current!, wifiOpen: true);
    }
  }

  @override
  Future<void> closeWifi() async {
    closeWifiCalls++;
    callLog.add('wifi.close');
    if (current != null) {
      current = _copySnapshot(current!, wifiOpen: false);
    }
  }

  bool? lastWifiCredentialsPassive;

  @override
  Future<List<CardWifiCredential>> wifiCredentials({
    bool passive = false,
  }) async {
    lastWifiCredentialsPassive = passive;
    return savedCredentials;
  }

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

  Future<CardOtaInfo> Function(String module)? otaInfoOverride;
  Object? failMainOtaInfo;
  Object? failWifiOtaInfo;

  @override
  Future<CardOtaInfo> otaInfo(String module) async {
    if (otaInfoOverride != null) {
      return otaInfoOverride!(module);
    }
    if (module == 'wifi' && failWifiOtaInfo != null) {
      throw failWifiOtaInfo!;
    }
    if (module == 'main' && failMainOtaInfo != null) {
      throw failMainOtaInfo!;
    }
    return module == 'wifi' ? wifiOta : mainOta;
  }

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
  Stream<CardProgress> otaMain() async* {
    callLog.add('ota.main');
    if (otaMainOverride != null) {
      yield* otaMainOverride!();
      return;
    }
    yield* _progress(mainProgress);
    if (failMainOta != null) throw failMainOta!;
    if (clearAfterMainOta) {
      current = null;
    } else if (postMainOtaSnapshot != null) {
      current = postMainOtaSnapshot;
    }
  }

  @override
  Stream<CardProgress> otaWifi({bool? restoreWifiOpen}) async* {
    callLog.add('ota.wifi');
    lastOtaWifiRestoreOpen = restoreWifiOpen;
    final prevWifiOpen = current?.wifiOpen ?? false;
    final targetWifiOpen = restoreWifiOpen ?? prevWifiOpen;
    if (!prevWifiOpen) {
      openWifiCalls++;
      if (current != null) {
        current = _copySnapshot(current!, wifiOpen: true);
      }
    }
    yield* _progress(wifiProgress);
    if (failWifiOta != null) {
      if (current != null) {
        current = _copySnapshot(current!, wifiOpen: targetWifiOpen);
      }
      if (!targetWifiOpen) {
        closeWifiCalls++;
      }
      throw failWifiOta!;
    }
    final nextSnap = postWifiOtaSnapshot ?? current;
    if (nextSnap != null) {
      current = _copySnapshot(nextSnap, wifiOpen: targetWifiOpen);
    }
    if (!targetWifiOpen) {
      closeWifiCalls++;
    }
  }

  @override
  Future<void> syncTime() async {}

  @override
  Future<Map<String, dynamic>> invokeBridgeCommand(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    callLog.add(kind);
    final handler = onBridgeCommand;
    if (handler != null) {
      return handler(kind, payload);
    }
    switch (kind) {
      case 'dyj_led_hint':
        final mode = '${payload?['mode'] ?? ''}';
        if (mode.isNotEmpty) ledHintModes.add(mode);
        return {'applied': true, 'mode': mode};
      case 'dyj_tts_speak':
        if (failDyjTts != null) throw failDyjTts!;
        if (!dyjTtsSupported) {
          throw const CardException(
            CardErrorKind.device,
            'unsupported: 点一机固件（v0.8.15）暂不支持 tts.speak 语音播报',
          );
        }
        final text = '${payload?['text'] ?? ''}'.trim();
        if (text.isNotEmpty) dyjTtsSpokenTexts.add(text);
        return {'supported': true, 'spoken': true};
      case 'dyj_button_status':
        return {
          'buttons': const [],
          'bindings': {'record': 'event_only'},
        };
      case 'card_controls.get':
        cardControlsGetCalls++;
        return {
          'supported': true,
          ...cardControls,
        };
      case 'card_controls.set':
        final copy = Map<String, dynamic>.from(payload ?? const {});
        cardControlsSetCalls.add(copy);
        for (final key in const [
          'btnSingle',
          'btnDouble',
          'btnLongPress',
          'btnLongRelease',
          'switchOn',
          'switchOff',
        ]) {
          if (copy[key] is String) {
            cardControls[key] = (copy[key] as String).trim();
          }
        }
        return {
          'supported': true,
          'applied': true,
          'written': copy.length,
        };
      case 'card_display.show':
        final copy = Map<String, dynamic>.from(payload ?? const {});
        displayShowCalls.add(copy);
        return {'supported': true, 'shown': true};
      case 'card_display.clear':
        displayClearCalls++;
        return {'supported': true, 'cleared': true};
      case 'ap.start':
        return {'ip': '192.168.4.1', 'ssid': 'DYJ_AP_TEST', 'port': 80};
      case 'ap.stop':
        return {'stopped': true};
      case 'device.set_config':
        final k = '${payload?['key'] ?? ''}'.trim();
        final v = '${payload?['value'] ?? ''}'.trim();
        if (k.isNotEmpty) {
          deviceConfigs[k] = v;
        }
        return {'ok': true};
      case 'device.restart':
        restartCalls++;
        if (failRestart != null) throw failRestart!;
        return {'ok': true, 'action': 'restart'};
      case 'device.shutdown':
        shutdownCalls++;
        if (failShutdown != null) throw failShutdown!;
        return {'ok': true, 'action': 'shutdown'};
      case 'camera_capture_and_fetch':
        final bytes = fakeCapturedPhotoBytes;
        if (bytes != null) {
          final dirPath = '${payload?['dir'] ?? Directory.systemTemp.path}';
          final dir = Directory(dirPath);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          final path = '${dir.path}/CAP_TEST.JPG';
          await File(path).writeAsBytes(bytes, flush: true);
          return {
            'name': 'CAP_TEST.JPG',
            'localPath': path,
            'size': bytes.length,
          };
        }
    }
    throw UnimplementedError('FakeCardGateway.$kind not configured');
  }

  @override
  Stream<CardProgress> invokeBridgeStream(
    String kind, [
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ]) async* {
    callLog.add(kind);
    final handler = onBridgeStream;
    if (handler == null) {
      throw UnimplementedError('FakeCardGateway.$kind stream not configured');
    }
    yield* handler(kind, payload, onFinal);
  }

  @override
  Future<void> dispose() async {}
}
