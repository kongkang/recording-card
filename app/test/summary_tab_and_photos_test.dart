// 总结 Tab 下拉隔离 / 相册缩略图叠放 / 对话详情内嵌照片与排除归入「未归类图片」验收。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';

import 'support/fake_recordings.dart';
import 'support/harness.dart';
import 'support/model_stub.dart';

void main() {
  testWidgets('总结 Tab：无总结时显示专属空态，下拉刷新绝不触发蓝牙录音卡文件取回', (tester) async {
    final recordings = await FakeRecordingSync.create(
      result: [seedEvents.first],
      stepDelay: Duration.zero,
    );
    final store = AppStore(
      events: seedEvents,
      recordings: recordings,
      loadPersistedState: false,
    );
    await pumpShell(tester, store: store);
    store.deviceConnected = () => true;

    // 切到「总结」Tab
    await tester.tap(find.byKey(const Key('tab-summary')));
    await tester.pump();

    expect(find.byKey(const Key('summary-empty-text')), findsOneWidget);
    expect(find.textContaining('还没有总结'), findsOneWidget);
    expect(find.textContaining('下拉可从录音卡取回'), findsNothing);

    // 在总结 Tab 做下拉刷新：只重读本地总结，不调用 recordings.sync
    await tester.fling(
      find.byKey(const Key('timeline-empty')),
      const Offset(0, 320),
      1200,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(recordings.syncCalls, 0, reason: '总结 Tab 下拉不应触发蓝牙同步录音文件');
    expect(find.byKey(const Key('sync-banner')), findsNothing);
  });

  testWidgets('相册缩略图 45px 叠放 + 详情对话流按时间插入照片 + 标记「不属于本段」移入当天顶部「未归类图片」', (
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
      ),
      EventPhoto(
        id: 'p2',
        path: '/nonexistent/slide_2.jpg',
        time: '14:26:30',
        source: 'system_album',
      ),
    ];
    final h = await pumpShell(tester, store: store, model: model);

    // 1) Timeline 右侧渲染 45×45 正方形相册缩略图
    final thumbFinder = find.byKey(const Key('pics-e1'));
    expect(thumbFinder, findsOneWidget);
    final thumbSize = tester.getSize(thumbFinder);
    expect(thumbSize.width, 45);
    expect(thumbSize.height, 45);

    // 初始没有「未归类图片」卡片
    expect(find.byKey(const Key('card-unc-0')), findsNothing);

    // 2) 生成一条覆盖 e1 的总结：先在总结结果页验证图片自然穿插在概览/逻辑结构/信息点/来源记录（无独立多媒体模块）
    await generateWeekSummary(tester, h.model);
    await tester.pump();

    expect(find.text('多媒体'), findsNothing);
    expect(find.byKey(const Key('sum-ov-inline-photo')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('mleaf-pic-e1-'),
      ),
      findsWidgets,
    );
    expect(find.byKey(const Key('pt-picico-0')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('pt-h-0')));
    await tester.tap(find.byKey(const Key('pt-h-0')));
    await tester.pump();
    expect(find.byKey(const Key('pt-figs-0')), findsOneWidget);
    expect(find.byKey(const Key('src-piccount-e1')), findsOneWidget);

    // 返回 Timeline 验证总结卡左下角紧跟片段数显示「· 含 2 张图片」（非右侧居中悬空）
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final sumId = store.summaries.first.id;
    final sumPicsFinder = find.byKey(Key('sumpics-$sumId'));
    expect(sumPicsFinder, findsOneWidget);
    expect(find.text('含 2 张图片'), findsOneWidget);
    final sumCardRect = tester.getRect(find.byKey(Key('sumcard-$sumId')));
    final sumPicsRect = tester.getRect(sumPicsFinder);
    expect(sumPicsRect.top, greaterThan(sumCardRect.center.dy - 4));
    expect(sumPicsRect.left, lessThan(sumCardRect.right - 60));

    // 3) 展开 e1 进入详情页「对话详情」，看到紧凑横向照片卡（72×72 缩略图 + 短胶囊「不属于本段」）及无框套框的被引用总结
    await tester.tap(find.byKey(const Key('card-e1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e1')));
    await tester.pump();

    expect(find.byKey(const Key('dphoto-e1-0')), findsOneWidget);
    expect(find.byKey(const Key('dphoto-e1-1')), findsOneWidget);
    expect(find.text('点一机抓拍 · 14:22:10'), findsOneWidget);
    expect(find.text('系统相册 · 14:26:30'), findsOneWidget);
    final dThumbSize = tester.getSize(find.byKey(const Key('dphoto-thumb-e1-0')));
    expect(dThumbSize.width, 72);
    expect(dThumbSize.height, 72);
    final excludeBtnSize = tester.getSize(
      find.byKey(const Key('dphoto-exclude-e1-0')),
    );
    expect(excludeBtnSize.width, lessThan(96));

    // 切到「被引用总结」验证单层卡片可点且无框套框
    await tester.tap(find.byKey(const Key('det-tab-refs')));
    await tester.pump();
    expect(find.byKey(Key('ref-$sumId')), findsOneWidget);
    await tester.tap(find.byKey(const Key('det-tab-dlg')));
    await tester.pump();

    // 4) 将第一张照片标记「不属于本段」：立即从本段对话移除
    await tester.ensureVisible(find.byKey(const Key('dphoto-exclude-e1-0')));
    await tester.tap(find.byKey(const Key('dphoto-exclude-e1-0')));
    await tester.pump();

    expect(find.text('点一机抓拍 · 14:22:10'), findsNothing);
    final e1 = store.events.firstWhere((e) => e.id == 'e1');
    expect(store.activePhotosForEvent(e1).length, 1);

    // 5) 返回 Timeline：总结卡图片数同步减为「含 1 张图片」，且当天分组顶部出现可点击的「今日未归类图片」
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();

    expect(find.text('含 1 张图片'), findsOneWidget);
    expect(find.byKey(const Key('card-unc-0')), findsOneWidget);
    expect(find.text('今日未归类图片'), findsOneWidget);
    expect(find.text('已移出对话流 · 共 1 张'), findsOneWidget);
    expect(find.byKey(const Key('unc-dismiss-day-0')), findsOneWidget);

    // 6) 点击「今日未归类图片」进入双列 1:1 正方形相册页，验证归入记录恢复照片
    await tester.tap(find.byKey(const Key('card-unc-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('p-unc')), findsOneWidget);
    expect(find.byKey(const Key('unc-album-grid')), findsOneWidget);
    final sqPhotoSize = tester.getSize(find.byKey(const Key('unc-photo-e1-p1')));
    expect((sqPhotoSize.width - sqPhotoSize.height).abs(), lessThan(0.5));

    await tester.tap(find.byKey(const Key('unc-reassign-e1-p1-e1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 归零后自动返回 Timeline，未归类卡片消失、总结卡恢复「含 2 张图片」
    expect(find.byKey(const Key('card-unc-0')), findsNothing);
    expect(find.text('含 2 张图片'), findsOneWidget);

    // 7) 再次排除一张并在卡片右下角直接点「不归类」，卡片立即收起
    store.excludePhoto('e1', 'p1');
    await tester.pump();
    expect(find.byKey(const Key('card-unc-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('unc-dismiss-day-0')));
    await tester.pump();
    expect(find.byKey(const Key('card-unc-0')), findsNothing);
  });
}
