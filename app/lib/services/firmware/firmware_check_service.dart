import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/device_backend.dart';

/// Version reads and release discovery are independent. In particular, absence
/// of a manifest says nothing about whether installed firmware is up to date.
enum FirmwareCheckState {
  notConfigured,
  noApplicableUpdate,
  deviceNotConnected,
  versionsUnavailable,
  offerAvailable,
  failed,
}

enum FirmwareVersionReadState { notRead, notConnected, available, failed }

enum WifiFirmwareVersionState { available, poweredDown, unknown }

enum FirmwareFailureStage { manifest, deviceVersions }

class FirmwareCheckException implements Exception {
  const FirmwareCheckException(this.stage, this.code, this.message);
  final FirmwareFailureStage stage;
  final String code;
  final String message;
  @override
  String toString() => message;
}

class FirmwareVersions {
  const FirmwareVersions._({required this.state, this.snapshot, this.error});
  const FirmwareVersions.notRead()
    : this._(state: FirmwareVersionReadState.notRead);
  const FirmwareVersions.notConnected()
    : this._(state: FirmwareVersionReadState.notConnected);
  FirmwareVersions.fromSnapshot(CardSnapshot snapshot)
    : this._(state: FirmwareVersionReadState.available, snapshot: snapshot);
  FirmwareVersions.failed(FirmwareCheckException error)
    : this._(state: FirmwareVersionReadState.failed, error: error);

  final FirmwareVersionReadState state;
  final CardSnapshot? snapshot;
  final FirmwareCheckException? error;
  String? get mainVersion =>
      snapshot?.infoAvailable == true ? _nonEmpty(snapshot?.fwVersion) : null;
  // The native snapshot uses zero as its backwards-compatible unknown value.
  // It cannot prove a real installed version of zero; fail closed in that case.
  int? get mainVersionCode => mainVersion == null || snapshot!.versionCode <= 0
      ? null
      : snapshot!.versionCode;
  String? get wifiVersion => _nonEmpty(snapshot?.wifiVersion);
  int? get wifiVersionCode =>
      wifiVersion == null || (snapshot?.wifiVersionCode ?? -1) < 0
      ? null
      : snapshot!.wifiVersionCode;
  WifiFirmwareVersionState get wifiState =>
      wifiVersion != null && wifiVersionCode != null
      ? WifiFirmwareVersionState.available
      : snapshot?.wifiOpen == false
      ? WifiFirmwareVersionState.poweredDown
      : WifiFirmwareVersionState.unknown;

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value;
}

class FirmwareCheckResult {
  const FirmwareCheckResult({
    required this.state,
    required this.versions,
    required this.message,
    this.offer,
    this.manifest,
    this.packages = const [],
    this.error,
  });
  final FirmwareCheckState state;
  final FirmwareVersions versions;
  final String message;
  final FirmwareOffer? offer;
  final FirmwareManifest? manifest;

  /// Only newer, exactly installed-version-bound stages are installable.
  final List<Map<String, dynamic>> packages;
  final FirmwareCheckException? error;
}

class FirmwareManifest {
  FirmwareManifest._(Map<String, dynamic> data, this.packages)
    : data = Map.unmodifiable(data),
      checksum = sha256.convert(utf8.encode(jsonEncode(data))).toString();
  final Map<String, dynamic> data;
  final List<Map<String, dynamic>> packages;
  final String checksum;
  String get deviceId => data['deviceId'] as String? ?? '';
  String get packageId => data['packageId'] as String? ?? '';
  String get notes => data['notes'] as String? ?? '可信固件清单中的适用更新';

