// Timeline 的状态链路：空态 / 下拉刷新 / 同步提示条。
//
// 这一轮 Timeline 不再有预置假数据：没同步到录音就是空态，下拉会真的走
// 「设备文件列表 → 下载 → 转码 → 转写」并逐阶段汇报进度（[SyncStage]），
// 完成后才把记录铺到时间轴上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';

import 'support/fake_recordings.dart';
import 'support/harness.dart';

void main() {
  testWidgets('没有录音时是空态（不是预置示例数据），下拉入口常驻', (tester) async {
    final store = AppStore(loadPersistedState: false);
    await pumpShell(tester, store: store);

    expect(store.events, isEmpty);
    expect(find.byKey(const Key('timeline-empty')), findsOneWidget);
    expect(find.textContaining('还没有录音'), findsOneWidget);
    expect(find.byKey(const Key('timeline-refresh')), findsOneWidget);
    expect(find.byKey(const Key('sync-banner')), findsNothing);
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
  });

  testWidgets('下拉同步：统一状态条按真实阶段推进并保持顶部留白，完成后收起', (tester) async {
    final recordings = await FakeRecordingSync.create(
      result: [seedEvents.first],
      stepDelay: const Duration(milliseconds: 300),
    );
    final store = AppStore(
      recordings: recordings,
      loadPersistedState: false,
    );
    // 取下录音的前提是设备在场；这条用例验证的是"连上之后"的取回流程
    await pumpShell(tester, store: store);
    store.deviceConnected = () => true;
    expect(find.byKey(const Key('timeline-empty')), findsOneWidget);

    // 真的做一次下拉手势（RefreshIndicator 是唯一同步入口）
    await tester.fling(
      find.byKey(const Key('timeline-empty')),
      const Offset(0, 320),
      1200,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(recordings.syncCalls, 1, reason: '下拉真的触发了同步');

    // 同步中：统一单行状态条 + 阶段文案 + 条内进度指示（旧 sync-banner 不再存在）
    expect(find.byKey(const Key('sync-banner')), findsNothing);
    expect(find.byKey(const Key('recording-status-block')), findsOneWidget);
    expect(find.byKey(const Key('recording-status-subtitle')), findsOneWidget);
    expect(find.byKey(const Key('recording-status-progress')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('recording-status-subtitle'))).data,
      anyOf(
        '正在读取录音卡文件列表…',
        '正在取回 REC001.apm（1/1）',
        '正在转写 REC001.apm',
      ),
    );
    final tabsBottom =
        tester.getBottomLeft(find.byKey(const Key('timeline-tabs-bar'))).dy;
    final barTop =
        tester.getTopLeft(find.byKey(const Key('recording-status-block'))).dy;
    expect(
      barTop - tabsBottom,
      greaterThanOrEqualTo(10.0),
      reason: '同步态顶部状态条与 Tab 栏之间必须保留顶部间距',
    );

    // 跑完四个阶段
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(store.syncStage, isNull, reason: '结束后收起状态条');
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
    expect(find.byKey(const Key('sync-banner')), findsNothing);
    expect(store.syncText, isEmpty);
    // 同步回来的记录上了时间轴
    expect(store.events.length, 1);
    expect(find.byKey(const Key('timeline-empty')), findsNothing);
    expect(find.byKey(const Key('timeline-item-e1')), findsOneWidget);
  });

  testWidgets('同步失败：空态直接显示失败原因，不留假数据', (tester) async {
    final recordings = await FakeRecordingSync.create(
      result: null,
      error: '录音卡未连接',
      stepDelay: Duration.zero,
    );
    final store = AppStore(
      recordings: recordings,
      loadPersistedState: false,
    );
    // 设备「在场」但设备侧报未连接：这是真实故障路径，要如实呈现
    await pumpShell(tester, store: store);
    store.deviceConnected = () => true;

    final error = await store.syncRecordings();

    expect(error, '录音卡未连接');
    expect(store.syncError, '录音卡未连接');
    await tester.pump();
    expect(store.events, isEmpty);
    expect(find.byKey(const Key('timeline-empty')), findsOneWidget);
    expect(find.textContaining('录音卡未连接'), findsOneWidget);
  });
}
