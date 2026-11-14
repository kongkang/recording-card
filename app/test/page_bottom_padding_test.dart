// 全页面底部呼吸留白规范验收：无论窄屏/宽屏、内容是否超出一屏，滚动到底部均保留 >= RCDims.pageBottomPad (48px) 留白。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/detail_page.dart';

import 'support/harness.dart';
import 'support/model_stub.dart';

void main() {
  testWidgets('全页面底部统一保留 >= 48px 呼吸留白（Timeline / 总结结果 / 记录详情 / 未归类相册 / Setting 及二级页）', (
    tester,
  ) async {
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
        excluded: true,
      ),
    ];
    final h = await pumpShell(
      tester,
      store: store,
      model: model,
      size: const Size(900, 680), // 宽屏双栏（覆盖左栏 + 右栏独立滚动到底部）
    );

    // 1) Timeline 左栏滚到底部
    final tlList = tester.widget<ListView>(
      find.descendant(
        of: find.byType(RefreshIndicator),
        matching: find.byType(ListView),
      ),
    );
    expect(
      (tlList.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(RCDims.pageBottomPad),
    );

    // 2) 生成总结后，在宽屏右栏「总结结果页」滚到底部，检查最后一张来源记录卡片距滚动视口底部 >= 48px
    await generateWeekSummary(tester, h.model);
    await tester.pump();
    final sumScrollFinder = find.byKey(const Key('sum-scroll'));
    final sumScrollable = tester.state<ScrollableState>(
      find.descendant(of: sumScrollFinder, matching: find.byType(Scrollable)).first,
    );
    sumScrollable.position.jumpTo(sumScrollable.position.maxScrollExtent);
    await tester.pump();
    final sumViewportBottom = tester.getRect(sumScrollFinder).bottom;
    final lastSrcId = store.summaries.first.srcIds.last;
    final lastSrcCardBottom = tester.getRect(find.byKey(Key('src-$lastSrcId'))).bottom;
    expect(
      sumViewportBottom - lastSrcCardBottom,
      greaterThanOrEqualTo(RCDims.pageBottomPad),
      reason: '总结结果页滚到底部应保留 >= 48px 底部留白',
    );

    // 3) 进入记录详情页，验证 ListView 底部留白 >= 48px
    await tester.tap(find.byKey(Key('src-$lastSrcId')));
    await tester.pump();
    final detailList = tester.widget<ListView>(
      find.descendant(
        of: find.byType(DetailPage),
        matching: find.byType(ListView),
      ),
    );
    expect(
      (detailList.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(RCDims.pageBottomPad),
    );

    // 4) 进入今日未归类图片双列相册页，验证 GridView 底部留白 >= 48px
    await tester.tap(find.byKey(const Key('card-unc-0')));
    await tester.pump();
    final uncGrid = tester.widget<GridView>(find.byKey(const Key('unc-album-grid')));
    expect(
      (uncGrid.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(RCDims.pageBottomPad),
    );

    // 5) 切到 Setting 一级页与二级子页，验证底部留白均 >= 48px
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();
    final setScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('setting-list')),
    );
    expect(
      (setScroll.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(RCDims.pageBottomPad),
    );

    await tester.tap(find.byKey(const Key('set-prompts')));
    await tester.pump();
    final setSubList = tester.widget<ListView>(
      find.byKey(const Key('setsub-scroll-prompts')),
    );
    expect(
      (setSubList.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(RCDims.pageBottomPad),
    );
  });
}