  static FirmwareManifest parse(String source) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      _invalid('manifest_json', '固件清单不是有效JSON');
    }
    if (decoded is! Map<String, dynamic> || decoded['packages'] is! List) {
      _invalid('manifest_shape', '固件清单必须包含packages列表');
    }
    final entries = decoded['packages'] as List;
    if (entries.length > 2) {
      _invalid('manifest_stages', '固件清单最多包含两个明确芯片阶段');
    }
    if (entries.isNotEmpty) {
      _string(decoded, 'deviceId');
      _string(decoded, 'packageId');
    }
    if (decoded['notes'] != null && decoded['notes'] is! String) {
      _invalid('manifest_notes', '固件清单说明格式错误');
    }
    final modules = <String>{};
    final packages = <Map<String, dynamic>>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        _invalid('package_shape', '固件包配置格式错误');
      }
      final module = _string(entry, 'module');
      if ((module != 'main' && module != 'wifi') || !modules.add(module)) {
        _invalid('package_module', '固件芯片必须是唯一的main或wifi阶段');
      }
      _versionCode(entry, 'installedVersionCode');
      _versionCode(entry, 'targetVersionCode');
      _string(entry, 'targetVersion');
      _string(entry, 'transportId');
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(_string(entry, 'sha256'))) {
        _invalid('package_checksum', '固件缺少可信SHA256');
      }
      if (entry['sizeBytes'] is! int ||
          entry['sizeBytes'] <= 0 ||
          entry['sizeBytes'] > 64 * 1024 * 1024) {
        _invalid('package_size', '固件大小超过受控范围');
      }
      _string(entry, module == 'main' ? 'dfuTargetId' : 'chipModel');
      validatePackageUrl(entry);
      packages.add(
        Map.unmodifiable({
          ...entry,
          'sha256': (entry['sha256'] as String).toLowerCase(),
          'allowedHosts': List<String>.unmodifiable(
            (entry['allowedHosts'] as List).cast<String>(),
          ),
        }),
      );
    }
    return FirmwareManifest._(decoded, List.unmodifiable(packages));
  }

  static Uri validatePackageUrl(Map<String, dynamic> package) {
    final url = Uri.tryParse(_string(package, 'url'));
    final hosts = package['allowedHosts'];
    if (hosts is! List ||
        hosts.isEmpty ||
        hosts.any((h) => h is! String || h.trim().isEmpty) ||
        url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        !hosts
            .map((h) => (h as String).toLowerCase())
            .contains(url.host.toLowerCase())) {
      _invalid('package_url', '固件下载地址不在明确HTTPS白名单');
    }
    return url;
  }

  static String _string(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty) {
      _invalid('package_field', '固件清单缺少有效$key');
    }
    return value;
  }

  static void _versionCode(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! int || value < 0 || value > 0xffffffff) {
      _invalid('package_version_code', '固件清单$key必须是有效版本号');
    }
  }

  static Never _invalid(String code, String message) =>
      throw FirmwareCheckException(
        FirmwareFailureStage.manifest,
        code,
        message,
      );
}

/// Read-only service: no Wi-Fi power changes, scan, connection, package download
/// or OTA calls. [readSnapshot] can use cached/native BASE_INFO-derived versions;
/// WIFI_STATUS is optional and must not tear down a real BLE connection.
class FirmwareCheckService {
  FirmwareCheckService({
    required this.loadManifest,
    required this.readSnapshot,
  });
  final Future<String> Function() loadManifest;
  final Future<CardSnapshot> Function() readSnapshot;

  Future<FirmwareVersions> readVersions({
    CardSnapshot? snapshot,
    bool? connected,
  }) async {
    if (connected == false) return const FirmwareVersions.notConnected();
    if (snapshot != null) return FirmwareVersions.fromSnapshot(snapshot);
    try {
      return FirmwareVersions.fromSnapshot(await readSnapshot());
    } catch (e) {
      if (e is CardGatewayException &&
          (e.code == 'disconnected' || e.code == 'not_connected')) {
        return const FirmwareVersions.notConnected();
      }
      return FirmwareVersions.failed(
        FirmwareCheckException(
          FirmwareFailureStage.deviceVersions,
          'device_versions',
          '设备固件版本读取失败：$e',
        ),
      );
    }
  }

