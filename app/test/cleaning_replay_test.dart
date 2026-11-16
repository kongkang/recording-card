import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/schedule/cleaning_replay.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';

void main() {
  test('回放清掉 AI 整理，保留原始转写和音频，并按窗口逐步放出', () async {
    final tmp = await Directory.systemTemp.createTemp('rc-replay-');
    addTearDown(() => tmp.delete(recursive: true));
    final store = RecordingStore(
      root: tmp,
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    final wav = File('${tmp.path}/keep.wav');
    final apm = File('${tmp.path}/keep.apm');
    await wav.writeAsBytes(const [1, 2, 3, 4, 5]);
    await apm.writeAsBytes(const [9, 9]);

    final file = RecordingFile(
      deviceName: 'KEEP01.WAV',
      session: 'sess',
      seq: 1,
      startAtMs: 0,
      apmPath: apm.path,
      createdAtMs: 1,
      wavPath: wav.path,
      durationMs: 670000,
      stage: RecordingStage.ready,
      slices: [
        AudioSlice(
          id: '0001',
          index: 0,
          startMs: 0,
          endMs: 670000,
          wavPath: wav.path,
          stage: SliceStage.transcribed,
        ),
      ],
      utterances: const [
        RawUtterance(
          id: 'u1',
          sliceId: '0001',
          startMs: 60000,
          endMs: 70000,
          text: '今天下午讨论了排期',
        ),
        RawUtterance(
          id: 'u2',
          sliceId: '0001',
          startMs: 360000,
          endMs: 370000,
          text: '第二段还在谈排期',
        ),
        RawUtterance(
          id: 'u3',
          sliceId: '0001',
          startMs: 660000,
          endMs: 670000,
          text: '第三段收尾',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 't1',
          startMs: 60000,
          endMs: 70000,
          speakerLabel: '说话人 1',
          text: '润色后的句子',
          srcUtteranceIds: ['u1'],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg1',
          sessionId: 'sess',
          index: 0,
          startAtMs: 0,
          endAtMs: 670000,
          title: '云端润色标题',
          brief: '云端摘要',
          longText: '云端长文',
          status: SegmentStatus.closed,
          sliceIds: const ['0001'],
          turnIds: const ['t1'],
        ),
      ],
    );
    await store.save(file);

    final topics = TopicSegmentationStore(resolveRoot: store.root);
    await topics.save(
      TopicSegmentationState(
        rollingByAnchor: {
          'seg1': TopicRunSegmentation(
            runKey: 'seg1',
            startAtMs: 0,
            endAtMs: 670000,
            evaluatedAtMs: 1,
            sections: const [
              TopicSectionOverride(
                title: '旧的云端话题',
                brief: '旧摘要',
                startTurnIndex: 0,
                endTurnIndex: 0,
                paragraphs: [
                  TopicParagraph(
                    speaker: '说话人 1',
                    text: '旧段落',
                    startAtMs: 0,
                    endAtMs: 1000,
                  ),
                ],
              ),
            ],
          ),
        },
      ),
    );

    final visibleCounts = <int>[];
    final result = await CleaningReplayService().run(
      store: store,
      topicStore: topics,
      windowMinutes: 5,
      cleanWindow: (visible, simNow, sessionEnded) async {
        visibleCounts.add(visible.single.utterances.length);
        expect(visible.single.wavPath, wav.path);
        expect(visible.single.turns, isEmpty);
        if (sessionEnded) {
          await topics.save(
            TopicSegmentationState(
              rollingByAnchor: {
                'seg1': TopicRunSegmentation(
                  runKey: 'seg1',
                  startAtMs: 0,
                  endAtMs: 670000,
                  evaluatedAtMs: 2,
                  sections: const [
                    TopicSectionOverride(
                      title: '新的回放话题',
                      brief: '新摘要',
                      startTurnIndex: 0,
                      endTurnIndex: 0,
                    ),
                  ],
                ),
              },
            ),
          );
        }
        return sessionEnded ? 1 : 0;
      },
    );

    expect(visibleCounts, [1, 2, 3]);
    expect(result.utterancesKept, 3);
    expect(result.windowsRun, 3);
    expect(result.cleanBatches, 1);
    expect(await wav.readAsBytes(), [1, 2, 3, 4, 5]);
    expect(await apm.readAsBytes(), [9, 9]);

    final reloaded = (await store.loadAll(refresh: true)).single;
    expect(reloaded.utterances.map((u) => u.text).toList(), [
      '今天下午讨论了排期',
      '第二段还在谈排期',
      '第三段收尾',
    ]);
    expect(reloaded.turns, isEmpty);
    expect(reloaded.segments.single.title, isNot('云端润色标题'));
    expect(reloaded.segments.single.brief, isNot('云端摘要'));
    expect(reloaded.wavPath, wav.path);
    expect(reloaded.apmPath, apm.path);

    final state = await topics.load(refresh: true);
    expect(state.rollingByAnchor['seg1']?.sections.single.title, '新的回放话题');
    expect(state.toJson().toString().contains('旧的云端话题'), isFalse);
  });

  test('1 分钟窗口也会逐步放出，不会一次把全部转写交出去', () async {
    final file = RecordingFile(
      deviceName: 'WIN.WAV',
      session: 's',
      seq: 1,
      startAtMs: 0,
      apmPath: '/tmp/win.apm',
      createdAtMs: 1,
      utterances: const [
        RawUtterance(
          id: 'u1',
          sliceId: 'a',
          startMs: 0,
          endMs: 10000,
          text: '第一分钟',
        ),
        RawUtterance(
          id: 'u2',
          sliceId: 'b',
          startMs: 60000,
          endMs: 70000,
          text: '第二分钟',
        ),
      ],
      slices: const [
        AudioSlice(
          id: 'a',
          index: 0,
          startMs: 0,
          endMs: 30000,
          wavPath: '/tmp/a.wav',
        ),
        AudioSlice(
          id: 'b',
          index: 1,
          startMs: 60000,
          endMs: 90000,
          wavPath: '/tmp/b.wav',
        ),
      ],
    );
    final first = maskRecording(file, 60000);
    expect(first.utterances.map((u) => u.id), ['u1']);
    expect(first.slices.map((s) => s.id), ['a']);
    final second = maskRecording(file, 70000);
    expect(second.utterances.map((u) => u.id), ['u1', 'u2']);
    expect(file.utterances, hasLength(2));
  });
}
