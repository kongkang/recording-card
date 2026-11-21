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
import 'dart:io' show File, Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 支持的硬件设备品类。
enum DeviceKind {
  cardV2('card_v2', '录音卡 V2'),
  dyjV1('dyj_v1', '点一机 V1'),
  boardV21('board_v21', '语音AI键盘 V2.1'),
  omiCv1('omi_cv1', 'Omi 录音器'),
  feishuD3200('feishu_d3200', '飞书录音豆'),
  appleWatch('apple_watch', 'Apple Watch');

  const DeviceKind(this.code, this.displayModel);

  final String code;
  final String displayModel;

  /// 按蓝牙广播名前缀识别设备品类：
  /// 必须先判 `DYJV2_` 再判 `DYJ_`，避免把 V2 误判成点一机 V1。
  static DeviceKind? fromBleName(String name) {
    final trimmed = name.trim().toUpperCase();
    if (trimmed.startsWith('DYJV2_') ||
        trimmed == 'DYJV2' ||
        trimmed.startsWith('DFU_DYJ')) {
      return DeviceKind.cardV2;
    }
    if (trimmed.startsWith('DYJ_') || trimmed.startsWith('DYJ')) {
      return DeviceKind.dyjV1;
    }
    if (trimmed.startsWith('REAI_VB_')) {
      return DeviceKind.boardV21;
    }
    if (trimmed == 'OMI' ||
        trimmed.startsWith('OMI-') ||
        trimmed.startsWith('OMI_') ||
        trimmed.startsWith('OMI ') ||
        trimmed == 'FRIEND' ||
        trimmed.startsWith('FRIEND_') ||
        trimmed.startsWith('FRIEND ')) {
      return DeviceKind.omiCv1;
    }
    if (trimmed == 'SOUNDCORE WORK' ||
        trimmed.startsWith('SOUNDCORE WORK ') ||
        trimmed.startsWith('D3200')) {
      return DeviceKind.feishuD3200;
    }
    final raw = name.trim();
    if (raw == '录音豆' || raw.startsWith('飞书录音豆')) {
      return DeviceKind.feishuD3200;
    }
    return null;
  }

  /// 剥离已知代际广播前缀（`DYJV2_`、`REAI_VB_`、`DYJ_`、`OMI-`/`OMI_`、`FRIEND_`），仅保留编号。
  /// 若剥离后为空或无已知前缀，则回退原名称（去除首尾空白）。
  static String bleShortId(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return trimmed;
    final upper = trimmed.toUpperCase();
    for (final prefix in const [
      'DYJV2_',
      'REAI_VB_',
      'DYJ_',
      'OMI-',
      'OMI_',
      'OMI ',
      'FRIEND_',
      'FRIEND ',
      'D3200-',
      'D3200_',
    ]) {
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
      case 'omi_cv1':
        return DeviceKind.omiCv1;
      case 'feishu_d3200':
        return DeviceKind.feishuD3200;
      case 'apple_watch':
        return DeviceKind.appleWatch;
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
    this.hasRemoteRecordControl = true,
    required this.hasMarkButton,
    this.hasConfigurableButtons = false,
    this.hasConfigurableSwitch = false,
    this.hasOledDisplay = false,
    this.hasStandaloneRealtimeStream = false,
    required this.otaMode,
  });

  final bool realtimeAudio;
  final bool hasOnboardStorage;
  final bool hasFileSync;
  final bool hasWifiConfig;
  final bool hasCameraMedia;
  final bool hasPhysicalRecordToggle;
  final bool hasRemoteRecordControl;
  final bool hasMarkButton;
  final bool hasConfigurableButtons;
  final bool hasConfigurableSwitch;
  final bool hasOledDisplay;
  final bool hasStandaloneRealtimeStream;
  final String otaMode; // 'dual_chip' | 'single_ota' | 'none'

  bool get hasDualChipOta => otaMode == 'dual_chip';
  bool get hasSingleOta => otaMode == 'single_ota';
  bool get hasOta => hasDualChipOta || hasSingleOta;

