import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/schedule/cleaning_task_ids.dart';
import 'package:recording_card/services/schedule/cleaning_tasks.dart';
import 'package:recording_card/services/schedule/organize_pass_service.dart';
import 'package:recording_card/services/schedule/task_schedule.dart';
import 'package:recording_card/services/schedule/task_scheduler.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/test_transitions.dart';

void main() {
  test('间隔可以是任意分钟，7 分钟和 4 小时都能计算下一次到期', () {
    final start = DateTime(2026, 11, 16, 9);
    expect(
      TaskSchedule.interval(7).nextAfter(start),
      start.add(const Duration(minutes: 7)),
    );
    expect(
      TaskSchedule.interval(240).nextAfter(start),
      start.add(const Duration(hours: 4)),
    );
    expect(TaskSchedule.interval(0).everyMinutes, 1);
    expect(TaskSchedule.interval(999999).everyMinutes, 10080);
  });

  test('cron 按下一次命中计算，而不是写死的几档间隔', () {
    final parsed = CronExpression.tryParse('*/15 * * * *');
    expect(parsed, isNotNull);
    expect(
      parsed!.nextAfter(DateTime(2026, 11, 16, 10)),
      DateTime(2026, 11, 16, 10, 15),
    );
    expect(
      CronExpression.tryParse('0 */4 * * *')!
          .nextAfter(DateTime(2026, 11, 16, 1)),
      DateTime(2026, 11, 16, 4),
    );
    expect(CronExpression.tryParse('not a cron'), isNull);
  });

  test('到期、关闭、运行日志和失败都会记下来', () async {
    var clock = DateTime(2026, 11, 16, 10);
    final scheduler = _scheduler(() => clock);
    addTearDown(scheduler.dispose);
    var runs = 0;
    scheduler.registerHandler('work', (invocation) async {
      runs += 1;
      if (invocation.reason == 'fail') {
        throw StateError('模型超时');
      }
      return TaskHandlerResult(
        success: true,
        output: {'n': runs},
        modelCalls: 2,
        inputChars: 30,
        outputChars: 12,
      );
    });
    await scheduler.load();
    await scheduler.ensureTasks([
      ScheduledTaskDefinition(
        id: 'job',
        name: '示例任务',
        detail: '',
        enabled: true,
        schedule: TaskSchedule.interval(7),
        handlerId: 'work',
      ),
    ]);

    await scheduler.tick();
    expect(runs, 1);
    var runtime = scheduler.runtimeFor('job');
    expect(runtime.totalModelCalls, 2);
    expect(runtime.lastInputChars, 30);
    expect(runtime.lastOutputChars, 12);
    expect(runtime.lastSuccess, isTrue);
    expect(runtime.logs.single.modelCalls, 2);
    expect(runtime.nextDueAt, clock.add(const Duration(minutes: 7)));

    clock = clock.add(const Duration(minutes: 6));
    await scheduler.tick();
    expect(runs, 1);

    clock = clock.add(const Duration(minutes: 1));
    await scheduler.tick();
    expect(runs, 2);

    await scheduler.setEnabled('job', false);
    clock = clock.add(const Duration(minutes: 7));
    await scheduler.tick();
    expect(runs, 2);

    await scheduler.setEnabled('job', true);
    final failed = await scheduler.runNow('job', reason: 'fail');
    expect(failed!.success, isFalse);
    expect(failed.error, contains('模型超时'));
    expect(scheduler.runtimeFor('job').lastSuccess, isFalse);
  });

  test('同一任务运行中会加锁，锁超时后可以再跑并记下失败', () async {
    final scheduler = _scheduler(() => DateTime(2026, 11, 16, 12));
    addTearDown(scheduler.dispose);
    final started = Completer<void>();
    final release = Completer<void>();
    scheduler.registerHandler('work', (_) async {
      if (!started.isCompleted) started.complete();
      await release.future;
      return const TaskHandlerResult(success: true, output: {'ok': true});
    });
    await scheduler.load();
    await scheduler.ensureTasks([
      ScheduledTaskDefinition(
        id: 'job',
        name: '示例任务',
        detail: '',
        enabled: true,
        schedule: TaskSchedule.interval(5),
        handlerId: 'work',
      ),
    ]);

    final first = scheduler.runNow('job');
    await started.future;
    final skipped = await scheduler.runNow('job');
    expect(skipped!.success, isFalse);
    expect(skipped.skipped, isTrue);
    expect(skipped.error, contains('正在运行'));
    release.complete();
    expect((await first)!.success, isTrue);

    scheduler.debugLock('job', since: DateTime(2026, 11, 16, 11, 30));
    var ranAfterStale = false;
    scheduler.registerHandler('work', (_) async {
      ranAfterStale = true;
      return const TaskHandlerResult(success: true, modelCalls: 1);
    });
    await scheduler.tick(now: DateTime(2026, 11, 16, 12, 30));
    expect(ranAfterStale, isTrue);
    expect(
      scheduler
          .runtimeFor('job')
          .logs
          .any((log) => log.error?.contains('超时') ?? false),
      isTrue,
    );
  });

  test('后一个任务读到前一个任务的上一轮输出', () async {
    final scheduler = _scheduler(() => DateTime(2026, 11, 16, 8));
    addTearDown(scheduler.dispose);
    String? seen;
    scheduler.registerHandler('produce', (_) async {
      return const TaskHandlerResult(
        success: true,
        output: {'text': 'organized-a', 'sections': []},
        modelCalls: 1,
        inputChars: 8,
        outputChars: 12,
      );
    });
    scheduler.registerHandler('consume', (invocation) async {
      seen = invocation.upstream?.payload['text'] as String?;
      return const TaskHandlerResult(success: true, modelCalls: 1);
    });
    await scheduler.load();
    await scheduler.ensureTasks([
      ScheduledTaskDefinition(
        id: 'a',
        name: '上游',
        detail: '',
        enabled: true,
        schedule: TaskSchedule.interval(30),
        handlerId: 'produce',
      ),
      ScheduledTaskDefinition(
        id: 'b',
        name: '下游',
        detail: '',
        enabled: true,
        schedule: TaskSchedule.interval(30),
        inputFromTaskId: 'a',
        handlerId: 'consume',
      ),
    ]);

    await scheduler.tick();
    expect(seen, 'organized-a');
    expect(scheduler.runtimeFor('b').lastSuccess, isTrue);

    final reopened = TaskScheduler(
      store: JsonStore(store: scheduler.debugStore),
      now: () => DateTime(2026, 11, 16, 9),
    );
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.taskById('b')!.inputFromTaskId, 'a');
    expect(reopened.taskById('a')!.enabled, isTrue);
    expect(reopened.runtimeFor('a').lastOutput?.payload['text'], 'organized-a');
    expect(reopened.runtimeFor('a').totalModelCalls, 1);
  });

  test('中轮只把已整理段落送给模型，并覆盖到更新的时间轴结果', () async {
    final chat = _ScriptedChat((system, user) {
      expect(user.contains('"utterances"'), isFalse);
      expect(user.contains('原始逐句标记-不要出现'), isFalse);
      expect(user.contains('已整理段落甲'), isTrue);
      expect(system.contains('不是原始逐句转写'), isTrue);
      return '''
{"sections":[{"title":"合并后的长段","brief":"两段合成","overview":"同一话题被收成一段","sourceIndexes":[0,1],"paragraphs":[{"speaker":"说话人 1","text":"已整理段落甲。已整理段落乙。"}]}]}
''';
    });
    final service = OrganizePassService(
      chat: chat,
      modelResolver: () => 'deepseek-v4-flash',
      ready: () => true,
    );
    final result = await service.merge(
      prompt: CleaningTaskIds.mediumPrompt,
      overlapSections: 3,
      sections: const [
        OrganizedSection(
          anchorId: 'seg1',
          title: '阶段甲',
          brief: '甲',
          overview: '甲的概述',
          startAtMs: 1000,
          endAtMs: 2000,
          paragraphs: [
            OrganizedParagraph(
              speaker: '说话人 1',
              text: '已整理段落甲',
              startAtMs: 1000,
              endAtMs: 1500,
            ),
          ],
        ),
        OrganizedSection(
          anchorId: 'seg1',
          title: '阶段乙',
          brief: '乙',
          overview: '乙的概述',
          startAtMs: 2000,
          endAtMs: 3000,
          paragraphs: [
            OrganizedParagraph(
              speaker: '说话人 1',
              text: '已整理段落乙',
              startAtMs: 2000,
              endAtMs: 2500,
            ),
          ],
        ),
      ],
    );
    expect(result.ok, isTrue);
    expect(result.modelCalls, 1);
    expect(result.sections, hasLength(1));
    expect(result.sections.single.title, '合并后的长段');
    expect(chat.userBodies.single.contains('原始逐句标记-不要出现'), isFalse);
  });

  test('更新的长轮结果盖住短轮，更旧的长轮不盖', () {
    final start = DateTime(2026, 11, 16, 15).millisecondsSinceEpoch;
    final file = _speechFile(start);
    TopicRunSegmentation run(String title, int at) => TopicRunSegmentation(
      runKey: 'seg1',
      startAtMs: start,
      endAtMs: start + 4000,
      evaluatedAtMs: at,
      coveredUtteranceEndMs: start + 4000,
      coveredUtteranceIds: const {'u1'},
      sections: [
        TopicSectionOverride(
          title: title,
          brief: '$title 的摘要',
          overview: '$title 的阶段概述',
          startTurnIndex: 0,
          endTurnIndex: 0,
          cleanedByCloud: true,
          startAtMs: start,
          endAtMs: start + 4000,
          paragraphs: [
            TopicParagraph(
              speaker: '说话人 1',
              text: '我们把排期定在周五',
              startAtMs: start,
              endAtMs: start + 4000,
            ),
          ],
        ),
      ],
    );

    final newer = SegmentProjection.build(
      [file],
      topicState: TopicSegmentationState(
        rollingByAnchor: {'seg1': run('短轮标题', 10)},
        stageByTask: {
          'clean.long': {'seg1': run('长轮标题', 20)},
        },
      ),
    );
    expect(newer.events.map((event) => event.title), ['长轮标题']);

    final older = SegmentProjection.build(
      [file],
      topicState: TopicSegmentationState(
        rollingByAnchor: {'seg1': run('短轮标题', 30)},
        stageByTask: {
          'clean.long': {'seg1': run('长轮标题', 5)},
        },
      ),
    );
    expect(older.events.map((event) => event.title), ['短轮标题']);
  });

  test('未手动指定时展示网关模型，deepseek-v3 不是已选项', () async {
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    expect(config.cloudModel, isEmpty);
    expect(config.userPickedCloudModel, isFalse);

    config.syncGatewayModels(const [
      'deepseek-v4-flash',
    ], primaryTextModel: 'deepseek-v4-flash');
    expect(config.effectiveModelId, 'deepseek-v4-flash');
    expect(config.modelSourceLabel, '网关默认');
    expect(config.cloudStatusSummary, 'deepseek-v4-flash · 网关默认');

    await config.setCloudModel('qwen-max');
    expect(config.modelSourceLabel, '用户指定');
    await config.clearCloudModelPick();
    expect(config.effectiveModelId, 'deepseek-v4-flash');
    expect(config.userPickedCloudModel, isFalse);
  });

  testWidgets('开发者设置不连点版本号也能看到模型和三轮任务', (tester) async {
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    config.syncGatewayModels(const [
      'deepseek-v4-flash',
    ], primaryTextModel: 'deepseek-v4-flash');
    final scheduler = _scheduler(() => DateTime(2026, 11, 16, 8));
    addTearDown(scheduler.dispose);
    await scheduler.load();
    await scheduler.ensureTasks(defaultCleaningTasks(shortMinutes: 10));
    final store = AppStore(events: const [], loadPersistedState: false)
      ..taskScheduler = scheduler;
    addTearDown(store.dispose);

    await tester.pumpWidget(
      StoreScope(
        store: store,
        child: MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: SettingSubPage(
              subId: 'dev',
              agentConfig: config,
              standalone: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('dev-effective-model')), findsOneWidget);
    expect(find.text('deepseek-v4-flash'), findsWidgets);
    expect(find.text('来源：网关默认'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('dev-effective-model'))).data,
      'deepseek-v4-flash',
    );
    expect(find.text('短轮清洗'), findsOneWidget);
    final devScroll = find
        .descendant(
          of: find.byKey(const Key('setsub-scroll-dev')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('中轮整理'),
      200,
      scrollable: devScroll,
    );
    expect(find.text('长轮整理'), findsOneWidget);
    expect(find.byKey(const Key('dev-replay-run')), findsOneWidget);
    expect(config.developerMode, isFalse);
  });
}

