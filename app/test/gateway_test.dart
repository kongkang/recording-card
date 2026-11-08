// 硬件网关契约测试 —— 真实 FFI 桥在测试进程里不可用（没有链接 card_bridge），
// 这里锁住两件**能确定**的事：
// 1) 错误分类与用户文案（界面据此区分「卡没开机」和「这台设备不支持」）；
// 2) 桥不可用时的 `UnsupportedCardGateway` 必须每个能力都显式失败，
//    绝不返回预置假数据冒充真实设备状态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';

/// 逐个调用网关的每个能力（名称 → 调用闭包）。
Map<String, Future<Object?> Function(CardGateway)> _ops() {
  return {
    'scan': (g) => g.scan(),
    'connect': (g) => g.connect('dev-1'),
    'snapshot': (g) => g.snapshot(),
    'record': (g) => g.record('toggle'),
    'mark': (g) => g.mark(),
    'files': (g) => g.files(),
    'download': (g) => g.download('a.apm', '/tmp'),
    'deleteFile': (g) => g.deleteFile('a.apm'),
    'transcode': (g) => g.transcode('/tmp/a.apm', '/tmp/a.wav'),
    'scanWifi': (g) => g.scanWifi(),
    'connectWifi': (g) => g.connectWifi('ssid', 'pwd'),
    'openWifi': (g) => g.openWifi(),
    'closeWifi': (g) => g.closeWifi(),
    'wifiCredentials': (g) => g.wifiCredentials(),
    'forgetWifi': (g) => g.forgetWifi('ssid'),
    'startSync': (g) => g.startSync(),
    'syncStatus': (g) => g.syncStatus(),
    'setUploadUrl': (g) => g.setUploadUrl('https://upload.invalid'),
    'otaInfo': (g) => g.otaInfo('main'),
    'syncTime': (g) => g.syncTime(),
    'disconnect': (g) => g.disconnect(),
  };
}

void main() {
  group('CardException 文案与分类', () {
    test('三个命名构造给出各自可读的中文文案', () {
      final unavailable = CardException.unavailable();
      expect(unavailable.kind, CardErrorKind.unavailable);
      expect(unavailable.message, '此设备不支持连接录音卡');

      final disconnected = CardException.disconnected();
      expect(disconnected.kind, CardErrorKind.disconnected);
      expect(disconnected.message, '录音卡未连接');

      final timeout = CardException.timeout();
      expect(timeout.kind, CardErrorKind.timeout);
      expect(timeout.message, '操作超时，请重试');
    });

    test('可携带设备侧原始错误文案，toString 带分类便于排障', () {
      const e = CardException(CardErrorKind.device, '固件返回 code=7');
      expect(e.message, '固件返回 code=7');
      expect(e.toString(), contains('device'));
      expect(e.toString(), contains('固件返回 code=7'));
    });
  });

  group('UnsupportedCardGateway（桥不可用）', () {
    const gateway = UnsupportedCardGateway();

    test('available 为 false，界面据此呈现「需要连接录音卡」', () {
      expect(gateway.available, isFalse);
    });

    test('每个能力都抛 unavailable，不返回任何假数据', () async {
      for (final entry in _ops().entries) {
        await expectLater(
          entry.value(gateway),
          throwsA(
            isA<CardException>().having(
              (e) => e.kind,
              'kind',
              CardErrorKind.unavailable,
            ),
          ),
          reason: '${entry.key} 必须显式失败',
        );
      }
    });

    test('两阶段 OTA 流以 unavailable 错误收场（而不是空流假装成功）', () async {
      for (final stream in [gateway.otaMain(), gateway.otaWifi()]) {
        await expectLater(
          stream.toList(),
          throwsA(
            isA<CardException>().having(
              (e) => e.kind,
              'kind',
              CardErrorKind.unavailable,
            ),
          ),
        );
      }
    });

    test('dispose 不抛（收尾永远安全）', () async {
      await gateway.dispose();
    });
  });

  group('设备回报的解析容错', () {
    test('CardSnapshot.fromJson：字段缺失/类型错都按 0 兜底，不崩', () {
      final snapshot = CardSnapshot.fromJson({
        'battery': {'level': 63, 'isCharging': true},
        'state': {'recording': true},
        'info': {'version': '2.1.0', 'versionCode': 21},
      });
      expect(snapshot.batteryLevel, 63);
      expect(snapshot.isCharging, isTrue);
      expect(snapshot.recording, isTrue);
      expect(snapshot.fwVersion, '2.1.0');
      expect(snapshot.fwVersionCode, 21);
      // 未回报的字段：空串 / 0，而不是编造
      expect(snapshot.wifiVersion, '');
      expect(snapshot.wifiVersionCode, 0);
      expect(snapshot.storageFreeMb, isNull);
    });

    test('CardOtaInfo.isNewerThan：只有 versionCode 更大才算有更新', () {
      const info = CardOtaInfo(version: '2.3.0', versionCode: 23, url: 'u');
      expect(info.isNewerThan(22), isTrue);
      expect(info.isNewerThan(23), isFalse);
      expect(info.isNewerThan(24), isFalse);
      const empty = CardOtaInfo(version: '', versionCode: 0, url: '');
      expect(empty.isNewerThan(0), isFalse, reason: '未查到固件信息时不能说「有更新」');
    });

    test('CardSyncStatus.fromJson：兼容 running 布尔与 state 字符串两种回报', () {
      expect(
        CardSyncStatus.fromJson({'running': true, 'pending': 3}).running,
        isTrue,
      );
      expect(
        CardSyncStatus.fromJson({'state': 'running'}).running,
        isTrue,
      );
      final idle = CardSyncStatus.fromJson({'uploaded': 5});
      expect(idle.running, isFalse);
      expect(idle.uploaded, 5);
    });

    test('CardWifiNetwork.fromJson：ssid/name 两种字段名都认，secured/lock 同理', () {
      final a = CardWifiNetwork.fromJson({'ssid': 'Home', 'rssi': -48});
      expect(a.ssid, 'Home');
      expect(a.rssi, -48);
      expect(a.secured, isFalse);
      final b = CardWifiNetwork.fromJson({'name': 'Office', 'lock': true});
      expect(b.ssid, 'Office');
      expect(b.secured, isTrue);
    });

    test('CardFile / CardProgress 解析缺字段不崩', () {
      expect(CardFile.fromJson({}).name, '');
      final p = CardProgress.fromJson({'percent': 40, 'text': '写入中'});
      expect(p.percent, 40);
      expect(p.text, '写入中');
      expect(p.stage, '');
    });

    test('CardOtaResult 解析终态', () {
      final r = CardOtaResult.fromJson({
        'module': 'main',
        'upToDate': true,
        'version': '2.2.0',
      });
      expect(r.module, 'main');
      expect(r.upToDate, isTrue);
      expect(r.version, '2.2.0');
    });
  });
}