  static const cardV2 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: true,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: true,
    hasMarkButton: true,
    hasConfigurableButtons: true,
    hasConfigurableSwitch: true,
    hasOledDisplay: true,
    hasStandaloneRealtimeStream: false,
    otaMode: 'dual_chip',
  );

  static const dyjV1 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: true,
    hasCameraMedia: true,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: true,
    hasMarkButton: false,
    hasConfigurableButtons: true,
    hasConfigurableSwitch: false,
    hasOledDisplay: false,
    hasStandaloneRealtimeStream: true,
    otaMode: 'single_ota',
  );

  static const boardV21 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: false,
    hasFileSync: false,
    hasWifiConfig: false,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: true,
    hasMarkButton: false,
    hasStandaloneRealtimeStream: true,
    otaMode: 'none',
  );

  /// 飞书录音豆 D3200：BLE 拉取板载 Opus，本机解成 16kHz WAV。不含实时流、Wi-Fi 与固件升级。
  static const feishuD3200 = HardwareCapabilities(
    realtimeAudio: false,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: false,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: true,
    hasMarkButton: false,
    otaMode: 'none',
  );

  /// Omi 量产版 / Friend Pendant：BLE 实时 Opus/PCM/uLaw/LC3 流 + 按键手势（禁长按防 3s 关机）+ 板载存储同步。
  static const omiCv1 = HardwareCapabilities(
    realtimeAudio: true,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: false,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: true,
    hasMarkButton: true,
    hasConfigurableButtons: true,
    hasStandaloneRealtimeStream: true,
    otaMode: 'none',
  );

  /// Apple Watch 独立采集硬件（WCSession 本地传片 + 表端离线缓存，无蓝牙实时 PCM 流 / Wi-Fi / 固件 OTA）。
  static const appleWatch = HardwareCapabilities(
    realtimeAudio: false,
    hasOnboardStorage: true,
    hasFileSync: true,
    hasWifiConfig: false,
    hasCameraMedia: false,
    hasPhysicalRecordToggle: true,
    hasRemoteRecordControl: true,
    hasMarkButton: true,
    otaMode: 'none',
  );

  static HardwareCapabilities forKind(DeviceKind kind) => switch (kind) {
    DeviceKind.cardV2 => cardV2,
    DeviceKind.dyjV1 => dyjV1,
    DeviceKind.boardV21 => boardV21,
    DeviceKind.omiCv1 => omiCv1,
    DeviceKind.feishuD3200 => feishuD3200,
    DeviceKind.appleWatch => appleWatch,
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
      hasRemoteRecordControl: flag(
        'hasRemoteRecordControl',
        fallback.hasRemoteRecordControl,
      ),
      hasMarkButton: flag('hasMarkButton', fallback.hasMarkButton),
      hasConfigurableButtons: flag(
        'hasConfigurableButtons',
        fallback.hasConfigurableButtons,
      ),
      hasConfigurableSwitch: flag(
        'hasConfigurableSwitch',
        fallback.hasConfigurableSwitch,
      ),
      hasOledDisplay: flag('hasOledDisplay', fallback.hasOledDisplay),
      hasStandaloneRealtimeStream: flag(
        'hasStandaloneRealtimeStream',
        fallback.hasStandaloneRealtimeStream,
      ),
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
      isCharging:
          battery['isCharging'] == true || battery['charging'] == true,
      wifiOpen:
          state['wifiOpen'] == true || state['wifiEnabled'] == true,
      recording:
          recordStatus['isRecording'] == true ||
          recordStatus['recording'] == true,
      realtimeEnabled: recordStatus['realtimeEnabled'] == true,
      recordSession: recordStatus['session'] as String?,
      recordErrorCode: (recordStatus['error'] as num?)?.toInt(),
      recordReason: recordStatus['reason']?.toString(),
      fwVersion:
          (info['version'] as String?) ??
          (info['firmwareVersion'] as String?) ??
          '',
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
    this.lastSeenAt,
    this.kind,
    this.displayModel,
    this.capabilities,
  });

  final String id;
  final String name;
  final int? rssi;
  final DateTime? lastSeenAt;
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

  factory CameraSyncItem.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?) ?? '';
    return CameraSyncItem(
      name: name,
      path: (json['path'] as String?) ?? '',
      bytesWritten:
          (json['bytesWritten'] as num?)?.toInt() ??
          (json['bytes'] as num?)?.toInt() ??
          0,
      capturedAtSec:
          (json['capturedAt'] as num?)?.toInt() ??
          (json['capturedAtSec'] as num?)?.toInt() ??
          (json['createdAt'] as num?)?.toInt() ??
          _parseCapturedEpochSec(name),
      source: (json['source'] as String?) ?? 'dyj_camera',
    );
  }

  static int? _parseCapturedEpochSec(String name) {
    final ymd = RegExp(
      r'(20\d{2})(\d{2})(\d{2})[_-]?(\d{2})(\d{2})(\d{2})',
    ).firstMatch(name);
    if (ymd != null) {
      final y = int.tryParse(ymd.group(1)!);
      final m = int.tryParse(ymd.group(2)!);
      final d = int.tryParse(ymd.group(3)!);
      final hh = int.tryParse(ymd.group(4)!);
      final mm = int.tryParse(ymd.group(5)!);
      final ss = int.tryParse(ymd.group(6)!);
      if (y != null &&
          m != null &&
          d != null &&
          hh != null &&
          mm != null &&
          ss != null &&
          m >= 1 &&
          m <= 12 &&
          d >= 1 &&
          d <= 31 &&
          hh <= 23 &&
          mm <= 59 &&
          ss <= 59) {
        return DateTime(y, m, d, hh, mm, ss).millisecondsSinceEpoch ~/ 1000;
      }
    }
    final epoch = RegExp(r'(?<!\d)(1[6-9]\d{8}|2\d{9})(?!\d)').firstMatch(name);
    if (epoch != null) {
      return int.tryParse(epoch.group(1)!);
    }
    return null;
  }

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

  factory CardFile.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?) ?? '';
    return CardFile(
      name: name,
      size: (json['size'] as num?)?.toInt() ?? 0,
      index: _intOrNull(json['index']),
      createdAtSec: _intOrNull(
        json['created_at'] ?? json['createdAt'] ?? json['createTime'],
      ),
      session: _stringOrNull(json['session']),
      seq: _intOrNull(json['seq']),
      startAtSec:
          _intOrNull(json['start_at'] ?? json['startAt']) ??
          CameraSyncItem._parseCapturedEpochSec(name),
      synced: json['synced'] is bool ? json['synced'] as bool : null,
    );
  }

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
  bool get isOgg {
    final lower = name.toLowerCase();
    return lower.endsWith('.ogg') || lower.endsWith('.opus');
  }

  bool get isWav => name.toLowerCase().endsWith('.wav');

  bool get isAudioRecording => isApm || isAmr || isOgg || isWav;

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
    this.needUpdate,
    this.currentVersionCode,
  });
  factory CardOtaInfo.fromJson(Map<String, dynamic> json) => CardOtaInfo(
    version: (json['version'] as String?) ?? '',
    versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
    url: (json['url'] as String?) ?? '',
    needUpdate: json['needUpdate'] is bool ? json['needUpdate'] as bool : null,
    currentVersionCode: (json['currentVersionCode'] as num?)?.toInt(),
  );
  final String version;
  final int versionCode;
  final String url;
  final bool? needUpdate;
  final int? currentVersionCode;

  bool isNewerThan(int installedVersionCode) {
    if (needUpdate != null) return needUpdate!;
    return installedVersionCode > 0 && versionCode > installedVersionCode;
  }
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

