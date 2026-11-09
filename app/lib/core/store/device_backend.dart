library;

import '../device/card_gateway.dart';
import 'app_backend.dart';

class DeviceChoice {
  const DeviceChoice(this.id, this.name);
  final String id;
  final String name;
}

class DeviceReading {
  const DeviceReading(
    this.snapshot, {
    this.id,
    this.targetId,
    this.recordedSeconds,
    this.batteryEstimate,
    this.connectedWifi,
    this.recordingKnown = true,
    this.batteryKnown = true,
  });
  final CardSnapshot snapshot;
  final String? id;
  final String? targetId;

  /// Only a verified SDK duration/sample clock, never time since app connection.
  final int? recordedSeconds;
  final String? batteryEstimate;
  final String? connectedWifi;
  final bool recordingKnown;
  final bool batteryKnown;
}

class WifiNet {
  const WifiNet(this.name, this.signal, {this.lock = false, this.frequencyMhz});
  final String name;
  final int signal;
  final bool lock;
  final int? frequencyMhz;
}

/// Never contains a password. Backend owns secure network credential storage.
class SavedWifi {
  const SavedWifi(this.name);
  final String name;
}

class FirmwareOffer {
  const FirmwareOffer({
    required this.packageId,
    required this.deviceId,
    required this.targetMainVersion,
    required this.targetWifiVersion,
    required this.checksum,
    required this.notes,
  });
  final String packageId;
  final String deviceId;
  final String targetMainVersion;
  final String targetWifiVersion;
  final String checksum;
  final String notes;
  bool get valid =>
      packageId.isNotEmpty &&
      deviceId.isNotEmpty &&
      RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(checksum) &&
      (targetMainVersion.isNotEmpty || targetWifiVersion.isNotEmpty);
}

class FirmwareConsent {
  const FirmwareConsent({
    required this.packageId,
    required this.deviceId,
    required this.checksum,
  });
  final String packageId;
  final String deviceId;
  final String checksum;
}

abstract class DeviceBackend {
  bool get available;
  Future<List<DeviceChoice>> scan();
  Future<DeviceReading> connect(String id);
  Future<void> disconnect();
  Future<DeviceReading> status();

  /// Success means the configured sync/import contract completed. Audio need not
  /// be uploaded; production may bind a verified local file import instead.
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress);
  Future<List<SavedWifi>> savedWifi();
  Future<List<WifiNet>> scanWifi();
  Future<void> connectSavedWifi(String name);
  Future<void> joinWifi(String name, String password);
  Future<FirmwareOffer?> firmwareOffer();
  Future<void> updateFirmware(
    FirmwareOffer offer,
    FirmwareConsent consent,
    ProgressSink onProgress,
  );
}

/// Optional capability keeps existing `implements DeviceBackend` test doubles
/// source-compatible. Runtime wrappers must explicitly implement this interface.
/// Resolve only with SDK-confirmed RECORD_STATUS, never a desired-state echo.
abstract interface class RecordingDeviceBackend {
  Future<DeviceReading> startRecording();
  Future<DeviceReading> stopRecording();
}

class DeviceSyncOutcome {
  const DeviceSyncOutcome({
    required this.savedCount,
    this.retainedSourceCount = 0,
  });
  final int savedCount;
  final int retainedSourceCount;
  bool get moveComplete => retainedSourceCount == 0;
}

/// Optional file-transfer capability; legacy injected backends stay compatible.
abstract interface class FileTransferDeviceBackend {
  DeviceSyncOutcome? get lastSyncOutcome;
  Future<void> prepareFastTransfer();
  Future<void> cancelFastTransfer();
  Future<void> fastSync(RecordingPolicy policy, ProgressSink onProgress);
}

extension DeviceRecordingControl on DeviceBackend {
  Future<DeviceReading> startRecording() async {
    final control = this;
    if (control is! RecordingDeviceBackend) {
      throw StateError('开始录音服务未配置');
    }
    return (control as RecordingDeviceBackend).startRecording();
  }

  Future<DeviceReading> stopRecording() async {
    final control = this;
    if (control is! RecordingDeviceBackend) {
      throw StateError('停止录音服务未配置');
    }
    return (control as RecordingDeviceBackend).stopRecording();
  }
}

