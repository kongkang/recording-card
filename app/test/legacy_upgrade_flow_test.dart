/// 旧版固件独立引导升级全流程集成测试：
/// ① 点击旧固件设备弹出独立引导层（原 StatusSheet 收起、不污染主连接态）
/// ② 点「设置 Wi-Fi 并自动升级」扫描并展示 Wi-Fi（未配网/已连接两种场景）
/// ③ 选定 CloudOS.com 输入密码点「连接并自动升级」→ 串行配网 + OTA 进度 + 自动重连蓝牙 → 正常连接态 StatusSheet
/// ④ 配网报错可「返回重设 Wi-Fi」或「重试升级」；点「暂不升级」主动释放蓝牙会话。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

const _legacyV1 = CardDevice(
  id: 'dyj-q2m34r-legacy',
  name: 'DYJ_Q2M34R',
  rssi: -54,
  kind: DeviceKind.dyjV1,
);

CardSnapshot _upgraded0815Snapshot() => const CardSnapshot(
  batteryLevel: 100,
  isCharging: true,
  wifiOpen: true,
  recording: false,
  fwVersion: '0.8.15',
  fwVersionCode: 815,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_Q2M34R',
  deviceId: 'C5F96AD5895ADF02',
  storageTotalMb: 11180,
  storageFreeMb: 9980,
  deviceKind: DeviceKind.dyjV1,
  displayModel: '点一机 V1',
  capabilities: HardwareCapabilities.dyjV1,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    '①②③④ 旧固件触发独立引导升级：扫描 Wi-Fi → 填密码配网 → OTA 进度 → 自动重连 0.8.15 正常状态页',
    (tester) async {
      String? connectedWifiSsid;
      String? connectedWifiPwd;
      late final FakeCardGateway gw;
      gw = FakeCardGateway(devices: const [_legacyV1])
        ..failConnect = const CardException(
          CardErrorKind.device,
          'LEGACY_UPGRADE_REQUIRED|dyj_v1|0.7.2|0.8.12|检测到点一机固件版本不兼容（当前 v0.7.2），请配置 Wi-Fi 完成自动升级',
        )
        ..onBridgeCommand = (kind, payload) async {
          switch (kind) {
            case 'legacy_upgrade_open':
              return {
                'ok': true,
                'data': {
                  'deviceId': _legacyV1.id,
                  'name': _legacyV1.name,
                  'deviceKind': 'dyj_v1',
                  'currentVersion': '0.7.2',
                  'targetVersion': '0.8.15',
                  'wifiEnabled': true,
                  'wifiConnected': false,
                  'currentSsid': null,
                },
              };
            case 'legacy_upgrade_scan_wifi':
              return {
                'ok': true,
                'data': {
                  'networks': [
                    {
                      'ssid': 'CloudOS.com',
                      'rssi': -48,
                      'secure': true,
                      'connected': false,
                    },
                    {
                      'ssid': 'StudioGuest',
                      'rssi': -72,
                      'secure': false,
                      'connected': false,
                    },
                  ],
                  'currentSsid': null,
                },
              };
            case 'legacy_upgrade_connect_wifi':
              connectedWifiSsid = payload?['ssid'] as String?;
              connectedWifiPwd = payload?['password'] as String?;
              return {
                'ok': true,
                'data': {
                  'connected': true,
                  'ssid': connectedWifiSsid,
                  'ip': '192.168.31.57',
                },
              };
            case 'legacy_upgrade_close':
              return {'ok': true};
            default:
              throw CardException(CardErrorKind.unknown, 'unexpected $kind');
          }
        }
        ..onBridgeStream = (kind, payload, onFinal) async* {
          expect(kind, 'legacy_upgrade_run_ota');
          yield const CardProgress(
            stage: 'downloading',
            percent: 25,
            text: '正在下载新固件 27%…',
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          yield const CardProgress(
            stage: 'installing',
            percent: 84,
            text: '下载完成，正在静默安装新固件…',
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          gw.failConnect = null;
          gw.current = _upgraded0815Snapshot();
          onFinal?.call({
            'ok': true,
            'deviceId': _legacyV1.id,
            'name': _legacyV1.name,
            'targetVersion': '0.8.15',
          });
        }
        ..savedCredentials = [const CardWifiCredential(ssid: 'CloudOS.com')]
        ..mainOta = const CardOtaInfo(
          version: '0.8.15',
          versionCode: 815,
          url: 'https://hdd.dev.reai.com/ota/dyj1/app-815.apk',
          needUpdate: false,
          currentVersionCode: 815,
        );

      final device = DeviceStore(gateway: gw);
      await pumpShell(tester, device: device);

      // 1) 点开胶囊并点击旧固件 Q2M34R
      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('dev-item-dyj-q2m34r-legacy')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 主状态弹层应已收起，且未污染连接状态；独立升级弹层展示在 prompt 阶段
      expect(device.isConnected, isFalse);
      expect(device.sheetOpen, isFalse);
      expect(device.linkError, isNull);
      expect(find.byKey(const Key('legacy-upg-sheet')), findsOneWidget);
      expect(find.textContaining('v0.7.2'), findsOneWidget);
      expect(find.byKey(const Key('legacy-upg-start-wifi')), findsOneWidget);

      // 2) 点「设置 Wi-Fi 并自动升级」→ 打开旧会话并扫出 CloudOS.com
      await tester.tap(find.byKey(const Key('legacy-upg-start-wifi')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(device.legacyUpgrade.error, isNull);
      expect(find.byKey(const Key('legacy-upg-wifi-CloudOS.com')), findsOneWidget);
      expect(find.byKey(const Key('legacy-upg-pwd-input')), findsOneWidget);

      // 3) 输入 Wi-Fi 密码并触发自动配网升级
      await tester.enterText(
        find.byKey(const Key('legacy-upg-pwd-input')),
        '18503056146',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('legacy-upg-connect-btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(connectedWifiSsid, 'CloudOS.com');
      expect(connectedWifiPwd, '18503056146');

      // 等 OTA 流和自动重连完成
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 4) 独立升级层已自动收起，正常连接态已进入 v0.8.15 并展示状态面板
      expect(find.byKey(const Key('legacy-upg-sheet')), findsNothing);
      expect(device.isConnected, isTrue);
      expect(device.fwVersion, '0.8.15');
      expect(device.sheetOpen, isTrue);
      expect(find.byKey(const Key('fw-update')), findsOneWidget);
      await tester.tap(find.byKey(const Key('fw-update')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('0.8.15'), findsOneWidget);
      expect(find.byKey(const Key('fw-wifi-ver')), findsNothing);
      expect(gw.callLog, containsAllInOrder([
        'legacy_upgrade_open',
        'legacy_upgrade_scan_wifi',
        'legacy_upgrade_connect_wifi',
        'legacy_upgrade_run_ota',
      ]));
    },
  );

  testWidgets('配网失败可返回重设 Wi-Fi；点击「暂不升级」主动释放蓝牙会话', (tester) async {
    final gw = FakeCardGateway(devices: const [_legacyV1])
      ..failConnect = const CardException(
        CardErrorKind.device,
        'LEGACY_UPGRADE_REQUIRED|dyj_v1|0.7.2|0.8.12|需要升级',
      )
      ..onBridgeCommand = (kind, payload) async {
        switch (kind) {
          case 'legacy_upgrade_open':
            return {
              'ok': true,
              'data': {
                'deviceId': _legacyV1.id,
                'name': _legacyV1.name,
                'deviceKind': 'dyj_v1',
                'currentVersion': '0.7.2',
                'targetVersion': '0.8.15',
                'wifiEnabled': true,
                'wifiConnected': false,
              },
            };
          case 'legacy_upgrade_scan_wifi':
            return {
              'ok': true,
              'data': {
                'networks': [
                  {
                    'ssid': 'CloudOS.com',
                    'rssi': -50,
                    'secure': true,
                    'connected': false,
                  },
                ],
              },
            };
          case 'legacy_upgrade_connect_wifi':
            throw const CardException(CardErrorKind.device, 'Wi-Fi 密码错误');
          case 'legacy_upgrade_close':
            return {'ok': true};
          default:
            return {'ok': true};
        }
      };

    final device = DeviceStore(gateway: gw);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('dev-item-dyj-q2m34r-legacy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 先点「设置 Wi-Fi」再故意输错触发失败
    await tester.tap(find.byKey(const Key('legacy-upg-start-wifi')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.enterText(
      find.byKey(const Key('legacy-upg-pwd-input')),
      'wrong-pwd',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('legacy-upg-connect-btn')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byKey(const Key('legacy-upg-error')), findsOneWidget);
    expect(find.textContaining('Wi-Fi 密码错误'), findsOneWidget);

    // 点「返回重设 Wi-Fi」后点「取消」应调 legacy_upgrade_close 并隐藏弹窗
    await tester.tap(find.byKey(const Key('legacy-upg-back-wifi')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('legacy-upg-pwd-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('legacy-upg-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('legacy-upg-sheet')), findsNothing);
    expect(gw.callLog, contains('legacy_upgrade_close'));
  });
}
