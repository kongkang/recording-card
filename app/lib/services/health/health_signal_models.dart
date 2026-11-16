/// 本机健康 / 位置样本、查询条件，以及和录音时间的重叠关联。
///
/// 时间一律是 Unix 毫秒。点样本的 [HealthSignalSample.endMs] 可以等于
/// [HealthSignalSample.startMs]；睡眠、锻炼这类跨度样本保留原始起止。
library;

import 'dart:convert';

/// 一条已落盘录音的绝对时间区间。
class RecordingSpan {
  const RecordingSpan({
    required this.id,
    required this.startMs,
    required this.endMs,
  });

  final String id;
  final int startMs;
  final int endMs;
}

/// 样本与录音区间重叠时，选重叠最长的录音；一样长则取较晚开始的那条。
///
/// 点样本（end <= start）按一个时刻判断：落在 `[span.start, span.end)` 内即关联。
String? linkRecordingId(int startMs, int endMs, List<RecordingSpan> spans) {
  final sampleEnd = endMs < startMs ? startMs : endMs;
  final point = sampleEnd == startMs;
  String? bestId;
  var bestOverlap = 0;
  var bestStart = -1 << 62;
  for (final span in spans) {
    if (span.id.isEmpty || span.endMs <= span.startMs) continue;
    if (point) {
      if (startMs < span.startMs || startMs >= span.endMs) continue;
      final overlap = 1;
      if (overlap > bestOverlap ||
          (overlap == bestOverlap && span.startMs >= bestStart)) {
        bestOverlap = overlap;
        bestStart = span.startMs;
        bestId = span.id;
      }
      continue;
    }
    final left = startMs > span.startMs ? startMs : span.startMs;
    final right = sampleEnd < span.endMs ? sampleEnd : span.endMs;
    final overlap = right - left;
    if (overlap <= 0) continue;
    if (overlap > bestOverlap ||
        (overlap == bestOverlap && span.startMs >= bestStart)) {
      bestOverlap = overlap;
      bestStart = span.startMs;
      bestId = span.id;
    }
  }
  return bestId;
}

/// 平台无关的样本查询。
///
/// 时间范围按交集：样本满足 `endMs >= startMs`（查询下界，含）且
/// `startMs < endMs`（查询上界，不含）。[source] 同时匹配来源名和 bundle。
class HealthSignalQuery {
  const HealthSignalQuery({
    this.startMs,
    this.endMs,
    this.type,
    this.source,
    this.recordingId,
    this.limit = 200,
    this.offset = 0,
    this.ascending = false,
  });

  final int? startMs;
  final int? endMs;
  final String? type;
  final String? source;
  final String? recordingId;
  final int limit;
  final int offset;
  final bool ascending;
}

/// 一行已采集样本。身份由类型、代表时刻和来源组成，重复导入会覆盖。
class HealthSignalSample {
  const HealthSignalSample({
    required this.id,
    required this.type,
    required this.startMs,
    required this.endMs,
    required this.ingestedAtMs,
    this.valueNum,
    this.valueText,
    this.unit,
    this.sourceName,
    this.sourceBundle,
    this.recordingId,
    this.aggregation = 'point',
    this.metadata = const {},
  });

  final String id;
  final String type;
  final int startMs;
  final int endMs;
  final double? valueNum;
  final String? valueText;
  final String? unit;
  final String? sourceName;
  final String? sourceBundle;
  final String? recordingId;

  /// `nearest` / `sum` / `average` / `span` / `point` / `characteristic`。
  final String aggregation;
  final Map<String, Object?> metadata;
  final int ingestedAtMs;

  Map<String, Object?> toRow() => {
    'id': id,
    'type': type,
    'start_ms': startMs,
    'end_ms': endMs < startMs ? startMs : endMs,
    'value_num': valueNum,
    'value_text': valueText,
    'unit': unit,
    'source_name': sourceName,
    'source_bundle': sourceBundle,
    'recording_id': recordingId,
    'aggregation': aggregation,
    'metadata_json': metadata.isEmpty ? null : jsonEncode(metadata),
    'ingested_at_ms': ingestedAtMs,
  };

  factory HealthSignalSample.fromRow(Map<String, Object?> row) {
    return HealthSignalSample(
      id: '${row['id'] ?? ''}',
      type: '${row['type'] ?? ''}',
      startMs: _asInt(row['start_ms']),
      endMs: _asInt(row['end_ms']),
      valueNum: _asDouble(row['value_num']),
      valueText: row['value_text'] as String?,
      unit: row['unit'] as String?,
      sourceName: row['source_name'] as String?,
      sourceBundle: row['source_bundle'] as String?,
      recordingId: row['recording_id'] as String?,
      aggregation: '${row['aggregation'] ?? 'point'}',
      metadata: decodeHealthMetadata(row['metadata_json']),
      ingestedAtMs: _asInt(row['ingested_at_ms']),
    );
  }
}

String healthSampleId({
  required String type,
  required int startMs,
  String? sourceBundle,
}) {
  final src = (sourceBundle == null || sourceBundle.isEmpty)
      ? '-'
      : sourceBundle;
  return '$type|$startMs|$src';
}

Map<String, Object?> decodeHealthMetadata(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
  } on Object {
    return const {};
  }
  return const {};
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
