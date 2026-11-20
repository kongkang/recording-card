// 蓝牙扫描结果真实过期处理验收：
//
// 1. 弹层停留 60 秒后：BLE 列表保留但全部置灰 disabled（显示「已过期」），顶部提示过期、主按钮切为 FilledButton「重新扫描」；
// 2. 真实广播时间锚点：CardDevice.lastSeenAt 早于扫描完成 10 秒时，在扫描完成后第 50 秒即过期；
// 3. Apple Watch 走 WCSession 不受 BLE 扫描 TTL 影响，BLE 条目过期时 Watch 仍保持可点击连接；
// 4. 点「重新扫描」后恢复有效列表并可点击连接；
// 5. 切回前台校准：未超 60 秒按剩余真实墙钟重排定时器且不自动重扫；超过 60 秒切回前台自动触发重新扫描；
// 6. 直接调用 DeviceStore.connectTo 命中过期 BLE 设备也会被拦截，不触发底层建连；
// 7. 关闭弹层与卸载页面后定时器彻底释放，无悬挂定时器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';

CardSnapshot _connectedSnapshot(String id, String name) => CardSnapshot(
  batteryLevel: 82,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '2.2.0',
  fwVersionCode: 22,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: name,
  deviceId: id,
);

void main() {
  testWidgets('扫描列表保留且满 60 秒后 BLE 置灰过期，点击无效，「重新扫描」升为主按钮', (
    tester,
  ) async {
    var fakeNow = DateTime(2026, 11, 19, 18, 0, 0);
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -52),
        CardDevice(id: 'v1', name: 'DYJ_001A', rssi: -68),
      ],
    );
    final device = DeviceStore(gateway: gateway, now: () => fakeNow);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(gateway.scanCalls, 1);
    expect(find.byKey(const Key('dev-pick-hint')), findsOneWidget);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-v2'))).onTap,
      isNotNull,
    );
    expect(
      find.ancestor(
        of: find.text('重新扫描'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );

    // 59 秒时仍有效
    fakeNow = fakeNow.add(const Duration(seconds: 59));
    await tester.pump(const Duration(seconds: 59));
    expect(device.isBleScanExpired, isFalse);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-v2'))).onTap,
      isNotNull,
    );

    // 满 60 秒：列表保留但 disabled，显示「已过期」与提示文案
    fakeNow = fakeNow.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(device.isBleScanExpired, isTrue);
    expect(find.byKey(const Key('dev-scan-expired-hint')), findsOneWidget);
    expect(find.text('蓝牙设备列表已过期，请重新扫描'), findsOneWidget);
    expect(find.byKey(const Key('dev-expired-v2')), findsOneWidget);
    expect(find.byKey(const Key('dev-expired-v1')), findsOneWidget);
    expect(find.text('已过期'), findsNWidgets(2));
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-v2'))).onTap,
      isNull,
    );
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-v1'))).onTap,
      isNull,
    );

    // 点击已过期条目不会触发建连
    await tester.tap(find.byKey(const Key('dev-item-v2')));
    await tester.pump();
    expect(gateway.connectCalls, 0);
    expect(device.isConnected, isFalse);

    // 「重新扫描」升级为主要填充按钮
    expect(
      find.ancestor(
        of: find.text('重新扫描'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('关闭'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('使用真实广播时间戳 lastSeenAt 锚定 60 秒有效期', (tester) async {
    var fakeNow = DateTime(2026, 11, 19, 18, 0, 10);
    final gateway = FakeCardGateway(
      devices: [
        CardDevice(
          id: 'v2',
          name: 'DYJV2_9920',
          rssi: -50,
          lastSeenAt: fakeNow.subtract(const Duration(seconds: 10)),
        ),
      ],
    );
    final device = DeviceStore(gateway: gateway, now: () => fakeNow);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    // 广播发生在扫描完成前 10 秒，因此 49 秒时仍有效、50 秒时即过期
    fakeNow = fakeNow.add(const Duration(seconds: 49));
    await tester.pump(const Duration(seconds: 49));
    expect(device.isBleScanExpired, isFalse);
    expect(find.byKey(const Key('dev-expired-v2')), findsNothing);

    fakeNow = fakeNow.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(device.isBleScanExpired, isTrue);
    expect(find.byKey(const Key('dev-expired-v2')), findsOneWidget);
  });

  testWidgets('BLE 过期时 Apple Watch 保持可连接，且点「重新扫描」可恢复 BLE 列表', (
    tester,
  ) async {
    var fakeNow = DateTime(2026, 11, 19, 18, 0, 0);
    final watchService = WatchHardwareService(backend: FakeWatchBridgeBackend());
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -55)],
    );
    final device = DeviceStore(
      gateway: gateway,
      watchHardware: watchService,
      now: () => fakeNow,
    );
    await pumpShell(tester, device: device);
    await device.setWatchLinkEnabled(true);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-item-v2')), findsOneWidget);
    expect(
      find.byKey(const Key('dev-item-${WatchHardwareService.watchDeviceId}')),
      findsOneWidget,
    );

    // 60 秒后仅 BLE 设备过期，Apple Watch 保持可点击
    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));
    expect(find.byKey(const Key('dev-expired-v2')), findsOneWidget);
    expect(
      find.byKey(
        const Key('dev-expired-${WatchHardwareService.watchDeviceId}'),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<InkWell>(
            find.byKey(
              const Key('dev-item-${WatchHardwareService.watchDeviceId}'),
            ),
          )
          .onTap,
      isNotNull,
    );

    // 点击「重新扫描」刷新 BLE 列表后恢复可连，并能正常连接
    await tester.tap(find.byKey(const Key('dev-rescan')));
    await tester.pump();
    await tester.pump();
    expect(gateway.scanCalls, 2);
    expect(device.isBleScanExpired, isFalse);
    expect(find.byKey(const Key('dev-expired-v2')), findsNothing);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-v2'))).onTap,
      isNotNull,
    );

    gateway.current = _connectedSnapshot('v2', 'DYJV2_9920');
    await tester.tap(find.byKey(const Key('dev-item-v2')));
    await tester.pump();
    await tester.pump();
    expect(gateway.connectCalls, 1);
    expect(device.isConnected, isTrue);

    // 同时验证 Apple Watch 在 BLE 过期态下也可直接连接
    await device.disconnectDevice();
    await tester.pump();
    await tester.pump();
    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));
    expect(find.byKey(const Key('dev-expired-v2')), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('dev-item-${WatchHardwareService.watchDeviceId}')),
    );
    await tester.pump();
    await tester.pump();
    expect(device.isConnected, isTrue);
    expect(device.activeKind, DeviceKind.appleWatch);
  });

  testWidgets('切回前台校准：20 秒不自动重扫并按剩余 40 秒到期，超 60 秒立即自动重扫', (
    tester,
  ) async {
    var fakeNow = DateTime(2026, 11, 19, 18, 0, 0);
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -48)],
    );
    final device = DeviceStore(gateway: gateway, now: () => fakeNow);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    expect(gateway.scanCalls, 1);

    // 模拟锁屏 20 秒后回到前台（FakeAsync timer 没走、仅墙钟推进 20 秒）
    fakeNow = fakeNow.add(const Duration(seconds: 20));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(gateway.scanCalls, 1, reason: '未过期切回前台不应触发自动重扫');
    expect(device.isBleScanExpired, isFalse);

    // 定时器应被重排到剩余 40 秒
    fakeNow = fakeNow.add(const Duration(seconds: 39));
    await tester.pump(const Duration(seconds: 39));
    expect(device.isBleScanExpired, isFalse);
    fakeNow = fakeNow.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(device.isBleScanExpired, isTrue);

    // 先点重新扫描得到新列表，再模拟锁屏 120 秒后切回前台 → 自动重扫刷新
    await tester.tap(find.byKey(const Key('dev-rescan')));
    await tester.pump();
    await tester.pump();
    expect(gateway.scanCalls, 2);
    expect(device.isBleScanExpired, isFalse);

    fakeNow = fakeNow.add(const Duration(seconds: 120));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(gateway.scanCalls, 3, reason: '已过期切回前台应自动触发一次重扫');
    expect(device.isBleScanExpired, isFalse);
    expect(find.byKey(const Key('dev-expired-v2')), findsNothing);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('dev-item-v2'))).onTap,
      isNotNull,
    );
  });

  testWidgets('直接调用 connectTo 过期设备时显式拦截且不发底层建连；关闭弹层清理定时器', (
    tester,
  ) async {
    var fakeNow = DateTime(2026, 11, 19, 18, 0, 0);
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -50)],
    );
    final device = DeviceStore(gateway: gateway, now: () => fakeNow);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    fakeNow = fakeNow.add(const Duration(seconds: 65));
    await device.connectTo(device.discovered.single);
    expect(gateway.connectCalls, 0);
    expect(device.isConnected, isFalse);
    expect(device.linkError, contains('已过期'));

    // 关闭弹层后干净释放过期定时器，testWidgets 卸载无悬挂定时器报错
    await tester.tap(find.byKey(const Key('sheet-close')));
    await tester.pump();
    expect(device.sheetOpen, isFalse);
  });

  testWidgets('蓝牙通道关闭后重新扫描仍可点，并会再发起一次扫描', (tester) async {
    final gateway = FakeCardGateway(
      devices: const [CardDevice(id: 'v2', name: 'DYJV2_9920', rssi: -42)],
      scanError: const CardException(
        CardErrorKind.device,
        'BLE start_scan failed: Other("Channel closed")',
      ),
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    expect(find.text('蓝牙通道已断开，请点重新扫描'), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('dev-rescan')),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('dev-rescan')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(gateway.scanCalls, greaterThanOrEqualTo(2));
    expect(device.linkState, isNot(LinkState.scanning));
    expect(device.linkError, isNull);
    expect(device.discovered.single.id, 'v2');
    expect(find.byKey(const Key('dev-item-v2')), findsOneWidget);
  });
}
