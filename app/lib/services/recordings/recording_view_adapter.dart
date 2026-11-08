/// 录音 → Timeline UI 模型适配 —— 把录音卡采集到的 [Recording] 还原成
/// 现有页面使用的 [RecordEvent]（dayOffset / 时长 / 说话人 / 来源 / 对话 / 原始转写）。
library;

import '../../core/models/record.dart';
import 'recording.dart';

/// 无状态适配器；实例方法与顶层函数等价，便于注入或直接调用。
class RecordingViewAdapter {
  const RecordingViewAdapter();

  RecordEvent toRecordEvent(Recording r, {DateTime? now}) => _adapt(r, now);

  List<RecordEvent> toTimelineEvents(
    List<Recording> recordings, {
    DateTime? now,
  }) => _adaptAll(recordings, now);
}

/// 单条录音 → [RecordEvent]。
///
/// [now] 为「今天」的基准时间（测试可注入）；不传则取本地当前时间。
RecordEvent toRecordEvent(Recording r, {DateTime? now}) => _adapt(r, now);

/// 批量适配并按 [Recording.recordedAt] 倒序（最新在前）。
///
/// 全部事件共用同一个 [now] 基准，避免跨零点时同批数据出现日期不一致。
List<RecordEvent> toTimelineEvents(
  List<Recording> recordings, {
  DateTime? now,
}) => _adaptAll(recordings, now);

RecordEvent _adapt(Recording r, DateTime? now) {
  final brief = r.cleanTranscript ?? r.rawTranscript ?? '';
  final dialog = <TurnLine>[
    for (final turn in r.turns)
      TurnLine(
        turn.speaker,
        turn.text,
        _rangeLabel(r.recordedAt, turn.startMs, turn.endMs),
      ),
  ];
  return RecordEvent(
    id: r.id,
    dayOffset: _calendarDayOffset(now ?? DateTime.now(), r.recordedAt),
    title: r.title,
    brief: brief,
    longText: brief,
    time: _hm(r.recordedAt),
    dur: _durationLabel(r.durationMs),
    speakers: _speakerLabel(r.turns),
    mark: r.mark ?? '',
    srcMap: _sourceMap(r),
    dialog: dialog,
    raw: _rawLines(r.rawTranscript, dialog),
  );
}

List<RecordEvent> _adaptAll(List<Recording> recordings, DateTime? now) {
  final clock = now ?? DateTime.now();
  final sorted = [...recordings]
    ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  return [for (final r in sorted) _adapt(r, clock)];
}

/// 日历天差（0=今天，1=昨天）：按年月日比较，不受时刻与夏令时影响。
int _calendarDayOffset(DateTime now, DateTime at) {
  final today = DateTime.utc(now.year, now.month, now.day);
  final day = DateTime.utc(at.year, at.month, at.day);
  return today.difference(day).inDays;
}

/// 录音整体来源区间：优先用 turns 的最早开始与最晚结束，无 turns 时用录音时长。
String _sourceMap(Recording r) {
  if (r.turns.isEmpty) {
    return _rangeLabel(r.recordedAt, 0, r.durationMs);
  }
  var startMs = r.turns.first.startMs;
  var endMs = r.turns.first.endMs;
  for (final turn in r.turns.skip(1)) {
    if (turn.startMs < startMs) startMs = turn.startMs;
    if (turn.endMs > endMs) endMs = turn.endMs;
  }
  return _rangeLabel(r.recordedAt, startMs, endMs);
}

/// "来源 HH:mm—HH:mm"，时间点 = recordedAt + 毫秒偏移。
String _rangeLabel(DateTime base, int startMs, int endMs) =>
    '来源 ${_clockAt(base, startMs)}—${_clockAt(base, endMs)}';

String _clockAt(DateTime base, int offsetMs) =>
    _hm(base.add(Duration(milliseconds: offsetMs)));

String _hm(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

/// 中文时长：1 小时内保留秒（18分40秒），超过 1 小时省略秒（1小时2分）。
String _durationLabel(int milliseconds) {
  final totalSeconds = milliseconds <= 0 ? 0 : milliseconds ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return minutes == 0 ? '$hours小时' : '$hours小时$minutes分';
  }
  if (minutes > 0) {
    return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
  }
  return '$seconds秒';
}

/// turns 的说话人去重排序；没有可用说话人时显示「未知」。
String _speakerLabel(List<SpeakerTurn> turns) {
  final names = <String>{
    for (final turn in turns)
      if (turn.speaker.trim().isNotEmpty) turn.speaker.trim(),
  }.toList()..sort();
  return names.isEmpty ? '未知' : names.join(' / ');
}

/// 原始转写按行拆分；空文本回退清洗后的 dialog，绝不丢内容。
List<TurnLine> _rawLines(String? rawTranscript, List<TurnLine> dialog) {
  if (rawTranscript == null || rawTranscript.trim().isEmpty) {
    return [...dialog];
  }
  return [
    for (final line in rawTranscript.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) TurnLine('未知', line.trim(), '原始转写'),
  ];
}
