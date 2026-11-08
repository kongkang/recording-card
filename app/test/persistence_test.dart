// 持久化验收（TDD 第一轮）——设计基线要求「路由栈与已生成总结卡同会话不丢」，
// 登录态 / 设置 / Wi-Fi 保存网络随进程重启保留。
//
// 说明：测试只依赖 KvStore 抽象 + MemoryKvStore，不触发平台通道；
// 生产实现（SharedPreferencesKvStore）在 main.dart 注入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/kv_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/services/auth_service.dart';
import 'test_transitions.dart';

SummaryCard _doneSummary(String id) => SummaryCard(id: id, time: '10:00')
  ..state = SummaryState.done
  ..title = '测试总结'
  ..srcIds = const ['e1'];

void main() {
  group('auth persistence', () {
    test('登录态写入 KvStore，新实例可恢复', () {
      final kv = MemoryKvStore();
      final first = AuthService(storage: kv);
      expect(first.signIn('kong', 'secret'), isNull);

      final restored = AuthService(storage: kv);
      expect(restored.isSignedIn, isTrue);
      expect(restored.session!.account, 'kong');
      expect(restored.session!.issuedAt, isA<DateTime>());
    });

    test('登出清除持久化会话', () {
      final kv = MemoryKvStore();
      AuthService(storage: kv).signIn('kong', 'secret');
      AuthService(storage: kv).signOut();

      expect(AuthService(storage: kv).isSignedIn, isFalse);
      expect(kv.getString(AuthService.storageKey), isNull);
    });

    test('损坏的会话 JSON 不崩溃，按未登录处理', () {
      final kv = MemoryKvStore({AuthService.storageKey: '{not-json'});
      final auth = AuthService(storage: kv);
      expect(auth.isSignedIn, isFalse);
    });
  });

  group('app state persistence', () {
    test('已生成总结与路由栈写入 KvStore，新实例可恢复', () {
      final kv = MemoryKvStore();
      final store = AppStore(storage: kv)..summaries = [_doneSummary('s1')];
      store.openSum('s1', fresh: true);

      final restored = AppStore(storage: kv);
      expect(restored.summaries.map((s) => s.id), ['s1']);
      expect(restored.summaries.single.title, '测试总结');
      expect(restored.stackTop, const RouteEntry('sum', 's1'));
    });

    test('pending / generating 不写入持久化', () {
      final kv = MemoryKvStore();
      final store = AppStore(storage: kv)
        ..summaries = [SummaryCard(id: 'p1', time: '11:00')];
      store.startSummary(); // 产生 pending action card
      store.cancelSummary();

      final restored = AppStore(storage: kv);
      expect(restored.summaries.where((s) => s.state != SummaryState.done),
          isEmpty);
    });

    test('损坏的路由 JSON 不崩溃，按空会话处理', () {
      final kv = MemoryKvStore({AppStore.storageKey: '[]'});
      final store = AppStore(storage: kv);
      expect(store.summaries, isEmpty);
      expect(store.subStack, isEmpty);
    });
  });

  group('settings persistence', () {
    test('默认值与切换后持久化', () {
      final kv = MemoryKvStore();
      final settings = SettingsStore(storage: kv);
      expect(settings.valueOf('持续录音'), isTrue);
      expect(settings.valueOf('仅 Wi-Fi 同步'), isFalse);

      settings.toggle('持续录音');
      settings.toggle('仅 Wi-Fi 同步');

      final restored = SettingsStore(storage: kv);
      expect(restored.valueOf('持续录音'), isFalse);
      expect(restored.valueOf('仅 Wi-Fi 同步'), isTrue);
    });

    test('损坏的 JSON 回落到默认值', () {
      final kv = MemoryKvStore({SettingsStore.storageKey: 'oops'});
      expect(SettingsStore(storage: kv).valueOf('持续录音'), isTrue);
    });
  });

  group('wifi persistence', () {
    testWidgets('新网络连接成功后保存列表与最后网络，重启可恢复', (tester) async {
      final kv = MemoryKvStore();
      final device = DeviceStore(
        gateway: const MockCardGateway(),
        storage: kv,
      );
      addTearDown(device.dispose);
      device.wifiScan();
      await tester.pump(const Duration(milliseconds: 1300));
      device.wifiPick('Office-2.4G');
      device.wifiJoinNew('demo-password');
      await tester.pump(const Duration(milliseconds: 1500));
      expect(device.wifiLast, 'Office-2.4G');

      final restored = DeviceStore(
        gateway: const MockCardGateway(),
        storage: kv,
      );
      addTearDown(restored.dispose);
      expect(restored.wifiSaved.map((w) => w.name), contains('Office-2.4G'));
      expect(restored.wifiLast, 'Office-2.4G');
    });

    testWidgets('已保存网络直连成功更新最后网络并持久化', (tester) async {
      final kv = MemoryKvStore();
      final device = DeviceStore(
        gateway: const MockCardGateway(),
        storage: kv,
      );
      addTearDown(device.dispose);
      device.wifiScan();
      await tester.pump(const Duration(milliseconds: 1300));
      device.wifiConnectSaved('Office-2.4G');
      await tester.pump(const Duration(milliseconds: 1300));
      expect(device.wifiLast, 'Office-2.4G');

      final restored = DeviceStore(
        gateway: const MockCardGateway(),
        storage: kv,
      );
      addTearDown(restored.dispose);
      expect(restored.wifiLast, 'Office-2.4G');
    });
  });

  group('startup restore', () {
    testWidgets('外壳启动时恢复持久化总结与路由栈', (tester) async {
      final kv = MemoryKvStore();
      final store = AppStore(storage: kv)..summaries = [_doneSummary('s1')];
      store.openSum('s1', fresh: true);

      final restored = AppStore(storage: kv);
      final device = DeviceStore(
        gateway: const MockCardGateway(),
        storage: kv,
      );
      addTearDown(device.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: AppShell(store: restored, device: device),
      ));
      await tester.pump();

      expect(restored.stackTop, const RouteEntry('sum', 's1'));
      expect(find.byKey(const Key('sum-title')), findsOneWidget);
    });

    testWidgets('Setting 页读取持久化开关状态', (tester) async {
      final kv = MemoryKvStore();
      SettingsStore(storage: kv).toggle('持续录音');
      final settings = SettingsStore(storage: kv);

      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(body: SettingPage(settings: settings)),
      ));
      final toggle = tester.widget<AnimatedContainer>(find.descendant(
        of: find.byKey(const Key('sw-0')),
        matching: find.byType(AnimatedContainer).first,
      ));
      expect((toggle.decoration as BoxDecoration).color, RCColors.ax);
    });
  });
}
