/// 把样本收成设置页「最近采集数据」的一行。
///
/// 布局对齐原型：时间、活动态、指标、地点。同一分钟里的心率 / 血氧 / 步数
/// 合成一行；睡眠和锻炼这类长样本单独成行。没有真实样本的格子不出现。
library;

import 'dart:convert';

import 'health_signal_models.dart';

class HealthSignalListRow {
  const HealthSignalListRow({
    required this.anchorMs,
    required this.timeLabel,
    required this.kind,
    required this.metric,
    required this.meta,
  });

  final int anchorMs;
  final String timeLabel;
  final String kind;
  final String metric;
  final String meta;
}

const Map<String, String> healthTypeLabels = {
  'heart_rate': '心率',
  'resting_heart_rate': '静息心率',
  'walking_heart_rate_average': '步行心率',
  'heart_rate_variability_sdnn': 'HRV',
  'heart_rate_recovery_one_minute': '心率恢复',
  'oxygen_saturation': '血氧',
  'respiratory_rate': '呼吸',
  'step_count': '步数',
  'active_energy_burned': '活动能量',
  'basal_energy_burned': '静息能量',
  'distance_walking_running': '步行距离',
  'flights_climbed': '楼层',
  'sleep_analysis': '睡眠',
  'workout': '运动',
  'location': '位置',
  'blood_pressure': '血压',
  'body_mass': '体重',
  'vo2_max': '最大摄氧量',
  'state_of_mind': '情绪',
  'electrocardiogram': '心电图',
  'activity_summary': '活动',
  'apple_exercise_time': '锻炼',
  'apple_stand_time': '站立',
  'walking_speed': '步行速度',
  'environmental_audio_exposure': '环境声',
  'headphone_audio_exposure': '耳机音量',
};

String healthTypeLabel(String type) =>
    healthTypeLabels[type] ?? type.replaceAll('_', ' ');

List<HealthSignalListRow> buildHealthSignalRows(
  List<HealthSignalSample> samples,
) {
  final longs = <HealthSignalSample>[];
  final shorts = <HealthSignalSample>[];
  for (final sample in samples) {
    final duration = sample.endMs - sample.startMs;
    if (sample.type == 'sleep_analysis' ||
        sample.type == 'workout' ||
        sample.type == 'activity_summary' ||
        duration > 90000) {
      longs.add(sample);
    } else {
      shorts.add(sample);
    }
  }

  final groups = <int, List<HealthSignalSample>>{};
  for (final sample in shorts) {
    final local = DateTime.fromMillisecondsSinceEpoch(sample.startMs);
    final minute = DateTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    ).millisecondsSinceEpoch;
    groups.putIfAbsent(minute, () => []).add(sample);
  }

  final timed = <({int at, HealthSignalListRow row})>[];
  for (final entry in groups.entries) {
    timed.add((at: entry.key, row: _rowFromGroup(entry.key, entry.value)));
  }
  for (final sample in longs) {
    timed.add((at: sample.startMs, row: _rowFromLong(sample)));
  }
  timed.sort((a, b) => b.at.compareTo(a.at));
  return [for (final item in timed) item.row];
}

HealthSignalListRow _rowFromGroup(
  int minuteMs,
  List<HealthSignalSample> items,
) {
  final heart = _pick(items, 'heart_rate');
  final oxygen = _pick(items, 'oxygen_saturation');
  final hrv = _pick(items, 'heart_rate_variability_sdnn');
  final steps = _pick(items, 'step_count');
  final location = _pick(items, 'location');
  final parts = <String>[
    if (heart != null) formatHealthMetric(heart),
    if (oxygen != null) formatHealthMetric(oxygen),
    if (hrv != null) formatHealthMetric(hrv),
    if (steps != null && (heart != null || oxygen != null || hrv != null))
      formatHealthMetric(steps),
  ];
  final metric = parts.isNotEmpty
      ? parts.take(3).join(' · ')
      : formatHealthMetric(
          heart ??
              oxygen ??
              steps ??
              location ??
              (items..sort((a, b) => b.startMs.compareTo(a.startMs))).first,
        );
  return HealthSignalListRow(
    anchorMs: minuteMs,
    timeLabel: formatHealthClock(minuteMs),
    kind: _kindForGroup(items, steps: steps, heart: heart, location: location),
    metric: metric,
    meta: _metaFor(items),
  );
}

