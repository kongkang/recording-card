/// 录音硬件统一网关 —— 经 card_bridge（Rust FFI）把多款硬件 SDK 的能力解耦暴露给 App：
/// - 录音卡 V2（`reai-card-sdk` v0.0.6，`DYJV2_*`）
/// - 点一机 V1（`reai-dyj-sdk` v0.1.14，`DYJ_*`）
/// - 语音 AI 键盘 V2.1（`reai-board-sdk` v0.3.5，`REAI_VB_*`）
///
/// 分层：
/// - [RealCardGateway]  桥符号可用时走真实 BLE（引用计数式单例）。
/// - [UnsupportedCardGateway]  桥不可用（模拟器/未链接）时的显式失败实现：
///   所有调用抛 [CardException.unavailable]，界面据此呈现"需要连接录音卡"，
///   不再回退到预置假数据（正式版不能把演示数据当真实设备状态展示）。
///
/// 设计要点（照参考工程踩坑经验）：
/// - **所有命令串行**：SDK 要求设备命令严格串行，这里用一个 Future 链做闸门，
///   避免 UI 连点导致 list_files / status 交错发帧。
/// - **流式协议**：桥回多条消息，`final:true` 收尾；OTA 与实时流靠它推进度。
/// - **回调内存所有权**：桥交出的 JSON 指针须由 Dart 拷贝后调 free_string 释放。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 支持的硬件设备品类。
enum DeviceKind {
  cardV2('card_v2', '录音卡 V2'),
  dyjV1('dyj_v1', '点一机 V1'),
  boardV21('board_v21', '语音AI键盘 V2.1');

  const DeviceKind(this.code, this.displayModel);

  final String code;
  final String displayModel;

  /// 按蓝牙广播名前缀识别设备品类：
  /// 必须先判 `DYJV2_` 再判 `DYJ_`，避免把 V2 误判成点一机 V1。
  static DeviceKind? fromBleName(String name) {
    final trimmed = name.trim().toUpperCase();
    if (trimmed.startsWith('DYJV2_') || trimmed == 'DYJV2') {
      return DeviceKind.cardV2;
    }
    if (trimmed.startsWith('DYJ_') || trimmed.startsWith('DYJ')) {
      return DeviceKind.dyjV1;
    }
    if (trimmed.startsWith('REAI_VB_')) {
      return DeviceKind.boardV21;
    }
    return null;
  }

  /// 剥离已知代际广播前缀（`DYJV2_`、`REAI_VB_`、`DYJ_`），仅保留下划线后的蓝牙编号。
  /// 若剥离后为空或无已知前缀，则回退原名称（去除首尾空白）。
  static String bleShortId(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return trimmed;
    final upper = trimmed.toUpperCase();
    for (final prefix in const ['DYJV2_', 'REAI_VB_', 'DYJ_']) {
      if (upper.startsWith(prefix)) {
        final suffix = trimmed.substring(prefix.length).trim();
        return suffix.isNotEmpty ? suffix : trimmed;
      }
    }
    return trimmed;
  }

  static DeviceKind fromCode(String? raw, {String fallbackName = ''}) {
    switch (raw?.trim()) {
      case 'card_v2':
        return DeviceKind.cardV2;
      case 'dyj_v1':
        return DeviceKind.dyjV1;
      case 'board_v21':
        return DeviceKind.boardV21;
      default:
        return fromBleName(fallbackName) ?? DeviceKind.cardV2;
    }
  }
}

/// 硬件能力矩阵 —— UI 与状态机只按能力门控展示/调用，不写死型号分支。
@immutable
class HardwareCapabilities {
  const HardwareCapabilities({
    required this.realtimeAudio,
    required this.hasOnboardStorage,
    required this.hasFileSync,
    required this.hasWifiConfig,
    required this.hasCameraMedia,
    required this.hasPhysicalRecordToggle,
    required this.hasMarkButton,
    required this.otaMode,
  });

  final bool realtimeAudio;
  final bool hasOnboardStorage;
  final bool hasFileSync;
  final bool hasWifiConfig;
  final bool hasCameraMedia;
  final bool hasPhysicalRecordToggle;
  final bool hasMarkButton;
  final String otaMode; // 'dual_chip' | 'none'

  bool get hasDualChipOta => otaMode == 'dual_chip';

  static const cardV2 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: true,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasMarkButton: true,
    otaMode: 'dual_chip',
  );

  static const dyjV1 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: true,
    hasCameraMedia: true,
    hasPhysicalRecordToggle: true,
    hasMarkButton: false,
    otaMode: 'none',
  );

  static const boardV21 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: false,
    hasFileSync: false,
    hasWifiConfig: false,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasMarkButton: false,
    otaMode: 'none',
  );

  static HardwareCapabilities forKind(DeviceKind kind) => switch (kind) {
    DeviceKind.cardV2 => cardV2,
    DeviceKind.dyjV1 => dyjV1,
    DeviceKind.boardV21 => boardV21,
  };

  factory HardwareCapabilities.fromJson(
    Map<String, dynamic>? json, {
    DeviceKind fallbackKind = DeviceKind.cardV2,
  }) {
    final fallback = forKind(fallbackKind);
    if (json == null || json.isEmpty) return fallback;
    bool flag(String k, bool def) => json[k] is bool ? json[k] as bool : def;
    return HardwareCapabilities(
      realtimeAudio: flag('realtimeAudio', fallback.realtimeAudio),
      hasOnboardStorage: flag('hasOnboardStorage', fallback.hasOnboardStorage),
      hasFileSync: flag('hasFileSync', fallback.hasFileSync),
      hasWifiConfig: flag('hasWifiConfig', fallback.hasWifiConfig),
      hasCameraMedia: flag('hasCameraMedia', fallback.hasCameraMedia),
      hasPhysicalRecordToggle: flag(
        'hasPhysicalRecordToggle',
        fallback.hasPhysicalRecordToggle,
      ),
      hasMarkButton: flag('hasMarkButton', fallback.hasMarkButton),
      otaMode: (json['otaMode'] as String?) ?? fallback.otaMode,
    );
  }
}

