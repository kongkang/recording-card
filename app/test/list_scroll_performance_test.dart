library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/segment_view.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/pages/summary_result_page.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/widgets/photo_thumbnail.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/harness.dart';
import 'support/test_transitions.dart';

const String _kPng4x4Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGMwOR75HxkzkC4AAOFIJTGNUj/yAAAAAElFTkSuQmCC';

List<RecordEvent> _manyEvents(int count) {
  return [
    for (var i = 0; i < count; i++)
      RecordEvent(
        id: 'perf-$i',
        dayOffset: i ~/ 10,
        title: '记录 #$i',
        brief: '这是第 $i 条录音记录的摘要文本。',
        longText: '这是第 $i 条录音记录的详细内容。',
        time:
            '${(23 - (i % 10)).toString().padLeft(2, '0')}:00',
        dur: '5分00秒',
        speakers: '说话人 1',
        mark: '',
        srcMap: '',
        dialog: const [
          TurnLine('说话人 1', '今天上午我们同步了产品发布计划和核心接口进度。', '00:00'),
        ],
        raw: const [
          TurnLine('说话人 1', '今天上午我们同步了产品发布计划和核心接口进度。', '00:00'),
        ],
      ),
  ];
}

RecordingFile _sampleFile(
  String name, {
  required int startAtMs,
  String title = '讨论',
}) {
  return RecordingFile(
    deviceName: name,
    session: 'S-$name',
    seq: 1,
    startAtMs: startAtMs,
    apmPath: '/tmp/$name.apm',
    wavPath: '/tmp/$name.wav',
    durationMs: 60000,
    stage: RecordingStage.ready,
    createdAtMs: startAtMs + 1000,
    segments: [
      SegmentRecord(
        id: 'seg-$name',
        sessionId: 'S-$name',
        index: 0,
        startAtMs: startAtMs,
        endAtMs: startAtMs + 60000,
        title: title,
        brief: '摘要',
        status: SegmentStatus.closed,
      ),
    ],
  );
}

