import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/export/export_service.dart';

const record = RecordEvent(
  id: 'real-test-1',
  dayOffset: 0,
  title: '独立测试录音',
  brief: '非样例内容',
  longText: '讨论真实预算与下次检查',
  time: '09:00',
  dur: '8秒',
  speakers: '未知',
  mark: '',
  srcMap: '来源 00:00—00:08',
  dialog: [TurnLine('未知', '清洗后的内容', '来源 00:00—00:08')],
  raw: [TurnLine('未知', '嗯，原始预算是<&>中文终点', '来源 00:00—00:08')],
);
SummaryCard completed(SummaryCard target) => target
  ..state = SummaryState.done
  ..title = '独立预算总结'
  ..overview = '预算必须经过审核。'
  ..subDesc = '1 条记录'
  ..structure = [
    const MapBranch('预算', ['审核', '确认']),
  ]
  ..points = [
    const InfoPoint('预算审核', '保留来源事实。', [
      SourceRef('real-test-1', '独立测试录音', '00:00—00:08'),
    ]),
  ]
  ..todos = ['周五复查预算'];
CallbackAppBackend appBackend({
  Future<SummaryCard> Function(
    List<RecordEvent>,
    SummaryCard,
    RecordingPolicy,
    ProgressSink,
  )?
  generate,
  Future<void> Function(RecordingPolicy)? apply,
}) => CallbackAppBackend(
  load: () async => [record],
  apply: apply ?? (_) async {},
  generate:
      generate ?? (events, target, policy, progress) async => completed(target),
);
const snapshot = CardSnapshot(
  batteryLevel: 55,
  isCharging: false,
  wifiOpen: true,
  recording: true,
  fwVersion: '1',
  wifiVersion: '1',
);
CallbackDeviceBackend deviceBackend({
  Future<void> Function(RecordingPolicy, ProgressSink)? sync,
  Future<void> Function(FirmwareOffer, FirmwareConsent, ProgressSink)? install,
  Future<void> Function(String, String)? join,
}) => CallbackDeviceBackend(
  isAvailable: () => true,
  scanDevices: () async => [const DeviceChoice('test-card', '测试卡')],
  connectDevice: (id) async =>
      const DeviceReading(snapshot, id: 'test-card', recordedSeconds: 3),
  readStatus: () async => const DeviceReading(
    snapshot,
    id: 'test-card',
    recordedSeconds: 3,
    connectedWifi: '测试网络',
  ),
  disconnectDevice: () async {},
  synchronize: sync,
  listSavedWifi: () async => [const SavedWifi('测试网络')],
  scanNetworks: () async => [
    const WifiNet('测试网络', 3, lock: true, frequencyMhz: 2412),
  ],
  joinNetwork: join,
  connectSavedNetwork: (_) async {},
  checkFirmware: () async => const FirmwareOffer(
    packageId: 'test-package',
    deviceId: 'test-card',
    targetMainVersion: '2',
    targetWifiVersion: '2',
    checksum:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    notes: '测试包',
  ),
  installFirmware: install,
);