/// 硬件按键/拨杆事件（录音卡 V2 `BTN_CLICK`/`TOGGLE_SWITCH`、点一机 V1 `button.event`、第三方按键手势事件等）。
class HardwareButtonEvent {
  const HardwareButtonEvent({
    required this.gesture,
    this.rawGesture,
    this.button,
    this.action,
    this.durationMs,
    this.deviceTs = 0,
    required this.receivedAtMs,
    this.deviceAction,
    this.source,
  });

  /// 归一化硬件原始手势名（如 V2 `single -> click`、`double -> double_click`、
  /// `long -> long_press`、`long_release -> long_press_end`）。
  static String normalizeGesture(String raw) {
    final clean = raw.trim();
    return switch (clean) {
      'single' => 'click',
      'double' => 'double_click',
      'long' => 'long_press',
      'long_release' => 'long_press_end',
      _ => clean,
    };
  }

  factory HardwareButtonEvent.fromEvent(Map<String, dynamic> event) {
    final btnField = event['button'];
    final nested = btnField is Map
        ? Map<String, dynamic>.from(btnField)
        : const <String, dynamic>{};
    final rawCandidate =
        event['rawGesture'] ??
        nested['gesture'] ??
        nested['key'] ??
        event['gesture'] ??
        event['type'];
    final rawGestureStr = rawCandidate?.toString().trim();
    final gestureSource =
        (event['gesture'] ??
                nested['gesture'] ??
                nested['key'] ??
                event['type'] ??
                '')
            .toString();
    var normalized = normalizeGesture(gestureSource);
    if (normalized.isEmpty && event['kind'] == 'toggle_switch') {
      final pos = '${event['position'] ?? ''}'.trim();
      if (pos == 'on' || pos == 'off') {
        normalized = 'switch_$pos';
      }
    }
    final resolvedButton = switch (btnField) {
      final String s when s.trim().isNotEmpty => s.trim(),
      _ =>
        (nested['name'] ?? nested['button'] ?? event['buttonId'])
            ?.toString()
            .trim(),
    };
    final resolvedAction =
        (event['deviceAction'] ?? event['action'] ?? nested['action'])
            ?.toString()
            .trim();
    final cleanAction = resolvedAction != null && resolvedAction.isNotEmpty
        ? resolvedAction
        : null;
    final rawSource = event['source']?.toString().trim();
    return HardwareButtonEvent(
      gesture: normalized,
      rawGesture: (rawGestureStr != null && rawGestureStr.isNotEmpty)
          ? rawGestureStr
          : (normalized.isNotEmpty ? normalized : null),
      button: (resolvedButton != null && resolvedButton.isNotEmpty)
          ? resolvedButton
          : null,
      action: cleanAction,
      durationMs: (event['durationMs'] as num?)?.toInt(),
      deviceTs: (event['deviceTs'] as num?)?.toInt() ?? 0,
      receivedAtMs:
          (event['receivedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      deviceAction: cleanAction,
      source: rawSource != null && rawSource.isNotEmpty ? rawSource : null,
    );
  }

  /// `'down' | 'up' | 'click' | 'double_click' | 'long_press' | 'long_press_start' | 'long_press_end' | 'switch_on' | 'switch_off'`
  final String gesture;
  final String? rawGesture;
  final String? button;
  final String? action;
  final int? durationMs;
  final int deviceTs;
  final int receivedAtMs;
  final String? deviceAction;
  final String? source;
}

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

  /// 硬件物理按键与拨杆事件。
  Iterable<HardwareButtonEvent> get buttonEvents => [
    for (final e in events)
      if ((e['event']?['kind'] == 'button' ||
              e['event']?['kind'] == 'toggle_switch') &&
          e['event'] is Map)
        HardwareButtonEvent.fromEvent(
          Map<String, dynamic>.from(e['event'] as Map),
        ),
  ];

  /// 硬件侧边拨杆事件。
  Iterable<HardwareButtonEvent> get switchEvents => [
    for (final e in events)
      if (e['event']?['kind'] == 'toggle_switch' && e['event'] is Map)
        HardwareButtonEvent.fromEvent(
          Map<String, dynamic>.from(e['event'] as Map),
        ),
  ];

  /// 点一机 V1 硬件按键拍照/录像分段事件。
  Iterable<Map<String, dynamic>> get cameraEvents =>
      events.where((e) => e['event']?['kind'] == 'camera');

  /// 录音分段自动滚动事件（点一机 V1 `record.segment`）。
  Iterable<Map<String, dynamic>> get recordSegmentEvents =>
      events.where((e) => e['event']?['kind'] == 'record_segment');

  /// 传感器实时采样推送事件（点一机 V1 `sensor.data`）。
  Iterable<Map<String, dynamic>> get sensorEvents =>
      events.where((e) => e['event']?['kind'] == 'sensor');

  /// GNSS 定位推送事件（点一机 V1 `location.fix`）。
  Iterable<Map<String, dynamic>> get locationEvents =>
      events.where((e) => e['event']?['kind'] == 'location');

  /// 端侧流式 ASR 识别事件（点一机 V1 `asr.partial` / `asr.final` / `asr.state` / `asr.error`）。
  Iterable<Map<String, dynamic>> get asrEvents =>
      events.where((e) => e['event']?['kind'] == 'asr');

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

  /// 通用扩展桥命令透传（供解耦扩展域如旧固件独立升级复用，不污染主接口）。
  Future<Map<String, dynamic>> invokeBridgeCommand(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  ]);

