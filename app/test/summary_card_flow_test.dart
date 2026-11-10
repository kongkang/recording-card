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
  testWidgets('总结卡在来源最新一天的分组顶部；点击直接进结果页', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    final card = h.store.summaries.firstWhere(
      (s) => s.state == SummaryState.done,
    );
    final anchor = _latestSource(h.store.events, card.srcIds);

    // 同一分组内：总结卡在顶部，最新来源记录排在后面
    final groups = h.store.feedGroups;
    final group = groups.firstWhere(
      (g) => g.items.any((x) => identical(x, card)),
    );
    final anchorIndex = group.items.indexWhere(
      (x) => x is RecordEvent && x.id == anchor.id,
    );
    final cardIndex = group.items.indexWhere((x) => identical(x, card));
    expect(anchorIndex, isNonNegative);
    expect(cardIndex, 0, reason: '总结卡应在当天分组最上方');
    expect(anchorIndex, greaterThan(cardIndex), reason: '记录排在总结卡后面');

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
  });
}
