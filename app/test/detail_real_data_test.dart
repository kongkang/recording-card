import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/test_transitions.dart';

RecordingFile _file({
  SegmentStatus status = SegmentStatus.closed,
  bool polishStale = false,
}) {
  final start = DateTime.now()
      .subtract(const Duration(hours: 2))
      .millisecondsSinceEpoch;
  return RecordingFile(
    deviceName: 'A.APM',
    session: 'S',
    seq: 1,
    startAtMs: start,
    apmPath: '/tmp/a.apm',
    createdAtMs: start,
    durationMs: 60000,
    timeSynced: true,
    polishStale: polishStale,
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
    turns: polishStale
        ? const []
        : const [
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
        endAtMs: start + 60000,
        title: status == SegmentStatus.live ? '整理中…' : '项目讨论',
        brief: '讨论了排期',
        longText: '详细概述',
        speakerLabels: const ['说话人 1', '说话人 2'],
        speakerCount: 2,
        status: status,
        sliceIds: const ['0001'],
        turnIds: polishStale ? const [] : const ['t0'],
      ),
    ],
  );
}

AppStore _storeFor(RecordingFile file) {
  final result = SegmentProjection.build([file]);
  final store = AppStore(events: result.events);
  store.segmentViews = result.views;
  return store;
}

Widget _host(AppStore store, Widget child) => StoreScope(
  store: store,
  child: MaterialApp(theme: testTheme(), home: Scaffold(body: child)),
);