  Future<FirmwareCheckResult> check({
    CardSnapshot? snapshot,
    bool? connected,
  }) async {
    var versions = connected == false
        ? const FirmwareVersions.notConnected()
        : snapshot == null
        ? const FirmwareVersions.notRead()
        : FirmwareVersions.fromSnapshot(snapshot);
    final FirmwareManifest manifest;
    try {
      final source = await loadManifest();
      if (source.trim().isEmpty) {
        return FirmwareCheckResult(
          state: FirmwareCheckState.notConfigured,
          versions: versions,
          message: '未配置升级清单，没有可用更新信息',
        );
      }
      manifest = FirmwareManifest.parse(source);
    } catch (e) {
      final error = e is FirmwareCheckException
          ? e
          : FirmwareCheckException(
              FirmwareFailureStage.manifest,
              'manifest_service',
              '固件清单服务失败：$e',
            );
      return FirmwareCheckResult(
        state: FirmwareCheckState.failed,
        versions: versions,
        message: error.message,
        error: error,
      );
    }
    if (manifest.packages.isEmpty) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.noApplicableUpdate,
        versions: versions,
        message: '清单没有发布升级包',
        manifest: manifest,
      );
    }
    versions = await readVersions(snapshot: snapshot, connected: connected);
    if (versions.state == FirmwareVersionReadState.notConnected) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.deviceNotConnected,
        versions: versions,
        message: '请先连接录音卡以读取固件版本',
        manifest: manifest,
      );
    }
    if (versions.error != null) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.failed,
        versions: versions,
        message: versions.error!.message,
        error: versions.error,
        manifest: manifest,
      );
    }
    final actual = versions.snapshot!;
    // A valid manifest for another card is not an offer for this card.
    if (actual.deviceId.trim().isEmpty) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.versionsUnavailable,
        versions: versions,
        message: '设备未返回可验证身份，不能判断适用更新',
        manifest: manifest,
      );
    }
    if (manifest.deviceId != actual.deviceId) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.noApplicableUpdate,
        versions: versions,
        message: '清单没有适用于当前录音卡的升级包',
        manifest: manifest,
      );
    }
    final packages = <Map<String, dynamic>>[];
    var missingVersion = false;
    for (final package in manifest.packages) {
      final installed = package['module'] == 'main'
          ? versions.mainVersionCode
          : versions.wifiVersionCode;
      if (installed == null) {
        missingVersion = true;
        continue;
      }
      // SDK OtaInfo::is_newer_than compares numeric versionCode, never labels.
      if ((package['targetVersionCode'] as int) <= installed) continue;
      if (package['installedVersionCode'] != installed) {
        return FirmwareCheckResult(
          state: FirmwareCheckState.noApplicableUpdate,
          versions: versions,
          message: '升级包未绑定当前已装版本，没有适用更新',
          manifest: manifest,
        );
      }
      packages.add(package);
    }
    // Do not silently split an unverified two-stage release. A main-only
    // manifest can still offer an update while Wi-Fi is off or unknown.
    if (missingVersion) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.versionsUnavailable,
        versions: versions,
        message: versions.wifiState == WifiFirmwareVersionState.poweredDown
            ? 'Wi-Fi芯片未开启，版本未知；未判断该清单是否适用'
            : '芯片固件版本未知，未判断该清单是否适用',
        manifest: manifest,
      );
    }
    if (packages.isEmpty) {
      return FirmwareCheckResult(
        state: FirmwareCheckState.noApplicableUpdate,
        versions: versions,
        message: '当前清单没有比已装版本更新的适用包',
        manifest: manifest,
      );
    }
    final offer = FirmwareOffer(
      packageId: manifest.packageId,
      deviceId: actual.deviceId,
      targetMainVersion:
          packages
              .where((p) => p['module'] == 'main')
              .map((p) => p['targetVersion'] as String)
              .firstOrNull ??
          '',
      targetWifiVersion:
          packages
              .where((p) => p['module'] == 'wifi')
              .map((p) => p['targetVersion'] as String)
              .firstOrNull ??
          '',
      checksum: manifest.checksum,
      notes: manifest.notes,
    );
    return FirmwareCheckResult(
      state: FirmwareCheckState.offerAvailable,
      versions: versions,
      message: '有可用更新',
      offer: offer,
      manifest: manifest,
      packages: List.unmodifiable(packages),
    );
  }
}
