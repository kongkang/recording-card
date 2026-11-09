import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/status_sheet.dart';

import 'record_control_test.dart' as fixture;

Switch recordingSwitch(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(const Key('recording-switch')));

Future<void> mount(
  WidgetTester tester,
  DeviceStore store, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(store.dispose);
  // Open only the UI; tests call status/control explicitly, without a timer.
  store.sheetOpen = true;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(children: [StatusSheetOverlay(store: store)]),
      ),
    ),
  );
}

void main() {
  testWidgets('disconnected sheet hides unusable rows and keeps scan', (
    tester,
  ) async {
    // Unconnected: recording/battery/sync/Wi-Fi/firmware rows are meaningless,
    // so they are hidden instead of rendered disabled. Only scan/reconnect stay.
    final store = DeviceStore(
      backend: fixture.backend(),
      persistence: MemoryStorePersistence(),
    );
    await mount(tester, store);
    expect(find.byKey(const Key('recording-switch')), findsNothing);
    expect(find.byKey(const Key('rec-clock')), findsNothing);
    expect(find.byKey(const Key('batt-eta')), findsNothing);
    expect(find.byKey(const Key('sync-now')), findsNothing);
    expect(find.byKey(const Key('wifi-row')), findsNothing);
    expect(find.byKey(const Key('fw-update')), findsNothing);
    expect(find.byKey(const Key('device-scan')), findsOneWidget);
    expect(find.text('未连接'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet caps height and always exposes grabber and close', (
    tester,
  ) async {
    final store = DeviceStore(
      backend: fixture.backend(),
      persistence: MemoryStorePersistence(),
    );
    await mount(tester, store);
    // 80% of 844 with 390x844 viewport: the card must leave the status area free.
    final card = tester.getSize(find.byKey(const Key('sheet-card')));
    expect(card.height, lessThanOrEqualTo(844 * 0.8));
    expect(find.byKey(const Key('sheet-grabber')), findsOneWidget);
    expect(find.byKey(const Key('sheet-close-icon')), findsOneWidget);
    // Closing via the header icon must actually dismiss the sheet.
    await tester.tap(find.byKey(const Key('sheet-close-icon')));
    await tester.pump();
    expect(store.sheetOpen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('grabber close is locked only while firmware is updating', (
    tester,
  ) async {
    final store = DeviceStore(
      backend: fixture.backend(),
      persistence: MemoryStorePersistence(),
    );
    await mount(tester, store);
    store.fwUpdating = true;
    await tester.pump();
    await tester.tap(find.byKey(const Key('sheet-close-icon')));
    await tester.pump();
    // Firmware write in progress: the sheet must refuse to close.
    expect(store.sheetOpen, isTrue);
    store.fwUpdating = false;
    await tester.pump();
    await tester.tap(find.byKey(const Key('sheet-grabber')));
    await tester.pump();
    expect(store.sheetOpen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recording switch waits for confirmation then allows explicit stop',
    (tester) async {
      final start = Completer<DeviceReading>();
      final stop = Completer<DeviceReading>();
      var starts = 0;
      var stops = 0;
      final store = DeviceStore(
        backend: fixture.backend(
          start: () {
            starts++;
            return start.future;
          },
          stop: () {
            stops++;
            return stop.future;
          },
        ),
        persistence: MemoryStorePersistence(),
      );
      await store.connectDevice('transport');
      await mount(tester, store);
      final switchFinder = find.byKey(const Key('recording-switch'));
      expect(
        find.descendant(
          of: find.byKey(const Key('recval')),
          matching: switchFinder,
        ),
        findsOneWidget,
      );
      await tester.tap(switchFinder);
      await tester.pump();
      expect(starts, 1);
      expect(recordingSwitch(tester).value, isFalse);
      expect(recordingSwitch(tester).onChanged, isNull);
      expect(find.text('正在开始录音…'), findsOneWidget);
      start.complete(fixture.sample(true));
      await tester.pump();
      expect(recordingSwitch(tester).value, isTrue);
      expect(recordingSwitch(tester).onChanged, isNotNull);
      expect(find.text('录音中'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('rec-clock'))).data,
        '—:——:——',
      );
      await tester.tap(switchFinder);
      await tester.pump();
      expect(stops, 1);
      expect(recordingSwitch(tester).value, isTrue);
      stop.complete(fixture.sample(false));
      await tester.pump();
      expect(recordingSwitch(tester).value, isFalse);
      expect(find.text('未录音'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed control retains switch and shows readable red error', (
    tester,
  ) async {
    final store = DeviceStore(
      backend: fixture.backend(
        start: () async => throw StateError('设备拒绝：SD卡未挂载'),
      ),
      persistence: MemoryStorePersistence(),
    );
    await store.connectDevice('transport');
    await mount(tester, store);
    await tester.tap(find.byKey(const Key('recording-switch')));
    await tester.pump();
    expect(recordingSwitch(tester).value, isFalse);
    expect(recordingSwitch(tester).onChanged, isNull);
    expect(find.text('状态待确认'), findsOneWidget);
    final error = tester.widget<Text>(find.byKey(const Key('dev-state')));
    expect(error.data, contains('SD卡未挂载'));
    expect(error.style!.color, RCColors.danger);
    expect(store.connected, isTrue);
    await store.refreshFromDevice();
    await tester.pump();
    expect(recordingSwitch(tester).onChanged, isNotNull);
  });

  testWidgets(
    'transient refresh does not display fake disconnect or unknown battery',
    (tester) async {
      final store = DeviceStore(
        backend: fixture.backend(
          status: () async => throw TimeoutException('状态查询超时'),
        ),
        persistence: MemoryStorePersistence(),
      );
      await store.connectDevice('transport');
      await mount(tester, store);
      await store.refreshFromDevice();
      await tester.pump();
      expect(find.text('未连接'), findsNothing);
      expect(find.text('电量未知'), findsNothing);
      expect(find.text('电量高 · 上次读取'), findsOneWidget);
      expect(find.text('状态待确认'), findsOneWidget);
      expect(recordingSwitch(tester).onChanged, isNull);
      expect(
        tester.widget<Text>(find.byKey(const Key('dev-state'))).style!.color,
        RCColors.danger,
      );
    },
  );

  testWidgets('firmware failure is red and no manifest cannot enable update', (
    tester,
  ) async {
    final store = DeviceStore(
      backend: CallbackDeviceBackend(
        isAvailable: () => true,
        scanDevices: () async => [],
        connectDevice: (_) async => fixture.sample(false),
        readStatus: () async => fixture.sample(false),
        disconnectDevice: () async {},
        checkFirmware: () async => throw StateError('可信固件清单未提供'),
      ),
      persistence: MemoryStorePersistence(),
    );
    await store.connectDevice('transport');
    await store.checkFirmware();
    await mount(tester, store);
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-val'))).style!.color,
      RCColors.danger,
    );
    expect(find.text('更新检查失败'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('upg-state'))).style!.color,
      RCColors.danger,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('upg-btn'))).onPressed,
      isNull,
    );
  });

  testWidgets('no applicable firmware does not claim latest', (tester) async {
    final store = DeviceStore(
      backend: fixture.backend(),
      persistence: MemoryStorePersistence(),
    );
    await store.connectDevice('transport');
    await store.checkFirmware();
    await mount(tester, store);
    expect(find.text('已是最新'), findsNothing);
    expect(find.text('没有适用更新'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('fw-val'))).style!.color,
      RCColors.sec,
    );
  });

  for (final width in [320.0, 375.0, 390.0, 900.0]) {
    testWidgets(
      'recording row stays single-line without overflow at width $width',
      (tester) async {
        final store = DeviceStore(
          backend: fixture.backend(initiallyRecording: true),
          persistence: MemoryStorePersistence(),
        );
        await store.connectDevice('transport');
        await mount(tester, store, width: width);
        expect(find.byKey(const Key('recording-switch')), findsOneWidget);
        expect(
          tester
              .getRect(find.byKey(const Key('recording-switch')))
              .overlaps(tester.getRect(find.byKey(const Key('recval')))),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