void main() {
  testWidgets('1. Timeline 300 条记录按需虚拟化渲染，且无 IntrinsicHeight', (
    tester,
  ) async {
    final store = AppStore(
      events: _manyEvents(300),
      loadPersistedState: false,
    );
    await pumpShell(tester, store: store, size: const Size(390, 844));

    expect(find.byKey(const Key('card-perf-0')), findsOneWidget);
    expect(find.byKey(const Key('card-perf-299')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(TimelinePage),
        matching: find.byType(IntrinsicHeight),
      ),
      findsNothing,
    );

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('timeline-list')),
        matching: find.byType(Scrollable),
      ),
    );
    for (var i = 0; i < 20; i++) {
      final target = scrollable.position.maxScrollExtent;
      if ((scrollable.position.pixels - target).abs() < 1.0 &&
          find.byKey(const Key('card-perf-299')).evaluate().isNotEmpty) {
        break;
      }
      scrollable.position.jumpTo(target);
      await tester.pump();
    }

    expect(find.byKey(const Key('card-perf-0')), findsNothing);
    expect(find.byKey(const Key('card-perf-299')), findsOneWidget);
  });

  testWidgets('2. Timeline 录音每秒计时只更新状态块，不失效 feedEntries 缓存', (
    tester,
  ) async {
    final status = RecordingStatusController()..startRecording();
    addTearDown(status.dispose);
    final store = AppStore(
      events: seedEvents,
      status: status,
      loadPersistedState: false,
    );
    await pumpShell(
      tester,
      store: store,
      recordingStatus: status,
      size: const Size(390, 844),
    );

    final entriesBefore = store.feedEntries;
    for (var s = 1; s <= 10; s++) {
      status.updateElapsed(s);
      await tester.pump();
    }

    expect(
      tester.widget<Text>(find.byKey(const Key('recording-status-subtitle'))).data,
      contains('00:00:10'),
    );
    expect(identical(store.feedEntries, entriesBefore), isTrue);
  });

  test('3. AppStore 缓存 feedGroups/feedEntries，展开收起不失效，数据变更精确失效', () {
    final store = AppStore(
      events: List.of(seedEvents),
      loadPersistedState: false,
    );
    addTearDown(store.dispose);

    final groups0 = store.feedGroups;
    final entries0 = store.feedEntries;
    expect(identical(store.feedGroups, groups0), isTrue);
    expect(identical(store.feedEntries, entries0), isTrue);

    store.tapCard('e1', isSummary: false);
    expect(identical(store.feedGroups, groups0), isTrue);
    expect(identical(store.feedEntries, entries0), isTrue);

    store.eventPhotos['e1'] = const [
      EventPhoto(
        id: 'p-ex',
        time: '14:25:00',
        excluded: true,
      ),
    ];
    final entriesAfterPhoto = store.feedEntries;
    expect(identical(entriesAfterPhoto, entries0), isFalse);
    expect(
      entriesAfterPhoto
          .whereType<FeedItemEntry>()
          .any((it) => it.item is UnclassifiedPhotosCard),
      isTrue,
    );

    store.setFilter(FeedFilter.event);
    final entriesEventFilter = store.feedEntries;
    expect(identical(entriesEventFilter, entriesAfterPhoto), isFalse);

    store.summaries = [
      SummaryCard(
        id: 's1',
        time: '18:00',
        state: SummaryState.done,
      )
        ..title = '新总结'
        ..srcIds = const ['e1'],
    ];
    expect(identical(store.feedEntries, entriesEventFilter), isFalse);

    final afterSum = store.feedEntries;
    store.events = seedEvents.take(2).toList();
    expect(identical(store.feedEntries, afterSum), isFalse);
  });

  testWidgets('4. SummaryResultPage 滚动仅位移目录浮钮，不重建 CustomScrollView', (
    tester,
  ) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    final sumPage = find.byType(SummaryResultPage);
    final animatedInSum = find.descendant(
      of: sumPage,
      matching: find.byType(AnimatedBuilder),
    );
    expect(
      find.descendant(
        of: animatedInSum,
        matching: find.byKey(const Key('sum-scroll')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: animatedInSum,
        matching: find.byKey(const Key('toc-btn')),
      ),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const Key('sum-scroll')),
      const Offset(0, -400),
    );
    await tester.pump();
    final tabs1 = tester.getTopLeft(find.byKey(const Key('stabs'))).dy;
    final toc1 = tester.getTopLeft(find.byKey(const Key('toc-btn'))).dy;
    expect(toc1 - tabs1, closeTo(56, 2));

    await tester.tap(find.byKey(const Key('toc-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('toc-item-sec-ft')), findsOneWidget);
  });

  testWidgets('5. DetailPage 对话与原始数据 200 条按需懒渲染', (tester) async {
    final turns = [
      for (var i = 0; i < 200; i++)
        TurnLine(
          i.isEven ? '说话人 1' : '说话人 2',
          '第 $i 句对话内容',
          '00:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}',
        ),
    ];
    final longEvent = RecordEvent(
      id: 'e-long',
      dayOffset: 0,
      title: '长对话记录',
      brief: '长摘要',
      longText: '长概述',
      time: '10:00',
      dur: '30分00秒',
      speakers: '说话人 1 / 说话人 2',
      mark: '',
      srcMap: '',
      dialog: turns,
      raw: turns,
    );
    final store = AppStore(events: [longEvent], loadPersistedState: false);
    final view = SegmentView(
      segment: SegmentRecord(
        id: 'e-long',
        sessionId: 'S1',
        index: 0,
        startAtMs: 1730000000000,
        endAtMs: 1730001800000,
        title: '长对话记录',
        status: SegmentStatus.closed,
      ),
      file: RecordingFile(
        deviceName: 'LONG.APM',
        session: 'S1',
        seq: 1,
        startAtMs: 1730000000000,
        apmPath: '',
        durationMs: 1800000,
        stage: RecordingStage.ready,
        createdAtMs: 1730001800000,
      ),
      turns: [
        for (var i = 0; i < 200; i++)
          PolishedTurn(
            id: 't$i',
            startMs: i * 5000,
            endMs: i * 5000 + 3000,
            speakerLabel: i.isEven ? '说话人 1' : '说话人 2',
            text: '第 $i 句对话内容',
            srcUtteranceIds: ['u$i'],
          ),
      ],
      utterances: [
        for (var i = 0; i < 200; i++)
          RawUtterance(
            id: 'u$i',
            sliceId: '0001',
            startMs: i * 5000,
            endMs: i * 5000 + 3000,
            text: '原始第 $i 句',
            speakerLabel: i.isEven ? '说话人 1' : '说话人 2',
          ),
      ],
      slices: const [],
    );
    store.segmentViews = {'e-long': view};
    addTearDown(store.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: StoreScope(
          store: store,
          child: const Scaffold(body: DetailPage(eventId: 'e-long')),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('turn-para-e-long-0')), findsOneWidget);
    expect(find.byKey(const Key('turn-para-e-long-199')), findsNothing);

    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();

    expect(find.byKey(const Key('raw-utt-u0')), findsOneWidget);
    expect(find.byKey(const Key('raw-utt-u199')), findsNothing);
  });

  testWidgets('6. PhotoThumbnail 按展示宽度降采样且缺失文件异步安全回退', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('rc-thumb-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pngPath = '${dir.path}/sample.png';
    File(pngPath).writeAsBytesSync(base64Decode(_kPng4x4Base64), flush: true);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 45,
            height: 45,
            child: PhotoThumbnail(path: pngPath, logicalWidth: 45),
          ),
        ),
      ),
    );
    await tester.pump();

    final imageWidget = tester.widget<Image>(find.byType(Image));
    expect(imageWidget.image, isA<ResizeImage>());
    final resized = imageWidget.image as ResizeImage;
    expect(resized.width, 96);
    expect(resized.height, isNull);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 45,
                height: 45,
                child: PhotoThumbnail(path: '', logicalWidth: 45),
              ),
              SizedBox(
                width: 45,
                height: 45,
                child: PhotoThumbnail(
                  path: '/nonexistent/missing.jpg',
                  logicalWidth: 45,
                  source: 'dyj_camera',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
  });

  test('7. RecordingStore 增量缓存与 >=24 条后台 Isolate 解析及增删改一致性', () async {
    final root = await Directory.systemTemp.createTemp('rc-store-perf-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = RecordingStore(
      root: root,
      jsonStore: JsonStore(store: InMemoryStore()),
    );

    for (var i = 0; i < 30; i++) {
      await store.save(
        _sampleFile(
          'F${i.toString().padLeft(2, '0')}.APM',
          startAtMs: 1730000000000 + i * 60000,
          title: '录音 $i',
        ),
      );
    }

    final loaded30 = await store.loadAll(refresh: true);
    expect(loaded30.length, 30);
    expect(loaded30.first.deviceName, 'F29.APM');

    // 验证缓存返回独立副本，外部就地修改不会污染缓存
    loaded30.first.stage = RecordingStage.failed;
    final reloadCached = await store.loadAll(refresh: true);
    expect(reloadCached.first.stage, RecordingStage.ready);

    await store.save(
      _sampleFile(
        'F05.APM',
        startAtMs: 1730000000000 + 5 * 60000,
        title: '已更新标题',
      ),
    );
    await store.remove('F10.APM');

    final loaded29 = await store.loadAll(refresh: true);
    expect(loaded29.length, 29);
    expect(loaded29.any((f) => f.deviceName == 'F10.APM'), isFalse);
    final updated = loaded29.singleWhere((f) => f.deviceName == 'F05.APM');
    expect(updated.segments.single.title, '已更新标题');
  });
}