/// 设备快照（battery/state/device_info/storage/record/capabilities 的 Dart 投影）
class CardSnapshot {
  const CardSnapshot({
    required this.batteryLevel,
    required this.isCharging,
    required this.wifiOpen,
    required this.recording,
    required this.fwVersion,
    required this.fwVersionCode,
    required this.wifiVersion,
    required this.wifiVersionCode,
    required this.deviceName,
    required this.deviceId,
    this.storageTotalMb,
    this.storageFreeMb,
    this.hasBattery = true,
    this.realtimeEnabled = false,
    this.recordSession,
    this.recordErrorCode,
    this.recordReason,
    this.deviceKind = DeviceKind.cardV2,
    this.displayModel,
    this.capabilities,
  });

  factory CardSnapshot.fromJson(Map<String, dynamic> json) {
    final battery = _map(json['battery']);
    final state = _map(json['state']);
    final info = _map(json['info']);
    final storage = _map(json['storage']);
    final recordStatus = json['record'] is Map<String, dynamic>
        ? json['record'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final hasBattery = battery['level'] is num;
    final storageTotal = _int(storage['total']);
    final storageUsed = _int(storage['used']);
    final devName = (info['deviceName'] as String?) ?? '';
    final kind = DeviceKind.fromCode(
      json['deviceKind'] as String?,
      fallbackName: devName,
    );
    final capsMap = json['capabilities'] is Map<String, dynamic>
        ? json['capabilities'] as Map<String, dynamic>
        : null;
    return CardSnapshot(
      batteryLevel: hasBattery ? _int(battery['level']) : 0,
      hasBattery: hasBattery,
      isCharging: battery['isCharging'] == true,
      wifiOpen: state['wifiOpen'] == true,
      recording: recordStatus['isRecording'] == true,
      realtimeEnabled: recordStatus['realtimeEnabled'] == true,
      recordSession: recordStatus['session'] as String?,
      recordErrorCode: (recordStatus['error'] as num?)?.toInt(),
      recordReason: recordStatus['reason']?.toString(),
      fwVersion: (info['version'] as String?) ?? '',
      fwVersionCode: _int(info['versionCode']),
      wifiVersion: (info['wifiVersion'] as String?) ?? '',
      wifiVersionCode: _int(info['wifiVersionCode']),
      deviceName: devName,
      deviceId: (info['deviceId'] as String?) ?? '',
      storageTotalMb: storage.isEmpty ? null : storageTotal,
      storageFreeMb: storage.isEmpty
          ? null
          : (storageTotal - storageUsed < 0 ? 0 : storageTotal - storageUsed),
      deviceKind: kind,
      displayModel: (json['displayModel'] as String?) ?? kind.displayModel,
      capabilities: HardwareCapabilities.fromJson(capsMap, fallbackKind: kind),
    );
  }

  final int batteryLevel;
  final bool isCharging;
  final bool wifiOpen;
  final bool recording;
  final String fwVersion;
  final int fwVersionCode;
  final String wifiVersion;
  final int wifiVersionCode;
  final String deviceName;
  final String deviceId;
  final int? storageTotalMb;
  final int? storageFreeMb;

  /// 本次快照是否真的读到了电量（false = level 字段缺失，界面按「未知」展示）。
  final bool hasBattery;

  /// 设备端实时流开关是否打开（**不是**"正在录音"，两者独立）。
  final bool realtimeEnabled;

  /// 本次录音的会话编号（主控 0.3.8 起设备回传；旧固件为 null）。
  final String? recordSession;

  /// 录音出错时固件回的错误码（此时 recording 为 false）。
  final int? recordErrorCode;

  /// 这次录音状态变化的来源：button / switch / app / auto …
  final String? recordReason;

  final DeviceKind deviceKind;
  final String? displayModel;
  final HardwareCapabilities? capabilities;

  DeviceKind get effectiveKind =>
      (capabilities == null &&
          displayModel == null &&
          deviceKind == DeviceKind.cardV2)
      ? (DeviceKind.fromBleName(deviceName) ?? deviceKind)
      : deviceKind;

  HardwareCapabilities get resolvedCapabilities =>
      capabilities ?? HardwareCapabilities.forKind(effectiveKind);

  String get modelLabel => displayModel ?? effectiveKind.displayModel;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}

/// 扫描到的硬件设备：`id` 用于 connect，`name` 是蓝牙广播名。
class CardDevice {
  const CardDevice({
    required this.id,
    required this.name,
    this.rssi,
    this.kind,
    this.displayModel,
    this.capabilities,
  });

  final String id;
  final String name;
  final int? rssi;
  final DeviceKind? kind;
  final String? displayModel;
  final HardwareCapabilities? capabilities;

  DeviceKind get deviceKind =>
      kind ?? DeviceKind.fromBleName(name) ?? DeviceKind.cardV2;

  String get shortName => DeviceKind.bleShortId(name);

  String get modelLabel => displayModel ?? deviceKind.displayModel;

