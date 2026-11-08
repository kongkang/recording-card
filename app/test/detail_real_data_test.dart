import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
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

    expect(find.byKey(const Key('detail-note')), findsOneWidget);
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
}