/// Injectable orchestration for B/C integration. Missing capabilities fail closed.
class CallbackDeviceBackend implements DeviceBackend, RecordingDeviceBackend {
  CallbackDeviceBackend({
    required this.isAvailable,
    required this.scanDevices,
    required this.connectDevice,
    required this.readStatus,
    required this.disconnectDevice,
    this.beginRecording,
    this.endRecording,
    this.synchronize,
    this.listSavedWifi,
    this.scanNetworks,
    this.connectSavedNetwork,
    this.joinNetwork,
    this.checkFirmware,
    this.installFirmware,
  });
  final bool Function() isAvailable;
  final Future<List<DeviceChoice>> Function() scanDevices;
  final Future<DeviceReading> Function(String) connectDevice;
  final Future<DeviceReading> Function() readStatus;
  final Future<void> Function() disconnectDevice;
  final Future<DeviceReading> Function()? beginRecording;
  final Future<DeviceReading> Function()? endRecording;
  final Future<void> Function(RecordingPolicy, ProgressSink)? synchronize;
  final Future<List<SavedWifi>> Function()? listSavedWifi;
  final Future<List<WifiNet>> Function()? scanNetworks;
  final Future<void> Function(String)? connectSavedNetwork;
  final Future<void> Function(String, String)? joinNetwork;
  final Future<FirmwareOffer?> Function()? checkFirmware;
  final Future<void> Function(FirmwareOffer, FirmwareConsent, ProgressSink)?
  installFirmware;
  Never _missing(String name) => throw StateError('$name服务未配置');
  @override
  bool get available => isAvailable();
  @override
  Future<List<DeviceChoice>> scan() => scanDevices();
  @override
  Future<DeviceReading> connect(String id) => connectDevice(id);
  @override
  Future<DeviceReading> status() => readStatus();
  @override
  Future<void> disconnect() => disconnectDevice();
  @override
  Future<DeviceReading> startRecording() async {
    if (beginRecording == null) _missing('开始录音');
    return beginRecording!();
  }

  @override
  Future<DeviceReading> stopRecording() async {
    if (endRecording == null) _missing('停止录音');
    return endRecording!();
  }

  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink sink) async {
    if (synchronize == null) _missing('文件同步');
    await synchronize!(policy, sink);
  }

  @override
  Future<List<SavedWifi>> savedWifi() async {
    if (listSavedWifi == null) _missing('安全Wi-Fi配置');
    return listSavedWifi!();
  }

  @override
  Future<List<WifiNet>> scanWifi() async {
    if (scanNetworks == null) _missing('Wi-Fi扫描');
    return scanNetworks!();
  }

  @override
  Future<void> connectSavedWifi(String name) async {
    if (connectSavedNetwork == null) _missing('已保存Wi-Fi连接');
    await connectSavedNetwork!(name);
  }

  @override
  Future<void> joinWifi(String name, String password) async {
    if (joinNetwork == null) _missing('Wi-Fi连接');
    await joinNetwork!(name, password);
  }

  @override
  Future<FirmwareOffer?> firmwareOffer() async {
    if (checkFirmware == null) _missing('固件清单');
    return checkFirmware!();
  }

  @override
  Future<void> updateFirmware(
    FirmwareOffer offer,
    FirmwareConsent consent,
    ProgressSink sink,
  ) async {
    if (installFirmware == null) _missing('固件升级');
    await installFirmware!(offer, consent, sink);
  }
}

/// Current gateway compatibility. Only known scan/connect/status are adapted.
/// B's new Wi-Fi/OTA and C's sync are supplied by CallbackDeviceBackend above;
/// do not guess native method names or silently pretend unavailable capabilities work.
class GatewayDeviceBackend extends CallbackDeviceBackend {
  GatewayDeviceBackend(CardGateway? gateway)
    : super(
        isAvailable: () => gateway?.available ?? false,
        scanDevices: () async {
          if (gateway == null || !gateway.available) {
            throw StateError('蓝牙服务不可用，请检查原生桥与权限');
          }
          final result = await (gateway as dynamic).scan() as List;
          return [
            for (final d in result)
              d is String
                  ? DeviceChoice(d, d)
                  : DeviceChoice(d.id as String, d.name as String),
          ];
        },
        connectDevice: (id) async {
          if (gateway == null) throw StateError('蓝牙服务不可用');
          await (gateway as dynamic).connect(id);
          final snapshot = await gateway.status();
          return DeviceReading(snapshot, id: id);
        },
        readStatus: () async {
          if (gateway == null || !gateway.available) {
            throw StateError('蓝牙服务不可用，请检查原生桥与权限');
          }
          final snapshot = await gateway.status();
          return DeviceReading(snapshot);
        },
        disconnectDevice: () async {
          if (gateway == null) throw StateError('蓝牙服务不可用');
          await (gateway as dynamic).disconnect();
        },
        beginRecording: () => _setRecording(gateway, true),
        endRecording: () => _setRecording(gateway, false),
      );

  static Future<DeviceReading> _setRecording(
    CardGateway? gateway,
    bool enabled,
  ) async {
    if (gateway == null || !gateway.available) {
      throw StateError('蓝牙服务不可用，请检查原生桥与权限');
    }
    final record = await gateway.setRecording(enabled);
    if (record['isRecording'] != enabled) {
      throw StateError('设备未确认${enabled ? '开始' : '停止'}录音');
    }
    final snapshot = await gateway.status();
    if (snapshot.recording != enabled) {
      throw StateError('设备录音状态确认未通过');
    }
    return DeviceReading(snapshot);
  }
}
