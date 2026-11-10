// feed 倒序排序验收：按日分组（今天 → 昨天 → 更早），同一天内时间从晚到早。
//
// 原型 mock 数据里 e4/e5 在“昨天”同一天，但数组顺序是 09:30 在 16:40 前面；
// 展示层必须自己按 time 排序，不能依赖数据源顺序。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_store.dart';

RecordEvent _event(String id, int dayOffset, String time) => RecordEvent(
  id: id,
  dayOffset: dayOffset,
  title: id,
  brief: '',
  longText: '',
  time: time,
  dur: '1分',
  speakers: 'A',
  mark: '',
  srcMap: '',
  dialog: const [],
  raw: const [],
);

void main() {
  test('feed：今天在前、同一天内时间从晚到早', () {
    final store = AppStore(
      events: [
        _event('today-late', 0, '14:20'),
        _event('today-early', 0, '10:12'),
        _event('today-mid', 0, '13:05'),
        _event('yday-early', 1, '09:30'),
        _event('yday-late', 1, '16:40'),
      ],
      loadPersistedState: false,
    );
    addTearDown(store.dispose);

    final groups = store.feedGroups;
    expect(groups.length, 2);
    expect(groups[0].dayLabel, '今天');
    expect(groups[1].dayLabel, '昨天');

    String times(FeedGroup g) => g.items
        .whereType<RecordEvent>()
        .map((e) => e.time)
        .join(',');

    expect(times(groups[0]), '14:20,13:05,10:12');
    expect(times(groups[1]), '16:40,09:30');
  });
}