  HardwareCapabilities get resolvedCapabilities =>
      capabilities ?? HardwareCapabilities.forKind(deviceKind);
}

/// 点一机 V1 硬件抓拍照片同步结果。
class CameraSyncItem {
  const CameraSyncItem({
    required this.name,
    required this.path,
    required this.bytesWritten,
    this.capturedAtSec,
    this.source = 'dyj_camera',
  });

  factory CameraSyncItem.fromJson(Map<String, dynamic> json) => CameraSyncItem(
    name: (json['name'] as String?) ?? '',
    path: (json['path'] as String?) ?? '',
    bytesWritten: (json['bytesWritten'] as num?)?.toInt() ?? 0,
    capturedAtSec: (json['capturedAt'] as num?)?.toInt(),
    source: (json['source'] as String?) ?? 'dyj_camera',
  );

  final String name;
  final String path;
  final int bytesWritten;
  final int? capturedAtSec;
  final String source;
}

/// 断连结果：桥如实报告这次是否真的释放了 BLE 链路。
class CardDisconnectReport {
  const CardDisconnectReport({
    required this.released,
    this.hadDevice = false,
    this.detail,
  });

  final bool released;
  final bool hadDevice;
  final String? detail;

  factory CardDisconnectReport.fromJson(Map<String, dynamic> json) {
    final released = json['released'];
    final sdk = json['sdk'];
    return CardDisconnectReport(
      released: released is bool ? released : true,
      hadDevice: json['hadDevice'] == true,
      detail: sdk?.toString(),
    );
  }

  static const alreadyReleased = CardDisconnectReport(released: true);
}

/// 设备上的录音文件（支持录音卡 V2 `.APM` 与点一机 V1 `.amr`）。
class CardFile {
  const CardFile({
    required this.name,
    required this.size,
    this.index,
    this.createdAtSec,
    this.session,
    this.seq,
    this.startAtSec,
    this.synced,
  });

  factory CardFile.fromJson(Map<String, dynamic> json) => CardFile(
    name: (json['name'] as String?) ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    index: _intOrNull(json['index']),
    createdAtSec: _intOrNull(json['created_at'] ?? json['createdAt']),
    session: _stringOrNull(json['session']),
    seq: _intOrNull(json['seq']),
    startAtSec: _intOrNull(json['start_at'] ?? json['startAt']),
    synced: json['synced'] is bool ? json['synced'] as bool : null,
  );

  final String name;
  final int size;
  final int? index;
  final int? createdAtSec;
  final String? session;
  final int? seq;
  final int? startAtSec;
  final bool? synced;

  bool get isApm => name.toUpperCase().endsWith('.APM');

  bool get isAmr => name.toUpperCase().endsWith('.AMR');

  /// 兼容 `.APM`（录音卡 V2）与 `.AMR`（点一机 V1）。
  bool get isAudioRecording => isApm || isAmr;

  bool get isTxt => name.toUpperCase().endsWith('.TXT');

  DateTime? get startTime => startAtSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(startAtSec! * 1000);

  DateTime? get fileModifiedTime => createdAtSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(createdAtSec! * 1000);

  static int? _intOrNull(Object? value) =>
      value is num ? value.toInt() : null;

  static String? _stringOrNull(Object? value) {
    if (value is! String) return null;
    final v = value.trim();
    return v.isEmpty ? null : v;
  }
}

/// 下载结果。
class CardDownload {
  const CardDownload({
    required this.path,
    required this.bytesWritten,
    required this.originalName,
  });
  factory CardDownload.fromJson(Map<String, dynamic> json) => CardDownload(
    path: (json['path'] as String?) ?? '',
    bytesWritten: (json['bytesWritten'] as num?)?.toInt() ?? 0,
    originalName: (json['originalName'] as String?) ?? '',
  );
  final String path;
  final int bytesWritten;
  final String originalName;
}

/// 设备扫描到的 Wi-Fi 网络。
class CardWifiNetwork {
  const CardWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secured,
  });
  factory CardWifiNetwork.fromJson(Map<String, dynamic> json) {
    final rawEnc = (json['encryption'] as String?)?.trim().toLowerCase();
    final encSecured =
        rawEnc != null && rawEnc.isNotEmpty && rawEnc != 'open' && rawEnc != 'none';
    return CardWifiNetwork(
      ssid: (json['ssid'] as String?) ?? (json['name'] as String?) ?? '',
      rssi: (json['rssi'] as num?)?.toInt() ?? -100,
      secured:
          json['secured'] == true ||
          json['secure'] == true ||
          json['lock'] == true ||
          encSecured,
    );
  }
  final String ssid;
  final int rssi;
  final bool secured;
}

/// 设备端已保存的 Wi-Fi 凭据。
class CardWifiCredential {
  const CardWifiCredential({required this.ssid});
  factory CardWifiCredential.fromJson(Map<String, dynamic> json) =>
      CardWifiCredential(
        ssid: (json['ssid'] as String?) ?? (json['name'] as String?) ?? '',
      );
  final String ssid;
}

/// 同步上传状态。
class CardSyncStatus {
  const CardSyncStatus({
    required this.pending,
    required this.uploaded,
    required this.running,
    this.message,
  });
  factory CardSyncStatus.fromJson(Map<String, dynamic> json) => CardSyncStatus(
    pending: (json['pending'] as num?)?.toInt() ?? 0,
    uploaded: (json['uploaded'] as num?)?.toInt() ?? 0,
    running: json['running'] == true || json['state'] == 'running',
    message: json['message'] as String?,
  );
  final int pending;
  final int uploaded;
  final bool running;
  final String? message;
}

