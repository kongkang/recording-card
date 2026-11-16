import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';

RecordingFile _file({SegmentStatus status = SegmentStatus.closed}) {
  final start = DateTime.now()
      .subtract(const Duration(hours: 2))
      .millisecondsSinceEpoch;
  final end = start + 60000;
  return RecordingFile(
    deviceName: 'A.APM',
    session: 'S',
    seq: 1,
    startAtMs: start,
    apmPath: '/tmp/a.apm',
    createdAtMs: start,
    durationMs: 60000,
    timeSynced: true,
    slices: const [
      AudioSlice(
        id: '0001',
        index: 0,
        startMs: 0,
        endMs: 60000,
        wavPath: '/tmp/0.wav',
        silenceAfterMs: 25000,
      ),
    ],
    utterances: const [
      RawUtterance(
        id: '0001u0',
        sliceId: '0001',
        startMs: 1000,
        endMs: 4000,
        text: '原始一',
        emotion: 'NEUTRAL',
        speakerLabel: '说话人 1',
      ),
      RawUtterance(
        id: '0001u1',
        sliceId: '0001',
        startMs: 30000,
        endMs: 34000,
        text: '原始二',
        speakerLabel: '说话人 2',
      ),
    ],
    turns: const [
      PolishedTurn(
        id: 't0',
        startMs: 1000,
        endMs: 4000,
        speakerLabel: '说话人 1',
        text: '清洗一。',
        srcUtteranceIds: ['0001u0'],
      ),
    ],
    segments: [
      SegmentRecord(
        id: 'seg1',
        sessionId: 'S',
        index: 0,
        startAtMs: start,
        endAtMs: end,
        title: '项目讨论',
        brief: '讨论了排期',
        longText: '详细概述',
        speakerLabels: const ['说话人 1', '说话人 2'],
        speakerCount: 2,
        status: status,
        sliceIds: const ['0001'],
        turnIds: const ['t0'],
      ),
    ],
  );
}

void main() {
  test('分段投影：事件摘要 + 详情视图（turns/utterances/slices）', () {
    final result = SegmentProjection.build([_file()]);
    expect(result.events.length, 1);
    final e = result.events.single;
    expect(e.id, 'seg1');
    expect(e.title, '项目讨论');
    expect(e.brief, '讨论了排期');
    expect(e.longText, '详细概述');
    expect(e.speakers, '说话人 1 / 说话人 2（推测）');
    expect(e.live, isFalse);
    expect(e.note, isNull);
    expect(e.dialog.single.text, '清洗一。');
    expect(e.raw.length, 2);
    expect(e.raw.first.spk, contains('情绪 NEUTRAL'));
    expect(e.srcMap, startsWith('来源 '));

    final view = result.views['seg1']!;
    expect(view.turns.single.id, 't0');
    expect(view.utterances.length, 2);
    expect(view.slices.single.id, '0001');
  });

  test('live 分段：整理中、不可进详情（事件带 live 标记）', () {
    final result = SegmentProjection.build([
      _file(status: SegmentStatus.live),
    ]);
    final e = result.events.single;
    expect(e.live, isTrue);
    expect(e.note, '正在整理这段录音');
  });

  test('润色未完成：事件仍带原文 dialog，详情有降级提示', () {
    final file = _file();
    file.turns = const [];
    file.segments.first.turnIds = const [];
    file.polishStale = true;
    final result = SegmentProjection.build([file]);
    final e = result.events.single;
    expect(e.dialog, isNotEmpty);
    expect(e.dialog.first.text, '原始一');
    expect(e.note, isNull);
  });

  test('时间未校准：用户可见事件不再展示错误徽标', () {
    final file = _file();
    file.timeSynced = false;
    final e = SegmentProjection.build([file]).events.single;
    expect(e.note, isNull);
    expect(e.title, '项目讨论');
    expect(e.brief, '讨论了排期');
  });

  test('fallback 清洗未完成：不展示总结未完成，仍给出标题与摘要', () {
    final file = _file();
    file.segments.first.fallback = true;
    final e = SegmentProjection.build([file]).events.single;
    expect(e.note, isNull);
    expect(e.note, isNot(equals('总结未完成')));
    expect(e.title, '项目讨论');
    expect(e.brief, '讨论了排期');
    expect(e.brief.contains('总结未完成'), isFalse);
    expect(e.brief.contains('清洗未完成'), isFalse);
  });

  test('summary 优先映射到事件卡摘要', () {
    final file = _file();
    file.segments.first.brief = '';
    file.segments.first.summary = '和同事确认了今晚的测试安排。';
    final e = SegmentProjection.build([file]).events.single;
    expect(e.brief, '和同事确认了今晚的测试安排。');
  });
}
