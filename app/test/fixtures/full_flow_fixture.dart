import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';

/// Non-sensitive, test-only records. Never import this file from lib/.
/// Fresh lists on every call prevent fixture mutation leaking between tests.
List<RecordEvent> fullFlowFixtureEvents() => [
  const RecordEvent(
    id: 'qa-orchid',
    dayOffset: 0,
    title: '兰花实验记录',
    brief: '比较两种浇水周期。',
    longText: '测试文本：每周二检查湿度，保留不确定的说话人归类。',
    time: '09:10',
    dur: '2分00秒',
    speakers: 'A / B（推测）',
    mark: '09:11',
    srcMap: '来源 09:10—09:12',
    dialog: [TurnLine('A', '周二检查湿度。', '09:10—09:11')],
    raw: [TurnLine('A', '嗯，周二，啊，检查湿度。', '09:10—09:11')],
  ),
  const RecordEvent(
    id: 'qa-lantern',
    dayOffset: 1,
    title: '纸灯笼材料比较',
    brief: '讨论纸张耐用性，而非项目排期。',
    longText: '测试特殊字符：<材料> & "纸张"；不包含真实用户数据。',
    time: '16:00',
    dur: '3分00秒',
    speakers: 'A（推测）',
    mark: '',
    srcMap: '来源 16:00—16:03',
    dialog: [TurnLine('A', '比较纸张耐用性。', '16:00—16:02')],
    raw: [TurnLine('A', '呃，比较纸张，耐用性。', '16:00—16:02')],
  ),
];

/// Explicit completed result fixture, not a stand-in for AnalysisService.
/// Its sources intentionally refer only to the orchid record, not all records.
SummaryCard fullFlowFixtureSummary() =>
    SummaryCard(
        id: 'qa-summary-orchid',
        time: '10:00',
        state: SummaryState.done,
      )
      ..progress = 100
      ..srcIds = ['qa-orchid']
      ..title = '兰花检查计划'
      ..subDesc = '1 条记录'
      ..overview = '仅根据兰花记录：周二检查湿度。'
      ..structure = [
        const MapBranch('检查', ['周二检查湿度']),
      ]
      ..points = [
        const InfoPoint('检查周期', '周二检查湿度。', [
          SourceRef('qa-orchid', '兰花实验记录', '09:10—09:11'),
        ]),
      ]
      ..todos = ['周二检查湿度']
      ..srcDesc = '1 条记录'
      ..markdown = '# 兰花检查计划\n\n周二检查湿度。\n\n来源 qa-orchid 09:10—09:11\n';

/// QA oracle over EXISTING public models; this does not replace production
/// validation. SourceRef.range is an HH:mm range at this baseline. New services
/// should also test their absolute timestamp/ms mapping via the JSON auditor.
List<String> auditFixtureSources(
  SummaryCard summary,
  List<RecordEvent> events, {
  required Set<String> selectedIds,
}) {
  final errors = <String>[];
  final byId = {for (final event in events) event.id: event};
  if (byId.length != events.length) errors.add('duplicate record id');
  if (summary.srcIds.toSet().length != summary.srcIds.length) {
    errors.add('duplicate summary source');
  }
  for (final id in selectedIds) {
    if (!byId.containsKey(id)) errors.add('unknown selection: $id');
  }
  for (final id in summary.srcIds) {
    if (!byId.containsKey(id) || !selectedIds.contains(id)) {
      errors.add('illegal summary source: $id');
    }
  }
  if (summary.state == SummaryState.done && summary.srcIds.isEmpty) {
    errors.add('completed summary without sources');
  }
  for (final point in summary.points) {
    if (point.sources.isEmpty) errors.add('information point without sources');
    for (final ref in point.sources) {
      final event = byId[ref.eventId];
      if (event == null || !summary.srcIds.contains(ref.eventId)) {
        errors.add('illegal point source: ${ref.eventId}');
        continue;
      }
      final outer = _clockRange(event.srcMap.replaceFirst('来源 ', ''));
      final inner = _clockRange(ref.range);
      if (outer == null ||
          inner == null ||
          inner.$1 < outer.$1 ||
          inner.$2 > outer.$2) {
        errors.add('out-of-range source: ${ref.eventId} ${ref.range}');
      }
      if (ref.label != event.title) errors.add('source label mismatch');
    }
  }
  return errors;
}

(int, int)? _clockRange(String value) {
  final match = RegExp(
    r'^(\d{2}):(\d{2})[—–-](\d{2}):(\d{2})$',
  ).firstMatch(value);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
  if (parts[0] > 23 || parts[2] > 23 || parts[1] > 59 || parts[3] > 59) {
    return null;
  }
  final start = parts[0] * 60 + parts[1];
  final end = parts[2] * 60 + parts[3];
  // Ambiguous cross-midnight ranges need actual dates, not invented offsets.
  return end >= start ? (start, end) : null;
}