void main() {
  testWidgets('详情页：对话详情用润色 turn，原始数据按切片分组', (tester) async {
    final store = _storeFor(_file());
    addTearDown(store.dispose);
    await tester.pumpWidget(_host(store, const DetailPage(eventId: 'seg1')));
    await tester.pump();

    expect(find.text('清洗一。'), findsOneWidget);
    expect(find.textContaining('说话人 1'), findsWidgets);

    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();

    expect(find.byKey(const Key('raw-slice-0001')), findsOneWidget);
    expect(find.text('原始一'), findsOneWidget);
    expect(find.text('原始二'), findsOneWidget);
    expect(find.textContaining('情绪 NEUTRAL'), findsOneWidget);
    expect(find.textContaining('静音约 25 秒'), findsOneWidget);
  });

  testWidgets('详情页：润色未完成时提示并回退本地原文', (tester) async {
    final store = _storeFor(_file(polishStale: true));
    addTearDown(store.dispose);
    await tester.pumpWidget(_host(store, const DetailPage(eventId: 'seg1')));
    await tester.pump();

    expect(find.byKey(const Key('detail-note')), findsNothing);
    expect(find.textContaining('总结未完成'), findsNothing);
    expect(find.textContaining('清洗未完成'), findsNothing);
    expect(find.textContaining('部分内容未润色'), findsNothing);
    expect(find.text('原始一'), findsOneWidget);
  });

  testWidgets('Timeline：live 分段显示整理中，不可勾选/进详情', (tester) async {
    final store = _storeFor(_file(status: SegmentStatus.live));
    addTearDown(store.dispose);
    store
      ..selMode = true
      ..selIds.clear();
    await tester.pumpWidget(_host(store, const TimelinePage()));
    await tester.pump();

    expect(find.text('整理中'), findsOneWidget);
    expect(find.byKey(const Key('detail-seg1')), findsNothing);
    expect(find.byKey(const Key('selbox-seg1')), findsNothing);
  });

  testWidgets('原始数据：播放器吸顶不随列表滚走、带可拖拽进度条、按切片自身时长展示并支持点卡片快进', (
    tester,
  ) async {
    late Directory tmp;
    late String wavPath;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('rc-detail-raw-');
      wavPath = '${tmp.path}/slice_0005.wav';
      // 生成真实 60 秒 16kHz 单声道 WAV
      await File(wavPath).writeAsBytes(
        encodeWav(Float32List(16000 * 60)),
        flush: true,
      );
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    final start = DateTime.now()
        .subtract(const Duration(minutes: 10))
        .millisecondsSinceEpoch;
    final manyUtterances = [
      for (var i = 0; i < 18; i++)
        RawUtterance(
          id: '0001u$i',
          sliceId: '0001',
          startMs: i * 3000,
          endMs: i * 3000 + 2000,
          text: '第 $i 句测试语音内容用于验证列表滚动与时间戳快进联动',
          speakerLabel: '说话人 1',
        ),
    ];
    final file = RecordingFile(
      deviceName: 'LIVE_2DD798CE_0006.WAV',
      session: '2DD798CE',
      seq: 6,
      startAtMs: start,
      apmPath: wavPath,
      wavPath: wavPath,
      createdAtMs: start,
      durationMs: 60000,
      timeSynced: true,
      slices: [
        AudioSlice(
          id: '0001',
          index: 0,
          startMs: 0,
          endMs: 60000,
          wavPath: wavPath,
        ),
      ],
      utterances: manyUtterances,
      segments: [
        SegmentRecord(
          id: 'seg6',
          sessionId: '2DD798CE',
          index: 5,
          startAtMs: start,
          endAtMs: start + 60000,
          title: '第六片实时切片',
          brief: '摘要',
          longText: '一\n二\n三\n四\n五\n六\n七',
          status: SegmentStatus.closed,
          sliceIds: const ['0001'],
        ),
      ],
    );

    final store = _storeFor(file);
    addTearDown(store.dispose);
    await tester.pumpWidget(_host(store, const DetailPage(eventId: 'seg6')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.byKey(const Key('raw-sticky-player')), findsOneWidget);
    expect(find.byKey(const Key('raw-audio-slider')), findsOneWidget);
    expect(
      find.text('00:00 / 01:00'),
      findsOneWidget,
      reason: '第 6 个切片应只显示自身 1 分钟时长，而非整场 6 分钟',
    );

    final topBefore = tester
        .getTopLeft(find.byKey(const Key('raw-audio-player')))
        .dy;
    // 持续滚动原始数据列表直到底部第 10 句卡片出现，验证吸顶播放器位置纹丝不动
    await tester.scrollUntilVisible(
      find.byKey(const Key('raw-utt-0001u10')),
      180,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
    final topAfter = tester
        .getTopLeft(find.byKey(const Key('raw-audio-player')))
        .dy;
    expect(topAfter, topBefore, reason: '播放器必须 sticky 固定在原始数据顶部');

    // 点击第 10 句卡片（startMs = 30000ms = 00:30），进度立即跳到 00:30 / 01:00
    await tester.tap(find.byKey(const Key('raw-utt-0001u10')));
    await tester.pump();
    expect(find.text('00:30 / 01:00'), findsOneWidget);
  });

  testWidgets('Timeline：展开简介最多 4 行，且录音中下拉刷新不会丢失顶部录音状态块', (
    tester,
  ) async {
    final status = RecordingStatusController()..startRecording();
    status.updateElapsed(125);
    addTearDown(status.dispose);
    final result = SegmentProjection.build([_file()]);
    final store = AppStore(events: result.events, status: status)
      ..segmentViews = result.views;
    addTearDown(store.dispose);
    store.deviceConnected = () => true;
    store.deviceRecording = () => true;

    await tester.pumpWidget(
      _host(store, TimelinePage(recordingStatus: status)),
    );
    await tester.pump();

    expect(find.byKey(const Key('recording-status-block')), findsOneWidget);
    expect(status.phase, RecordingPhase.recording);

    // 折叠态即展示 2–3 行生活摘要
    final briefText = tester.widget<Text>(find.byKey(const Key('card-summary-seg1')));
    expect(briefText.data, '讨论了排期');
    expect(briefText.maxLines, 3);
    expect(briefText.overflow, TextOverflow.ellipsis);

    // 展开后显示更完整概述
    await tester.tap(find.byKey(const Key('card-seg1')));
    await tester.pump();
    final summaryText = tester.widget<Text>(find.text('详细概述'));
    expect(summaryText.maxLines, 4);
    expect(summaryText.overflow, TextOverflow.ellipsis);

    // 录音期间触发下拉刷新：顶部「正在录音」状态块不得被冲掉
    await store.syncRecordings();
    await tester.pump();
    expect(status.phase, RecordingPhase.recording);
    expect(find.byKey(const Key('recording-status-block')), findsOneWidget);
  });
  testWidgets('对话详情：同人短间隔一段，长停顿同气泡另起一段，换人新气泡，不见情绪标签', (
    tester,
  ) async {
    final start = DateTime.now()
        .subtract(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    final file = RecordingFile(
      deviceName: 'PAUSE.APM',
      session: 'S_PAUSE',
      seq: 1,
      startAtMs: start,
      apmPath: '/tmp/pause.apm',
      createdAtMs: start,
      durationMs: 180000,
      timeSynced: true,
      stage: RecordingStage.ready,
      utterances: const [
        RawUtterance(
          id: 'u0',
          sliceId: 's1',
          startMs: 1000,
          endMs: 8000,
          text: '今晚先把方案写完。',
          emotion: 'HAPPY',
          speakerLabel: '说话人 1',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 't0',
          startMs: 1000,
          endMs: 8000,
          speakerLabel: '说话人 1（推测）',
          text: '今晚先把方案写完。',
          srcUtteranceIds: ['u0'],
        ),
        PolishedTurn(
          id: 't1',
          startMs: 9000,
          endMs: 16000,
          speakerLabel: '说话人 1（推测）',
          text: '把纪要也一并发到群里。',
          srcUtteranceIds: ['u0'],
        ),
        PolishedTurn(
          id: 't2',
          startMs: 50000,
          endMs: 62000,
          speakerLabel: '说话人 1（推测）',
          text: '明日早间再同步给团队。',
          srcUtteranceIds: ['u0'],
        ),
        PolishedTurn(
          id: 't3',
          startMs: 70000,
          endMs: 80000,
          speakerLabel: '说话人 2（推测）',
          text: '好，我早上先看一眼。',
          srcUtteranceIds: ['u1'],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-pause',
          sessionId: 'S_PAUSE',
          index: 0,
          startAtMs: start,
          endAtMs: start + 180000,
          title: '晨间工作计划',
          brief: '先写完方案，明早再同步。',
          longText: '先把方案和纪要准备好，明早再同步给团队。',
          speakerLabels: const ['说话人 1', '说话人 2'],
          speakerCount: 2,
          status: SegmentStatus.closed,
          turnIds: const ['t0', 't1', 't2', 't3'],
        ),
      ],
    );
    final store = _storeFor(file);
    addTearDown(store.dispose);
    await tester.pumpWidget(_host(store, const DetailPage(eventId: 'seg-pause')));
    await tester.pump();

    // 短间隔 t0+t1 与长停顿 t2 都在同一个气泡；换人 t3 新气泡
    expect(find.byKey(const Key('turn-spk-0')), findsOneWidget);
    expect(find.byKey(const Key('turn-spk-1')), findsNothing);
    expect(find.byKey(const Key('turn-spk-2')), findsNothing);
    expect(find.byKey(const Key('turn-spk-3')), findsOneWidget);
    expect(find.byKey(const Key('turn-para-seg-pause-0')), findsOneWidget);
    expect(
      find.byKey(const Key('turn-para-body-seg-pause-0-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('turn-para-body-seg-pause-0-1')),
      findsOneWidget,
    );
    expect(find.textContaining('今晚先把方案写完。把纪要也一并发到群里。'), findsOneWidget);
    expect(find.text('明日早间再同步给团队。'), findsOneWidget);
    expect(find.text('好，我早上先看一眼。'), findsOneWidget);
    expect(find.textContaining('（推测）'), findsNothing);
    expect(find.textContaining('HAPPY'), findsNothing);
    expect(find.textContaining('情绪'), findsNothing);

    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();
    expect(find.textContaining('情绪 HAPPY'), findsOneWidget);
    expect(find.text('今晚先把方案写完。'), findsOneWidget);
  });
}
