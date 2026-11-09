import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/runtime/firmware_provider.dart';

// All identities, versions, URLs and hashes below are explicit test fixtures.
// No production config, native bridge, Bluetooth, HTTP or OTA is used.
CardSnapshot snapshot({
  bool wifiOpen = false,
  String mainVersion = 'test-main-current',
  int mainCode = 10,
  String wifiVersion = '',
  int? wifiCode,
  String deviceId = 'fixture-card',
}) => CardSnapshot(
  batteryLevel: 50,
  isCharging: false,
  wifiOpen: wifiOpen,
  recording: false,
  fwVersion: mainVersion,
  wifiVersion: wifiVersion,
  versionCode: mainCode,
  wifiVersionCode: wifiCode,
  deviceId: deviceId,
);

Map<String, dynamic> package({
  String module = 'main',
  int installed = 10,
  int target = 11,
  String targetLabel = 'test-release',
}) => {
  'module': module,
  'installedVersionCode': installed,
  'targetVersionCode': target,
  'targetVersion': targetLabel,
  'transportId': 'fixture-transport',
  'sha256': 'a' * 64,
  'sizeBytes': 12,
  'dfuTargetId': 'fixture-bootloader',
  'chipModel': 'fixture-board',
  'url': 'https://firmware.invalid/fixture.bin',
  'allowedHosts': ['firmware.invalid'],
};

String manifest(
  List<Map<String, dynamic>> packages, {
  String deviceId = 'fixture-card',
}) => jsonEncode({
  'packageId': 'fixture-release',
  'deviceId': deviceId,
  'notes': 'fixture release notes',
  'packages': packages,
});

class FirmwareGatewaySpy extends CardGateway {
  CardSnapshot value = snapshot();
  Object? failure;
  int statusCalls = 0;
  @override
  bool get available => true;
  @override
  Future<CardSnapshot> status() async {
    statusCalls++;
    if (failure != null) throw failure!;
    return value;
  }
  // Every other operation inherits an explicit unsupported exception. In
  // particular no scan/connect/setWifiEnabled/updateFirmware is implemented.
}

