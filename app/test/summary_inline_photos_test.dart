// M1/M3/M4 专项验收：总结卡左下角图片数、总结结果页统计行动态图片数、
// 概览/逻辑结构/信息点/来源记录穿插配图、预览弹层 pm-jump-dlg 跳转详情与排除后动态联动降级。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';

import 'support/harness.dart';
import 'support/model_stub.dart';

void main() {
  testWidgets(
    '总结结果页穿插配图全链路：sum-sub 动态计数 + 四处内联配图 + 弹层定位原话跳转 + 排除后实时降级',
    (tester) async {
      final model = SummaryModel();
      final store = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      store.eventPhotos['e1'] = const [
        EventPhoto(
          id: 'p1',
          path: '/nonexistent/whiteboard_1.jpg',
          time: '14:22:10',
          source: 'dyj_camera',
        ),
        EventPhoto(
          id: 'p2',
          path: '/nonexistent/slide_2.jpg',
          time: '14:30:05',
          source: 'system_album',
        ),
      ];

      final h = await pumpShell(tester, store: store, model: model);

      // 1) 生成覆盖本周记录（含 e1）的总结，自动进入总结结果页
      await generateWeekSummary(tester, h.model);
      await tester.pump();

      // 统计行动态追加「· 含 2 张图片」
      final sumSub = tester.widget<Text>(find.byKey(const Key('sum-sub')));
      expect(sumSub.data, contains('含 2 张图片'));

      // 概览内联配图卡、逻辑结构叶子线性图片图标、信息点标题图标与展开配图、来源记录图片数全部就绪
      expect(find.byKey(const Key('sum-ov-inline-photo')), findsOneWidget);
      expect(find.byKey(const Key('mleaf-pic-e1-p1')), findsWidgets);
      expect(find.byKey(const Key('pt-picico-0')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('pt-h-0')));
      await tester.tap(find.byKey(const Key('pt-h-0')));
      await tester.pump();
      expect(find.byKey(const Key('pt-figs-0')), findsOneWidget);
      expect(find.byKey(const Key('sum-pt-photo-e1-p1')), findsOneWidget);
      expect(find.byKey(const Key('src-piccount-e1')), findsOneWidget);

      // 2) 点击概览穿插配图卡 -> 弹出 PhotoPreviewSheet，含附近原话引用与 pm-jump-dlg 跳转按钮
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('sum-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scrollable.position.jumpTo(0);
      await tester.pump();

      await tester.tap(find.byKey(const Key('sum-ov-inline-photo')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('photo-preview-sheet')), findsOneWidget);
      expect(find.byKey(const Key('pm-jump-dlg')), findsOneWidget);
      expect(find.text('定位到原始对话流 ›'), findsOneWidget);

      // 点击「定位到原始对话流 ›」-> 关闭弹层并压栈跳转到 e1 对话详情页，面包屑显示「返回总结」
      await tester.tap(find.byKey(const Key('pm-jump-dlg')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('photo-preview-sheet')), findsNothing);
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.text('午后项目方向讨论'), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(const Key('crumb-back')),
          matching: find.textContaining('总结'),
        ),
        findsOneWidget,
      );

      // 3) 在详情页把 e1 的两张图片全部标记「不属于本段」后返回总结结果页
      await tester.ensureVisible(find.byKey(const Key('dphoto-exclude-e1-0')));
      await tester.tap(find.byKey(const Key('dphoto-exclude-e1-0')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('dphoto-exclude-e1-0')));
      await tester.tap(find.byKey(const Key('dphoto-exclude-e1-0')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();

      // 4) 验证总结结果页实时联动降级：统计行移除图片数、概览配图消失、叶子退化为普通纯文本芯片、信息点与来源无图片标
      final updatedSumSub = tester.widget<Text>(find.byKey(const Key('sum-sub')));
      expect(updatedSumSub.data, isNot(contains('张图片')));
      expect(find.byKey(const Key('sum-ov-inline-photo')), findsNothing);
      expect(find.byKey(const Key('mleaf-pic-e1-p1')), findsNothing);
      expect(find.byKey(const Key('pt-picico-0')), findsNothing);
      expect(find.byKey(const Key('src-piccount-e1')), findsNothing);

      // 返回 Timeline：总结卡左下角图片计数同样隐藏
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();
      final sumId = store.summaries.first.id;
      expect(find.byKey(Key('sumpics-$sumId')), findsNothing);
    },
  );
}