  /// 通用扩展桥流式进度命令透传。
  Stream<CardProgress> invokeBridgeStream(
    String kind, [
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ]);

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

typedef FfiCardGateway = RealCardGateway;

typedef TestBridgeDispatch =
    void Function(
      String kind,
      Map<String, dynamic>? payload,
      void Function(Map<String, dynamic> event) emit,
    );

/// FFI 真实网关。
class RealCardGateway implements CardGateway {
  /// 文件下载无进度停滞超时阈值（只要字节进度持续推进即自动续期，彻底规避 10m 硬上限误杀）。
  static const Duration downloadInactivityTimeout = Duration(seconds: 75);

  RealCardGateway._(ffi.DynamicLibrary lib)
    : _command = lib
          .lookup<ffi.NativeFunction<_CommandNative>>('card_bridge_command')
          .asFunction(),
      _free = lib
          .lookup<ffi.NativeFunction<_FreeNative>>('card_bridge_free_string')
          .asFunction(),
      _version = lib
          .lookup<ffi.NativeFunction<_VersionNative>>('card_bridge_version')
          .asFunction(),
      _testDispatch = null,
      _downloadWatchdogTimeout = downloadInactivityTimeout {
    _callable = ffi.NativeCallable<_CbNative>.listener(_onEvent);
  }

  @visibleForTesting
  RealCardGateway.forTesting({
    required TestBridgeDispatch dispatch,
    Duration downloadWatchdogTimeout = downloadInactivityTimeout,
  }) : _command = null,
       _free = null,
       _version = null,
       _testDispatch = dispatch,
       _downloadWatchdogTimeout = downloadWatchdogTimeout,
       _callable = null;

  RealCardGateway.fromAddresses({
    required int commandAddress,
    required int freeAddress,
    required int versionAddress,
  }) : _command = ffi.Pointer<ffi.NativeFunction<_CommandNative>>.fromAddress(
         commandAddress,
       ).asFunction(),
       _free = ffi.Pointer<ffi.NativeFunction<_FreeNative>>.fromAddress(
         freeAddress,
       ).asFunction(),
       _version = ffi.Pointer<ffi.NativeFunction<_VersionNative>>.fromAddress(
         versionAddress,
       ).asFunction(),
       _testDispatch = null,
       _downloadWatchdogTimeout = downloadInactivityTimeout {
    _callable = ffi.NativeCallable<_CbNative>.listener(_onEvent);
  }

  static RealCardGateway? _instance;
  static const MethodChannel _bridgeControlChannel = MethodChannel(
    'com.reai.recordingcard/bluetooth',
  );

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }

  static int _parseBridgeAddress(Object? raw) {
    if (raw is int && raw > 0) return raw;
    if (raw is String) {
      final parsed = BigInt.tryParse(raw.trim());
      if (parsed != null && parsed > BigInt.zero) {
        return parsed.toUnsigned(64).toInt();
      }
    }
    return 0;
  }

  /// 当 iOS Release 包符号表被外层 `strip` 剥离导致 `DynamicLibrary.process().lookup()` 找不到符号时，
  /// 通过原生桥通道取回静态链入的 C 函数指针地址直接绑定 FFI（`STRIP_STYLE=all` 下仍可恢复）。
  static Future<RealCardGateway?> tryBindFromPlatformChannel({
    MethodChannel? channelOverride,
    RealCardGateway Function({
      required int commandAddress,
      required int freeAddress,
      required int versionAddress,
    })?
    factoryOverride,
  }) async {
    if (_instance != null) return _instance;
    if (channelOverride == null && !Platform.isIOS) return null;
    final channel = channelOverride ?? _bridgeControlChannel;
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>(
        'bridgeSymbols',
      );
      if (raw == null) return null;
      final cmd = _parseBridgeAddress(raw['command']);
      final free = _parseBridgeAddress(raw['free']);
      final ver = _parseBridgeAddress(raw['version']);
      if (cmd == 0 || free == 0 || ver == 0) return null;
      final build = factoryOverride ?? RealCardGateway.fromAddresses;
      _instance = build(
        commandAddress: cmd,
        freeAddress: free,
        versionAddress: ver,
      );
      return _instance;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on Object {
      return null;
    }
  }

  static RealCardGateway? maybe() {
    if (_instance != null) return _instance;
    const envLib = String.fromEnvironment('RC_CARD_BRIDGE_LIB');
    // 依次整体尝试「打开 + 符号查找」：
    // ① 测试/桌面显式指定路径（`RC_CARD_BRIDGE_LIB`）；
    // ② 进程符号表——iOS 静态链接直连；
    // ③ libcard_bridge.dylib——iOS/macOS 动态库兜底；
    // ④ libcard_bridge.so——Android jniLibs。注意 System.loadLibrary 走 RTLD_LOCAL，
    //    dlopen(NULL)(=process()) 看不到它的符号，必须显式 dlopen 拿到库自身句柄。
    final openers = <ffi.DynamicLibrary Function()>[
      if (envLib.isNotEmpty) () => ffi.DynamicLibrary.open(envLib),
      ffi.DynamicLibrary.process,
      () => ffi.DynamicLibrary.open('libcard_bridge.dylib'),
      () => ffi.DynamicLibrary.open('libcard_bridge.so'),
      if (Platform.isMacOS) _openBundledMacBridge,
    ];
    for (final open in openers) {
      try {
        final lib = open();
        _instance = RealCardGateway._(lib); // 构造器内完成全部符号查找
        return _instance;
      } catch (_) {}
    }
    return null;
  }

