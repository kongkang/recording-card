import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/health/health_signal_bucket.dart';
import 'package:recording_card/services/health/health_signal_collector.dart';
import 'package:recording_card/services/health/health_signal_controller.dart';
import 'package:recording_card/services/health/health_signal_models.dart';
import 'package:recording_card/services/health/health_signal_rows.dart';
import 'package:recording_card/services/health/health_signal_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_transitions.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  test('录音重叠取更长的一段，点样本落在区间内才关联', () {
    const spans = [
      RecordingSpan(id: 'early', startMs: 0, endMs: 10_000),
      RecordingSpan(id: 'late', startMs: 8_000, endMs: 20_000),
    ];
    expect(linkRecordingId(9_000, 12_000, spans), 'late');
    expect(linkRecordingId(1_000, 9_500, spans), 'early');
    expect(linkRecordingId(9_000, 9_000, spans), 'late');
    expect(linkRecordingId(20_000, 20_000, spans), isNull);
    expect(linkRecordingId(3_000, 3_000, spans), 'early');
  });

  test('原始样本按窗口取最近点或求和，长样本和已汇总样本不再加工', () {
    const interval = 60_000;
    const phase = 30_000;
    final bucketed = bucketHealthDrafts(
      [
        HealthSignalDraft(
          type: 'heart_rate',
          startMs: 10_000,
          endMs: 10_000,
          valueNum: 70,
          aggregation: 'raw',
          sourceBundle: 'watch',
        ),
        HealthSignalDraft(
          type: 'heart_rate',
          startMs: 40_000,
          endMs: 40_000,
          valueNum: 88,
          aggregation: 'raw',
          sourceBundle: 'watch',
        ),
        HealthSignalDraft(
          type: 'step_count',
          startMs: 1_000,
          endMs: 1_000,
          valueNum: 10,
          aggregation: 'raw',
          cumulative: true,
          sourceBundle: 'phone',
        ),
        HealthSignalDraft(
          type: 'step_count',
          startMs: 2_000,
          endMs: 2_000,
          valueNum: 5,
          aggregation: 'raw',
          cumulative: true,
          sourceBundle: 'phone',
        ),
        HealthSignalDraft(
          type: 'step_count',
          startMs: 70_000,
          endMs: 70_000,
          valueNum: 0,
          aggregation: 'raw',
          cumulative: true,
          sourceBundle: 'phone',
        ),
        HealthSignalDraft(
          type: 'sleep_analysis',
          startMs: 0,
          endMs: 8 * 60 * 60 * 1000,
          valueText: '深睡',
          aggregation: 'raw',
        ),
        HealthSignalDraft(
          type: 'heart_rate',
          startMs: 30_000,
          endMs: 60_000,
          valueNum: 64,
          aggregation: 'average',
          sourceBundle: 'healthkit',
        ),
      ],
      intervalMs: interval,
      phaseMs: phase,
    );

    final heart = bucketed.where((item) => item.type == 'heart_rate').toList();
    expect(heart, hasLength(2));
    final nearest = heart.firstWhere((item) => item.aggregation == 'nearest');
    expect(nearest.valueNum, 88);
    expect(nearest.startMs, 30_000);
    expect(nearest.metadata['observedMs'], 40_000);
    expect(
      heart.firstWhere((item) => item.aggregation == 'average').valueNum,
      64,
    );

    final steps = bucketed.where((item) => item.type == 'step_count').toList();
    expect(steps, hasLength(1));
    expect(steps.single.valueNum, 15);
    expect(steps.single.aggregation, 'sum');
    expect(steps.single.startMs, 30_000);

    final sleep = bucketed.singleWhere((item) => item.type == 'sleep_analysis');
    expect(sleep.aggregation, 'span');
    expect(sleep.valueText, '深睡');
  });

  test('同一分钟的心率和位置合成一行', () {
    final minute = DateTime(2026, 11, 16, 14, 38).millisecondsSinceEpoch;
    final rows = buildHealthSignalRows([
      _sample(type: 'heart_rate', startMs: minute + 1000, valueNum: 88),
      _sample(
        type: 'location',
        startMs: minute + 2000,
        valueText: '{"lat":22.5,"lng":113.9,"place":"南山科技园"}',
        sourceBundle: 'location.phased',
      ),
      _sample(
        type: 'sleep_analysis',
        startMs: minute - 3600_000,
        endMs: minute,
        valueText: '深睡',
      ),
    ]);
    expect(rows.first.kind, '静坐');
    expect(rows.first.metric, contains('88 bpm'));
    expect(rows.first.meta, '南山科技园');
    expect(rows.last.kind, '睡眠');
  });

  test('查询可以按时间、类型、来源和录音过滤，并在录音变化后重连', () async {
    final dir = await Directory.systemTemp.createTemp('rc-health-db-');
    addTearDown(() => dir.delete(recursive: true));
    final store = HealthSignalStore(
      factory: databaseFactoryFfi,
      path: () async => '${dir.path}/health.db',
    );
    addTearDown(store.close);
    await store.upsertAll([
      _sample(
        type: 'heart_rate',
        startMs: 1_000,
        endMs: 2_000,
        sourceName: '手表',
        sourceBundle: 'watch',
        recordingId: 'rec-old',
      ),
      _sample(
        type: 'step_count',
        startMs: 5_000,
        endMs: 5_000,
        sourceName: '手机',
        sourceBundle: 'phone',
      ),
    ]);

    expect(await store.count(const HealthSignalQuery()), 2);
    final heart = await store.query(
      const HealthSignalQuery(type: 'heart_rate'),
    );
    expect(heart, hasLength(1));
    final bySource = await store.query(
      const HealthSignalQuery(source: 'phone'),
    );
    expect(bySource.single.type, 'step_count');
    final overlapped = await store.query(
      const HealthSignalQuery(startMs: 1_500, endMs: 1_800),
    );
    expect(overlapped.single.type, 'heart_rate');
    final touched = await store.query(
      const HealthSignalQuery(startMs: 2_000, endMs: 4_000),
    );
    expect(touched.single.type, 'heart_rate');
    final missed = await store.query(
      const HealthSignalQuery(startMs: 2_001, endMs: 4_000),
    );
    expect(missed, isEmpty);
    final linked = await store.query(
      const HealthSignalQuery(recordingId: 'rec-old'),
    );
    expect(linked, hasLength(1));

    final changed = await store.relink(const [
      RecordingSpan(id: 'rec-new', startMs: 500, endMs: 3_000),
    ]);
    expect(changed, 1);
    final again = await store.query(
      const HealthSignalQuery(type: 'heart_rate'),
    );
    expect(again.single.recordingId, 'rec-new');
    await store.upsertAll([again.single]);
    expect(await store.count(const HealthSignalQuery()), 2);
  });

  test('采样配置默认 1 分钟、相位 30 秒，并能落盘', () async {
    final memory = InMemoryStore();
    final config = AgentConfigStore(store: memory);
    addTearDown(config.dispose);
    await config.load();
    expect(config.healthSignalEnabled, isFalse);
    expect(config.recordingSliceSeconds, 60);
    expect(config.healthSampleIntervalSeconds, 60);
    expect(config.healthSamplePhaseSeconds, 30);
    expect(config.healthSampleIntervalMs, 60_000);
    expect(AgentConfigStore.formatSampleWindow(60), '1 分钟');
    expect(AgentConfigStore.formatSampleWindow(300), '5 分钟');

    await config.setRecordingSliceSeconds(10);
    await config.setHealthSamplePhaseSeconds(90);
    expect(config.recordingSliceSeconds, 60);
    expect(config.healthSamplePhaseSeconds, 59);
    await config.setHealthSampleIntervalSeconds(300);
    await config.setHealthSamplePhaseSeconds(30);
    await config.setHealthSignalEnabled(true);

    final loaded = AgentConfigStore(store: memory);
    addTearDown(loaded.dispose);
    await loaded.load();
    expect(loaded.healthSignalEnabled, isTrue);
    expect(loaded.healthSampleIntervalSeconds, 300);
    expect(loaded.healthSamplePhaseSeconds, 30);
    expect(loaded.recordingSliceSeconds, 60);

    await loaded.setHealthSamplePhaseSeconds(200);
    await loaded.setHealthSampleIntervalSeconds(60);
    expect(loaded.healthSamplePhaseSeconds, 59);
  });

  test('当前平台没有采集实现时，开关不会被打开', () async {
    final dir = await Directory.systemTemp.createTemp('rc-health-off-');
    addTearDown(() => dir.delete(recursive: true));
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    final controller = HealthSignalController(
      store: HealthSignalStore(
        factory: databaseFactoryFfi,
        path: () async => '${dir.path}/health.db',
      ),
      collector: const AndroidHealthSignalCollector(),
      config: config,
    );
    addTearDown(controller.dispose);
    final access = await controller.setEnabled(true);
    expect(access.available, isFalse);
    expect(config.healthSignalEnabled, isFalse);
    expect(controller.statusMessage, contains('Health Connect'));
  });

  test('采集通道在开启或关闭时抛错会安全回滚并提示原因', () async {
    final dir = await Directory.systemTemp.createTemp('rc-health-err-');
    addTearDown(() => dir.delete(recursive: true));
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    final collector = _FakeCollector(drafts: const [])
      ..setCollectionActiveError = StateError('health_collection_failed');
    final controller = HealthSignalController(
      store: HealthSignalStore(
        factory: databaseFactoryFfi,
        path: () async => '${dir.path}/health.db',
      ),
      collector: collector,
      config: config,
    );
    addTearDown(controller.dispose);

    await controller.setEnabled(true);
    expect(controller.enabled, isFalse);
    expect(config.healthSignalEnabled, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.statusMessage, contains('健康采集通道不可用'));

    await config.setHealthSignalEnabled(true);
    await controller.setEnabled(false);
    expect(controller.enabled, isFalse);
    expect(controller.statusMessage, contains('健康采集通道不可用'));
  });

  group('设置页健康信号', () {
    late Directory dir;
    late AgentConfigStore config;
    late _FakeCollector collector;
    late HealthSignalController controller;

    Future<void> boot({required bool enabled}) async {
      dir = await Directory.systemTemp.createTemp('rc-health-ui-');
      config = AgentConfigStore(store: InMemoryStore());
      await config.load();
      final minute = DateTime(2026, 11, 16, 14, 38).millisecondsSinceEpoch;
      collector = _FakeCollector(
        drafts: [
          HealthSignalDraft(
            type: 'heart_rate',
            startMs: minute,
            endMs: minute,
            valueNum: 88,
            aggregation: 'nearest',
            sourceName: '健康',
            sourceBundle: 'healthkit',
          ),
        ],
      );
      controller = HealthSignalController(
        store: HealthSignalStore(
          factory: databaseFactoryFfi,
          path: () async => '${dir.path}/health.db',
        ),
        collector: collector,
        config: config,
        clock: () => DateTime(2026, 11, 16, 15),
      );
      if (!enabled) return;
      final access = await controller.setEnabled(true);
      expect(access.available, isTrue);
      expect(config.healthSignalEnabled, isTrue);
      expect(controller.sampleCount, 1);
      expect(collector.active, isTrue);
    }

    Future<void> shutdown() async {
      controller.dispose();
      config.dispose();
      if (dir.existsSync()) await dir.delete(recursive: true);
    }

    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: SettingPage(
              settings: SettingsStore(store: InMemoryStore()),
              agentConfig: config,
              healthSignals: controller,
            ),
          ),
        ),
      );
    }

    group('关闭', () {
      setUp(() => boot(enabled: false));
      tearDown(shutdown);

      testWidgets('默认关闭，取消授权说明后仍保持关闭', (tester) async {
        await pumpSettings(tester);
        expect(
          tester.widget<Text>(find.byKey(const Key('sv-health'))).data,
          '已关闭',
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('set-health-location')),
          200,
        );
        await tester.tap(find.byKey(const Key('set-health-location')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('health-empty')), findsOneWidget);
        expect(find.byKey(const Key('health-clinical-note')), findsOneWidget);
        await tester.tap(find.byKey(const Key('health-sync-row')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('health-perm-guide')), findsOneWidget);
        await tester.tap(find.byKey(const Key('health-perm-cancel')));
        await tester.pumpAndSettle();
        expect(config.healthSignalEnabled, isFalse);
        expect(collector.active, isFalse);
      });
    });

    group('已开启', () {
      setUp(() => boot(enabled: true));
      tearDown(shutdown);

      testWidgets('已授权的本机样本显示在列表，关闭开关不删记录', (tester) async {
        await pumpSettings(tester);
        expect(
          tester.widget<Text>(find.byKey(const Key('sv-health'))).data,
          '已开启 · 1 条',
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('set-health-location')),
          200,
        );
        await tester.tap(find.byKey(const Key('set-health-location')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('health-item-0')), findsOneWidget);
        expect(find.textContaining('88 bpm'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('health-count'))).data,
          '共 1 条',
        );

        await tester.tap(find.byKey(const Key('health-sync-row')));
        await tester.pumpAndSettle();
        expect(config.healthSignalEnabled, isFalse);
        expect(find.byKey(const Key('health-perm-guide')), findsNothing);
        expect(find.byKey(const Key('health-item-0')), findsOneWidget);

        await tester.tap(find.byKey(const Key('standalone-crumb-back')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('sv-health'))).data,
          '已关闭',
        );
      });
    });
  });

  testWidgets('开发者模式关闭时不显示采样节拍', (tester) async {
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: SettingSubPage(subId: 'dev', agentConfig: config),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('dev-cycle-value')), findsOneWidget);
    expect(find.byKey(const Key('dev-health-interval-value')), findsNothing);

    await config.setDeveloperMode(true);
    await tester.pump();
    expect(find.byKey(const Key('dev-slice-seconds-value')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('dev-health-interval-preset-300')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('dev-health-interval-value')))
          .data,
      '1 分钟',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('dev-health-phase-value'))).data,
      '30 秒',
    );
    await tester.tap(find.byKey(const Key('dev-health-interval-preset-300')));
    await tester.pump();
    expect(config.healthSampleIntervalSeconds, 300);
    await tester.ensureVisible(find.byKey(const Key('dev-slice-preset-300')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dev-slice-preset-300')));
    await tester.pump();
    expect(config.recordingSliceSeconds, 300);
  });
}

