import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/app_backend.dart';
import '../../core/store/service_backends.dart';
import '../firmware/firmware_check_service.dart';
import 'runtime_config.dart';

export '../firmware/firmware_check_service.dart';

/// Public build-config manifest. No guessed releases, board IDs or bootloader.
/// Checking is read-only; packages are fetched only inside the consented install.
class FirmwareProvider {
  FirmwareProvider(this.gateway, {Future<String> Function()? loadManifest})
    : _checks = FirmwareCheckService(
        loadManifest:
            loadManifest ?? (() async => RuntimeConfig.firmwareManifest),
        readSnapshot: gateway.status,
      );
  final CardGateway gateway;
  final FirmwareCheckService _checks;
  FirmwareCheckResult? lastCheck;

  /// Version reads do not depend on having an upgrade manifest. Supply the
  /// DeviceStore's current snapshot to avoid a duplicate native transaction.
  Future<FirmwareVersions> readVersions({
    CardSnapshot? snapshot,
    bool? connected,
  }) => _checks.readVersions(snapshot: snapshot, connected: connected);

  /// Rich result for UI integration: missing configuration, optional Wi-Fi
  /// versions, disconnection and genuine failures must not be conflated.
  Future<FirmwareCheckResult> check({
    CardSnapshot? snapshot,
    bool? connected,
  }) async {
    final result = await _checks.check(
      snapshot: snapshot,
      connected: connected,
    );
    lastCheck = result;
    return result;
  }

  /// Existing backend seam. Null means no *verified applicable offer*, not
  /// "installed firmware is latest". A missing manifest never touches BLE.
  Future<FirmwareRelease?> offer() async {
    final result = await check();
    if (result.error != null) throw result.error!;
    final offer = result.offer;
    if (offer == null) return null;
    final packages = result.packages;
    final snapshot = result.versions.snapshot!;
    final canonicalHash = offer.checksum;
    return FirmwareRelease(
      offer: offer,
      install: (consent, sink) async {
        if (consent.deviceId != offer.deviceId ||
            consent.packageId != offer.packageId ||
            consent.checksum != canonicalHash) {
          throw StateError('固件授权与精确清单不匹配');
        }
        final support = await getApplicationSupportDirectory();
        for (var i = 0; i < packages.length; i++) {
          final p = packages[i];
          final current = await gateway.status();
          final installed = p['module'] == 'main'
              ? current.versionCode
              : current.wifiVersionCode;
          if (current.deviceId != snapshot.deviceId ||
              installed != p['installedVersionCode'] ||
              current.recording ||
              current.realtimeEnabled) {
            throw StateError('OTA设备身份/已装版本变化或录音/实时传输未停止');
          }
          sink(
            TaskProgress(
              '阶段 ${i + 1}/${packages.length} · 校验并下载${p['module']}包',
            ),
          );
          final path = await _download(
            p,
            Directory('${support.path}/recording_card/firmware'),
          );
          final plan = CardFirmwarePlan(
            module: p['module'] as String,
            transportId: p['transportId'] as String,
            deviceId: current.deviceId,
            installedVersionCode: p['installedVersionCode'] as int,
            targetVersionCode: p['targetVersionCode'] as int,
            targetVersion: p['targetVersion'] as String,
            packagePath: path,
            sha256: p['sha256'] as String,
            dfuTargetId: p['dfuTargetId'] as String?,
            chipModel: p['chipModel'] as String?,
          );
          await gateway.updateFirmware(
            plan,
            userConfirmed: true,
            onProgress: (progress) => sink(
              TaskProgress(
                '阶段 ${i + 1}/${packages.length} · ${progress.stage}',
                percent: progress.fraction == null
                    ? null
                    : progress.fraction! * 100,
              ),
            ),
          );
          if (p['module'] == 'main') {
            await gateway.connect(p['transportId'] as String);
          }
          final after = await gateway.status();
          final version = p['module'] == 'main'
              ? after.versionCode
              : after.wifiVersionCode;
          if (after.deviceId != snapshot.deviceId ||
              version != p['targetVersionCode']) {
            throw StateError('更新后身份/版本未验证，不能报告成功');
          }
        }
      },
    );
  }

  Future<String> _download(
    Map<String, dynamic> package,
    Directory directory,
  ) async {
    final url = FirmwareManifest.validatePackageUrl(package);
    await directory.create(recursive: true);
    final file = File('${directory.path}/${package['sha256']}.bin');
    final size = package['sizeBytes'] as int;
    if (size <= 0 || size > 64 * 1024 * 1024) throw StateError('固件大小超过受控范围');
    if (await file.exists() &&
        await file.length() == size &&
        (await sha256.bind(file.openRead()).first).toString() ==
            package['sha256']) {
      return file.path;
    }
    final client = HttpClient();
    final partial = File('${file.path}.part');
    IOSink? sink;
    try {
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) throw StateError('可信固件下载失败或发生重定向');
      sink = partial.openWrite();
      var received = 0;
      await for (final block in response.timeout(const Duration(seconds: 30))) {
        received += block.length;
        if (received > size) throw StateError('固件下载长度超出可信清单');
        sink.add(block);
        await sink.flush();
      }
      await sink.close();
      sink = null;
      if (received != size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              package['sha256']) {
        throw StateError('固件SHA256/长度校验失败');
      }
      await partial.rename(file.path);
      return file.path;
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }
}