HealthSignalListRow _rowFromLong(HealthSignalSample sample) {
  final kind = sample.type == 'sleep_analysis'
      ? '睡眠'
      : sample.type == 'workout'
      ? (sample.valueText?.trim().isNotEmpty == true
            ? sample.valueText!.trim()
            : '运动')
      : healthTypeLabel(sample.type);
  return HealthSignalListRow(
    anchorMs: sample.startMs,
    timeLabel: formatHealthClock(sample.startMs),
    kind: kind,
    metric: formatHealthMetric(sample),
    meta: placeOf(sample) ?? _sourceLabel(sample),
  );
}

String _kindForGroup(
  List<HealthSignalSample> items, {
  required HealthSignalSample? steps,
  required HealthSignalSample? heart,
  required HealthSignalSample? location,
}) {
  final stepValue = steps?.valueNum;
  if (stepValue != null && stepValue >= 80) return '步行';
  if (stepValue != null && stepValue < 30) return '静坐';
  final hr = heart?.valueNum;
  if (stepValue == null && hr != null && hr < 90) return '静坐';
  if (hr != null) return '心率';
  if (location != null && items.length == 1) return '位置';
  if (items.length == 1) return healthTypeLabel(items.first.type);
  return '活动';
}

String _metaFor(List<HealthSignalSample> items) {
  for (final sample in items) {
    final place = placeOf(sample);
    if (place != null) return place;
  }
  for (final sample in items) {
    if (sample.recordingId != null && sample.recordingId!.isNotEmpty) {
      return '已关联录音';
    }
  }
  return _sourceLabel(items.first);
}

String _sourceLabel(HealthSignalSample sample) {
  final name = sample.sourceName?.trim();
  if (name != null && name.isNotEmpty) return name;
  return '本机';
}

HealthSignalSample? _pick(List<HealthSignalSample> items, String type) {
  HealthSignalSample? best;
  for (final item in items) {
    if (item.type != type) continue;
    if (best == null || item.startMs >= best.startMs) best = item;
  }
  return best;
}

String formatHealthClock(int ms) {
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String formatZhDuration(int ms) {
  final totalMin = ms <= 0 ? 0 : (ms / 60000).round();
  final hours = totalMin ~/ 60;
  final minutes = totalMin % 60;
  if (hours > 0) return '$hours小时$minutes分';
  return '$minutes分';
}

String? placeOf(HealthSignalSample sample) {
  final direct = sample.metadata['place'];
  if (direct is String && direct.trim().isNotEmpty) return direct.trim();
  final text = sample.valueText;
  if (text == null || !text.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map && decoded['place'] is String) {
      final place = (decoded['place'] as String).trim();
      if (place.isNotEmpty) return place;
    }
  } on Object {
    return null;
  }
  return null;
}

String formatHealthMetric(HealthSignalSample sample) {
  final value = sample.valueNum;
  switch (sample.type) {
    case 'heart_rate':
    case 'resting_heart_rate':
    case 'walking_heart_rate_average':
    case 'heart_rate_recovery_one_minute':
      if (value == null) return healthTypeLabel(sample.type);
      return '${value.round()} bpm';
    case 'heart_rate_variability_sdnn':
      if (value == null) return 'HRV';
      return 'HRV ${value.round()} ms';
    case 'oxygen_saturation':
      if (value == null) return '血氧';
      final percent = value <= 1.5 ? value * 100 : value;
      return '血氧 ${percent.round()}%';
    case 'step_count':
      if (value == null) return '步数';
      final perMin = value.round();
      return perMin >= 80 ? '$perMin 步/分' : '$perMin 步';
    case 'respiratory_rate':
      if (value == null) return '呼吸';
      return '呼吸 ${value.round()} 次/分';
    case 'location':
      return placeOf(sample) ?? '已记录位置';
    case 'sleep_analysis':
      final duration = formatZhDuration(sample.endMs - sample.startMs);
      final stage = sample.valueText?.trim();
      if (stage != null && stage.isNotEmpty && !stage.startsWith('{')) {
        return '$stage · $duration';
      }
      return duration;
    case 'workout':
      final duration = formatZhDuration(sample.endMs - sample.startMs);
      final name = sample.valueText?.trim();
      if (name != null && name.isNotEmpty) return duration;
      return duration;
    case 'blood_pressure':
      final text = sample.valueText?.trim();
      if (text != null && text.isNotEmpty) return text;
      return '血压';
    default:
      if (value == null) {
        final text = sample.valueText?.trim();
        if (text != null && text.isNotEmpty && !text.startsWith('{')) {
          return text;
        }
        return healthTypeLabel(sample.type);
      }
      final unit = sample.unit?.trim();
      final number = _trimNum(value);
      if (unit == null || unit.isEmpty) return number;
      return '$number $unit';
  }
}

String _trimNum(double value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(1);
}
