// 录音 → Timeline UI 模型适配验收（TDD）—— 字段映射、跨天 dayOffset、
// 时长格式、空 turns/raw 容错与按 recordedAt 倒序。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recording.dart';
import 'package:recording_card/services/recordings/recording_view_adapter.dart';

Recording _rec({
  String id = 'r1',
  String title = '项目周会',
  DateTime? at,
  int durationMs = 1120000,
  String? rawTranscript,
  String? cleanTranscript,
  String? mark,
  List<SpeakerTurn> turns = const [],
}) => Recording(
  id: id,
  title: title,
  recordedAt: at ?? DateTime(2026, 11, 8, 14, 20),
  durationMs: durationMs,
  rawTranscript: rawTranscript,
  cleanTranscript: cleanTranscript,
  mark: mark,
  turns: turns,
);

SpeakerTurn _turn(String spk, String text, int startMs, int endMs) =>
    SpeakerTurn(speaker: spk, text: text, startMs: startMs, endMs: endMs);

void main() {
  const adapter = RecordingViewAdapter();
  final now = DateTime(2026, 11, 8, 16, 5);

  test('字段映射：标题/时间/时长/摘要/说话人/来源/对话', () {
    final e = adapter.toRecordEvent(
      _rec(
        title: '项目周会',
        cleanTranscript: '讨论排期与分工。',
        rawTranscript: '呃，讨论一下排期。\n然后分工。',
        mark: '重要对话',
        turns: [
          _turn('B', '先砍两个低优先级功能。', 0, 120000),
          _turn('A', '可以，导出延后两周。', 120000, 240000),
          _turn('B', '我周五前给结论。', 1080000, 1120000),
        ],
      ),
      now: now,
    );

    expect(e.id, 'r1');
    expect(e.dayOffset, 0);
    expect(e.title, '项目周会');
    expect(e.time, '14:20');
    expect(e.dur, '18分40秒');
    expect(e.brief, '讨论排期与分工。');
    expect(e.longText, '讨论排期与分工。');
    expect(e.speakers, 'A / B');
    expect(e.mark, '重要对话');
    expect(e.srcMap, '来源 14:20—14:38');

    expect(e.dialog.map((l) => l.spk), ['B', 'A', 'B']);
    expect(e.dialog.map((l) => l.text), [
      '先砍两个低优先级功能。',
      '可以，导出延后两周。',
      '我周五前给结论。',
    ]);
    expect(e.dialog.map((l) => l.src), [
      '来源 14:20—14:22',
      '来源 14:22—14:24',
      '来源 14:38—14:38',
    ]);
  });

  test('raw 按换行拆行：跳过空行、统一未知说话人与原始转写来源', () {
    final e = adapter.toRecordEvent(
      _rec(rawTranscript: ' 第一行 \n\n第二行\r\n第三行\n'),
      now: now,
    );

    expect(e.raw.map((l) => l.spk), ['未知', '未知', '未知']);
    expect(e.raw.map((l) => l.text), ['第一行', '第二行', '第三行']);
    expect(e.raw.map((l) => l.src), ['原始转写', '原始转写', '原始转写']);
  });

  test('rawTranscript 为空时 raw 回退 dialog', () {
    final e = adapter.toRecordEvent(
      _rec(
        rawTranscript: '',
        cleanTranscript: '清洗后的内容。',
        turns: [_turn('A', '清洗后的内容。', 0, 120000)],
      ),
      now: now,
    );

    expect(e.raw, hasLength(1));
    expect(e.raw.first.spk, 'A');
    expect(e.raw.first.text, '清洗后的内容。');
    expect(e.raw.first.src, '来源 14:20—14:22');
  });

  test('cleanTranscript 缺失回退 rawTranscript，二者都缺失为空串', () {
    final withRaw = adapter.toRecordEvent(
      _rec(rawTranscript: '原始转写文本'),
      now: now,
    );
    expect(withRaw.brief, '原始转写文本');
    expect(withRaw.longText, '原始转写文本');

    final empty = adapter.toRecordEvent(_rec(), now: now);
    expect(empty.brief, '');
    expect(empty.longText, '');
    expect(empty.mark, '');
  });

  test('空 turns：说话人未知，来源按录音起点 + 时长推导', () {
    final e = adapter.toRecordEvent(_rec(turns: const []), now: now);

    expect(e.speakers, '未知');
    expect(e.srcMap, '来源 14:20—14:38');
    expect(e.dialog, isEmpty);
    expect(e.raw, isEmpty);
  });

  test('说话人去重排序，空说话人归入未知', () {
    final e = adapter.toRecordEvent(
      _rec(
        turns: [
          _turn('B', '一', 0, 1000),
          _turn('A', '二', 1000, 2000),
          _turn('B', '三', 2000, 3000),
          _turn('', '四', 3000, 4000),
        ],
      ),
      now: now,
    );

    expect(e.speakers, 'A / B');
    expect(e.dialog.map((l) => l.spk), ['B', 'A', 'B', '']);
  });

  test('时长格式：分钟秒 / 小时分钟 / 秒', () {
    final cases = <int, String>{
      1120000: '18分40秒',
      185000: '3分05秒',
      40000: '40秒',
      0: '0秒',
      3720000: '1小时2分',
      3600000: '1小时',
      5400000: '1小时30分',
    };
    for (final entry in cases.entries) {
      final e = adapter.toRecordEvent(_rec(durationMs: entry.key), now: now);
      expect(e.dur, entry.value, reason: '${entry.key}ms');
    }
  });

  test('dayOffset 按日历天而非 24 小时计算', () {
    // 同一天：00:05 与 23:50 只差 15 分钟，但跨了一个日历天。
    final crossDay = adapter.toRecordEvent(
      _rec(at: DateTime(2026, 11, 7, 23, 50)),
      now: DateTime(2026, 11, 8, 0, 5),
    );
    expect(crossDay.dayOffset, 1);
    expect(crossDay.time, '23:50');

    // 同一天内相隔 23 小时仍为 0。
    final sameDay = adapter.toRecordEvent(
      _rec(at: DateTime(2026, 11, 8, 0, 5)),
      now: DateTime(2026, 11, 8, 23, 50),
    );
    expect(sameDay.dayOffset, 0);

    final threeDays = adapter.toRecordEvent(
      _rec(at: DateTime(2026, 11, 5, 9)),
      now: now,
    );
    expect(threeDays.dayOffset, 3);
  });

  test('toTimelineEvents 按 recordedAt 倒序且不修改入参', () {
    final recordings = [
      _rec(id: 'old', at: DateTime(2026, 11, 1, 9)),
      _rec(id: 'new', at: DateTime(2026, 11, 3, 9)),
      _rec(id: 'mid', at: DateTime(2026, 11, 2, 9)),
    ];

    final events = adapter.toTimelineEvents(recordings, now: now);

    expect(events.map((e) => e.id), ['new', 'mid', 'old']);
    expect(events.map((e) => e.dayOffset), [5, 6, 7]);
    expect(recordings.map((r) => r.id), ['old', 'new', 'mid']);
  });
}
