import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'verify_narrow_test.dart' as fixture;

void main() {
  testWidgets(
    'verified silence is completed on Timeline, detail and raw tabs',
    (tester) async {
      final (store, _) = await fixture.boot(tester);
      final event = store.events.first.copyWith(
        status: 'silent',
        transcriptionStatus: 'completed',
        originalTranscript: '',
        cleanedTranscript: null,
        longText: '',
        brief: '本地转写完成，未检测到有效语音',
        dialog: [],
        raw: [],
        error: null,
      );
      store.events
        ..clear()
        ..add(event);
      store.tapCard(event.id, isSummary: false);
      await tester.pump();
      expect(find.text('本地转写完成，未检测到有效语音；原始音频已保留'), findsOneWidget);
      expect(find.text('原始音频已保存，等待本机转写'), findsNothing);
      await tester.tap(find.text('详情'));
      await tester.pump();
      expect(find.text('本地转写完成，未检测到有效语音。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pump();
      expect(find.text('本地转写完成，未检测到有效语音；原始音频完整保留。'), findsOneWidget);
      expect(find.text('暂无原始转写，请检查转录任务或模型配置。'), findsNothing);
    },
  );
}