  /// 桌面端把 `libcard_bridge.dylib` 放在可执行文件旁边，按绝对路径打开。
  static ffi.DynamicLibrary _openBundledMacBridge() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      '${exeDir.path}/libcard_bridge.dylib',
      '${exeDir.parent.path}/Frameworks/libcard_bridge.dylib',
    ];
    Object? last;
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        return ffi.DynamicLibrary.open(path);
      } catch (error) {
        last = error;
      }
    }
    throw last ?? StateError('libcard_bridge.dylib 未打进应用包');
  }

  final _CommandDart? _command;
  final _FreeDart? _free;
  final _VersionDart? _version;
  final TestBridgeDispatch? _testDispatch;
  final Duration _downloadWatchdogTimeout;
  late final ffi.NativeCallable<_CbNative>? _callable;

  /// 是否绑定真实原生 FFI 动态库（区分单元测试注入桩）。
  bool get isNativeFfi => _testDispatch == null;

  final Map<int, StreamController<Map<String, dynamic>>> _pending = {};
  int _ticket = 0;

  Future<void> _queue = Future<void>.value();

  @override
  bool get available => true;

  String get bridgeVersion {
    final ver = _version;
    if (ver == null) return 'card_bridge/test';
    final ptr = ver();
    if (ptr == ffi.nullptr) return '';
    return ptr.toDartString();
  }

  void _invokeRawCommand(
    int ticket,
    String kind,
    Map<String, dynamic>? payload,
  ) {
    final testDispatch = _testDispatch;
    if (testDispatch != null) {
      scheduleMicrotask(() {
        testDispatch(kind, payload, (decoded) => _deliverDecoded(ticket, decoded));
      });
      return;
    }
    final cmd = _command!;
    final callable = _callable!;
    final kindPtr = kind.toNativeUtf8();
    final payloadPtr = (payload == null || payload.isEmpty)
        ? ffi.nullptr
        : jsonEncode(payload).toNativeUtf8();
    try {
      cmd(kindPtr, payloadPtr, callable.nativeFunction, ticket);
    } finally {
      malloc.free(kindPtr);
      if (payloadPtr != ffi.nullptr) malloc.free(payloadPtr);
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _queue;
    _queue = () async {
      // 前一命令的失败不能楔死整条串行链：吸收其结果后再执行当前命令，
      // 否则一次超时/异常会让后续所有桥命令（含扫描）永久排队（真机 2026-11-16 实测挂死形状）。
      try {
        await previous;
      } catch (_) {}
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

    try {
      _invokeRawCommand(ticket, kind, payload);
    } catch (e) {
      _pending.remove(ticket);
      timer?.cancel();
      controller
        ..addError(CardException(CardErrorKind.unknown, '调用桥失败：$e'))
        ..close();
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

  static bool _didDownloadProgressAdvance(
    Map<String, dynamic> progress, {
    required int? lastBytes,
    required double? lastPercent,
    required int? lastPoll,
    required void Function(int? nextBytes, double? nextPercent, int? nextPoll)
    updateTrackers,
  }) {
    final rawBytes =
        progress['bytesWritten'] ??
        progress['sent'] ??
        progress['bytes'] ??
        progress['receivedBytes'];
    if (rawBytes is num) {
      final b = rawBytes.toInt();
      if (lastBytes == null || b > lastBytes) {
        updateTrackers(b, lastPercent, lastPoll);
        return true;
      }
      return false;
    }
    final rawPct = progress['percent'] ?? progress['percentage'];
    if (rawPct is num) {
      final p = rawPct.toDouble();
      if (lastPercent == null || p > lastPercent) {
        updateTrackers(lastBytes, p, lastPoll);
        return true;
      }
      return false;
    }
    final rawPoll = progress['poll'];
    if (rawPoll is num) {
      final poll = rawPoll.toInt();
      if (lastPoll == null || poll > lastPoll) {
        updateTrackers(lastBytes, lastPercent, poll);
        return true;
      }
      return false;
    }
    return false;
  }

  /// 带进度续期的空闲看门狗命令执行器：
  /// 每次收到真实推进的下载进度即重置 [inactivityTimeout]（默认 75s），
  /// 仅当完全无进度停滞达到阈值才判定超时，防止 BLE 大文件在 10m 临界点被 Dart 提前中断而固件删源。
  Future<Map<String, dynamic>> _onceWithProgressWatchdog(
    String kind,
    Map<String, dynamic>? payload, {
    Duration? inactivityTimeout,
  }) {
    final idleLimit = inactivityTimeout ?? _downloadWatchdogTimeout;
    return _serial(() async {
      final ticket = ++_ticket;
      final controller = StreamController<Map<String, dynamic>>(sync: true);
      _pending[ticket] = controller;

      final completer = Completer<Map<String, dynamic>>();
      Timer? watchdog;
      StreamSubscription<Map<String, dynamic>>? sub;
      int? lastBytes;
      double? lastPercent;
      int? lastPoll;

      void armWatchdog() {
        watchdog?.cancel();
        watchdog = Timer(idleLimit, () {
          _pending.remove(ticket);
          if (!completer.isCompleted) {
            completer.completeError(
              CardException.timeout(
                '$kind 传输停滞超时（连续 ${idleLimit.inSeconds}s 无进度）',
              ),
            );
          }
        });
      }

      armWatchdog();

      sub = controller.stream.listen(
        (json) {
          if (json['ok'] != true) {
            watchdog?.cancel();
            if (!completer.isCompleted) {
              completer.completeError(_error(kind, json['error']?.toString()));
            }
            return;
          }
          if (json['final'] == true) {
            watchdog?.cancel();
            if (!completer.isCompleted) {
              completer.complete(json);
            }
            return;
          }
          final progress = json['progress'];
          if (progress is Map) {
            final map = Map<String, dynamic>.from(progress);
            final advanced = _didDownloadProgressAdvance(
              map,
              lastBytes: lastBytes,
              lastPercent: lastPercent,
              lastPoll: lastPoll,
              updateTrackers: (b, p, poll) {
                lastBytes = b;
                lastPercent = p;
                lastPoll = poll;
              },
            );
            if (advanced) {
              armWatchdog();
            }
          }
        },
        onError: (Object err, StackTrace st) {
          watchdog?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(err, st);
          }
        },
        onDone: () {
          watchdog?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(
              CardException(CardErrorKind.unknown, '$kind 未返回终态即结束'),
            );
          }
        },
      );

      try {
        _invokeRawCommand(ticket, kind, payload);
        return await completer.future;
      } finally {
        watchdog?.cancel();
        _pending.remove(ticket);
        unawaited(sub.cancel());
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      }
    });
  }

  /// 直接读取纯内存态或非串口指令，避免被耗时 BLE 串行队列（snapshot / ota.info）饥饿阻塞。
  Future<Map<String, dynamic>> _onceFast(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 3),
  ]) async {
    final json = await _open(kind, payload, timeout).first;
    if (json['ok'] != true) {
      throw _error(kind, json['error']?.toString());
    }
    return json;
  }

  Stream<CardProgress> _progress(
    String kind,
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ) async* {
    final controller = StreamController<Map<String, dynamic>>();
    final ticket = ++_ticket;
    _pending[ticket] = controller;

    _invokeRawCommand(ticket, kind, payload);

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
    if (text.startsWith('LEGACY_UPGRADE_REQUIRED|')) {
      return CardException(CardErrorKind.device, text);
    }
    final lower = text.toLowerCase();
    if (lower.startsWith('unsupported') || lower.contains('unsupported:')) {
      return CardException(CardErrorKind.device, text);
    }
    if (lower.contains('channel closed')) {
      return const CardException(
        CardErrorKind.device,
        '蓝牙扫描通道异常中断，请点击「重新扫描」重试',
      );
    }
    if (lower.contains('permissiondenied') ||
        lower.contains('permission denied')) {
      return const CardException(
        CardErrorKind.device,
        '未开启蓝牙权限，请在系统设置中允许「录音卡」使用蓝牙',
      );
    }
    if (lower.contains('poweredoff') || lower.contains('powered off')) {
      return const CardException(
        CardErrorKind.device,
        '系统蓝牙未开启，请打开蓝牙后重试',
      );
    }
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
      3001 => '点一机忙碌或存储空间不足$suffix',
      3003 => '点一机尚未连接 Wi-Fi，请先配网后再试$suffix',
      3401 => '点一机需要开启系统定位开关后才能扫描 Wi-Fi$suffix',
      _ => '录音卡返回错误$suffix',
    };
  }

  static Map<String, dynamic>? lastDeviceErrorDetail;

  void _deliverDecoded(int ticket, Map<String, dynamic> decoded) {
    final controller = _pending[ticket];
    if (controller == null) return;
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
  }

  void _onEvent(int ticket, ffi.Pointer<Utf8> json) {
    StreamController<Map<String, dynamic>>? controller;
    try {
      final text = json.toDartString();
      controller = _pending[ticket];
      if (controller == null) return;
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      _deliverDecoded(ticket, decoded);
    } catch (e) {
      if (controller != null && !controller.isClosed) {
        controller.addError(CardException(CardErrorKind.unknown, '桥回包解析失败：$e'));
        _pending.remove(ticket);
        controller.close();
      }
    } finally {
      _free?.call(json);
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
          // 调试直连模式：桥对未识别设备上报 deviceKind=unknown，这里按名字兜底、
          // 兜不上则保持 null（列表无过滤直通展示，连接前再由驱动按需识别）。
          final rawKind = d['deviceKind'] as String?;
          final kind =
              rawKind == 'unknown'
              ? DeviceKind.fromBleName(name)
              : DeviceKind.fromCode(rawKind, fallbackName: name);
          final capsMap = d['capabilities'] is Map<String, dynamic>
              ? d['capabilities'] as Map<String, dynamic>
              : null;
          final lastSeenAtMs = (d['lastSeenAtMs'] as num?)?.toInt();
          return CardDevice(
            id: (d['id'] as String?) ?? '',
            name: name,
            rssi: (d['rssi'] as num?)?.toInt(),
            lastSeenAt: lastSeenAtMs != null && lastSeenAtMs > 0
                ? DateTime.fromMillisecondsSinceEpoch(lastSeenAtMs)
                : null,
            kind: kind,
            displayModel:
                (d['displayModel'] as String?) ?? kind?.displayModel ?? 'BLE 设备',
            capabilities: HardwareCapabilities.fromJson(
              capsMap,
              fallbackKind: kind ?? DeviceKind.cardV2,
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
      const Duration(seconds: 55),
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
    final json = await _once('disconnect', null, const Duration(seconds: 15));
    final data = json['data'];
    return CardDisconnectReport.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  @override
  Future<CardSnapshot> snapshot() async {
    final json = await _once('snapshot', null, const Duration(seconds: 25));
    return CardSnapshot.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> record(String action) =>
      _once('record', {'action': action}, const Duration(seconds: 20));

  @override
  Future<void> startRecording({int? durationSecs}) => _once(
    'record.start',
    durationSecs != null && durationSecs > 0
        ? {'durationSecs': durationSecs}
        : null,
    const Duration(seconds: 20),
  );

  @override
  Future<void> stopRecording() async {
    try {
      await _once('record.stop', null, const Duration(seconds: 20));
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

    _invokeRawCommand(ticket, 'realtime.open', null);
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
    final json = await _onceFast(
      'events.pull',
      {'after': after},
      const Duration(seconds: 2),
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
  Future<void> mark() => _once('mark', null, const Duration(seconds: 15));

  @override
  Future<List<CardFile>> files() async {
    final json = await _once('files', null, const Duration(seconds: 40));
    final rawData = json['data'];
    final list = switch (rawData) {
      final List<dynamic> l => l,
      final Map<String, dynamic> m => m['files'] as List<dynamic>? ?? const [],
      final Map<Object?, Object?> m => m['files'] as List<dynamic>? ?? const [],
      _ => const <dynamic>[],
    };
    return list
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) => CardFile.fromJson({
            for (final e in item.entries) '${e.key}': e.value,
          }),
        )
        .toList();
  }

  @override
  Future<CardDownload> download(String name, String dir) async {
    final json = await _onceWithProgressWatchdog('download', {
      'name': name,
      'dir': dir,
    });
    return CardDownload.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<CardDownload> takeOldestFile(String dir) async {
    final json = await _onceWithProgressWatchdog('file.takeOldest', {
      'dir': dir,
    });
    return CardDownload.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> deleteFile(String name) =>
      _once('deleteFile', {'name': name}, const Duration(seconds: 20));

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
    final rawData = json['data'];
    final list = switch (rawData) {
      final List<dynamic> l => l,
      final Map<String, dynamic> m => m['photos'] as List<dynamic>? ?? const [],
      final Map<Object?, Object?> m => m['photos'] as List<dynamic>? ?? const [],
      _ => const <dynamic>[],
    };
    return list
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) => CameraSyncItem.fromJson({
            for (final e in item.entries) '${e.key}': e.value,
          }),
        )
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
  Future<void> closeWifi() => _once('wifi.close', null, const Duration(seconds: 15));

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
  Future<void> forgetWifi(String ssid) =>
      _once('wifi.forget', {'ssid': ssid}, const Duration(seconds: 15));

  @override
  Future<void> startSync() =>
      _once('sync.start', null, const Duration(seconds: 30));

  @override
  Future<CardSyncStatus> syncStatus() async {
    final json = await _once('sync.status', null, const Duration(seconds: 15));
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
  Future<void> syncTime() => _once('time.sync', null, const Duration(seconds: 15));

  @override
  Future<Map<String, dynamic>> invokeBridgeCommand(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  ]) => _once(kind, payload, timeout);

  @override
  Stream<CardProgress> invokeBridgeStream(
    String kind, [
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ]) => _progress(kind, payload, onFinal);

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
  Future<Map<String, dynamic>> invokeBridgeCommand(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  ]) async => _fail();
  @override
  Stream<CardProgress> invokeBridgeStream(
    String kind, [
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ]) => Stream.error(CardException.unavailable());
  @override
  Future<void> dispose() async {}
}

CardGateway realOrUnsupported() =>
    RealCardGateway.maybe() ?? const UnsupportedCardGateway();

/// 命令转发网关：每条 BLE 命令"发出"和"返回"以及实时音频收包都回调 [onActivity]。
class ActivityGateway implements CardGateway {
  ActivityGateway(this._inner, this.onActivity, {this.onRealtimeError});

  final CardGateway _inner;
  final void Function() onActivity;
  final void Function(Object error)? onRealtimeError;

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
    return _inner.realtimeAudio().transform(
      StreamTransformer<
        RealtimeAudioEvent,
        RealtimeAudioEvent
      >.fromHandlers(
        handleData: (event, sink) {
          if (event.kind == RealtimeAudioKind.audio) {
            onActivity();
          }
          sink.add(event);
        },
        handleError: (error, stackTrace, sink) {
          onRealtimeError?.call(error);
          sink.addError(error, stackTrace);
        },
      ),
    );
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
  Future<Map<String, dynamic>> invokeBridgeCommand(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  ]) => _run(() => _inner.invokeBridgeCommand(kind, payload, timeout));

  @override
  Stream<CardProgress> invokeBridgeStream(
    String kind, [
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ]) => _pipe(_inner.invokeBridgeStream(kind, payload, onFinal));

  @override
  Future<void> dispose() => _inner.dispose();
}

/// 点一机 V1 开放 SDK 扩展命令封装（基于 [CardGateway.invokeBridgeCommand]，不破坏现有网关抽象契约）。
extension DyjV1HardwareCommands on CardGateway {
  Future<Map<String, dynamic>> _dyjData(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    final res = await invokeBridgeCommand(kind, payload, timeout);
    final raw = res['data'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return res;
  }

  /// 按指定切片分钟数触发点一机 V1 本地分段录音（`record.start` + `segmentMin`）。
  Future<Map<String, dynamic>> startRecordingSegment({
    required int segmentMinutes,
  }) => _dyjData('record.start', {'segmentMin': segmentMinutes});

  Future<Map<String, dynamic>> dyjDeviceInfo({bool verbose = false}) =>
      _dyjData('dyj.device.info', {'verbose': verbose});

  Future<Map<String, dynamic>> dyjDeviceTime({int? epochMs}) => _dyjData(
    'dyj.device.time',
    epochMs == null ? null : {'epochMs': epochMs},
  );

  Future<Map<String, dynamic>> dyjDeviceReboot({bool confirm = false}) =>
      _dyjData('dyj.device.reboot', {'confirm': confirm});

  Future<Map<String, dynamic>> dyjOtaConfigGet() =>
      _dyjData('dyj.ota.config.get');

  Future<Map<String, dynamic>> dyjOtaConfigSet(String url) =>
      _dyjData('dyj.ota.config.set', {'url': url});

  Future<Map<String, dynamic>> dyjSensorStatus() =>
      _dyjData('dyj.sensor.status');

  Future<Map<String, dynamic>> dyjSensorRead({List<String>? types}) =>
      _dyjData('dyj.sensor.read', types == null ? null : {'types': types});

  Future<Map<String, dynamic>> dyjSensorStreamStart({
    List<String>? types,
    int intervalMs = 500,
  }) => _dyjData('dyj.sensor.stream.start', {
    'types': ?types,
    'intervalMs': intervalMs,
  });

  Future<Map<String, dynamic>> dyjSensorStreamStop() =>
      _dyjData('dyj.sensor.stream.stop');

  Future<Map<String, dynamic>> dyjLocationStatus() =>
      _dyjData('dyj.location.status');

  Future<Map<String, dynamic>> dyjLocationGet({int timeoutS = 10}) => _dyjData(
    'dyj.location.get',
    {'timeoutS': timeoutS},
    const Duration(seconds: 35),
  );

  Future<Map<String, dynamic>> dyjLocationStreamStart({
    int minIntervalS = 5,
  }) => _dyjData('dyj.location.stream.start', {'minIntervalS': minIntervalS});

  Future<Map<String, dynamic>> dyjLocationStreamStop() =>
      _dyjData('dyj.location.stream.stop');

  Future<Map<String, dynamic>> dyjCameraStatus() =>
      _dyjData('dyj.camera.status');

  Future<Map<String, dynamic>> dyjCameraCapture() =>
      _dyjData('dyj.camera.capture');

  Future<Map<String, dynamic>> dyjCameraRecordStart({
    int? maxS,
    int? segmentS,
  }) => _dyjData('dyj.camera.record.start', {
    'maxS': ?maxS,
    'segmentS': ?segmentS,
  });

  Future<Map<String, dynamic>> dyjCameraRecordStop() =>
      _dyjData('dyj.camera.record.stop');

  Future<Map<String, dynamic>> dyjCameraRecordStatus() =>
      _dyjData('dyj.camera.record.status');

  Future<Map<String, dynamic>> dyjCameraDelete(String name) =>
      _dyjData('dyj.camera.delete', {'name': name});

  Future<Map<String, dynamic>> dyjVibratorOnce({
    int durationMs = 200,
    int? amplitude,
  }) => _dyjData('dyj.vibrator.once', {
    'durationMs': durationMs,
    'amplitude': ?amplitude,
  });

  Future<Map<String, dynamic>> dyjVibratorCancel() =>
      _dyjData('dyj.vibrator.cancel');

  Future<Map<String, dynamic>> dyjVolumeGet() => _dyjData('dyj.volume.get');

  Future<Map<String, dynamic>> dyjVolumeSet(String stream, int value) =>
      _dyjData('dyj.volume.set', {'stream': stream, 'value': value});

  Future<Map<String, dynamic>> dyjLedStatus() => _dyjData('dyj.led.status');

  Future<Map<String, dynamic>> dyjLedSet(
    String pattern, {
    String? brightness,
    int? priority,
    int? timeoutS,
  }) => _dyjData('dyj.led.set', {
    'pattern': pattern,
    'brightness': ?brightness,
    'priority': ?priority,
    'timeoutS': ?timeoutS,
  });

  Future<Map<String, dynamic>> dyjLedClear() => _dyjData('dyj.led.clear');

  Future<Map<String, dynamic>> dyjButtonBindGet() =>
      _dyjData('dyj.button.bind.get');

  Future<Map<String, dynamic>> dyjButtonBindSet(
    String gesture,
    String action,
  ) => _dyjData('dyj.button.bind.set', {'gesture': gesture, 'action': action});

  Future<Map<String, dynamic>> dyjAsrStatus() => _dyjData('dyj.asr.status');

  Future<Map<String, dynamic>> dyjAsrConfigGet() =>
      _dyjData('dyj.asr.config.get');

  Future<Map<String, dynamic>> dyjAsrConfigSet({
    bool? attach,
    bool? partial,
  }) => _dyjData('dyj.asr.config.set', {
    'attach': ?attach,
    'partial': ?partial,
  });

  Future<Map<String, dynamic>> dyjAsrStart({
    String mode = 'continuous',
    bool partial = true,
    int maxS = 1800,
  }) => _dyjData(
    'dyj.asr.start',
    {'mode': mode, 'partial': partial, 'maxS': maxS},
    const Duration(seconds: 25),
  );

  Future<Map<String, dynamic>> dyjAsrStop() => _dyjData('dyj.asr.stop');
}