HealthSignalSample _sample({
  required String type,
  required int startMs,
  int? endMs,
  double? valueNum,
  String? valueText,
  String? sourceName,
  String? sourceBundle,
  String? recordingId,
}) {
  return HealthSignalSample(
    id: healthSampleId(
      type: type,
      startMs: startMs,
      sourceBundle: sourceBundle,
    ),
    type: type,
    startMs: startMs,
    endMs: endMs ?? startMs,
    valueNum: valueNum,
    valueText: valueText,
    sourceName: sourceName,
    sourceBundle: sourceBundle,
    recordingId: recordingId,
    ingestedAtMs: 1,
  );
}

class _FakeCollector implements HealthSignalCollector {
  _FakeCollector({required this.drafts});

  List<HealthSignalDraft> drafts;
  bool active = false;
  int catchUps = 0;
  Object? setCollectionActiveError;

  @override
  Future<HealthPlatformInfo> info() async {
    return const HealthPlatformInfo(
      platform: 'test',
      available: true,
      clinicalRecords: false,
      clinicalReason: '测试环境没有临床病历权限',
    );
  }

  @override
  Future<HealthAccessResult> requestAccess() async {
    return const HealthAccessResult(
      available: true,
      requestedTypeCount: 12,
      location: 'whenInUse',
      clinicalSkipped: true,
    );
  }

  @override
  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  }) async {
    if (setCollectionActiveError != null) {
      throw setCollectionActiveError!;
    }
    this.active = active;
  }

  @override
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  }) async {
    catchUps += 1;
  }

  @override
  Future<List<HealthSignalDraft>> drainSpool() async {
    final out = drafts;
    drafts = const [];
    return out;
  }

  @override
  Stream<void> get updates => const Stream<void>.empty();
}