void main() {
  late FirmwareGatewaySpy gateway;
  setUp(() => gateway = FirmwareGatewaySpy());
  FirmwareProvider provider(String source) =>
      FirmwareProvider(gateway, loadManifest: () async => source);

  test(
    'default unconfigured manifest has no offer and never reads the gateway',
    () async {
      final p = FirmwareProvider(gateway);
      expect(await p.offer(), isNull);
      expect(p.lastCheck!.state, FirmwareCheckState.notConfigured);
      expect(p.lastCheck!.versions.state, FirmwareVersionReadState.notRead);
      expect(gateway.statusCalls, 0);
    },
  );

  test(
    'blank manifest is no offer even while disconnected or gateway fails',
    () async {
      gateway.failure = const CardGatewayException(
        'disconnected',
        'fixture disconnected',
      );
      final p = provider(' \n ');
      final result = await p.check(connected: false);
      expect(result.state, FirmwareCheckState.notConfigured);
      expect(result.versions.state, FirmwareVersionReadState.notConnected);
      expect(result.error, isNull);
      expect(await p.offer(), isNull);
      expect(gateway.statusCalls, 0);
    },
  );

  test(
    'no manifest still preserves separately read or cached device versions',
    () async {
      final p = provider('');
      final result = await p.check(snapshot: gateway.value, connected: true);
      expect(result.versions.mainVersion, 'test-main-current');
      expect(result.versions.mainVersionCode, 10);
      expect(result.versions.wifiVersion, isNull);
      expect(result.versions.wifiVersionCode, isNull);
      expect(result.versions.wifiState, WifiFirmwareVersionState.poweredDown);
      expect(result.state, FirmwareCheckState.notConfigured);
      expect(gateway.statusCalls, 0);
      final versions = await p.readVersions();
      expect(versions.state, FirmwareVersionReadState.available);
      expect(versions.mainVersionCode, 10);
      expect(gateway.statusCalls, 1);
    },
  );

  test(
    'empty published package list does not require a device or claim latest',
    () async {
      final result = await provider('{"packages":[]}').check();
      expect(result.state, FirmwareCheckState.noApplicableUpdate);
      expect(result.message, '清单没有发布升级包');
      expect(result.offer, isNull);
      expect(result.error, isNull);
      expect(gateway.statusCalls, 0);
    },
  );

  test(
    'explicit disconnection never queries a stale cached snapshot',
    () async {
      final result = await provider(manifest([package()]))
          .check(snapshot: gateway.value, connected: false);
      expect(result.state, FirmwareCheckState.deviceNotConnected);
      expect(result.versions.mainVersion, isNull);
      expect(result.offer, isNull);
      expect(result.error, isNull);
      expect(gateway.statusCalls, 0);
    },
  );

  for (final code in ['disconnected', 'not_connected']) {
    test(
      'native $code is a connection prerequisite, not manifest failure',
      () async {
        gateway.failure = CardGatewayException(code, 'fixture disconnected');
        final p = provider(manifest([package()]));
        expect((await p.check()).state, FirmwareCheckState.deviceNotConnected);
        expect(await p.offer(), isNull);
        expect(p.lastCheck!.error, isNull);
      },
    );
  }

  test(
    'genuine snapshot failure is not suppressed or reported as no update',
    () async {
      gateway.failure = const CardGatewayException(
        'timeout',
        'fixture version timeout',
      );
      final p = provider(manifest([package()]));
      final result = await p.check();
      expect(result.state, FirmwareCheckState.failed);
      expect(result.versions.state, FirmwareVersionReadState.failed);
      expect(result.error!.stage, FirmwareFailureStage.deviceVersions);
      expect(result.error!.message, contains('fixture version timeout'));
      await expectLater(p.offer(), throwsA(isA<FirmwareCheckException>()));
    },
  );

  test(
    'unavailable bridge remains a real read failure with a configured manifest',
    () async {
      final p = FirmwareProvider(
        const UnavailableCardGateway(),
        loadManifest: () async => manifest([package()]),
      );
      final result = await p.check();
      expect(result.state, FirmwareCheckState.failed);
      expect(result.error!.stage, FirmwareFailureStage.deviceVersions);
      expect(result.offer, isNull);
    },
  );

  test(
    'manifest service failure is distinct from device version failure',
    () async {
      final p = FirmwareProvider(
        gateway,
        loadManifest: () async => throw StateError('fixture manifest offline'),
      );
      final result = await p.check(snapshot: gateway.value);
      expect(result.state, FirmwareCheckState.failed);
      expect(result.error!.stage, FirmwareFailureStage.manifest);
      expect(result.error!.code, 'manifest_service');
      expect(result.versions.state, FirmwareVersionReadState.available);
      expect(gateway.statusCalls, 0);
      await expectLater(p.offer(), throwsA(isA<FirmwareCheckException>()));
    },
  );

  test(
    'main-only release can be offered with Wi-Fi chip powered down',
    () async {
      final source = manifest([package()]);
      final p = provider(source);
      final release = await p.offer();
      expect(release!.offer.valid, isTrue);
      expect(release.offer.targetMainVersion, 'test-release');
      expect(release.offer.targetWifiVersion, isEmpty);
      expect(release.offer.deviceId, gateway.value.deviceId);
      expect(
        release.offer.checksum,
        sha256.convert(utf8.encode(jsonEncode(jsonDecode(source)))).toString(),
      );
      expect(
        p.lastCheck!.versions.wifiState,
        WifiFirmwareVersionState.poweredDown,
      );
      expect(p.lastCheck!.state, FirmwareCheckState.offerAvailable);
      expect(gateway.statusCalls, 1);
    },
  );

  test(
    'cached snapshot avoids extra read while checking a configured release',
    () async {
      final result = await provider(manifest([package()]))
          .check(snapshot: gateway.value, connected: true);
      expect(result.state, FirmwareCheckState.offerAvailable);
      expect(gateway.statusCalls, 0);
    },
  );

  test(
    'main-only release also works with Wi-Fi powered on but version unknown',
    () async {
      gateway.value = snapshot(wifiOpen: true);
      final result = await provider(manifest([package()])).check();
      expect(result.state, FirmwareCheckState.offerAvailable);
      expect(result.versions.wifiState, WifiFirmwareVersionState.unknown);
      expect(result.offer!.targetWifiVersion, isEmpty);
    },
  );

  for (final wifiOpen in [false, true]) {
    test(
      'unknown Wi-Fi version suppresses Wi-Fi offer without a service error (open=$wifiOpen)',
      () async {
        gateway.value = snapshot(wifiOpen: wifiOpen);
        final p = provider(manifest([package(module: 'wifi')]));
        final result = await p.check();
        expect(result.state, FirmwareCheckState.versionsUnavailable);
        expect(
          result.versions.wifiState,
          wifiOpen
              ? WifiFirmwareVersionState.unknown
              : WifiFirmwareVersionState.poweredDown,
        );
        expect(result.offer, isNull);
        expect(result.error, isNull);
        expect(await p.offer(), isNull);
      },
    );
  }

  test(
    'BASE_INFO Wi-Fi version remains usable even if module is powered down',
    () async {
      gateway.value = snapshot(wifiVersion: 'test-wifi-current', wifiCode: 10);
      final result = await provider(manifest([package(module: 'wifi')]))
          .check();
      expect(result.versions.wifiState, WifiFirmwareVersionState.available);
      expect(result.state, FirmwareCheckState.offerAvailable);
      expect(result.offer!.targetMainVersion, isEmpty);
      expect(result.offer!.targetWifiVersion, 'test-release');
    },
  );

  test(
    'unknown stage never becomes a guessed or partial two-stage offer',
    () async {
      final result = await provider(
        manifest([package(), package(module: 'wifi')]),
      ).check();
      expect(result.state, FirmwareCheckState.versionsUnavailable);
      expect(result.offer, isNull);
      expect(result.packages, isEmpty);
      expect(result.versions.mainVersionCode, 10);
    },
  );

  test('known two-stage offer uses exactly the manifest versions', () async {
    gateway.value = snapshot(
      wifiOpen: true,
      wifiVersion: 'test-wifi-current',
      wifiCode: 20,
    );
    final result = await provider(
      manifest([
        package(targetLabel: 'test-main-target'),
        package(
          module: 'wifi',
          installed: 20,
          target: 21,
          targetLabel: 'test-wifi-target',
        ),
      ]),
    ).check();
    expect(result.state, FirmwareCheckState.offerAvailable);
    expect(result.packages.map((p) => p['module']), ['main', 'wifi']);
    expect(result.offer!.targetMainVersion, 'test-main-target');
    expect(result.offer!.targetWifiVersion, 'test-wifi-target');
  });

  for (final target in [9, 10]) {
    test(
      'equal or older version code $target gives no offer, not failed downgrade',
      () async {
        final result = await provider(
          manifest([
            package(target: target, targetLabel: '9999.label-is-not-compared'),
          ]),
        ).check();
        expect(result.state, FirmwareCheckState.noApplicableUpdate);
        expect(result.error, isNull);
        expect(result.offer, isNull);
      },
    );
  }

  test(
    'newer numeric code is authoritative even when display label sorts lower',
    () async {
      gateway.value = snapshot(mainVersion: '999.999');
      final result = await provider(manifest([package(targetLabel: '0.1')]))
          .check();
      expect(result.state, FirmwareCheckState.offerAvailable);
      expect(result.offer!.targetMainVersion, '0.1');
    },
  );

  test(
    'already-installed stage is omitted without copying its version into offer',
    () async {
      gateway.value = snapshot(
        wifiOpen: true,
        wifiVersion: 'test-wifi-current',
        wifiCode: 10,
      );
      final result = await provider(
        manifest([package(target: 10), package(module: 'wifi')]),
      ).check();
      expect(result.state, FirmwareCheckState.offerAvailable);
      expect(result.packages.map((p) => p['module']), ['wifi']);
      expect(result.offer!.targetMainVersion, isEmpty);
    },
  );

  test('manifest for another device is no applicable offer', () async {
    final result = await provider(
      manifest([package()], deviceId: 'other-fixture-card'),
    ).check();
    expect(result.state, FirmwareCheckState.noApplicableUpdate);
    expect(result.offer, isNull);
    expect(result.error, isNull);
  });

  test(
    'newer package with different base version remains inapplicable',
    () async {
      final result = await provider(manifest([package(installed: 8)])).check();
      expect(result.state, FirmwareCheckState.noApplicableUpdate);
      expect(result.offer, isNull);
      expect(result.error, isNull);
    },
  );

  test('missing main version or identity is unavailable, never a fabricated zero version', () async {
    gateway.value = snapshot(mainVersion: '');
    var result = await provider(manifest([package()])).check();
    expect(result.state, FirmwareCheckState.versionsUnavailable);
    expect(result.versions.mainVersionCode, isNull);
    gateway.value = snapshot(deviceId: '');
    result = await provider(manifest([package()])).check();
    expect(result.state, FirmwareCheckState.versionsUnavailable);
    expect(result.offer, isNull);
  });

  test('native compatibility zero main code is unknown and cannot produce an offer', () async {
    gateway.value = snapshot(mainCode: 0);
    final result = await provider(manifest([package(installed: 0, target: 1)]))
        .check();
    expect(result.state, FirmwareCheckState.versionsUnavailable);
    expect(result.versions.mainVersionCode, isNull);
    expect(result.offer, isNull);
  });

  test('native optional BASE_INFO failure preserves connection but provides no main offer', () async {
    gateway.value = CardSnapshot.fromJson({
      'battery': {'level': 50, 'isCharging': false},
      'state': {'wifiOpen': false},
      'record': {'isRecording': false, 'realtimeEnabled': false},
      'info': null,
      'wifi': {'status': 'off', 'connected': false},
      'optionalErrors': {
        'info': {'code': 'timeout', 'message': 'fixture BASE_INFO timeout'},
      },
    });
    final result = await provider(manifest([package()])).check();
    expect(result.state, FirmwareCheckState.versionsUnavailable);
    expect(result.versions.state, FirmwareVersionReadState.available);
    expect(result.versions.mainVersion, isNull);
    expect(result.versions.mainVersionCode, isNull);
    expect(result.versions.snapshot!.optionalErrors, contains('info'));
    expect(result.offer, isNull);
    expect(result.error, isNull);
  });

  test(
    'partial Wi-Fi fields remain unknown, not a made-up version/code',
    () async {
      gateway.value = snapshot(
        wifiOpen: true,
        wifiVersion: 'fixture-label-only',
      );
      var result = await provider(manifest([package(module: 'wifi')])).check();
      expect(result.state, FirmwareCheckState.versionsUnavailable);
      expect(result.versions.wifiVersion, 'fixture-label-only');
      expect(result.versions.wifiVersionCode, isNull);
      gateway.value = snapshot(wifiOpen: true, wifiCode: 10);
      result = await provider(manifest([package(module: 'wifi')])).check();
      expect(result.versions.wifiVersion, isNull);
      expect(result.versions.wifiVersionCode, isNull);
      expect(result.offer, isNull);
    },
  );

  for (final source in ['{bad', '[]', '{}', '{"packages":null}']) {
    test(
      'malformed manifest $source is a genuine config failure before device I/O',
      () async {
        final result = await provider(source).check();
        expect(result.state, FirmwareCheckState.failed);
        expect(result.error!.stage, FirmwareFailureStage.manifest);
        expect(gateway.statusCalls, 0);
      },
    );
  }

  final invalidFields = <String, Object?>{
    'module': 'unknown-chip',
    'installedVersionCode': -1,
    'targetVersionCode': '11',
    'targetVersion': '',
    'transportId': '',
    'sha256': 'not-a-hash',
    'sizeBytes': 0,
    'dfuTargetId': '',
    'url': 'http://firmware.invalid/insecure.bin',
    'allowedHosts': ['other.invalid'],
  };
  for (final entry in invalidFields.entries) {
    test(
      'invalid ${entry.key} rejects an otherwise newer release before device I/O',
      () async {
        final invalid = package()..[entry.key] = entry.value;
        final p = provider(manifest([invalid]));
        final result = await p.check();
        expect(result.state, FirmwareCheckState.failed);
        expect(result.error!.stage, FirmwareFailureStage.manifest);
        expect(result.offer, isNull);
        expect(gateway.statusCalls, 0);
      },
    );
  }

  test('duplicate modules and more than two stages are rejected', () async {
    for (final packages in [
      [package(), package()],
      [package(), package(module: 'wifi'), package()],
    ]) {
      final result = await provider(manifest(packages)).check();
      expect(result.state, FirmwareCheckState.failed);
      expect(result.offer, isNull);
    }
    expect(gateway.statusCalls, 0);
  });

  test('missing Wi-Fi chip identity is rejected', () async {
    final p = package(module: 'wifi')..remove('chipModel');
    final result = await provider(manifest([p])).check();
    expect(result.state, FirmwareCheckState.failed);
    expect(gateway.statusCalls, 0);
  });

  test('userinfo, fragment, and non-whitelisted URLs are rejected', () async {
    for (final url in [
      'https://user:secret@firmware.invalid/file.bin',
      'https://firmware.invalid/file.bin#fragment',
      'https://other.invalid/file.bin',
    ]) {
      final p = package()..['url'] = url;
      expect(
        (await provider(manifest([p])).check()).state,
        FirmwareCheckState.failed,
      );
    }
    expect(gateway.statusCalls, 0);
  });

  test('uppercase SHA is normalized for verification without rewriting manifest consent hash', () async {
    final pkg = package()..['sha256'] = 'A' * 64;
    final source = manifest([pkg]);
    final result = await provider(source).check();
    expect(result.packages.single['sha256'], 'a' * 64);
    expect(
      result.offer!.checksum,
      sha256.convert(utf8.encode(jsonEncode(jsonDecode(source)))).toString(),
    );
    expect(() => result.packages.add(pkg), throwsUnsupportedError);
    expect(
      () => result.packages.single['url'] = 'http://other.invalid',
      throwsUnsupportedError,
    );
    expect(
      () =>
          (result.packages.single['allowedHosts'] as List).add('other.invalid'),
      throwsUnsupportedError,
    );
  });
}
