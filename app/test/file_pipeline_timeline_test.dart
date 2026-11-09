import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/widgets/store_scope.dart';

const pendingAudio = RecordEvent(
  id: 'local-audio',
  dayOffset: 0,
  title: '已取回录音',
  brief: '',
  longText: '',
  time: '',
  dur: '',
  speakers: '',
  mark: '',
  srcMap: '',
  dialog: [],
  raw: [],
  audioPath: '/private/local/audio.wav',
  transcriptionStatus: 'waiting_model',
  error: '[model_missing] model.int8.onnx未安装，请配置本机模型',
);

void main() {
  Future<AppStore> mount(WidgetTester tester, RecordEvent event) async {
    final store = AppStore(
      events: [event],
      persistence: MemoryStorePersistence(),
    );
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoreScope(store: store, child: const TimelinePage()),
        ),
      ),
    );
    return store;
  }

  testWidgets(
    'collapsed missing-model audio is visibly saved and queued, not task failed',
    (tester) async {
      await mount(tester, pendingAudio);
      expect(find.text('原音频已保存 · 等待本机模型'), findsOneWidget);
      expect(find.textContaining('处理失败'), findsNothing);
      await tester.tap(find.byKey(const Key('card-local-audio')));
      await tester.pump();
      expect(
        find.text('[model_missing] model.int8.onnx未安装，请配置本机模型'),
        findsOneWidget,
      );
      expect(find.text('原始音频已保存，等待本机转写'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cloud failure displays original text AND exact login error without overwriting either',
    (tester) async {
      final event = pendingAudio.copyWith(
        originalTranscript: '不可覆盖的真实原文',
        longText: '不可覆盖的真实原文',
        transcriptionStatus: 'analysis_failed',
        error: '未登录：请登录后重试文本润色',
      );
      final store = await mount(tester, event);
      expect(find.text('原文已保存 · 润色或分析失败'), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-local-audio')));
      await tester.pump();
      expect(find.text('不可覆盖的真实原文'), findsOneWidget);
      expect(find.text('未登录：请登录后重试文本润色'), findsOneWidget);
      expect(store.events.single.originalTranscript, event.originalTranscript);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queued, running and cancelled states remain distinct during stable-id updates',
    (tester) async {
      final store = await mount(
        tester,
        pendingAudio.copyWith(transcriptionStatus: 'queued', error: null),
      );
      expect(find.text('原音频已保存 · 等待处理'), findsOneWidget);
      store.applyRecordUpdates([
        pendingAudio.copyWith(transcriptionStatus: 'running', error: null),
      ]);
      await tester.pump();
      expect(find.text('正在本机转写'), findsOneWidget);
      store.applyRecordUpdates([
        pendingAudio.copyWith(transcriptionStatus: 'cancelled'),
      ]);
      await tester.pump();
      expect(find.text('处理已取消 · 原音频与原文保留'), findsOneWidget);
      expect(store.events, hasLength(1));
      expect(store.events.single.audioPath, pendingAudio.audioPath);
      expect(tester.takeException(), isNull);
    },
  );
}
