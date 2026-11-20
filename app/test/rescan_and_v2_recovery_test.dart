// 蓝牙「重新扫描」可点击性与 Channel closed / 重连打断恢复测试：
//
// 1. RealCardGateway 对底层 `Other("Channel closed")` / `PermissionDenied` / `PoweredOff` 做清晰中文映射；
// 2. 扫描失败后「重新扫描」按钮保持可点击，点击后可成功重扫并连接 V2；
// 3. 看门狗处于 `LinkState.reconnecting` 时打开弹层，展示「正在重连录音卡…」，且点「重新扫描」立即打断重连刷新设备列表。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

CardSnapshot _v2Snapshot() => const CardSnapshot(
  batteryLevel: 78,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '0.3.19',
  fwVersionCode: 319,
  wifiVersion: '0.1.3',
  wifiVersionCode: 103,
  deviceName: 'DYJV2_T4W25T',
  deviceId: 'v2-live',
);

void main() {
  test('RealCardGateway 将底层 Channel closed / 权限 / 开关错误映射为明确提示', () async {
    Future<String> captureError(String raw) async {
      final gw = RealCardGateway.forTesting(
        dispatch: (kind, payload, emit) {
          emit({'ok': false, 'error': raw, 'final': true});
        },
      );
      try {
        await gw.scan();
        fail('expected CardException');
      } on CardException catch (e) {
        return e.message;
      } finally {
        await gw.dispose();
      }
    }

    expect(
      await captureError('BLE start_scan failed: Other("Channel closed")'),
      '蓝牙扫描通道异常中断，请点击「重新扫描」重试',
    );
    expect(
      await captureError('BLE unavailable: PermissionDenied'),
      '未开启蓝牙权限，请在系统设置中允许「录音卡」使用蓝牙',
    );
    expect(
      await captureError('BLE start_scan failed: PoweredOff'),
      '系统蓝牙未开启，请打开蓝牙后重试',
    );
  });

  testWidgets('扫描报错 Channel closed 后「重新扫描」可点击并可恢复发现与连接 V2', (
    tester,
  ) async {
    final gateway = FakeCardGateway(
      failScan: const CardException(
        CardErrorKind.device,
        '蓝牙扫描通道异常中断，请点击「重新扫描」重试',
      ),
      devices: const [
        CardDevice(id: 'v2-live', name: 'DYJV2_T4W25T', rssi: -56),
      ],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(gateway.scanCalls, 1);
    expect(device.linkState, LinkState.disconnected);
    expect(find.byKey(const Key('dev-scan-empty')), findsOneWidget);
    expect(find.text('蓝牙扫描通道异常中断，请点击「重新扫描」重试'), findsOneWidget);

    final rescanBtn = tester.widget<OutlinedButton>(
      find.byKey(const Key('dev-rescan')),
    );
    expect(rescanBtn.onPressed, isNotNull, reason: '扫描报错后重新扫描按钮必须保持可点击');

    // 修复通道后点「重新扫描」，恢复发现并可连接 V2
    gateway.failScan = null;
    gateway.current = _v2Snapshot();

    await tester.tap(find.byKey(const Key('dev-rescan')));
    await tester.pump();
    await tester.pump();

    expect(gateway.scanCalls, 2);
    expect(find.byKey(const Key('dev-item-v2-live')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dev-item-v2-live')));
    await tester.pump();
    await tester.pump();

    expect(gateway.connectCalls, 1);
    expect(device.isConnected, isTrue);
    expect(device.connectedName, 'DYJV2_T4W25T');
  });

  testWidgets('处于 reconnecting 重连态时展示提示且点「重新扫描」可立即打断重连', (
    tester,
  ) async {
    final connectHold = Completer<CardSnapshot?>();
    final gateway = FakeCardGateway(
      initialSnapshot: _v2Snapshot(),
      devices: const [
        CardDevice(id: 'v2-live', name: 'DYJV2_T4W25T', rssi: -55),
      ],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await device.connectTo(
      const CardDevice(id: 'v2-live', name: 'DYJV2_T4W25T', rssi: -55),
    );
    expect(device.isConnected, isTrue);

    // 触发看门狗掉线重连，让后台 connect 卡在待定态使 linkState 停在 reconnecting
    gateway.connectOverride = (id, {name, deviceKind}) => connectHold.future;
    gateway.failSnapshot = CardException.disconnected();
    unawaited(device.refreshFromDevice());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(device.linkState, LinkState.reconnecting);

    // 打开弹层：必须看到「正在重连录音卡…」且「重新扫描」保持可点击
    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    expect(find.byKey(const Key('dev-reconnecting-state')), findsOneWidget);
    expect(find.text('正在重连录音卡…'), findsOneWidget);
    final rescanBtn = tester.widget<OutlinedButton>(
      find.byKey(const Key('dev-rescan')),
    );
    expect(rescanBtn.onPressed, isNotNull, reason: '重连中仍应允许用户点重新扫描');

    // 点击「重新扫描」立即打断后台重连等待并发起真实扫描
    gateway.connectOverride = null;
    await tester.tap(find.byKey(const Key('dev-rescan')));
    await tester.pump();
    await tester.pump();

    expect(gateway.scanCalls, 1);
    expect(device.linkState, LinkState.disconnected);
    expect(find.byKey(const Key('dev-item-v2-live')), findsOneWidget);

    if (!connectHold.isCompleted) {
      connectHold.complete(null);
    }
  });

  testWidgets('多卡同场时主控 DFU 重启与失败恢复绝不串连旁边其它 DYJV2 卡', (
    tester,
  ) async {
    const mine = CardDevice(id: 'v2-mine', name: 'DYJV2_MINE', rssi: -68);
    const neighbor = CardDevice(
      id: 'v2-neighbor',
      name: 'DYJV2_NEIGHBOR',
      rssi: -50,
    );
    final oldSnap = const CardSnapshot(
      batteryLevel: 80,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '0.3.9',
      fwVersionCode: 309,
      wifiVersion: '0.1.4',
      wifiVersionCode: 104,
      deviceName: 'DYJV2_MINE',
      deviceId: 'v2-mine',
    );
    final updatedSnap = const CardSnapshot(
      batteryLevel: 80,
      isCharging: false,
      wifiOpen: false,
      recording: false,
      fwVersion: '0.3.19',
      fwVersionCode: 319,
      wifiVersion: '0.1.4',
      wifiVersionCode: 104,
      deviceName: 'DYJV2_MINE',
      deviceId: 'v2-mine',
    );

    final gw = _MultiCardOtaScanGateway(
      initialSnapshot: oldSnap,
      postMainOtaSnapshot: updatedSnap,
      neighbor: neighbor,
      mine: mine,
    );

    final store = DeviceStore(gateway: gw);
    addTearDown(store.dispose);
    await store.connectTo(mine);
    await store.checkFirmware();
    expect(store.mainNeedsUpdate, isTrue);

    final done = store.startFwUpdate();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    await done;

    expect(gw.scanCalls, greaterThanOrEqualTo(2));
    expect(
      gw.connectedIds.where((id) => id == neighbor.id),
      isEmpty,
      reason: '第 1 次扫描虽有邻居卡在场，也绝不能串连到 DYJV2_NEIGHBOR',
    );
    expect(store.fwStage, FwStage.done);
    expect(store.connectedName, 'DYJV2_MINE');
    expect(store.fwVersionCode, 319);
  });

  test('RealCardGateway.tryBindFromPlatformChannel 解析原生函数指针表并缓存单实例', () async {
    RealCardGateway.resetInstanceForTesting();
    addTearDown(RealCardGateway.resetInstanceForTesting);

    const testChannel = MethodChannel('com.reai.recordingcard/bluetooth');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(testChannel, (call) async {
          if (call.method == 'bridgeSymbols') {
            return <String, Object>{
              'command': '4393348640',
              'free': '4393348688',
              'version': '4393348672',
            };
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, null);
    });

    int? boundCmd;
    int? boundFree;
    int? boundVer;
    final channelBound = await RealCardGateway.tryBindFromPlatformChannel(
      channelOverride: testChannel,
      factoryOverride: ({
        required int commandAddress,
        required int freeAddress,
        required int versionAddress,
      }) {
        boundCmd = commandAddress;
        boundFree = freeAddress;
        boundVer = versionAddress;
        return RealCardGateway.forTesting(
          dispatch: (kind, payload, emit) {
            emit({'ok': true, 'data': const {}, 'final': true});
          },
        );
      },
    );
    expect(channelBound, isNotNull);
    expect(boundCmd, 4393348640);
    expect(boundFree, 4393348688);
    expect(boundVer, 4393348672);
  });

  testWidgets('符号剥离落入 Unsupported 后点击「重新扫描」可自愈重绑并恢复扫描连接 V2', (
    tester,
  ) async {
    // 模拟启动时 DynamicLibrary.process().lookup 失败导致落入 UnsupportedCardGateway（报此设备不支持连接录音卡），
    // 随后的恢复钩子模拟通过原生地址表取回可用网关，点「重新扫描」必须恢复发现并可连接 V2。
    var allowRecover = false;
    final recoveredGw = FakeCardGateway(
      initialSnapshot: _v2Snapshot(),
      devices: const [
        CardDevice(id: 'v2-live', name: 'DYJV2_T4W25T', rssi: -52),
      ],
    );
    final device = DeviceStore(
      gateway: const UnsupportedCardGateway(),
      nativeBridgeRecovery: () async => allowRecover ? recoveredGw : null,
    );
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(device.linkState, LinkState.unsupported);
    expect(find.text('此设备不支持连接录音卡'), findsOneWidget);

    allowRecover = true;
    await tester.tap(find.byKey(const Key('dev-rescan')));
    await tester.pump();
    await tester.pump();

    expect(device.liveDeviceAvailable, isTrue);
    expect(recoveredGw.scanCalls, 1);
    expect(find.byKey(const Key('dev-item-v2-live')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dev-item-v2-live')));
    await tester.pump();
    await tester.pump();

    expect(device.isConnected, isTrue);
    expect(device.connectedName, 'DYJV2_T4W25T');
  });
}

class _MultiCardOtaScanGateway extends FakeCardGateway {
  _MultiCardOtaScanGateway({
    required super.initialSnapshot,
    required CardSnapshot super.postMainOtaSnapshot,
    required this.neighbor,
    required this.mine,
  }) : super(
         devices: [neighbor, mine],
         mainOta: const CardOtaInfo(
           version: '0.3.19',
           versionCode: 319,
           url: 'https://ota.invalid/main_319.zip',
         ),
         wifiOta: const CardOtaInfo(
           version: '0.1.4',
           versionCode: 104,
           url: 'https://ota.invalid/wifi_104.bin',
         ),
         progressDelay: Duration.zero,
       );

  final CardDevice neighbor;
  final CardDevice mine;
  final List<String> connectedIds = [];

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async {
    scanCalls++;
    callLog.add('scan');
    // 第 1 次重启扫描时只有旁边的邻居卡在广播，本卡尚未完成重启；第 2 次扫描本卡上线
    if (scanCalls == 1) {
      return [neighbor];
    }
    return [neighbor, mine];
  }

  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) {
    connectedIds.add(deviceId);
    return super.connect(deviceId, name: name, deviceKind: deviceKind);
  }
}
