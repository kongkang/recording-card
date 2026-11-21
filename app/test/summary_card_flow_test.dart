// 总结卡在时间轴上的位置与点击行为验收。
//
// 设计（owner 2026-11-10 修正）：
// - 总结没有单独的详情说明，点卡片直接进总结结果页；
// - 总结卡是当天最后产出的卡片：倒序 feed 里放在它覆盖的最新一天的分组顶部，
//   记录按时间从晚到早排在后面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';

import 'support/harness.dart';

RecordEvent _latestSource(List<RecordEvent> all, List<String> ids) {
  final sources = all.where((e) => ids.contains(e.id)).toList()
    ..sort((a, b) {
      if (a.dayOffset != b.dayOffset) {
        return a.dayOffset.compareTo(b.dayOffset); // 日偏移小 = 更晚
      }
      return b.time.compareTo(a.time); // 同日时间晚 = 更晚
    });
  return sources.first;
}

void main() {
  testWidgets('总结卡按覆盖范围结尾时间内联插入；点击直接进结果页', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    final card = h.store.summaries.firstWhere(
      (s) => s.state == SummaryState.done,
    );
    final anchor = _latestSource(h.store.events, card.srcIds);

    // 同一分组内：覆盖到今天最晚事件 e1 时，总结卡位于其上方；若只总结较早时段则内联到对应结尾处
    final groups = h.store.feedGroups;
    final group = groups.firstWhere(
      (g) => g.items.any((x) => identical(x, card)),
    );
    final anchorIndex = group.items.indexWhere(
      (x) => x is RecordEvent && x.id == anchor.id,
    );
    final cardIndex = group.items.indexWhere((x) => identical(x, card));
    expect(anchorIndex, isNonNegative);
    expect(cardIndex, 0, reason: '包含当天最新记录时总结卡在其上方');
    expect(anchorIndex, greaterThan(cardIndex), reason: '来源最新记录紧随其后');

    // 回到时间轴，点击总结卡 → 直接进入结果页
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final sumCard = find.byKey(Key('card-${card.id}'));
    await tester.ensureVisible(sumCard);
    await tester.pump();
    await tester.tap(sumCard);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sum-title')), findsOneWidget);

    // 追加部分时段总结：只选 e2（不含更晚的 e1），应插入在 e1 下方、e2 上方（结尾时间点）
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    h.store.startSummary();
    h.store.toggleSel('e2');
    h.store.genSummary();
    await tester.pump();
    await finishGeneration(tester, h.model);

    final partial = h.store.summaries.firstWhere((s) => s.id != card.id);
    final todayItems = h.store.feedGroups.first.items;
    final e1Idx = todayItems.indexWhere((x) => x is RecordEvent && x.id == 'e1');
    final e2Idx = todayItems.indexWhere((x) => x is RecordEvent && x.id == 'e2');
    final partialIdx = todayItems.indexWhere((x) => identical(x, partial));
    expect(e1Idx, isNonNegative);
    expect(partialIdx, greaterThan(e1Idx), reason: '部分时段总结不应跑到大时段更晚记录 e1 顶部');
    expect(e2Idx, greaterThan(partialIdx), reason: '部分时段总结应紧贴在所覆盖结尾记录 e2 上方');
  });
}
