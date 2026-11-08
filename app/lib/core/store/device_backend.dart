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
  });
  final CardSnapshot snapshot;
  final String? id;
  final String? targetId;
  final int? recordedSeconds;
  final String? batteryEstimate;
  final String? connectedWifi;
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
      checksum.isNotEmpty &&
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

  /// Success means the configured upload contract completed, NOT merely local download.
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

/// Injectable orchestration for B/C integration. Missing capabilities fail closed.
class CallbackDeviceBackend implements DeviceBackend {
  CallbackDeviceBackend({
    required this.isAvailable,
    required this.scanDevices,
    required this.connectDevice,
    required this.readStatus,
    required this.disconnectDevice,
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
  Future<void> sync(RecordingPolicy policy, ProgressSink sink) async {
    if (synchronize == null) _missing('同步上传');
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
          if (snapshot == null) throw StateError('设备没有返回有效状态');
          return DeviceReading(snapshot, id: id);
        },
        readStatus: () async {
          if (gateway == null || !gateway.available) {
            throw StateError('蓝牙服务不可用，请检查原生桥与权限');
          }
          final snapshot = await gateway.status();
          if (snapshot == null) throw StateError('未连接录音卡');
          return DeviceReading(snapshot);
        },
        disconnectDevice: () async {
          if (gateway == null) throw StateError('蓝牙服务不可用');
          await (gateway as dynamic).disconnect();
        },
      );
}
