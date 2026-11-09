// 「仅使用 Wi-Fi 同步」策略的行为测试。
//
// 这个开关此前只有定义、没有消费者（打开也没效果），本测试锁住它真的会拦下载。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/network_policy.dart';

/// 固定结果的探测替身（不依赖真实网卡）。
class _FixedProbe implements NetworkProbe {
  const _FixedProbe(this.value);
  final bool value;

  @override
  Future<bool> isOnWifi() async => value;
}

void main() {
  group('NetworkPolicy', () {
    test('未开启「仅 Wi-Fi」：蜂窝也放行，并如实报告当前不是 Wi-Fi', () async {
      const policy = NetworkPolicy(probe: _FixedProbe(false));
      final d = await policy.check(wifiOnly: false);
      expect(d.allowed, isTrue);
      expect(d.isWifi, isFalse);
      expect(d.reason, isNull);
    });

    test('开启「仅 Wi-Fi」且在 Wi-Fi 上：放行', () async {
      const policy = NetworkPolicy(probe: _FixedProbe(true));
      final d = await policy.check(wifiOnly: true);
      expect(d.allowed, isTrue);
      expect(d.isWifi, isTrue);
    });

    test('开启「仅 Wi-Fi」但在蜂窝上：拦下，并给出可读原因', () async {
      const policy = NetworkPolicy(probe: _FixedProbe(false));
      final d = await policy.check(wifiOnly: true);
      expect(d.allowed, isFalse);
      expect(d.isWifi, isFalse);
      expect(d.reason, contains('仅使用 Wi-Fi 同步'));
    });
  });
}
