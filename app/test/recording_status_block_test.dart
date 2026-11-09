// 录音状态块验收（TDD）—— 只做状态展示、不可操作；idle 收起。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/widgets/recording_status_block.dart';

Widget _host(RecordingStatusController controller) => MaterialApp(
      home: Scaffold(body: RecordingStatusBlock(controller: controller)),
    );

void main() {
  testWidgets('idle 不占布局；录音/转写/错误/结束状态正确', (tester) async {
    final controller = RecordingStatusController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    expect(find.byKey(const Key('recording-status-block')), findsNothing);

    controller.startRecording();
    await tester.pump();
    expect(find.byKey(const Key('recording-status-block')), findsOneWidget);
    expect(find.text('正在录音'), findsOneWidget);

    controller.onSliceReceived();
    controller.onTranscriptionStarted();
    await tester.pump();
    expect(find.text('正在转写'), findsOneWidget);
    expect(find.text('剩余 1 段'), findsOneWidget);

    controller.onTranscriptionCompleted();
    await tester.pump();
    expect(find.text('正在录音'), findsOneWidget);
    expect(find.text('剩余 1 段'), findsNothing);

    controller.onError('网络中断');
    await tester.pump();
    expect(find.text('录音整理中断'), findsOneWidget);
    expect(find.textContaining('网络中断'), findsOneWidget);

    controller.stopRecording();
    await tester.pump();
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
  });

  testWidgets('状态块不可点击（IgnorePointer）', (tester) async {
    final controller = RecordingStatusController()..startRecording();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    await tester.pump();

    final block = find.byKey(const Key('recording-status-block'));
    final ignore = tester.widget<IgnorePointer>(
        find.ancestor(of: block, matching: find.byType(IgnorePointer)).first);
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('录音显示正计时；停止后同步态显示的阶段文案', (tester) async {
    final controller = RecordingStatusController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    controller.startRecording();
    controller.updateElapsed(65);
    await tester.pump();
    expect(find.text('正在录音'), findsOneWidget);
    expect(find.textContaining('已录 00:01:05'), findsOneWidget);

    controller.startSync(detail: '正在下载最新录音…');
    await tester.pump();
    expect(find.text('正在同步'), findsOneWidget);
    expect(find.text('正在下载最新录音…'), findsOneWidget);

    controller.updateSync('正在转写 1/2', remaining: 1);
    await tester.pump();
    expect(find.text('正在转写 1/2'), findsOneWidget);

    // 同步完成且不在录音会话中 → 收起
    controller.updateQueue(remaining: 0, active: false);
    await tester.pump();
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
  });
}
