// M2 专项验收：未归类图片卡片（card-unc / unc-pics / unc-dismiss-day）+
// #p-unc 双列 1:1 相册页 + 大图预览弹层 + 时间最接近候选选择 + 不归类状态跨会话持久化。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

void main() {
  testWidgets(
    '未归类相册页：45×45 缩略图、1:1 双列网格、大图预览、时间最接近候选改派与归零自动返回',
    (tester) async {
      final store = AppStore(
        events: seedEvents,
        loadPersistedState: false,
      );
      // e1(14:20)、e2(13:05)、e3(10:12) 均在今天(dayOffset=0)
      // p1 拍摄于 13:08:30，时间最接近 e2(13:05)
      store.eventPhotos['e1'] = const [
        EventPhoto(
          id: 'p1',
          path: '/nonexistent/board_1308.jpg',
          time: '13:08:30',
          source: 'dyj_camera',
          excluded: true,
        ),
      ];

      await pumpShell(tester, store: store);

      // 1) Timeline 分组顶部出现「今日未归类图片」卡片 + 45×45 叠放缩略图 + 「不归类」按钮
      expect(find.byKey(const Key('card-unc-0')), findsOneWidget);
      final uncPicsFinder = find.byKey(const Key('unc-pics-0'));
      expect(uncPicsFinder, findsOneWidget);
      final uncPicsSize = tester.getSize(uncPicsFinder);
      expect(uncPicsSize.width, 45);
      expect(uncPicsSize.height, 45);
      expect(find.byKey(const Key('unc-dismiss-day-0')), findsOneWidget);

      // 2) 点击进入双列 1:1 正方形相册页
      await tester.tap(find.byKey(const Key('card-unc-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('p-unc')), findsOneWidget);
      expect(find.byKey(const Key('unc-album-grid')), findsOneWidget);
      final tilePhotoFinder = find.byKey(const Key('unc-photo-e1-p1'));
      expect(tilePhotoFinder, findsOneWidget);
      final tilePhotoSize = tester.getSize(tilePhotoFinder);
      expect((tilePhotoSize.width - tilePhotoSize.height).abs(), lessThan(0.5));

      // 默认推荐按钮指向时间最接近的 e2（客户回访要点）
      expect(find.byKey(const Key('unc-reassign-e1-p1-e2')), findsOneWidget);

      // 3) 点击正方形缩略图打开复用预览弹层 PhotoPreviewSheet，验证信息展示后关闭弹层
      await tester.tap(tilePhotoFinder);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-preview-sheet')), findsOneWidget);
      expect(find.textContaining('原属记录：午后项目方向讨论'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // 点击遮罩关闭弹层
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-preview-sheet')), findsNothing);

      // 4) 点开候选下拉抽屉，验证首项带「时间最接近」徽标，并改派到 e3（晨间工作计划）
      await tester.tap(find.byKey(const Key('unc-pick-e1-p1')));
      await tester.pumpAndSettle();

      final candE2 = find.byKey(const Key('unc-cand-e2'));
      final candE3 = find.byKey(const Key('unc-cand-e3'));
      expect(candE2, findsOneWidget);
      expect(candE3, findsOneWidget);
      expect(
        find.descendant(of: candE2, matching: find.text('时间最接近')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: candE3, matching: find.text('时间最接近')),
        findsNothing,
      );

      await tester.tap(candE3);
      await tester.pumpAndSettle();

      // 5) 当日待归类归零后自动弹出回 Timeline，card-unc-0 消失，e3 获得该照片并展示 45px 缩略图
      expect(find.byKey(const Key('p-unc')), findsNothing);
      expect(find.byKey(const Key('card-unc-0')), findsNothing);
      final e3 = store.events.firstWhere((e) => e.id == 'e3');
      expect(store.activePhotosForEvent(e3).map((p) => p.id), ['p1']);
      expect(find.byKey(const Key('pics-e3')), findsOneWidget);
    },
  );

  testWidgets('单张「不归类」与「全部不归类」标记 dismissed=true 且跨会话持久化恢复不反弹', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store1 = AppStore(
      events: seedEvents,
      loadPersistedState: true,
    );
    await store1.init();
    store1.eventPhotos['e1'] = const [
      EventPhoto(
        id: 'p1',
        path: '/nonexistent/a.jpg',
        time: '14:22:00',
        source: 'dyj_camera',
        excluded: true,
      ),
      EventPhoto(
        id: 'p2',
        path: '/nonexistent/b.jpg',
        time: '14:24:00',
        source: 'system_album',
        excluded: true,
      ),
      EventPhoto(
        id: 'p3',
        path: '/nonexistent/c.jpg',
        time: '14:26:00',
        source: 'system_album',
        excluded: true,
      ),
    ];
    store1.notifyListeners();

    await pumpShell(tester, store: store1);
    expect(find.byKey(const Key('card-unc-0')), findsOneWidget);
    expect(find.text('已移出对话流 · 共 3 张'), findsOneWidget);

    // 进入相册页，先单张点「不归类」p1 -> 剩 2 张仍停留在相册页
    await tester.tap(find.byKey(const Key('card-unc-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('p-unc')), findsOneWidget);

    await tester.tap(find.byKey(const Key('unc-dismiss-e1-p1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('p-unc')), findsOneWidget);
    expect(store1.unclassifiedPhotosForDay(0).length, 2);

    // 再点右上角「全部不归类」-> 归零自动回 Timeline 且持久化落盘
    await tester.tap(find.byKey(const Key('unc-dismiss-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('p-unc')), findsNothing);
    expect(find.byKey(const Key('card-unc-0')), findsNothing);

    // 等待异步 SharedPreferences 落盘完成，新建 AppStore 冷启动恢复
    await tester.pump(const Duration(milliseconds: 50));
    final store2 = AppStore(
      events: seedEvents,
      loadPersistedState: true,
    );
    await store2.init();
    expect(store2.unclassifiedPhotosForDay(0), isEmpty);
    final restoredE1Photos = store2.eventPhotos['e1']!;
    expect(restoredE1Photos.length, 3);
    expect(restoredE1Photos.every((p) => p.excluded && p.dismissed), isTrue);
  });
}