/// 服务器上的固件信息。
class CardOtaInfo {
  const CardOtaInfo({
    required this.version,
    required this.versionCode,
    required this.url,
  });
  factory CardOtaInfo.fromJson(Map<String, dynamic> json) => CardOtaInfo(
    version: (json['version'] as String?) ?? '',
    versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
    url: (json['url'] as String?) ?? '',
  );
  final String version;
  final int versionCode;
  final String url;

  bool isNewerThan(int installedVersionCode) =>
      installedVersionCode > 0 && versionCode > installedVersionCode;
}

/// 长任务进度（OTA 等）。
class CardProgress {
  const CardProgress({
    required this.stage,
    required this.percent,
    required this.text,
    this.version,
    this.sent,
    this.total,
  });
  factory CardProgress.fromJson(Map<String, dynamic> json) => CardProgress(
    stage: (json['stage'] as String?) ?? '',
    percent: (json['percent'] as num?)?.toInt() ?? 0,
    text: (json['text'] as String?) ?? '',
    version: json['version'] as String?,
    sent: (json['sent'] as num?)?.toInt(),
    total: (json['total'] as num?)?.toInt(),
  );
  final String stage;
  final int percent;
  final String text;
  final String? version;
  final int? sent;
  final int? total;
}

/// 实时音频流的一个事件：16kHz 16bit 单声道 PCM 数据块，或一次"断档"标记。
class RealtimeAudioEvent {
  const RealtimeAudioEvent({
    required this.kind,
    this.pcm,
    this.sampleRate = 16000,
    this.receivedSamples = 0,
    this.gapIndex = 0,
  });

  final RealtimeAudioKind kind;
  final Uint8List? pcm;
  final int sampleRate;
  final int receivedSamples;
  final int gapIndex;
}

enum RealtimeAudioKind { open, audio, gap, closed }

/// 一次事件拉取的结果：序号 + 自上次以来新到的事件（零蓝牙流量，读内存队列）。
class DeviceEventBatch {
  const DeviceEventBatch({required this.seq, required this.events});
  const DeviceEventBatch.empty(this.seq) : events = const [];

  final int seq;
  final List<Map<String, dynamic>> events;

  /// 录音状态变化（设备侧拨杆/按键触发）。
  Iterable<Map<String, dynamic>> get recordEvents =>
      events.where((e) => e['event']?['kind'] == 'record');

  /// 电源/充电/电量主动上报（解决充饱电或插拔电源不刷新的问题）。
  Iterable<Map<String, dynamic>> get powerEvents =>
      events.where((e) => e['event']?['kind'] == 'power');

  /// 语音 AI 键盘物理语音键按下事件。
  Iterable<Map<String, dynamic>> get voiceKeyEvents =>
      events.where((e) => e['event']?['kind'] == 'voice_key');

  /// 点一机 V1 硬件按键拍照事件。
  Iterable<Map<String, dynamic>> get cameraEvents =>
      events.where((e) => e['event']?['kind'] == 'camera');

  /// 蓝牙链路被动断开通知。
  Iterable<Map<String, dynamic>> get disconnectedEvents =>
      events.where((e) => e['event']?['kind'] == 'disconnected');
}

/// 长任务终态。
class CardOtaResult {
  const CardOtaResult({
    required this.module,
    required this.upToDate,
    this.version,
  });
  factory CardOtaResult.fromJson(Map<String, dynamic> json) => CardOtaResult(
    module: (json['module'] as String?) ?? '',
    upToDate: json['upToDate'] == true,
    version: json['version'] as String?,
  );
  final String module;
  final bool upToDate;
  final String? version;
}

/// 转码结果（设备 `.apm` / `.amr` → 16kHz 单声道 WAV）。
class CardAudio {
  const CardAudio({
    required this.path,
    required this.samples,
    required this.durationSecs,
  });
  factory CardAudio.fromJson(Map<String, dynamic> json) => CardAudio(
    path: (json['path'] as String?) ?? '',
    samples: (json['samples'] as num?)?.toInt() ?? 0,
    durationSecs: (json['durationSecs'] as num?)?.toDouble() ?? 0,
  );
  final String path;
  final int samples;
  final double durationSecs;
}

/// 网关错误的分类。
enum CardErrorKind {
  unavailable,
  disconnected,
  device,
  timeout,
  unknown,
}

class CardException implements Exception {
  const CardException(this.kind, this.message);
  final CardErrorKind kind;
  final String message;

  CardException.unavailable([String? message])
    : this(CardErrorKind.unavailable, message ?? '此设备不支持连接录音卡');
  CardException.disconnected([String? message])
    : this(CardErrorKind.disconnected, message ?? '录音卡未连接');
  CardException.timeout([String? message])
    : this(CardErrorKind.timeout, message ?? '操作超时，请重试');

  @override
  String toString() => 'CardException($kind): $message';
}

abstract class CardGateway {
  bool get available;

