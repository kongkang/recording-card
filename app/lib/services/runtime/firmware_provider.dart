import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/device/card_gateway.dart';
import '../../core/store/device_backend.dart';
import '../../core/store/app_backend.dart';
import '../../core/store/service_backends.dart';
import 'runtime_config.dart';

/// Public build-config manifest. No guessed releases, board IDs or bootloader.
/// Packages are HTTPS fetched only after exact user confirmation in existing UI.
class FirmwareProvider {
  FirmwareProvider(this.gateway);
  final CardGateway gateway;
  Future<FirmwareRelease?> offer() async {
    if (RuntimeConfig.firmwareManifest.isEmpty) {
      throw StateError('可信固件清单未配置；不会自动发现或刷写未知包');
    }
    final manifest = (jsonDecode(RuntimeConfig.firmwareManifest) as Map)
        .cast<String, dynamic>();
    final snapshot = await gateway.status();
    if (manifest['deviceId'] != snapshot.deviceId ||
        snapshot.deviceId.isEmpty) {
      throw StateError('固件清单与真实设备身份不一致');
    }
    final packages = (manifest['packages'] as List)
        .map((p) => (p as Map).cast<String, dynamic>())
        .toList();
    if (packages.isEmpty ||
        packages.length > 2 ||
        packages.map((p) => p['module']).toSet().length != packages.length) {
      throw StateError('固件清单必须是唯一的1–2个明确芯片阶段');
    }
    final canonicalHash = sha256
        .convert(utf8.encode(jsonEncode(manifest)))
        .toString();
    String main = snapshot.fwVersion, wifi = snapshot.wifiVersion;
    bool newer = false;
    for (final p in packages) {
      final module = p['module'];
      if (module != 'main' && module != 'wifi') throw StateError('未知固件芯片');
      final installed = module == 'main'
          ? snapshot.versionCode
          : snapshot.wifiVersionCode;
      if (installed == null ||
          p['installedVersionCode'] != installed ||
          p['targetVersionCode'] is! int ||
          p['targetVersionCode'] <= installed) {
        throw StateError('包必须绑定真实已装版本且明确升级，拒绝降级/猜版本');
      }
      if (!RegExp(r'^[a-fA-F0-9]{64}$')
          .hasMatch(p['sha256'] as String? ?? '')) {
        throw StateError('固件缺少可信SHA256');
      }
      if (module == 'main' && (p['dfuTargetId'] as String? ?? '').isEmpty) {
        throw StateError('缺少精确bootloader身份');
      }
      if (module == 'wifi' && (p['chipModel'] as String? ?? '').isEmpty) {
        throw StateError('缺少精确Wi-Fi板型');
      }
      _validateUrl(p);
      if (module == 'main') {
        main = p['targetVersion'] as String;
      } else {
        wifi = p['targetVersion'] as String;
      }
      newer = true;
    }
    if (!newer) return null;
    final offer = FirmwareOffer(
      packageId: manifest['packageId'] as String,
      deviceId: snapshot.deviceId,
      targetMainVersion: main,
      targetWifiVersion: wifi,
      checksum: canonicalHash,
      notes: manifest['notes'] as String? ?? '精确测试包；刷写需另行授权',
    );
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
          if (current.deviceId != snapshot.deviceId ||
              current.recording ||
              current.realtimeEnabled) {
            throw StateError('OTA设备身份变化或录音/实时传输未停止');
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

  Uri _validateUrl(Map<String, dynamic> package) {
    final url = Uri.parse(package['url'] as String);
    final hosts = (package['allowedHosts'] as List).cast<String>().toSet();
    if (url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        !hosts.contains(url.host) ||
        hosts.isEmpty) {
      throw StateError('固件下载地址不在明确HTTPS白名单');
    }
    return url;
  }

  Future<String> _download(
    Map<String, dynamic> package,
    Directory directory,
  ) async {
    final url = _validateUrl(package);
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
