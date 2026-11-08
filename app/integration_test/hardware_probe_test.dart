// 真机硬件探针：在 iPhone 上验证 Rust 桥真的链进了二进制，并跑一次真实 BLE。
//
// 这是"硬件在环"的证据测试：它不 mock 任何东西——`RealCardGateway.maybe()` 只有在
// `card_bridge_command` 等符号真的在运行时动态表里可见时才会返回实例。
//
// 跑法：cd app && flutter test integration_test/hardware_probe_test.dart -d <deviceId>
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:recording_card/core/device/card_gateway.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('桥符号已链入（dlsym 可见）', (tester) async {
    final gateway = RealCardGateway.maybe();
    expect(
      gateway,
      isNotNull,
      reason: '静态库未链入或符号未导出：flutter run 时会永久走"不支持蓝牙"分支',
    );
    // ignore: avoid_print
    print('[probe] bridgeVersion = ${gateway!.bridgeVersion}');
    expect(gateway.bridgeVersion, contains('card_bridge/'));
  });

  testWidgets('真实扫描 / 连接 / 快照', (tester) async {
    final gateway = RealCardGateway.maybe();
    expect(gateway, isNotNull, reason: '桥未就绪');
    final bridge = gateway!;

    // 首次安装会弹系统蓝牙授权，用户点「允许」后才可能扫到；窗口给足
    final devices = await bridge.scan(timeoutMs: 12000);
    // ignore: avoid_print
    print('[probe] 扫到 ${devices.length} 台：'
        '${devices.map((d) => '${d.name}(${d.rssi}dBm)').join(', ')}');

    if (devices.isEmpty) {
      // 卡没开机/未广播属于环境问题，不算失败；但要在输出里说清楚
      // ignore: avoid_print
      print('[probe] 没有扫到录音卡：请确认录音卡已开机且未被其它主机占用');
      return;
    }

    final device = devices.first;
    final snapshot = await bridge.connect(device.id);
    // ignore: avoid_print
    print('[probe] 已连接 ${device.name}：电量 ${snapshot.batteryLevel}%'
        '（充电=${snapshot.isCharging}）固件 ${snapshot.fwVersion}'
        '/ WiFi ${snapshot.wifiVersion} 录音中=${snapshot.recording}');

    expect(snapshot.batteryLevel, greaterThan(0), reason: '真实电量应大于 0');
    expect(snapshot.fwVersion, isNotEmpty, reason: '主控固件版本应能读到');

    final files = await bridge.files();
    // ignore: avoid_print
    print('[probe] 设备上有 ${files.length} 个文件：'
        '${files.take(5).map((f) => '${f.name}(${f.size}B)').join(', ')}');

    await bridge.disconnect();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