void main() {
  test(
    'production is empty; unavailable service is an explicit error',
    () async {
      final store = AppStore(persistence: MemoryStorePersistence());
      addTearDown(store.dispose);
      expect(store.events, isEmpty);
      await store.initialize();
      expect(store.error, contains('服务未配置'));
      expect(store.settingError, isNotNull);
      expect(store.summaries, isEmpty);
    },
  );
  testWidgets(
    'generation is awaited, not six-second success; only selected sources',
    (tester) async {
      final gate = Completer<SummaryCard>();
      List<RecordEvent>? selected;
      final store = AppStore(
        events: [record],
        persistence: MemoryStorePersistence(),
        backend: appBackend(
          generate: (events, target, policy, sink) {
            selected = events;
            sink(const TaskProgress('真实请求中'));
            return gate.future;
          },
        ),
      );
      addTearDown(store.dispose);
      store.startSummary();
      store.toggleSel(record.id);
      final target = store.pend!;
      final future = store.genSummary();
      expect(store.isGenerating(target.id), isTrue);
      expect(selected!.single.id, record.id);
      expect(store.generationPercent(target.id), isNull);
      await tester.pump(const Duration(seconds: 7));
      expect(target.state, SummaryState.generating);
      expect(store.isGenerating(target.id), isTrue);
      gate.complete(completed(target));
      await future;
      expect(store.summaryById(target.id)!.state, SummaryState.done);
      expect(store.stackTop!.id, target.id);
      expect(store.summaryErrors, isEmpty);
    },
  );
  test(
    'failure survives restart; retry can complete and actions/routes persist',
    () async {
      var failing = true;
      final memory = MemoryStorePersistence();
      final backend = appBackend(
        generate: (events, target, policy, sink) async {
          if (failing) throw StateError('服务断开');
          return completed(target);
        },
      );
      final store = AppStore(
        events: [record],
        backend: backend,
        persistence: memory,
      );
      addTearDown(store.dispose);
      store.startSummary();
      store.toggleSel(record.id);
      await store.genSummary();
      final id = store.pend!.id;
      expect(store.summaryErrors[id], contains('服务断开'));
      await store.flushPersistence();
      final restored = AppStore(backend: backend, persistence: memory)
        ..restoreState(await memory.load());
      addTearDown(restored.dispose);
      expect(restored.summaryErrors[id], isNotNull);
      failing = false;
      await restored.retrySummary(id);
      restored.toggleTodo(id, 0);
      restored.setSummaryTab(id, 'pt');
      restored.setPointsExpanded(id, {0});
      restored.openDetail(record.id);
      await restored.flushPersistence();
      final again = AppStore(persistence: memory)
        ..restoreState(await memory.load());
      addTearDown(again.dispose);
      expect(again.todosDone(id), {0});
      expect(again.summaryTab(id), 'pt');
      expect(again.pointsExpanded(id), {0});
      expect(again.stackTop, RouteEntry('detail', record.id));
    },
  );
  test('non-selected source result is rejected', () async {
    final store = AppStore(
      events: [record],
      persistence: MemoryStorePersistence(),
      backend: appBackend(
        generate: (events, target, policy, sink) async =>
            completed(target)..srcIds = ['foreign-record'],
      ),
    );
    addTearDown(store.dispose);
    store.startSummary();
    store.toggleSel(record.id);
    await store.genSummary();
    expect(store.summaryErrors[store.pend!.id], contains('非所选来源'));
  });
  test(
    'six settings applied and durable; failed apply leaves old policy',
    () async {
      var failure = false;
      final policies = <RecordingPolicy>[];
      final memory = MemoryStorePersistence();
      final store = AppStore(
        backend: appBackend(
          apply: (p) async {
            if (failure) throw StateError('未连接');
            policies.add(p);
          },
        ),
        persistence: memory,
      );
      addTearDown(store.dispose);
      for (var i = 0; i < 6; i++) {
        await store.toggleSetting(i);
      }
      expect(policies.length, 6);
      expect(store.policy.values, [false, false, false, false, false, true]);
      await store.flushPersistence();
      final restored = AppStore(persistence: memory)
        ..restoreState(await memory.load());
      addTearDown(restored.dispose);
      expect(restored.policy.values, store.policy.values);
      failure = true;
      await store.toggleSetting(0);
      expect(store.policy.continuousRecording, isFalse);
      expect(store.settingError, isNotNull);
    },
  );
  testWidgets(
    'device sync does not report success before completion, OTA requires exact consent',
    (tester) async {
      final gate = Completer<void>();
      var installs = 0;
      final store = DeviceStore(
        backend: deviceBackend(
          sync: (policy, sink) => gate.future,
          install: (offer, consent, sink) async {
            installs++;
          },
        ),
        persistence: MemoryStorePersistence(),
      );
      addTearDown(store.dispose);
      expect(store.connected, isFalse);
      expect(store.batteryKnown, isFalse);
      expect(store.recClockText, contains('—'));
      await store.scanDevices();
      await store.connectDevice('test-card');
      expect(store.recSeconds, 3);
      final sync = store.syncNow();
      await tester.pump(const Duration(seconds: 7));
      expect(store.syncState, SyncState.busy);
      gate.complete();
      await sync;
      expect(store.syncState, SyncState.done);
      await store.checkFirmware();
      await store.startFwUpdate();
      expect(installs, 0);
      await store.startFwUpdate(
        consent: const FirmwareConsent(
          packageId: 'wrong',
          deviceId: 'test-card',
          checksum: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      );
      expect(installs, 0);
      await tester.pump(const Duration(seconds: 11));
      await store.startFwUpdate(
        consent: const FirmwareConsent(
          packageId: 'test-package',
          deviceId: 'test-card',
          checksum: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      );
      expect(installs, 1);
      expect(
        store.fwDone,
        isFalse,
        reason: 'Version did not change, no fake OTA success',
      );
      expect(store.fwStateText, contains('版本校验'));
    },
  );
  test(
    'WiFi requires verified snapshot and never stores password in UI',
    () async {
      var called = false;
      final store = DeviceStore(
        backend: deviceBackend(
          join: (name, password) async {
            expect(password, 'fixture-only');
            called = true;
          },
        ),
        persistence: MemoryStorePersistence(),
      );
      addTearDown(store.dispose);
      await store.wifiScan();
      store.wifiPick('测试网络');
      await store.wifiJoinNew('fixture-only');
      expect(called, isTrue);
      expect(store.wifiLast, '测试网络');
      expect(store.wifiStateText, contains('连接成功'));
      expect(store.wifiSaved.single.name, '测试网络');
    },
  );
  testWidgets(
    'narrow/wide preserve keys and routes with explicit event fixture',
    (tester) async {
      final store = AppStore(
        events: [record],
        backend: appBackend(),
        persistence: MemoryStorePersistence(),
      );
      final device = DeviceStore(
        backend: deviceBackend(),
        persistence: MemoryStorePersistence(),
      );
      addTearDown(store.dispose);
      addTearDown(device.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(store: store, device: device),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('app-header')), findsOneWidget);
      expect(find.byKey(const Key('tab-all')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-real-test-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detail-real-test-1')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.byKey(const Key('crumb-back')), findsOneWidget);
      expect(find.byKey(const Key('bottom-nav')), findsNothing);
      tester.view.physicalSize = const Size(900, 1100);
      await tester.pump();
      expect(find.byKey(const Key('card-real-test-1')), findsOneWidget);
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.byKey(const Key('bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('crumb-back')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'five formats contain complete Chinese sources and real signatures; injected share only',
    (tester) async {
      await tester.runAsync(() async {
        final output = Directory(
          '${Directory.current.parent.path}/.e-ui-artifacts',
        );
        await output.create(recursive: true);
        var shares = 0;
        final service = ExportService(
          directory: () async => output,
          fontLoader: () async => ByteData.sublistView(
            await File('lib/services/export/assets/NotoSansSC-Regular.ttf')
                .readAsBytes(),
          ),
          shareFiles: (artifact, origin) async {
            shares++;
            expect(await artifact.file.exists(), isTrue);
          },
        );
        final card = completed(
          SummaryCard(id: 'export-test', time: '09:00')..srcIds = [record.id],
        );
        for (final format in ExportFormat.values) {
          final artifact = await service.export(
            card,
            [record],
            format,
            completedTodos: {0},
          );
          final bytes = await artifact.file.readAsBytes();
          switch (format) {
            case ExportFormat.html:
              expect(utf8.decode(bytes), contains('中文终点'));
              expect(utf8.decode(bytes), contains('&lt;&amp;&gt;'));
            case ExportFormat.markdown:
              expect(utf8.decode(bytes), contains('中文终点'));
              expect(utf8.decode(bytes), contains('[x] 周五复查预算'));
            case ExportFormat.pdf:
              expect(ascii.decode(bytes.take(4).toList()), '%PDF');
            case ExportFormat.png:
              expect(bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
            case ExportFormat.docx:
              final zip = ZipDecoder().decodeBytes(bytes);
              final xml = utf8.decode(
                zip.findFile('word/document.xml')!.content as List<int>,
              );
              expect(xml, contains('中文终点'));
              expect(xml, contains('&lt;&amp;&gt;'));
          }
          await service.share(artifact);
          expect(artifact.files, isNotEmpty);
        }
        expect(shares, 5);
      });
    },
  );
}
