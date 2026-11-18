import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/memory_search_body.dart';
import 'package:recording_card/services/memory/local_memory_index.dart';
import 'package:recording_card/services/memory/memory_chunk.dart';
import 'package:recording_card/services/memory/memory_indexer.dart';
import 'package:recording_card/services/memory/memory_query.dart';
import 'package:recording_card/services/memory/memory_search_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_transitions.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  test('时间词从问句里拆出日期窗口，其余留给全文检索', () {
    final yesterday = parseMemoryQuery('前天看的电影是什么名字');
    expect(yesterday.window?.minOffset, 2);
    expect(yesterday.window?.maxOffset, 2);
    expect(yesterday.text, '电影是什么名字');

    final recent = parseMemoryQuery('前几天的爆米花');
    expect(recent.window?.minOffset, 1);
    expect(recent.window?.maxOffset, 7);
    expect(recent.text, '爆米花');

    final plain = parseMemoryQuery('黄金眼');
    expect(plain.window, isNull);
    expect(plain.text, '黄金眼');
  });

  test('只索引已完成总结和已落库记录，跳过生成中与正在录音', () {
    final chunks = buildMemoryChunks(
      MemoryCorpus(
        events: [
          _event(
            id: 'movie',
            dayOffset: 2,
            title: '电影院',
            dialog: '前天看了电影《007黄金眼》，还吃了爆米花',
          ),
          _event(
            id: 'live',
            dayOffset: 0,
            title: '正在录音',
            dialog: '这段还在录，不该被搜到黄金眼',
            live: true,
          ),
        ],
        summaries: [
          SummaryCard(id: 'done', time: '21:40', state: SummaryState.done)
            ..title = '今日总结'
            ..overview = '晚上确认了灰度回滚预案'
            ..srcIds = const ['movie'],
          SummaryCard(id: 'pending', time: '22:00')
            ..title = '未完成'
            ..overview = '不该出现的黄金眼草稿',
        ],
      ),
    );

    expect(chunks.map((c) => c.sourceId), ['movie', 'done']);
    expect(chunks.first.dayOffset, 2);
    expect(chunks.first.body, contains('爆米花'));
    expect(chunks.last.kind, 'summary');
    expect(chunks.last.dayOffset, 2);
  });

  test('本机全文能按语义片段召回，并按日期窗口过滤', () async {
    final harness = await _Harness.open();
    addTearDown(harness.close);
    await harness.reindex(_corpus());

    final movie = await harness.service.search('黄金眼');
    expect(movie.map((h) => h.sourceId), containsAll(['movie', 'sum-movie']));
    expect(movie.map((h) => h.sourceId), isNot(contains('rollback')));
    expect(
      movie.firstWhere((h) => h.sourceId == 'movie').snippet,
      contains('黄金眼'),
    );

    final loose = await harness.service.search('看电影');
    expect(loose.map((h) => h.sourceId), contains('movie'));
    expect(loose.map((h) => h.sourceId), isNot(contains('rollback')));

    final day = await harness.service.search('前天电影');
    expect(day.map((h) => h.sourceId), ['movie']);

    final today = await harness.service.search('今天');
    expect(today.map((h) => h.sourceId), ['rollback']);

    expect(await harness.service.search('量子计算'), isEmpty);
  });

  test('重建索引后，已删除的记录不再被命中', () async {
    final harness = await _Harness.open();
    addTearDown(harness.close);
    await harness.reindex(_corpus());
    expect(await harness.service.search('黄金眼'), isNotEmpty);

    await harness.reindex(const MemoryCorpus(events: [], summaries: []));
    expect(await harness.service.search('黄金眼'), isEmpty);
  });

  test('没有命中时不调用云端，并明确说本机没有记录', () async {
    final harness = await _Harness.open();
    addTearDown(harness.close);
    await harness.reindex(_corpus());

    final answer = await harness.service.ask('量子计算');
    expect(harness.prompts, isEmpty);
    expect(answer.fromModel, isFalse);
    expect(answer.hits, isEmpty);
    expect(answer.text, '本机没有找到相关记录。');
  });

  test('有命中时只把命中片段交给模型，不用无关记录编造', () async {
    final prompts = <List<MemoryChatTurn>>[];
    final harness = await _Harness.open(
      chat: (turns) async {
        prompts.add(turns);
        final user = turns.last.content;
        expect(user, contains('007黄金眼'));
        expect(user, contains('爆米花'));
        expect(user, isNot(contains('回滚预案')));
        expect(turns.first.content, contains('不要编造'));
        return '找到了，是《007黄金眼》，前天看的，还吃了爆米花。';
      },
    );
    addTearDown(harness.close);
    await harness.reindex(_corpus());

    final answer = await harness.service.ask('前几天看的电影是什么名字');
    expect(answer.fromModel, isTrue);
    expect(answer.text, contains('007黄金眼'));
    expect(answer.hits.map((h) => h.sourceId), contains('movie'));
    expect(answer.hits.map((h) => h.sourceId), isNot(contains('rollback')));
    expect(prompts, hasLength(1));
  });

  test('云端回答失败时保留本机命中，并如实显示失败', () async {
    final harness = await _Harness.open(
      chat: (_) async => throw Exception('网关超时'),
    );
    addTearDown(harness.close);
    await harness.reindex(_corpus());

    final answer = await harness.service.ask('黄金眼');
    expect(answer.fromModel, isFalse);
    expect(answer.hits, isNotEmpty);
    expect(answer.text, contains('云端回答失败'));
    expect(answer.text, contains('网关超时'));
  });

  testWidgets('设置页有本机记忆检索入口', (tester) async {
    final agent = AgentConfigStore(store: InMemoryStore());
    addTearDown(agent.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: SettingPage(
            settings: SettingsStore(store: InMemoryStore()),
            agentConfig: agent,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('set-memory-search')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('sv-memory'))).data, '仅本机');
  });

  testWidgets('检索页展示回答和来源，不编造未返回的内容', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MemorySearchBody(
              ask: (_) async => MemoryAnswer(
                hits: [
                  MemoryHit(
                    chunkId: 'recording:movie',
                    kind: 'recording',
                    sourceId: 'movie',
                    title: '电影院',
                    body: '前天看了电影《007黄金眼》',
                    snippet: '前天看了电影《007黄金眼》',
                    dayOffset: 2,
                    timeLabel: '15:10',
                  ),
                ],
                text: '找到了，是《007黄金眼》。',
                fromModel: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('memory-search-input')), '黄金眼');
    await tester.tap(find.byKey(const Key('memory-search-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(const Key('memory-search-answer')), findsOneWidget);
    expect(find.textContaining('007黄金眼'), findsWidgets);
    expect(find.byKey(const Key('memory-search-hit-0')), findsOneWidget);
    expect(find.textContaining('电影院'), findsOneWidget);
    expect(find.textContaining('回滚预案'), findsNothing);
  });
}

MemoryCorpus _corpus() => MemoryCorpus(
  events: [
    _event(
      id: 'movie',
      dayOffset: 2,
      title: '电影院',
      time: '15:10',
      dialog: '前天看了电影《007黄金眼》，进场前还买了爆米花。',
    ),
    _event(
      id: 'rollback',
      dayOffset: 0,
      title: '灰度发布',
      time: '09:30',
      dialog: '今天把回滚预案发到群里，前半小时有人盯盘。',
    ),
  ],
  summaries: [
    SummaryCard(id: 'sum-movie', time: '21:30', state: SummaryState.done)
      ..title = '观影'
      ..overview = '下午去看了《007黄金眼》。'
      ..srcIds = const ['movie'],
  ],
);

RecordEvent _event({
  required String id,
  required int dayOffset,
  required String title,
  required String dialog,
  String time = '12:00',
  bool live = false,
}) {
  return RecordEvent(
    id: id,
    dayOffset: dayOffset,
    title: title,
    brief: dialog,
    longText: dialog,
    time: time,
    dur: '5分',
    speakers: '未区分',
    mark: '',
    srcMap: '',
    dialog: [TurnLine('未区分', dialog, time)],
    raw: const [],
    live: live,
  );
}

class _Harness {
  _Harness(this.service, this.dir);

  final MemorySearchService service;
  final Directory dir;
  final List<List<MemoryChatTurn>> prompts = [];

  static Future<_Harness> open({
    Future<String> Function(List<MemoryChatTurn> turns)? chat,
  }) async {
    final dir = await Directory.systemTemp.createTemp('rc-memory-');
    final index = LocalMemoryIndex(
      factory: databaseFactoryFfi,
      path: () async => '${dir.path}/memory.db',
    );
    final service = MemorySearchService(
      index: index,
      corpus: _corpus,
      chat: chat,
    );
    return _Harness(service, dir);
  }

  Future<void> reindex(MemoryCorpus corpus) => service.reindex(corpus);

  Future<void> close() async {
    await service.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