  Future<List<CardDevice>> scan({int timeoutMs = 6000});

  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  });

  Future<CardDisconnectReport> disconnect();
  Future<CardSnapshot> snapshot();

  Future<void> record(String action); // start | stop | toggle
  Future<void> startRecording({int? durationSecs});
  Future<void> stopRecording();

  Stream<RealtimeAudioEvent> realtimeAudio();
  Future<void> closeRealtime();

  Future<DeviceEventBatch> pullEvents({int after = 0});
  Future<void> mark();

  Future<List<CardFile>> files();
  Future<CardDownload> download(String name, String dir);
  Future<CardDownload> takeOldestFile(String dir);
  Future<void> deleteFile(String name);

  /// 把设备落地文件（`.apm` / `.amr`）转成 WAV（16kHz/16bit 单声道）。
  Future<CardAudio> transcode(String apmPath, String wavPath);

  /// 点一机 V1 抓拍照片同步到本地目录（非相机设备安全返回空列表）。
  Future<List<CameraSyncItem>> syncCameraPhotos(
    String dir, {
    String? serverOrigin,
  });

  Future<List<CardWifiNetwork>> scanWifi();
  Future<void> connectWifi(String ssid, String password);
  Future<void> openWifi();
  Future<void> closeWifi();
  Future<List<CardWifiCredential>> wifiCredentials({bool passive = false});
  Future<void> forgetWifi(String ssid);

  Future<void> startSync();
  Future<CardSyncStatus> syncStatus();
  Future<void> setUploadUrl(String url);

  Future<CardOtaInfo> otaInfo(String module); // main | wifi
  Stream<CardProgress> otaMain();
  Stream<CardProgress> otaWifi({bool? restoreWifiOpen});

  Future<void> syncTime();

  Future<void> dispose();
}

// ── C ABI 镜像 ──────────────────────────────────────────────

typedef _CbNative = ffi.Void Function(ffi.UintPtr, ffi.Pointer<Utf8>);
typedef _CommandNative =
    ffi.Void Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      ffi.UintPtr,
    );
typedef _CommandDart =
    void Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      int,
    );
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);
typedef _VersionNative = ffi.Pointer<Utf8> Function();
typedef _VersionDart = ffi.Pointer<Utf8> Function();

/// FFI 真实网关。
class RealCardGateway implements CardGateway {
  RealCardGateway._(ffi.DynamicLibrary lib)
    : _command = lib
          .lookup<ffi.NativeFunction<_CommandNative>>('card_bridge_command')
          .asFunction(),
      _free = lib
          .lookup<ffi.NativeFunction<_FreeNative>>('card_bridge_free_string')
          .asFunction(),
      _version = lib
          .lookup<ffi.NativeFunction<_VersionNative>>('card_bridge_version')
          .asFunction() {
    _callable = ffi.NativeCallable<_CbNative>.listener(_onEvent);
  }

  static RealCardGateway? _instance;

  static RealCardGateway? maybe() {
    if (_instance != null) return _instance;
    ffi.DynamicLibrary lib;
    try {
      lib = ffi.DynamicLibrary.process();
    } catch (_) {
      try {
        lib = ffi.DynamicLibrary.open('libcard_bridge.dylib');
      } catch (_) {
        return null;
      }
    }
    try {
      _instance = RealCardGateway._(lib);
      return _instance;
    } catch (_) {
      return null;
    }
  }

  final _CommandDart _command;
  final _FreeDart _free;
  final _VersionDart _version;
  late final ffi.NativeCallable<_CbNative> _callable;

  final Map<int, StreamController<Map<String, dynamic>>> _pending = {};
  int _ticket = 0;

  Future<void> _queue = Future<void>.value();

  @override
  bool get available => true;

  String get bridgeVersion {
    final ptr = _version();
    if (ptr == ffi.nullptr) return '';
    return ptr.toDartString();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _queue;
    _queue = () async {
      await previous;
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }();
    return completer.future;
  }

