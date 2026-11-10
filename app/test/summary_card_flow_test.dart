// 总结卡在时间轴上的位置与点击行为验收。
//
// 设计（owner 2026-11-10）：
// - 总结没有单独的详情说明，点卡片直接进总结结果页；
// - 总结卡排在它所总结的那段时间内容之后（取来源记录里最早的一条作锚点），
//   而不是无条件堆在「今天」最上面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';

import 'support/harness.dart';

RecordEvent _oldestSource(List<RecordEvent> all, List<String> ids) {
  final sources = all.where((e) => ids.contains(e.id)).toList()
    ..sort((a, b) {
      if (a.dayOffset != b.dayOffset) {
        return b.dayOffset.compareTo(a.dayOffset); // 日偏移大 = 更早
      }
      return a.time.compareTo(b.time); // 同日时间早 = 更早
    });
  return sources.first;
}

void main() {
  testWidgets('总结卡紧跟所总结内容之后；点击直接进结果页', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    final card = h.store.summaries.firstWhere(
      (s) => s.state == SummaryState.done,
    );
    final anchor = _oldestSource(h.store.events, card.srcIds);

    // 同一分组内：锚点（所总结区间最早一条）→ 总结卡
    final groups = h.store.feedGroups;
    final group = groups.firstWhere(
      (g) => g.items.any((x) => identical(x, card)),
    );
    final anchorIndex = group.items.indexWhere(
      (x) => x is RecordEvent && x.id == anchor.id,
    );
    final cardIndex = group.items.indexWhere((x) => identical(x, card));
    expect(anchorIndex, isNonNegative);
    expect(
      cardIndex,
      anchorIndex + 1,
      reason: '总结卡应落在所总结内容的最早一条之后',
    );

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