TaskScheduler _scheduler(DateTime Function() now) {
  final backing = InMemoryStore();
  final scheduler = TaskScheduler(
    store: JsonStore(store: backing),
    now: now,
    staleLock: const Duration(minutes: 20),
  );
  scheduler.debugStore = backing;
  return scheduler;
}

class _ScriptedChat implements ChatCompletion {
  _ScriptedChat(this._respond);

  final String Function(String system, String user) _respond;
  final List<String> userBodies = [];

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    final system = messages.first.content;
    final user = messages.last.content;
    userBodies.add(user);
    return _respond(system, user);
  }
}

RecordingFile _speechFile(int start) {
  return RecordingFile(
    deviceName: 'SEG.WAV',
    session: 's',
    seq: 1,
    startAtMs: start,
    apmPath: '/tmp/seg.apm',
    createdAtMs: start,
    wavPath: '/tmp/seg.wav',
    durationMs: 4000,
    stage: RecordingStage.ready,
    slices: [
      AudioSlice(
        id: '0001',
        index: 0,
        startMs: 0,
        endMs: 4000,
        wavPath: '/tmp/seg.wav',
        stage: SliceStage.transcribed,
      ),
    ],
    utterances: [
      RawUtterance(
        id: 'u1',
        sliceId: '0001',
        startMs: 0,
        endMs: 4000,
        text: '我们把排期定在周五',
        speakerLabel: '说话人 1',
      ),
    ],
    segments: [
      SegmentRecord(
        id: 'seg1',
        sessionId: 's',
        index: 0,
        startAtMs: start,
        endAtMs: start + 4000,
        title: '原始标题',
        brief: '原始摘要',
        status: SegmentStatus.closed,
        sliceIds: const ['0001'],
      ),
    ],
  );
}

extension on TaskScheduler {
  static final Expando<KeyValueStore> _stores = Expando<KeyValueStore>();

  KeyValueStore get debugStore => _stores[this]!;

  set debugStore(KeyValueStore store) => _stores[this] = store;
}