  Stream<Map<String, dynamic>> _open(
    String kind, [
    Map<String, dynamic>? payload,
    Duration? timeout,
  ]) {
    final ticket = ++_ticket;
    final controller = StreamController<Map<String, dynamic>>();
    _pending[ticket] = controller;

    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        final c = _pending.remove(ticket);
        if (c != null && !c.isClosed) {
          c.addError(CardException.timeout('$kind 超时（${timeout.inSeconds}s）'));
          c.close();
        }
      });
    }
    controller.onCancel = () {
      timer?.cancel();
      _pending.remove(ticket);
    };

    final kindPtr = kind.toNativeUtf8();
    final payloadPtr = (payload == null || payload.isEmpty)
        ? ffi.nullptr
        : jsonEncode(payload).toNativeUtf8();
    try {
      _command(kindPtr, payloadPtr, _callable.nativeFunction, ticket);
    } catch (e) {
      _pending.remove(ticket);
      timer?.cancel();
      controller
        ..addError(CardException(CardErrorKind.unknown, '调用桥失败：$e'))
        ..close();
    } finally {
      malloc.free(kindPtr);
      if (payloadPtr != ffi.nullptr) malloc.free(payloadPtr);
    }

    return controller.stream.transform(
      StreamTransformer<
        Map<String, dynamic>,
        Map<String, dynamic>
      >.fromHandlers(
        handleDone: (sink) {
          timer?.cancel();
          sink.close();
        },
      ),
    );
  }

  Future<Map<String, dynamic>> _once(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 20),
  ]) {
    return _serial(() async {
      final json = await _open(kind, payload, timeout).first;
      if (json['ok'] != true) {
        throw _error(kind, json['error']?.toString());
      }
      return json;
    });
  }

  Stream<CardProgress> _progress(
    String kind,
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ) async* {
    final controller = StreamController<Map<String, dynamic>>();
    final ticket = ++_ticket;
    _pending[ticket] = controller;

    final kindPtr = kind.toNativeUtf8();
    final payloadPtr = (payload == null || payload.isEmpty)
        ? ffi.nullptr
        : jsonEncode(payload).toNativeUtf8();
    try {
      _command(kindPtr, payloadPtr, _callable.nativeFunction, ticket);
    } finally {
      malloc.free(kindPtr);
      if (payloadPtr != ffi.nullptr) malloc.free(payloadPtr);
    }

    await for (final json in controller.stream) {
      if (json['ok'] != true) {
        throw _error(kind, json['error']?.toString());
      }
      if (json['final'] == true) {
        onFinal?.call((json['data'] as Map<String, dynamic>?) ?? const {});
        return;
      }
      final p = json['progress'];
      if (p is Map<String, dynamic>) yield CardProgress.fromJson(p);
    }
  }

  CardException _error(String kind, String? message) {
    var text = message ?? '未知错误';
    final lower = text.toLowerCase();
    if (lower.contains('disconnect') || text.contains('未连接')) {
      return CardException.disconnected(text);
    }
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        text.contains('超时')) {
      return CardException.timeout();
    }
    final wrapped = RegExp(
      r'^invalid command `(.*)`$',
      dotAll: true,
    ).firstMatch(text);
    if (wrapped != null) text = wrapped.group(1)!;
    return CardException(CardErrorKind.device, _friendlyDeviceError(text));
  }

  static String _friendlyDeviceError(String raw) {
    final match = RegExp(r'code[:\s]*(-?\d+)').firstMatch(raw);
    final code = match == null ? null : int.tryParse(match.group(1)!);
    if (code == null) return raw;
    final suffix = '（设备错误码 $code）';
    return switch (code) {
      -1 => '录音卡拒绝了这条命令，请重连后重试$suffix',
      -2 => '录音卡拒绝了这条命令$suffix',
      -3 => '录音卡当前状态不允许该操作，请稍后重试$suffix',
      _ => '录音卡返回错误$suffix',
    };
  }

  static Map<String, dynamic>? lastDeviceErrorDetail;

  void _onEvent(int ticket, ffi.Pointer<Utf8> json) {
    StreamController<Map<String, dynamic>>? controller;
    try {
      final text = json.toDartString();
      controller = _pending[ticket];
      if (controller == null) return;
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final detail = decoded['detail'];
      if (detail is Map<String, dynamic>) {
        lastDeviceErrorDetail = detail;
        debugPrint('[card] 设备错误详情：$detail');
      }
      if (!controller.isClosed) controller.add(decoded);
      if (decoded['final'] == true) {
        _pending.remove(ticket);
        if (!controller.isClosed) controller.close();
      }
    } catch (e) {
      if (controller != null && !controller.isClosed) {
        controller.addError(CardException(CardErrorKind.unknown, '桥回包解析失败：$e'));
        _pending.remove(ticket);
        controller.close();
      }
    } finally {
      _free(json);
    }
  }

  // ── 具体能力 ──

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async {
    final json = await _once('scan', {
      'timeoutMs': timeoutMs,
    }, Duration(milliseconds: timeoutMs + 30000));
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map((d) {
          final name = (d['name'] as String?) ?? '录音卡';
          final kind = DeviceKind.fromCode(
            d['deviceKind'] as String?,
            fallbackName: name,
          );
          final capsMap = d['capabilities'] is Map<String, dynamic>
              ? d['capabilities'] as Map<String, dynamic>
              : null;
          return CardDevice(
            id: (d['id'] as String?) ?? '',
            name: name,
            rssi: (d['rssi'] as num?)?.toInt(),
            kind: kind,
            displayModel: (d['displayModel'] as String?) ?? kind.displayModel,
            capabilities: HardwareCapabilities.fromJson(
              capsMap,
              fallbackKind: kind,
            ),
          );
        })
        .where((d) => d.id.isNotEmpty)
        .toList();
  }

  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) async {
    final json = await _once(
      'connect',
      {
        'id': deviceId,
        if (name != null && name.isNotEmpty) 'name': name,
        if (deviceKind != null && deviceKind.isNotEmpty)
          'deviceKind': deviceKind,
      },
      const Duration(seconds: 35),
    );
    final data = json['data'];
    if (data is Map<String, dynamic> &&
        data['snapshot'] is Map<String, dynamic>) {
      return CardSnapshot.fromJson(data['snapshot'] as Map<String, dynamic>);
    }
    return await snapshot();
  }

  @override
  Future<CardDisconnectReport> disconnect() async {
    final json = await _once('disconnect');
    final data = json['data'];
    return CardDisconnectReport.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  @override
  Future<CardSnapshot> snapshot() async {
    final json = await _once('snapshot');
    return CardSnapshot.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> record(String action) => _once('record', {'action': action});

  @override
  Future<void> startRecording({int? durationSecs}) => _once(
    'record.start',
    durationSecs != null && durationSecs > 0
        ? {'durationSecs': durationSecs}
        : null,
  );

  @override
  Future<void> stopRecording() async {
    try {
      await _once('record.stop');
    } on CardException catch (e) {
      if (e.message.contains('没有录音')) return;
      rethrow;
    }
  }

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    final controller = StreamController<RealtimeAudioEvent>();
    final ticket = ++_ticket;
    _pending[ticket] = StreamController<Map<String, dynamic>>();

    void emit(Map<String, dynamic> json) {
      final progress = json['progress'];
      if (progress is! Map<String, dynamic>) {
        if (json['final'] == true) {
          controller.add(
            const RealtimeAudioEvent(kind: RealtimeAudioKind.closed),
          );
        }
        return;
      }
      final state = progress['state']?.toString();
      final received = (progress['receivedSamples'] as num?)?.toInt() ?? 0;
      if (state == 'audio') {
        final b64 = progress['pcm']?.toString() ?? '';
        controller.add(
          RealtimeAudioEvent(
            kind: RealtimeAudioKind.audio,
            pcm: base64Decode(b64),
            sampleRate: (progress['sampleRate'] as num?)?.toInt() ?? 16000,
            receivedSamples: received,
          ),
        );
      } else if (state == 'gap') {
        controller.add(
          RealtimeAudioEvent(
            kind: RealtimeAudioKind.gap,
            receivedSamples: received,
            gapIndex: (progress['gapIndex'] as num?)?.toInt() ?? 0,
          ),
        );
      } else if (state == 'open') {
        controller.add(
          const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
        );
      }
    }

    final inner = _pending[ticket]!;
    inner.stream.listen(
      emit,
      onError: (Object e) {
        if (!controller.isClosed) controller.addError(e);
      },
      onDone: () {
        _pending.remove(ticket);
        if (!controller.isClosed) controller.close();
      },
    );

    final kindPtr = 'realtime.open'.toNativeUtf8();
    try {
      _command(kindPtr, ffi.nullptr, _callable.nativeFunction, ticket);
    } finally {
      malloc.free(kindPtr);
    }
    return controller.stream;
  }

  @override
  Future<void> closeRealtime() async {
    try {
      await _once('realtime.close', const {}, const Duration(seconds: 10));
    } on CardException {
      // 收尾失败不影响录音本身
    }
  }

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) async {
    final json = await _once(
      'events.pull',
      {'after': after},
      const Duration(seconds: 5),
    );
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    final events = [
      for (final item in (data['events'] as List<dynamic>? ?? const []))
        if (item is Map<String, dynamic>) item,
    ];
    return DeviceEventBatch(
      seq: (data['seq'] as num?)?.toInt() ?? after,
      events: events,
    );
  }

  @override
  Future<void> mark() => _once('mark');

  @override
  Future<List<CardFile>> files() async {
    final json = await _once('files', null, const Duration(seconds: 40));
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CardFile.fromJson)
        .toList();
  }

  @override
  Future<CardDownload> download(String name, String dir) async {
    final json = await _once('download', {
      'name': name,
      'dir': dir,
    }, const Duration(minutes: 10));
    return CardDownload.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<CardDownload> takeOldestFile(String dir) async {
    final json = await _once('file.takeOldest', {
      'dir': dir,
    }, const Duration(minutes: 10));
    return CardDownload.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> deleteFile(String name) => _once('deleteFile', {'name': name});

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async {
    final json = await _once('transcode', {
      'apm': apmPath,
      'wav': wavPath,
    }, const Duration(minutes: 2));
    return CardAudio.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<List<CameraSyncItem>> syncCameraPhotos(
    String dir, {
    String? serverOrigin,
  }) async {
    final json = await _once(
      'camera.sync',
      {
        'dir': dir,
        if (serverOrigin != null && serverOrigin.isNotEmpty)
          'serverOrigin': serverOrigin,
      },
      const Duration(minutes: 3),
    );
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CameraSyncItem.fromJson)
        .where((p) => p.path.isNotEmpty)
        .toList();
  }

  @override
  Future<List<CardWifiNetwork>> scanWifi() async {
    final json = await _once('wifi.scan', null, const Duration(seconds: 40));
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CardWifiNetwork.fromJson)
        .toList();
  }

  @override
  Future<void> connectWifi(String ssid, String password) => _once(
    'wifi.connect',
    {'ssid': ssid, 'password': password},
    const Duration(seconds: 40),
  );

  @override
  Future<void> openWifi() =>
      _once('wifi.open', null, const Duration(seconds: 45));

  @override
  Future<void> closeWifi() => _once('wifi.close');

  @override
  Future<List<CardWifiCredential>> wifiCredentials({bool passive = false}) async {
    final json = await _once(
      'wifi.credentials',
      passive ? {'passive': true} : null,
    );
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CardWifiCredential.fromJson)
        .toList();
  }

  @override
  Future<void> forgetWifi(String ssid) => _once('wifi.forget', {'ssid': ssid});

  @override
  Future<void> startSync() => _once('sync.start');

  @override
  Future<CardSyncStatus> syncStatus() async {
    final json = await _once('sync.status');
    return CardSyncStatus.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> setUploadUrl(String url) => _once('upload.setUrl', {'url': url});

  @override
  Future<CardOtaInfo> otaInfo(String module) async {
    final json = await _once('ota.info', {
      'mod': module,
    }, const Duration(seconds: 30));
    return CardOtaInfo.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Stream<CardProgress> otaMain() => _progress('ota.main', null, null);

  @override
  Stream<CardProgress> otaWifi({bool? restoreWifiOpen}) => _progress(
    'ota.wifi',
    restoreWifiOpen == null ? null : {'restoreWifiOpen': restoreWifiOpen},
    null,
  );

  @override
  Future<void> syncTime() => _once('time.sync');

  @override
  Future<void> dispose() async {
    for (final c in _pending.values) {
      if (!c.isClosed) await c.close();
    }
    _pending.clear();
  }
}

/// 桥不可用时的实现：所有能力显式失败，绝不返回假数据。
class UnsupportedCardGateway implements CardGateway {
  const UnsupportedCardGateway();

  @override
  bool get available => false;

  Never _fail() => throw CardException.unavailable();

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async => _fail();
  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) async => _fail();
  @override
  Future<CardDisconnectReport> disconnect() async => _fail();
  @override
  Future<CardSnapshot> snapshot() async => _fail();
  @override
  Future<void> record(String action) async => _fail();
  @override
  Future<void> startRecording({int? durationSecs}) async => _fail();
  @override
  Future<void> stopRecording() async => _fail();
  @override
  Stream<RealtimeAudioEvent> realtimeAudio() =>
      Stream<RealtimeAudioEvent>.error(CardException.unavailable());
  @override
  Future<void> closeRealtime() async {}
  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) async =>
      DeviceEventBatch.empty(after);
  @override
  Future<void> mark() async => _fail();
  @override
  Future<List<CardFile>> files() async => _fail();
  @override
  Future<CardDownload> download(String name, String dir) async => _fail();
  @override
  Future<CardDownload> takeOldestFile(String dir) async => _fail();
  @override
  Future<void> deleteFile(String name) async => _fail();
  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async => _fail();
  @override
  Future<List<CameraSyncItem>> syncCameraPhotos(
    String dir, {
    String? serverOrigin,
  }) async => _fail();
  @override
  Future<List<CardWifiNetwork>> scanWifi() async => _fail();
  @override
  Future<void> connectWifi(String ssid, String password) async => _fail();
  @override
  Future<void> openWifi() async => _fail();
  @override
  Future<void> closeWifi() async => _fail();
  @override
  Future<List<CardWifiCredential>> wifiCredentials({bool passive = false}) async =>
      _fail();
  @override
  Future<void> forgetWifi(String ssid) async => _fail();
  @override
  Future<void> startSync() async => _fail();
  @override
  Future<CardSyncStatus> syncStatus() async => _fail();
  @override
  Future<void> setUploadUrl(String url) async => _fail();
  @override
  Future<CardOtaInfo> otaInfo(String module) async => _fail();
  @override
  Stream<CardProgress> otaMain() => Stream.error(CardException.unavailable());
  @override
  Stream<CardProgress> otaWifi({bool? restoreWifiOpen}) =>
      Stream.error(CardException.unavailable());
  @override
  Future<void> syncTime() async => _fail();
  @override
  Future<void> dispose() async {}
}

