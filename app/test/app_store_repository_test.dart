// AppStore 真实录音仓库接入验收 —— 注入仓库后不再回退 seed，仓库变更驱动重建。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/kv_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/services/recordings/recording.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';

Recording _rec(String id, String title) => Recording(
      id: id,
      title: title,
      recordedAt: DateTime.now(),
      durationMs: 65000,
      cleanTranscript: '清洗文本',
      rawTranscript: '原始文本',
      turns: const [
        SpeakerTurn(speaker: 'B', text: '第二句', startMs: 1000, endMs: 2000),
        SpeakerTurn(speaker: 'A', text: '第一句', startMs: 0, endMs: 900),
      ],
    );

void main() {
  test('注入仓库后使用真实录音，不回退 seed', () async {
    final repo = RecordingRepository(MemoryKvStore());
    final store = AppStore(recordings: repo);
    addTearDown(store.dispose);
    addTearDown(repo.dispose);

    expect(store.displayEvents, isEmpty);
    expect(store.feedGroups, isEmpty);

    await repo.upsert(_rec('r1', '真实会议'));
    expect(store.displayEvents.single.title, '真实会议');
    expect(store.displayEvents.single.speakers, 'A / B');
    expect(store.eventById('r1').dialog.first.text, '第二句');
    expect(store.feedGroups, isNotEmpty);
  });

  test('仓库变更通知 AppStore 监听者', () async {
    final repo = RecordingRepository(MemoryKvStore());
    final store = AppStore(recordings: repo);
    addTearDown(store.dispose);
    addTearDown(repo.dispose);
    var notified = 0;
    store.addListener(() => notified++);

    await repo.upsert(_rec('r1', '一'));
    await repo.upsert(_rec('r2', '二'));
    expect(notified, 2);
    expect(store.displayEvents.length, 2);
  });
}
