import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';

import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _SpyPhoneMicBackend implements PhoneMicBackend {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    startCalls++;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls++;
  }
}

const _cardV2Device = CardDevice(
  id: 'card-v2-1',
  name: 'DYJV2_T4W25T',
  rssi: -52,
  kind: DeviceKind.cardV2,
  capabilities: HardwareCapabilities.cardV2,
);

CardSnapshot _cardV2Snapshot({bool recording = false}) => CardSnapshot(
  batteryLevel: 88,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '0.3.10',
  fwVersionCode: 310,
  wifiVersion: '1.5.0',
  wifiVersionCode: 15,
  deviceName: 'DYJV2_T4W25T',
  deviceId: 'card-v2-1',
  deviceKind: DeviceKind.cardV2,
  capabilities: HardwareCapabilities.cardV2,
);

CardSnapshot _dyjV1Snapshot() => const CardSnapshot(
  batteryLevel: 80,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '0.8.15',
  fwVersionCode: 815,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_RA6BO5',
  deviceId: 'dyj-v1-1',
  deviceKind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

CardSnapshot _boardV21Snapshot() => const CardSnapshot(
  batteryLevel: 100,
  isCharging: true,
  wifiOpen: false,
  recording: false,
  fwVersion: '2.1.0',
  fwVersionCode: 210,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'REAI_VB_A91C',
  deviceId: 'board-v21-1',
  deviceKind: DeviceKind.boardV21,
  capabilities: HardwareCapabilities.boardV21,
);

CardSnapshot _omiSnapshot() => const CardSnapshot(
  batteryLevel: 76,
  isCharging: false,
  wifiOpen: false,
  recording: false,
  fwVersion: '2.0.5',
  fwVersionCode: 205,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'Omi-1234',
  deviceId: 'omi-1',
  deviceKind: DeviceKind.omiCv1,
  capabilities: HardwareCapabilities.omiCv1,
);

Future<void> _pumpSheet(
  WidgetTester tester,
  DeviceStore store, {
  AgentConfigStore? agentConfig,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      home: Scaffold(
        body: Stack(
          children: [
            StatusSheetOverlay(store: store, agentConfig: agentConfig),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('按键外侧摘要简洁展示（「已设置 N 项」）', () {
    testWidgets('外侧仅展示已设置项数，修改详情中的动作后会同步变化', (tester) async {
      final cfg = AgentConfigStore(store: InMemoryStore());
      addTearDown(cfg.dispose);
      await cfg.load();

      // 1) CardV2 默认 5 项（单击/双击/长按/拨杆开/拨杆关）
      final cardStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _cardV2Snapshot()),
      );
      addTearDown(cardStore.dispose);
      await cardStore.restoreLink();
      cardStore.openSheet();

      await _pumpSheet(tester, cardStore, agentConfig: cfg);
      expect(find.byKey(const Key('btn-config')), findsOneWidget);
      expect(find.byKey(const Key('btn-config-val')), findsOneWidget);
      expect(find.text('已设置 5 项'), findsOneWidget);
      expect(find.textContaining('双击同步'), findsNothing);
      expect(find.textContaining('拨杆开录'), findsNothing);

      // 进入详情页把单击改回「无动作」，返回外侧变为「已设置 4 项」
      await tester.tap(find.byKey(const Key('btn-config')));
      await tester.pump();
      expect(find.byKey(const Key('btn-config-view')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-cfg-click-none')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn-cfg-back')));
      await tester.pump();
      expect(find.text('已设置 4 项'), findsOneWidget);

      // 2) DyjV1 默认 3 项（单击/长按/双击）
      final dyjStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _dyjV1Snapshot()),
      );
      addTearDown(dyjStore.dispose);
      await dyjStore.restoreLink();
      dyjStore.openSheet();

      await _pumpSheet(tester, dyjStore, agentConfig: cfg);
      expect(find.text('已设置 3 项'), findsOneWidget);

      // 3) Omi 默认 2 项（单击/双击）
      final omiStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _omiSnapshot()),
      );
      addTearDown(omiStore.dispose);
      await omiStore.restoreLink();
      omiStore.openSheet();

      await _pumpSheet(tester, omiStore, agentConfig: cfg);
      expect(find.text('已设置 2 项'), findsOneWidget);
    });
  });

  group('「更多」菜单与重启 / 关机能力门控', () {
    testWidgets('按硬件能力展示更多入口与重启/关机按钮', (tester) async {
      // CardV2：展示「更多」，内含「重启设备」和「关机」
      final cardStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _cardV2Snapshot()),
      );
      addTearDown(cardStore.dispose);
      await cardStore.restoreLink();
      cardStore.openSheet();

      await _pumpSheet(tester, cardStore);
      expect(find.byKey(const Key('more-row')), findsOneWidget);
      await tester.tap(find.byKey(const Key('more-row')));
      await tester.pump();
      expect(find.byKey(const Key('more-view')), findsOneWidget);
      expect(find.byKey(const Key('more-restart-btn')), findsOneWidget);
      expect(find.byKey(const Key('more-shutdown-btn')), findsOneWidget);

      await tester.tap(find.byKey(const Key('more-back')));
      await tester.pump();
      expect(find.byKey(const Key('dev-main')), findsOneWidget);

      // DyjV1：仅支持远程重启，展示「重启设备」，隐藏「关机」
      final dyjStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _dyjV1Snapshot()),
      );
      addTearDown(dyjStore.dispose);
      await dyjStore.restoreLink();
      dyjStore.openSheet();

      await _pumpSheet(tester, dyjStore);
      expect(find.byKey(const Key('more-row')), findsOneWidget);
      await tester.tap(find.byKey(const Key('more-row')));
      await tester.pump();
      expect(find.byKey(const Key('more-restart-btn')), findsOneWidget);
      expect(find.byKey(const Key('more-shutdown-btn')), findsNothing);

      // BoardV21 & Omi：隐藏「更多」
      final boardStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _boardV21Snapshot()),
      );
      addTearDown(boardStore.dispose);
      await boardStore.restoreLink();
      boardStore.openSheet();
      await _pumpSheet(tester, boardStore);
      expect(find.byKey(const Key('more-row')), findsNothing);

      final omiStore = DeviceStore(
        gateway: FakeCardGateway(initialSnapshot: _omiSnapshot()),
      );
      addTearDown(omiStore.dispose);
      await omiStore.restoreLink();
      omiStore.openSheet();
      await _pumpSheet(tester, omiStore);
      expect(find.byKey(const Key('more-row')), findsNothing);
    });

    testWidgets('重启设备确认后发 device.restart、不触发手机保底并自动重连清空 -2 错误', (
      tester,
    ) async {
      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(recording: true),
        devices: const [_cardV2Device],
      );
      final mic = _SpyPhoneMicBackend();
      final store = DeviceStore(
        gateway: gw,
        phoneMicBackend: mic,
        restartReconnectDelay: Duration.zero,
      );
      addTearDown(store.dispose);
      await store.connectTo(_cardV2Device);
      store.recordingError = RealCardGateway.friendlyDeviceErrorForTest(
        'code: -2 message: 录音启动失败',
      );
      store.openSheet();

      await _pumpSheet(tester, store);
      expect(find.byKey(const Key('rec-error')), findsOneWidget);

      await tester.tap(find.byKey(const Key('more-row')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('more-restart-btn')));
      await tester.pumpAndSettle();

      // 先测取消不会下发指令
      await tester.tap(find.byKey(const Key('restart-cancel')));
      await tester.pumpAndSettle();
      expect(gw.restartCalls, 0);

      // 再确认重启（模拟重启后硬件处于待机态）
      gw.connectResult = _cardV2Snapshot(recording: false);
      await tester.tap(find.byKey(const Key('more-restart-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restart-confirm')));
      await tester.pumpAndSettle();

      expect(gw.restartCalls, 1);
      expect(gw.disconnectCalled, isTrue);
      expect(mic.startCalls, 0);
      expect(store.isPhoneRecording, isFalse);
      expect(store.isConnected, isTrue);
      expect(store.recordingError, isNull);
      expect(store.view, DeviceView.main);
      expect(store.devStateText, '设备已重启并重新连接');
      expect(find.byKey(const Key('dev-state')), findsOneWidget);
      expect(find.byKey(const Key('rec-error')), findsNothing);
    });

    testWidgets('重启命令被拒绝时停留在「更多」并就地显示错误，不强行断连', (
      tester,
    ) async {
      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(),
        devices: const [_cardV2Device],
      )..failRestart = const CardException(CardErrorKind.device, '重启被拒绝');
      final store = DeviceStore(
        gateway: gw,
        restartReconnectDelay: Duration.zero,
      );
      addTearDown(store.dispose);
      await store.connectTo(_cardV2Device);
      store.openSheet();

      await _pumpSheet(tester, store);
      await tester.tap(find.byKey(const Key('more-row')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('more-restart-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restart-confirm')));
      await tester.pumpAndSettle();

      expect(gw.restartCalls, 1);
      expect(store.isConnected, isTrue);
      expect(store.view, DeviceView.more);
      expect(find.byKey(const Key('more-power-error')), findsOneWidget);
      expect(find.textContaining('重启被拒绝'), findsOneWidget);
    });

    testWidgets('重启后三次自动重连均失败时回落未连接提示', (tester) async {
      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(),
        devices: const [_cardV2Device],
      );
      final mic = _SpyPhoneMicBackend();
      final store = DeviceStore(
        gateway: gw,
        phoneMicBackend: mic,
        restartReconnectDelay: Duration.zero,
      );
      addTearDown(store.dispose);
      await store.connectTo(_cardV2Device);
      gw.failConnect = const CardException(CardErrorKind.disconnected, '未开机');
      store.openSheet();

      await _pumpSheet(tester, store);
      await tester.tap(find.byKey(const Key('more-row')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('more-restart-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restart-confirm')));
      await tester.pumpAndSettle();

      expect(gw.restartCalls, 1);
      expect(store.linkState, LinkState.disconnected);
      expect(store.linkError, '设备已重启，请点击重新连接');
      expect(mic.startCalls, 0);
      expect(store.isPhoneRecording, isFalse);
      expect(find.text('设备已重启，请点击重新连接'), findsOneWidget);
    });

    testWidgets('关机确认后发 device.shutdown、不触发手机保底并安全断开', (tester) async {
      final gw = FakeCardGateway(
        initialSnapshot: _cardV2Snapshot(recording: true),
        devices: const [_cardV2Device],
      );
      final mic = _SpyPhoneMicBackend();
      final store = DeviceStore(gateway: gw, phoneMicBackend: mic);
      addTearDown(store.dispose);
      await store.connectTo(_cardV2Device);
      store.openSheet();

      await _pumpSheet(tester, store);
      await tester.tap(find.byKey(const Key('more-row')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('more-shutdown-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shutdown-confirm')));
      await tester.pumpAndSettle();

      expect(gw.shutdownCalls, 1);
      expect(gw.disconnectCalled, isTrue);
      expect(mic.startCalls, 0);
      expect(store.isPhoneRecording, isFalse);
      expect(store.isConnected, isFalse);
      expect(store.linkError, isNull);
      expect(store.view, DeviceView.main);
    });
  });

  group('能力矩阵与 -2 错误文案映射', () {
    test('HardwareCapabilities.fromJson 正确解析 hasDeviceRestart/hasDeviceShutdown', () {
      final cardCaps = HardwareCapabilities.fromJson(const {
        'realtimeAudio': true,
        'hasOnboardStorage': true,
        'hasFileSync': true,
        'hasWifiConfig': true,
        'hasCameraMedia': false,
        'hasPhysicalRecordToggle': true,
        'hasRemoteRecordControl': true,
        'hasMarkButton': true,
        'hasDeviceRestart': true,
        'hasDeviceShutdown': true,
        'otaMode': 'dual_chip',
      }, fallbackKind: DeviceKind.cardV2);
      expect(cardCaps.hasDeviceRestart, isTrue);
      expect(cardCaps.hasDeviceShutdown, isTrue);
      expect(cardCaps.hasMoreDeviceActions, isTrue);

      final dyjCaps = HardwareCapabilities.forKind(DeviceKind.dyjV1);
      expect(dyjCaps.hasDeviceRestart, isTrue);
      expect(dyjCaps.hasDeviceShutdown, isFalse);
      expect(dyjCaps.hasMoreDeviceActions, isTrue);

      final omiCaps = HardwareCapabilities.forKind(DeviceKind.omiCv1);
      expect(omiCaps.hasMoreDeviceActions, isFalse);
    });

    test('code -2 包含「录音启动失败」时提示在「更多」重启设备', () {
      final msg = RealCardGateway.friendlyDeviceErrorForTest(
        'code: -2, message: 录音启动失败',
      );
      expect(msg, '录音卡启动录音失败，可在「更多」中重启设备后重试（设备错误码 -2）');

      final generic = RealCardGateway.friendlyDeviceErrorForTest(
        'code: -2, message: invalid param',
      );
      expect(generic, '录音卡拒绝了这条命令（设备错误码 -2）');
    });
  });
}