CardGateway realOrUnsupported() =>
    RealCardGateway.maybe() ?? const UnsupportedCardGateway();

/// 命令转发网关：每条 BLE 命令"发出"和"返回"都回调一次 [onActivity]。
class ActivityGateway implements CardGateway {
  ActivityGateway(this._inner, this.onActivity);

  final CardGateway _inner;
  final void Function() onActivity;

  Future<T> _run<T>(Future<T> Function() action) async {
    onActivity();
    try {
      return await action();
    } finally {
      onActivity();
    }
  }

  Stream<T> _pipe<T>(Stream<T> source) async* {
    onActivity();
    try {
      yield* source;
    } finally {
      onActivity();
    }
  }

  @override
  bool get available => _inner.available;

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) =>
      _run(() => _inner.scan(timeoutMs: timeoutMs));

  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) => _run(
    () => _inner.connect(deviceId, name: name, deviceKind: deviceKind),
  );

  @override
  Future<CardDisconnectReport> disconnect() => _run(_inner.disconnect);

  @override
  Future<CardSnapshot> snapshot() => _run(_inner.snapshot);

  @override
  Future<void> record(String action) => _run(() => _inner.record(action));

  @override
  Future<void> startRecording({int? durationSecs}) =>
      _run(() => _inner.startRecording(durationSecs: durationSecs));

  @override
  Future<void> stopRecording() => _run(_inner.stopRecording);

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    onActivity();
    return _inner.realtimeAudio();
  }

  @override
  Future<void> closeRealtime() => _run(_inner.closeRealtime);

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) =>
      _inner.pullEvents(after: after);

  @override
  Future<void> mark() => _run(_inner.mark);

  @override
  Future<List<CardFile>> files() => _run(_inner.files);

  @override
  Future<CardDownload> download(String name, String dir) =>
      _run(() => _inner.download(name, dir));

  @override
  Future<CardDownload> takeOldestFile(String dir) =>
      _run(() => _inner.takeOldestFile(dir));

  @override
  Future<void> deleteFile(String name) => _run(() => _inner.deleteFile(name));

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) =>
      _run(() => _inner.transcode(apmPath, wavPath));

  @override
  Future<List<CameraSyncItem>> syncCameraPhotos(
    String dir, {
    String? serverOrigin,
  }) => _run(() => _inner.syncCameraPhotos(dir, serverOrigin: serverOrigin));

  @override
  Future<List<CardWifiNetwork>> scanWifi() => _run(_inner.scanWifi);

  @override
  Future<void> connectWifi(String ssid, String password) =>
      _run(() => _inner.connectWifi(ssid, password));

  @override
  Future<void> openWifi() => _run(_inner.openWifi);

  @override
  Future<void> closeWifi() => _run(_inner.closeWifi);

  @override
  Future<List<CardWifiCredential>> wifiCredentials({bool passive = false}) =>
      _run(() => _inner.wifiCredentials(passive: passive));

  @override
  Future<void> forgetWifi(String ssid) => _run(() => _inner.forgetWifi(ssid));

  @override
  Future<void> startSync() => _run(_inner.startSync);

  @override
  Future<CardSyncStatus> syncStatus() => _run(_inner.syncStatus);

  @override
  Future<void> setUploadUrl(String url) => _run(() => _inner.setUploadUrl(url));

  @override
  Future<CardOtaInfo> otaInfo(String module) =>
      _run(() => _inner.otaInfo(module));

  @override
  Stream<CardProgress> otaMain() => _pipe(_inner.otaMain());

  @override
  Stream<CardProgress> otaWifi({bool? restoreWifiOpen}) =>
      _pipe(_inner.otaWifi(restoreWifiOpen: restoreWifiOpen));

  @override
  Future<void> syncTime() => _run(_inner.syncTime);

  @override
  Future<void> dispose() => _inner.dispose();
}
