/// 把原始采样收成「每个窗口一个点」。
///
/// 窗口对齐到 Unix 毫秒网格：`[k * interval, (k + 1) * interval)`。
/// 代表时刻是窗口起点加相位偏移，用来和每分钟前半段的转写错开。
/// 离散量取离相位最近的真实样本，累计量取窗口内求和。没有样本的窗口不补零。
library;

import 'health_signal_models.dart';

/// 采集侧交来的一条尚未落盘的样本。
class HealthSignalDraft {
  const HealthSignalDraft({
    required this.type,
    required this.startMs,
    required this.endMs,
    this.valueNum,
    this.valueText,
    this.unit,
    this.sourceName,
    this.sourceBundle,
    this.aggregation = 'point',
    this.metadata = const {},
    this.cumulative = false,
  });

  final String type;
  final int startMs;
  final int endMs;
  final double? valueNum;
  final String? valueText;
  final String? unit;
  final String? sourceName;
  final String? sourceBundle;
  final String aggregation;
  final Map<String, Object?> metadata;

  /// 为 true 时，原始样本按窗口求和（步数、距离、能量）。
  final bool cumulative;

  bool get isRaw => aggregation == 'raw';

  HealthSignalDraft copyWith({
    int? startMs,
    int? endMs,
    double? valueNum,
    String? valueText,
    String? aggregation,
    Map<String, Object?>? metadata,
  }) {
    return HealthSignalDraft(
      type: type,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      valueNum: valueNum ?? this.valueNum,
      valueText: valueText ?? this.valueText,
      unit: unit,
      sourceName: sourceName,
      sourceBundle: sourceBundle,
      aggregation: aggregation ?? this.aggregation,
      metadata: metadata ?? this.metadata,
      cumulative: cumulative,
    );
  }

  HealthSignalSample toSample({
    String? recordingId,
    required int ingestedAtMs,
  }) {
    final end = endMs < startMs ? startMs : endMs;
    return HealthSignalSample(
      id: healthSampleId(
        type: type,
        startMs: startMs,
        sourceBundle: sourceBundle,
      ),
      type: type,
      startMs: startMs,
      endMs: end,
      valueNum: valueNum,
      valueText: valueText,
      unit: unit,
      sourceName: sourceName,
      sourceBundle: sourceBundle,
      recordingId: recordingId,
      aggregation: aggregation,
      metadata: metadata,
      ingestedAtMs: ingestedAtMs,
    );
  }

  factory HealthSignalDraft.fromJson(Map<String, Object?> json) {
    final metaRaw = json['metadata'];
    final metadata = <String, Object?>{};
    if (metaRaw is Map) {
      for (final entry in metaRaw.entries) {
        metadata['${entry.key}'] = entry.value;
      }
    }
    final start = _asInt(json['startMs']);
    final endRaw = json['endMs'];
    return HealthSignalDraft(
      type: '${json['type'] ?? ''}',
      startMs: start,
      endMs: endRaw == null ? start : _asInt(endRaw),
      valueNum: _asDouble(json['valueNum']),
      valueText: json['valueText'] as String?,
      unit: json['unit'] as String?,
      sourceName: json['sourceName'] as String?,
      sourceBundle: json['sourceBundle'] as String?,
      aggregation: '${json['aggregation'] ?? 'point'}',
      metadata: metadata,
      cumulative: json['cumulative'] == true,
    );
  }
}

/// 这些类型在一个窗口里应求和，而不是取最近的一个点。
const Set<String> cumulativeHealthTypes = {
  'step_count',
  'distance_walking_running',
  'distance_cycling',
  'distance_wheelchair',
  'distance_swimming',
  'distance_downhill_snow_sports',
  'distance_cross_country_skiing',
  'distance_paddle_sports',
  'distance_rowing',
  'basal_energy_burned',
  'active_energy_burned',
  'flights_climbed',
  'push_count',
  'swimming_stroke_count',
  'apple_exercise_time',
  'apple_move_time',
  'apple_stand_time',
  'nike_fuel',
};

const Set<String> spanHealthTypes = {
  'sleep_analysis',
  'workout',
  'workout_route',
  'activity_summary',
  'electrocardiogram',
  'audiogram',
  'heartbeat_series',
  'state_of_mind',
};

/// 只重分桶 `aggregation == raw` 的草稿。平台已经按窗口汇总过的草稿原样保留，
/// 避免把「每分钟合计」再加一次。
List<HealthSignalDraft> bucketHealthDrafts(
  List<HealthSignalDraft> drafts, {
  required int intervalMs,
  required int phaseMs,
}) {
  final interval = intervalMs < 1 ? 60000 : intervalMs;
  final phase = phaseMs.clamp(0, interval - 1);
  final passthrough = <HealthSignalDraft>[];
  final groups = <String, List<HealthSignalDraft>>{};
  for (final draft in drafts) {
    if (!draft.isRaw || draft.type.isEmpty) {
      passthrough.add(draft);
      continue;
    }
    final duration = draft.endMs - draft.startMs;
    if (spanHealthTypes.contains(draft.type) || duration > interval) {
      passthrough.add(
        draft.copyWith(
          aggregation: 'span',
          endMs: draft.endMs < draft.startMs ? draft.startMs : draft.endMs,
        ),
      );
      continue;
    }
    final windowStart = (draft.startMs ~/ interval) * interval;
    final source = draft.sourceBundle ?? '';
    final key = '${draft.type}|$windowStart|$source';
    groups.putIfAbsent(key, () => []).add(draft);
  }

  final bucketed = <HealthSignalDraft>[];
  for (final items in groups.values) {
    final head = items.first;
    final windowStart = (head.startMs ~/ interval) * interval;
    final preferred = windowStart + phase;
    final windowEnd = windowStart + interval;
    final cumulative =
        head.cumulative || cumulativeHealthTypes.contains(head.type);
    if (cumulative) {
      var sum = 0.0;
      var any = false;
      for (final item in items) {
        final value = item.valueNum;
        if (value == null) continue;
        sum += value;
        any = true;
      }
      if (!any || sum == 0) continue;
      bucketed.add(
        head.copyWith(
          startMs: preferred,
          endMs: windowEnd,
          valueNum: sum,
          aggregation: 'sum',
          metadata: {...head.metadata, 'samples': items.length},
        ),
      );
      continue;
    }
    HealthSignalDraft? nearest;
    var bestDistance = 1 << 62;
    for (final item in items) {
      final distance = (item.startMs - preferred).abs();
      if (nearest == null || distance < bestDistance) {
        nearest = item;
        bestDistance = distance;
      }
    }
    if (nearest == null) continue;
    bucketed.add(
      nearest.copyWith(
        startMs: preferred,
        endMs: windowEnd,
        aggregation: 'nearest',
        metadata: {...nearest.metadata, 'observedMs': nearest.startMs},
      ),
    );
  }
  return [...passthrough, ...bucketed];
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

double? _asDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return null;
}
