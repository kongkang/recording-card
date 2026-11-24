/// 总开关、权限、增量导入，以及把样本和录音 id 接上。
///
/// 开关默认关闭。打开后：向系统一次申请可请求的健康类型，按授权结果采集，
/// 先补最近 30 天，再靠观察者和回到前台补齐。不调用云端模型。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart';

import '../../core/store/agent_config_store.dart';
import 'health_signal_bucket.dart';
import 'health_signal_collector.dart';
import 'health_signal_models.dart';
import 'health_signal_rows.dart';
import 'health_signal_store.dart';

class HealthSignalController extends ChangeNotifier
    with WidgetsBindingObserver {
  HealthSignalController({
    required this.store,
    required this.collector,
    required this.config,
    this.recordingSpans,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    config.addListener(_onConfigChanged);
  }

  /// 首次打开时回补的历史上限。更早的样本留给以后按需扩展，避免一次读完整库。
  static const historyLookback = Duration(days: 30);
  static const _importFlag = 'initial_import_done';

  final HealthSignalStore store;
  final HealthSignalCollector collector;
  final AgentConfigStore config;
  final Future<List<RecordingSpan>> Function()? recordingSpans;
  final DateTime Function() _clock;

  bool _disposed = false;
  bool _started = false;
  bool _applying = false;
  bool _active = false;
  bool _syncing = false;
  bool _syncAgain = false;
  int _presentGen = 0;
  bool busy = false;
  int sampleCount = 0;
  String? statusMessage;
  List<HealthSignalListRow> rows = const [];
  HealthPlatformInfo? platformInfo;
  StreamSubscription<void>? _updatesSub;
  Timer? _resumeDebounce;

  bool get enabled => config.healthSignalEnabled;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _updatesSub = collector.updates.listen((_) {
      if (_active) unawaited(syncNow());
    });
    try {
      platformInfo = await _guardInfo();
      _active = config.healthSignalEnabled;
      // 把开关写回原生，避免上次进程没来得及停采集时后台还在读。
      final pushed = await _pushActive(_active);
      if (_active && pushed) {
        await syncNow();
      } else {
        await refreshPresentation();
      }
    } on Object catch (error) {
      statusMessage = '健康记录还没准备好：$error';
      _notify();
    }
  }

  Future<HealthAccessResult> setEnabled(
    bool value, {
    bool requestPermission = true,
  }) async {
    if (_disposed) {
      return const HealthAccessResult(available: false, requestedTypeCount: 0);
    }
    if (!value) {
      _applying = true;
      try {
        await config.setHealthSignalEnabled(false);
        _active = false;
        final pushed = await _pushActive(false);
        if (pushed) {
          statusMessage = null;
        }
      } finally {
        _applying = false;
      }
      _notify();
      return const HealthAccessResult(
        available: true,
        requestedTypeCount: 0,
        location: 'off',
      );
    }

    platformInfo ??= await _guardInfo();
    final info = platformInfo;
    if (info != null && !info.available) {
      statusMessage = info.detail ?? '当前设备不能采集健康与位置数据';
      _notify();
      return HealthAccessResult(
        available: false,
        requestedTypeCount: 0,
        message: statusMessage,
      );
    }

    HealthAccessResult access = const HealthAccessResult(
      available: true,
      requestedTypeCount: 0,
    );
    if (requestPermission) {
      access = await collector.requestAccess();
      if (!access.available) {
        statusMessage = access.message ?? '没有获得健康或定位授权';
        _notify();
        return access;
      }
    }

    _applying = true;
    busy = true;
    statusMessage = '正在从本机健康与定位导入…';
    _notify();
    try {
      await config.setHealthSignalEnabled(true);
      _active = true;
      final pushed = await _pushActive(true);
      if (!pushed) {
        _active = false;
        await config.setHealthSignalEnabled(false);
      } else {
        await syncNow();
        if (sampleCount == 0) {
          statusMessage = '已向系统申请授权。列表仍为空时，请到系统设置检查健康与定位是否允许';
        } else {
          statusMessage = null;
        }
      }
    } on Object catch (error) {
      statusMessage = '同步没有完成：$error';
    } finally {
      busy = false;
      _applying = false;
    }
    _notify();
    return access;
  }

  Future<void> syncNow() async {
    if (_disposed || !_active) {
      await refreshPresentation();
      return;
    }
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    busy = true;
    _notify();
    try {
      do {
        _syncAgain = false;
        final now = _clock().millisecondsSinceEpoch;
        final cursors = await store.readCursors();
        final interval = config.healthSampleIntervalMs;
        final sinceByType = <String, int>{
          for (final entry in cursors.entries)
            if (entry.value > interval) entry.key: entry.value - interval,
        };
        final initialDone = await store.flag(_importFlag);
        // 没有水位的类型回到 30 天；已有水位的类型由 sinceByType 收窄。
        final defaultSince = now - historyLookback.inMilliseconds;
        ({int minStartMs, int maxEndMs})? ingestedRange;
        try {
          await collector.catchUp(
            defaultSinceMs: defaultSince,
            untilMs: now,
            sinceByType: sinceByType,
            intervalMs: interval,
            phaseMs: config.healthSamplePhaseMs,
          );
        } finally {
          ingestedRange = await _drain();
        }
        await store.setFlag(_importFlag, true);
        if (!initialDone) {
          await _relink();
        } else if (ingestedRange != null) {
          await _relink(
            fromMs: ingestedRange.minStartMs,
            toMs: ingestedRange.maxEndMs,
          );
        }
      } while (_syncAgain && _active && !_disposed);
    } on Object catch (error) {
      statusMessage = '同步没有完成：$error';
    } finally {
      _syncing = false;
      busy = false;
      await refreshPresentation();
    }
  }

  Future<void> clearAllSamples() async {
    _presentGen++;
    await store.clearAll();
    sampleCount = 0;
    rows = const [];
    statusMessage = null;
    _notify();
  }

  Future<void> refreshPresentation() async {
    if (_disposed) return;
    final gen = ++_presentGen;
    try {
      final samples = await store.query(const HealthSignalQuery(limit: 800));
      final count = await store.count(const HealthSignalQuery());
      if (_disposed || gen != _presentGen) return;
      rows = buildHealthSignalRows(samples).take(120).toList(growable: false);
      sampleCount = count;
    } on Object catch (error) {
      if (_disposed || gen != _presentGen) return;
      statusMessage ??= '还不能读取本机健康记录：$error';
    }
    if (gen == _presentGen) _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_active || _disposed) return;
    _resumeDebounce?.cancel();
    _resumeDebounce = Timer(const Duration(seconds: 1), () {
      unawaited(syncNow());
    });
  }

  Future<({int minStartMs, int maxEndMs})?> _drain() async {
    final drafts = await collector.drainSpool();
    if (drafts.isEmpty) return null;
    return _ingest(drafts);
  }

  Future<({int minStartMs, int maxEndMs})?> _ingest(
    List<HealthSignalDraft> drafts,
  ) async {
    final intervalMs = config.healthSampleIntervalMs;
    final phaseMs = config.healthSamplePhaseMs;
    final spans = await _loadSpans();
    final now = _clock().millisecondsSinceEpoch;
    final samples = drafts.length >= 64
        ? await Isolate.run(
            () => _normalizeAndLinkSamples(
              drafts: drafts,
              spans: spans,
              intervalMs: intervalMs,
              phaseMs: phaseMs,
              ingestedAtMs: now,
            ),
          )
        : _normalizeAndLinkSamples(
            drafts: drafts,
            spans: spans,
            intervalMs: intervalMs,
            phaseMs: phaseMs,
            ingestedAtMs: now,
          );
    if (samples.isEmpty) return null;
    await store.upsertAll(samples);
    final cursors = await store.readCursors();
    final next = Map<String, int>.of(cursors);
    var minStart = samples.first.startMs;
    var maxEnd = samples.first.endMs < samples.first.startMs
        ? samples.first.startMs
        : samples.first.endMs;
    for (final sample in samples) {
      if (sample.startMs < minStart) minStart = sample.startMs;
      final end = sample.endMs < sample.startMs ? sample.startMs : sample.endMs;
      if (end > maxEnd) maxEnd = end;
      final prev = next[sample.type] ?? 0;
      if (end > prev) next[sample.type] = end;
    }
    await store.writeCursors(next);
    return (minStartMs: minStart, maxEndMs: maxEnd + 1);
  }

  Future<void> _relink({int? fromMs, int? toMs}) async {
    final spans = await _loadSpans();
    await store.relink(spans, fromMs: fromMs, toMs: toMs);
  }

  Future<List<RecordingSpan>> _loadSpans() async {
    final loader = recordingSpans;
    if (loader == null) return const [];
    try {
      return await loader();
    } on Object {
      return const [];
    }
  }

  Future<bool> _pushActive(bool active) async {
    try {
      await collector.setCollectionActive(
        active: active,
        intervalMs: config.healthSampleIntervalMs,
        phaseMs: config.healthSamplePhaseMs,
      );
      return true;
    } on Object catch (error) {
      statusMessage = '健康采集通道不可用：$error';
      _notify();
      return false;
    }
  }

  Future<HealthPlatformInfo> _guardInfo() async {
    try {
      return await collector.info();
    } on Object catch (error) {
      return HealthPlatformInfo(
        platform: 'unknown',
        available: false,
        detail: '$error',
      );
    }
  }

  void _onConfigChanged() {
    if (_applying || !_started || _disposed) return;
    if (config.healthSignalEnabled != _active) {
      unawaited(
        setEnabled(
          config.healthSignalEnabled,
          requestPermission: config.healthSignalEnabled,
        ),
      );
      return;
    }
    if (_active) {
      unawaited(_pushActive(true));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _resumeDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    config.removeListener(_onConfigChanged);
    unawaited(_updatesSub?.cancel());
    super.dispose();
  }
}

List<HealthSignalSample> _normalizeAndLinkSamples({
  required List<HealthSignalDraft> drafts,
  required List<RecordingSpan> spans,
  required int intervalMs,
  required int phaseMs,
  required int ingestedAtMs,
}) {
  final normalized = bucketHealthDrafts(
    drafts,
    intervalMs: intervalMs,
    phaseMs: phaseMs,
  );
  if (normalized.isEmpty) return const [];
  return [
    for (final draft in normalized)
      draft.toSample(
        recordingId: linkRecordingId(draft.startMs, draft.endMs, spans),
        ingestedAtMs: ingestedAtMs,
      ),
  ];
}
