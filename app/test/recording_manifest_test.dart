// 录音清单分段模型验收 —— 分段/事件 JSON 往返；Timeline 投影优先用分段：
// 对话=clean、原始数据=raw、标题/概览=阶段总结，且不编造说话人。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recordings_manifest.dart';

RecordingItem _item({List<RecordingSegment> segments = const [], List<RecordingEventSummary> events = const []}) =>
    RecordingItem(
      deviceName: '059F19DF.APM',
      apmPath: '/tmp/a.apm',
      wavPath: '/tmp/a.wav',
      transcript: '整文件转写',
      durationSecs: 60,
      recordedAt: DateTime(2026, 11, 9, 10),
      segments: segments,
      events: events,
    );

void main() {
  test('分段/事件 JSON 往返', () {
    final item = _item(
      segments: const [
        RecordingSegment(
          id: 'r-0',
          startMs: 0,
          endMs: 30000,
          rawText: '原始一',
          cleanText: '第一段',
          speaker: 'A',
        ),
      ],
      events: const [
        RecordingEventSummary(
          title: '话题一',
          overview: '概览一',
          startMs: 0,
          endMs: 30000,
          segmentIds: ['r-0'],
        ),
      ],
    );
    final back = RecordingItem.fromJson(item.toJson())!;
    expect(back.segments.single.cleanText, '第一段');
    expect(back.segments.single.rawText, '原始一');
    expect(back.events.single.title, '话题一');
  });

  test('有分段：对话用 clean、原始用 raw、标题用事件、说话人不编造', () {
    final item = _item(
      segments: const [
        RecordingSegment(
          id: 'r-0',
          startMs: 0,
          endMs: 30000,
          rawText: '嗯……原始一',
          cleanText: '第一段',
          speaker: 'A',
        ),
        RecordingSegment(
          id: 'r-1',
          startMs: 30000,
          endMs: 60000,
          rawText: '原始二',
          cleanText: '第二段',
          speaker: 'B',
        ),
      ],
      events: const [
        RecordingEventSummary(
          title: '话题一',
          overview: '概览一',
          startMs: 0,
          endMs: 60000,
          segmentIds: ['r-0', 'r-1'],
        ),
      ],
    );

    final event = item.event;
    expect(event.title, '话题一');
    expect(event.dialog.map((d) => d.text), ['第一段', '第二段']);
    expect(event.raw.map((d) => d.text), ['嗯……原始一', '原始二']);
    expect(event.speakers, 'A / B');
    expect(event.longText, '概览一');
    expect(event.srcMap, '来源 10:00—10:01');
  });

  test('多个阶段事件：Timeline 一条事件一张卡，内容按 segmentIds 拆分', () {
    final item = _item(
      segments: const [
        RecordingSegment(
          id: 'r-0',
          startMs: 0,
          endMs: 30000,
          rawText: '原始0',
          cleanText: '段0',
          speaker: 'A',
        ),
        RecordingSegment(
          id: 'r-1',
          startMs: 30000,
          endMs: 60000,
          rawText: '原始1',
          cleanText: '段1',
          speaker: 'B',
        ),
        RecordingSegment(
          id: 'r-2',
          startMs: 60000,
          endMs: 90000,
          rawText: '原始2',
          cleanText: '段2',
          speaker: 'B',
        ),
      ],
      events: const [
        RecordingEventSummary(
          title: '事件一',
          overview: '概览一',
          startMs: 0,
          endMs: 30000,
          segmentIds: ['r-0'],
        ),
        RecordingEventSummary(
          title: '事件二',
          overview: '概览二',
          startMs: 30000,
          endMs: 90000,
          segmentIds: ['r-1', 'r-2'],
        ),
      ],
    );

    final events = item.timelineEvents;
    expect(events, hasLength(2));
    expect(events.map((e) => e.title), ['事件一', '事件二']);
    expect(events[0].dialog.map((d) => d.text), ['段0']);
    expect(events[1].dialog.map((d) => d.text), ['段1', '段2']);
    expect(events[0].id, isNot(events[1].id));
    expect(events[1].speakers, 'B');
  });

  test('无分段/说话人缺失：回退旧整文件行为，标未区分', () {
    final item = _item();
    final event = item.event;
    expect(event.dialog.single.text, '整文件转写');
    expect(event.speakers, '未区分');

    final segmented = _item(segments: const [
      RecordingSegment(
        id: 'r-0',
        startMs: 0,
        endMs: 1000,
        rawText: '原始',
        cleanText: '清洗',
      )
    ]);
    expect(segmented.event.speakers, '未区分');
  });
}
