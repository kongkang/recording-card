import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/services/health/health_signal_bucket.dart';
import 'package:recording_card/services/health/health_signal_collector.dart';
import 'package:recording_card/services/health/health_signal_controller.dart';
import 'package:recording_card/services/health/health_signal_models.dart';
import 'package:recording_card/services/health/health_signal_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PerfFakeCollector implements HealthSignalCollector {
  List<HealthSignalDraft> pending = const [];
  final List<int> sinceValues = [];

  @override
  Future<HealthPlatformInfo> info() async =>
      const HealthPlatformInfo(platform: 'ios', available: true);

  @override
  Future<HealthAccessResult> requestAccess() async => const HealthAccessResult(
    available: true,
    requestedTypeCount: 2,
    location: 'always',
  );

  @override
  Future<void> setCollectionActive({
    required bool active,
    required int intervalMs,
    required int phaseMs,
  }) async {}

  @override
  Future<void> catchUp({
    required int defaultSinceMs,
    required int untilMs,
    required Map<String, int> sinceByType,
    required int intervalMs,
    required int phaseMs,
  }) async {
    sinceValues.add(defaultSinceMs);
  }

  @override
  Future<List<HealthSignalDraft>> drainSpool() async {
    final out = pending;
    pending = const [];
    return out;
  }

  @override
  Stream<void> get updates => const Stream<void>.empty();
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  test('大批量健康样本经 Isolate.run 分桶并用 Batch 批量入库且仅重连增量时间窗', () async {
    final dir = await Directory.systemTemp.createTemp('rc-health-perf-');
    addTearDown(() => dir.delete(recursive: true));

    final store = HealthSignalStore(
      factory: databaseFactoryFfi,
      path: () async => '${dir.path}/health.db',
    );
    addTearDown(store.close);

    // 预置一条 10 天前的旧样本（不与任何新样本重叠），验证增量 syncNow 不会触碰全表旧关联
    final oldTime = DateTime(2026, 11, 1, 9, 0).millisecondsSinceEpoch;
    await store.upsertAll([
      HealthSignalSample(
        id: 'heart_rate|$oldTime|old',
        type: 'heart_rate',
        startMs: oldTime,
        endMs: oldTime,
        valueNum: 66,
        recordingId: 'stale-old-rec',
        ingestedAtMs: oldTime,
      ),
    ]);

    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    await config.setHealthSignalEnabled(true);

    final baseMs = DateTime(2026, 11, 18, 8, 0).millisecondsSinceEpoch;
    final collector = _PerfFakeCollector()
      ..pending = [
        for (var i = 0; i < 120; i++)
          HealthSignalDraft(
            type: 'heart_rate',
            startMs: baseMs + i * 60_000 + 15_000,
            endMs: baseMs + i * 60_000 + 15_000,
            valueNum: (70 + (i % 20)).toDouble(),
            aggregation: 'raw',
            sourceBundle: 'watch',
          ),
      ];

    var spansCall = 0;
    final ctrl = HealthSignalController(
      store: store,
      collector: collector,
      config: config,
      recordingSpans: () async {
        spansCall++;
        return [
          RecordingSpan(
            id: 'rec-morning',
            startMs: baseMs,
            endMs: baseMs + 60 * 60_000,
          ),
        ];
      },
      clock: () => DateTime(2026, 11, 18, 12, 0),
    );
    addTearDown(ctrl.dispose);

    // 首次同步：完成 initial_import_done 标记与 120 条（>=64 走 Isolate.run）入库
    await ctrl.start();
    expect(ctrl.sampleCount, 121);
    final linkedMorning = await store.query(
      const HealthSignalQuery(recordingId: 'rec-morning', limit: 200),
    );
    expect(linkedMorning, hasLength(60));

    // 人为把 10 天前旧样本重新挂上旧标签，验证第二次增量同步仅局部 relink，不再扫描全表改掉它
    await store.upsertAll([
      HealthSignalSample(
        id: 'heart_rate|$oldTime|old',
        type: 'heart_rate',
        startMs: oldTime,
        endMs: oldTime,
        valueNum: 66,
        recordingId: 'keep-untouched',
        ingestedAtMs: oldTime,
      ),
    ]);

    final t2 = baseMs + 130 * 60_000;
    collector.pending = [
      HealthSignalDraft(
        type: 'heart_rate',
        startMs: t2,
        endMs: t2,
        valueNum: 82,
        aggregation: 'raw',
        sourceBundle: 'watch',
      ),
    ];
    await ctrl.syncNow();
    expect(spansCall, greaterThanOrEqualTo(2));

    final oldSample = (await store.query(
      HealthSignalQuery(startMs: oldTime, endMs: oldTime + 1000),
    )).single;
    expect(oldSample.recordingId, 'keep-untouched');
  });
}
