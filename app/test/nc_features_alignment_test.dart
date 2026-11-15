// NC 待确认功能完整落地对齐验收：
//
// 1. NC #1：Timeline `< 30s` 紧邻语音分片无时长上限合并（保留全部原始 WAV 分片与切片视图）、
//    `30s..59s` 仅声学拆段不调云端、遇 `>= 1 分钟` 空白触发独立 FastTopicSegmentAgent
//    并写入幂等水位锁防重跑。
// 2. NC #2 + #3（全文与详情命名）：总结「全文」同说话人连续发言合并为单段整段（无重复前缀）；
//    移除复杂全局标记入口，点击任意说话人（含「未区分」）弹出极简 `QuickSpeakerSheet`
//    （支持上下文模糊提示 `可能为：XXX`、最近 5 名称、单句拆分/批量合并、记住声纹）。
// 3. NC #3（Setting 声纹管理）：5 个常用自动识别槽位（槽位 1 锁定「我的声音」并支持单独录音）、
//    不限量人物库、5 槽位上限校验，以及 `matchFrequentOnly` 仅对常用槽位生效。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/voice_sample_capture.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _TopicFakeChat implements ChatCompletion {
  int calls = 0;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    calls += 1;
    return jsonEncode({
      'sections': [
        {
          'title': '季度预算对齐',
          'brief': '明确研发预算分配口径',
          'startTurn': 0,
          'endTurn': 0,
          'tags': ['预算'],
        },
        {
          'title': '试点上线安排',
          'brief': '敲定下周二内部试点与回访节点',
          'startTurn': 1,
          'endTurn': 1,
          'tags': ['上线'],
        },
      ],
    });
  }
}

RecordingFile _speechFile({
  required String name,
  required int seq,
  required int startAtMs,
  required int durationMs,
  required List<PolishedTurn> turns,
  required List<RawUtterance> raws,
  required List<AudioSlice> slices,
  String title = '连续沟通',
  String? wavPath,
}) {
  final effectiveWavPath =
      wavPath ?? (slices.first.wavPath.isEmpty ? null : slices.first.wavPath);
  return RecordingFile(
    deviceName: name,
    session: 'S-NC-01',
    seq: seq,
    startAtMs: startAtMs,
    apmPath: '/tmp/$name.apm',
    wavPath: effectiveWavPath,
    durationMs: durationMs,
    createdAtMs: startAtMs + durationMs,
    stage: RecordingStage.ready,
    slices: slices,
    utterances: raws,
    turns: turns,
    segments: [
      SegmentRecord(
        id: 'seg-$name',
        sessionId: 'S-NC-01',
        index: seq,
        startAtMs: startAtMs,
        endAtMs: startAtMs + durationMs,
        title: title,
        brief: turns.map((t) => t.text).join('；'),
        longText: turns.map((t) => '${t.speakerLabel}: ${t.text}').join('\n'),
        speakerLabels: {for (final t in turns) t.speakerLabel}.toList(),
        speakerCount: {for (final t in turns) t.speakerLabel}.length,
        status: SegmentStatus.closed,
        sliceIds: [for (final s in slices) s.id],
        turnIds: [for (final t in turns) t.id],
      ),
    ],
  );
}

void main() {
  test(
    'NC#1 service: <30s 超30分钟无上限合并、30..59s仅声学拆段不调云端、>=60s话题分段与幂等水位锁',
    () async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-nc1-');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });

      final now = DateTime.now();
      final day10am =
          DateTime(now.year, now.month, now.day, 10, 0).millisecondsSinceEpoch;
      // 两段各 20 分钟、间隔仅 15s（总计 40+ 分钟 > 原 30 分钟上限），应无上限合并为 1 条记录
      const len20m = 20 * 60 * 1000;
      const gap15s = 15 * 1000;

      final file1 = _speechFile(
        name: 'REC_A',
        seq: 1,
        startAtMs: day10am,
        durationMs: len20m,
        slices: const [
          AudioSlice(
            id: '0001',
            index: 0,
            startMs: 0,
            endMs: len20m,
            wavPath: '',
            stage: SliceStage.polished,
          ),
        ],
        raws: const [
          RawUtterance(
            id: 'u1',
            sliceId: '0001',
            startMs: 0,
            endMs: len20m,
            text: '先讨论季度预算边界',
            speakerLabel: '说话人 1（推测）',
          ),
        ],
        turns: const [
          PolishedTurn(
            id: 't1',
            startMs: 0,
            endMs: len20m,
            speakerLabel: '说话人 1（推测）',
            text: '先讨论季度预算边界。',
            srcUtteranceIds: ['u1'],
          ),
        ],
        title: '季度预算讨论',
      );
      final file2 = _speechFile(
        name: 'REC_B',
        seq: 2,
        startAtMs: day10am + len20m + gap15s,
        durationMs: len20m,
        slices: const [
          AudioSlice(
            id: '0002',
            index: 0,
            startMs: 0,
            endMs: len20m,
            wavPath: '',
            stage: SliceStage.polished,
          ),
        ],
        raws: const [
          RawUtterance(
            id: 'u2',
            sliceId: '0002',
            startMs: 0,
            endMs: len20m,
            text: '接着确认试点上线节奏',
            speakerLabel: '说话人 2（推测）',
          ),
        ],
        turns: const [
          PolishedTurn(
            id: 't2',
            startMs: 0,
            endMs: len20m,
            speakerLabel: '说话人 2（推测）',
            text: '接着确认试点上线节奏。',
            srcUtteranceIds: ['u2'],
          ),
        ],
        title: '试点上线讨论',
      );

      // 1) 45s 间隔：仅声学拆段，不触发 FastTopicSegmentAgent LLM
      final chat = _TopicFakeChat();
      final agent = FastTopicSegmentAgent(chat: chat, model: 'test-fast-model');
      final topicStore = TopicSegmentationStore(
        resolveRoot: () async => tmpDir,
      );
      final gap45Files = [
        file1,
        _speechFile(
          name: 'REC_45S',
          seq: 2,
          startAtMs: day10am + len20m + 45 * 1000,
          durationMs: 60 * 1000,
          slices: file2.slices,
          raws: file2.utterances,
          turns: file2.turns,
        ),
      ];
      final noTrigger = await agent.evaluateRuns(
        gap45Files,
        store: topicStore,
        sessionJustEnded: false,
        wallClockNowMs: day10am + len20m + 45 * 1000 + 60 * 1000 + 10 * 1000,
      );
      expect(noTrigger.evaluatedCount, 0);
      expect(chat.calls, 0);
      expect(SegmentProjection.build(gap45Files).events.length, 2);

      // 2) < 30s 超过 30 分钟仍无上限合并为 1 条记录，保留全部分片
      final mergedProj = SegmentProjection.build([file1, file2]);
      expect(mergedProj.events.length, 1);
      final mergedEv = mergedProj.events.single;
      expect(mergedEv.mergedSliceCount, 2);
      expect(mergedProj.views[mergedEv.id]?.mergedChildren.length, 2);

      // 3) >= 1 分钟空白触发 FastTopicSegmentAgent 话题拆分 + 幂等水位锁防重跑
      final firstEval = await agent.evaluateRuns(
        [file1, file2],
        store: topicStore,
        sessionJustEnded: true,
      );
      expect(firstEval.evaluatedCount, 1);
      expect(chat.calls, 1);

      final secondEval = await agent.evaluateRuns(
        [file1, file2],
        store: topicStore,
        sessionJustEnded: true,
      );
      expect(secondEval.evaluatedCount, 0);
      expect(secondEval.skippedLocked, 1);
      expect(chat.calls, 1);

      final splitProj = SegmentProjection.build(
        [file1, file2],
        topicState: secondEval.state,
      );
      expect(splitProj.events.length, 2);
      expect(
        splitProj.events.map((e) => e.title),
        containsAll(['季度预算对齐', '试点上线安排']),
      );
    },
  );

  testWidgets('NC#1 UI: Timeline 展示已合并 N 分片徽标 & 详情原始数据展示多段 WAV 分片列表', (
    tester,
  ) async {
    final now = DateTime.now();
    final day10am =
        DateTime(now.year, now.month, now.day, 10, 0).millisecondsSinceEpoch;
    const len20m = 20 * 60 * 1000;
    const gap15s = 15 * 1000;

    final file1 = _speechFile(
      name: 'REC_A',
      seq: 1,
      startAtMs: day10am,
      durationMs: len20m,
      wavPath: null,
      slices: const [
        AudioSlice(
          id: '0001',
          index: 0,
          startMs: 0,
          endMs: len20m,
          wavPath: '',
          stage: SliceStage.polished,
        ),
      ],
      raws: const [
        RawUtterance(
          id: 'u1',
          sliceId: '0001',
          startMs: 0,
          endMs: len20m,
          text: '先讨论季度预算边界',
          speakerLabel: '说话人 1（推测）',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 't1',
          startMs: 0,
          endMs: len20m,
          speakerLabel: '说话人 1（推测）',
          text: '先讨论季度预算边界。',
          srcUtteranceIds: ['u1'],
        ),
      ],
      title: '季度预算讨论',
    );
    final file2 = _speechFile(
      name: 'REC_B',
      seq: 2,
      startAtMs: day10am + len20m + gap15s,
      durationMs: len20m,
      wavPath: null,
      slices: const [
        AudioSlice(
          id: '0002',
          index: 0,
          startMs: 0,
          endMs: len20m,
          wavPath: '',
          stage: SliceStage.polished,
        ),
      ],
      raws: const [
        RawUtterance(
          id: 'u2',
          sliceId: '0002',
          startMs: 0,
          endMs: len20m,
          text: '接着确认试点上线节奏',
          speakerLabel: '说话人 2（推测）',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 't2',
          startMs: 0,
          endMs: len20m,
          speakerLabel: '说话人 2（推测）',
          text: '接着确认试点上线节奏。',
          srcUtteranceIds: ['u2'],
        ),
      ],
      title: '试点上线讨论',
    );

    final mergedProj = SegmentProjection.build([file1, file2]);
    expect(mergedProj.events.length, 1);
    final mergedEv = mergedProj.events.single;
    expect(mergedEv.mergedSliceCount, 2);

    final model = SummaryModel();
    final store = AppStore(
      events: const [],
      generator: await model.generator(),
      loadPersistedState: false,
    );
    store.recordingFiles = [file1, file2];
    store.events = mergedProj.events;
    store.segmentViews = mergedProj.views;
    final cfg = AgentConfigStore();
    final dev = DeviceStore(gateway: FakeCardGateway(devices: const []));
    addTearDown(dev.dispose);
    addTearDown(store.dispose);
    addTearDown(cfg.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(store: store, device: dev, agentConfig: cfg),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(Key('ev-merge-badge-${mergedEv.id}')), findsOneWidget);
    expect(find.textContaining('已合并 2 分片'), findsOneWidget);

    await tester.tap(find.byKey(Key('card-${mergedEv.id}')));
    await tester.pump();
    await tester.tap(find.byKey(Key('detail-${mergedEv.id}')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();
    expect(find.byKey(const Key('raw-merged-slice-0')), findsOneWidget);
    expect(find.byKey(const Key('raw-merged-slice-1')), findsOneWidget);
  });

  testWidgets('NC#2 + NC#3: 总结全文连续同人合并、极简说话人弹窗（模糊提示/5最近/单改拆分/批改合并）与未区分命名', (
    tester,
  ) async {
    final ev = RecordEvent(
      id: 'ev-ft',
      dayOffset: 0,
      title: '产品与客户沟通',
      brief: '讨论列表性能与反馈细节',
      longText: '产品与客户沟通',
      time: '13:05',
      dur: '6分10秒',
      speakers: '说话人 1 / 说话人 2',
      mark: '',
      srcMap: '来源 13:05—13:11',
      dialog: const [
        TurnLine('说话人 1', '张总，今天界面体验怎么样？', '来源 13:05—13:06'),
        TurnLine('说话人 2', '新版整体清爽，列表加载偏慢。', '来源 13:06—13:07'),
        TurnLine('说话人 2', '通常都要等两三秒才渲染完。', '来源 13:07—13:08'),
        TurnLine('说话人 1', '收到，已经纳入优化清单。', '来源 13:08—13:09'),
        TurnLine('说话人 2', '好，下次上线前同步我。', '来源 13:09—13:10'),
        TurnLine('未区分', '补充一条测试环境账号需求。', '来源 13:10—13:11'),
      ],
      raw: const [
        TurnLine('说话人 1', '张总，今天界面体验怎么样？', '来源 13:05—13:06'),
        TurnLine('说话人 2', '新版整体清爽，列表加载偏慢。', '来源 13:06—13:07'),
        TurnLine('说话人 2', '通常都要等两三秒才渲染完。', '来源 13:07—13:08'),
        TurnLine('说话人 1', '收到，已经纳入优化清单。', '来源 13:08—13:09'),
        TurnLine('说话人 2', '好，下次上线前同步我。', '来源 13:09—13:10'),
        TurnLine('未区分', '补充一条测试环境账号需求。', '来源 13:10—13:11'),
      ],
    );

    final model = SummaryModel();
    final store = AppStore(
      events: [ev],
      generator: await model.generator(),
      loadPersistedState: false,
    );
    for (final name in ['赵总', '王经理', '李工', '老陈', '张总']) {
      store.voiceprintStore.recordRecentName(name, notify: false);
    }
    final sum = SummaryCard(
      id: 'sum-ft-nc',
      time: '13:15',
      state: SummaryState.done,
    )
      ..srcIds = [ev.id]
      ..title = '沟通纪要'
      ..subDesc = '今天 13:05 · 1 条记录'
      ..overview = '已记录列表性能反馈与上线安排。'
      ..srcDesc = '今天 13:05 产品与客户沟通';
    store.summaries = [sum, ...store.summaries];

    final cfg = AgentConfigStore();
    final dev = DeviceStore(gateway: FakeCardGateway(devices: const []));
    addTearDown(dev.dispose);
    addTearDown(store.dispose);
    addTearDown(cfg.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(store: store, device: dev, agentConfig: cfg),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 进入总结结果页并切到「全文」
    await tester.tap(find.byKey(const Key('card-sum-ft-nc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stab-ft')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sum-mark-speaker-btn')), findsNothing);
    // group 1 应把第 2、3 句（说话人 2）合并到同一个段落中
    expect(find.byKey(const Key('sum-ft-group-ev-ft-1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-ft-group-ev-ft-1')),
        matching: find.textContaining('偏慢'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-ft-group-ev-ft-1')),
        matching: find.textContaining('两三秒'),
      ),
      findsOneWidget,
    );
    // 共 5 个连续说话人分组：1 -> (2+2) -> 1 -> 2 -> 未区分
    expect(find.byKey(const Key('sum-ft-group-ev-ft-4')), findsOneWidget);
    expect(find.byKey(const Key('sum-ft-group-ev-ft-5')), findsNothing);

    // 导出浮层不应出现标记说话人按钮
    await tester.tap(find.byKey(const Key('export-btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('export-mark-speaker-btn')), findsNothing);
    Navigator.of(tester.element(find.byKey(const Key('export-sheet')))).pop();
    await tester.pumpAndSettle();

    // 点击「说话人 2」打开极简命名弹窗，校验上下文提示、5 最近名称与双勾选
    await tester.tap(find.byKey(const Key('sum-ft-who-ev-ft-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('spk-quick-sheet')), findsOneWidget);
    expect(find.byKey(const Key('qspk-fuzzy-hint')), findsOneWidget);
    expect(find.textContaining('张总'), findsWidgets);
    expect(find.byKey(const Key('qspk-chk-remember')), findsOneWidget);
    expect(find.byKey(const Key('qspk-chk-batch')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('qspk-other-cnt')),
        matching: find.textContaining('2'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
    for (var i = 0; i < 5; i++) {
      expect(find.byKey(Key('qspk-recent-$i')), findsOneWidget);
    }

    // 取消勾选批量改名，仅把第 1 句改为「陈总」，合并段应拆成 2 组（总组数变 6）
    await tester.tap(find.byKey(const Key('qspk-chk-batch')));
    await tester.enterText(find.byKey(const Key('qspk-name-inp')), '陈总');
    await tester.pump();
    await tester.tap(find.byKey(const Key('qspk-save-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sum-ft-group-ev-ft-5')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-ft-who-ev-ft-1')),
        matching: find.textContaining('陈总'),
      ),
      findsOneWidget,
    );

    // 对话 2 中的剩余「说话人 2」用提示「张总」并保持勾选批量修改；同改其余处后会重新合并回 5 组
    await tester.tap(find.byKey(const Key('sum-ft-who-ev-ft-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qspk-apply-hint')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('qspk-save-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sum-ft-group-ev-ft-5')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-ft-who-ev-ft-1')),
        matching: find.textContaining('张总'),
      ),
      findsOneWidget,
    );

    // 跳入详情页并验证点击「未区分」（turn 5）也能独立命名而不污染其他发言
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('card-${ev.id}')));
    await tester.pump();
    await tester.tap(find.byKey(Key('detail-${ev.id}')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('turn-spk-5')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('turn-spk-5')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('qspk-name-inp')), '王五');
    await tester.pump();
    await tester.tap(find.byKey(const Key('qspk-save-btn')));
    await tester.pumpAndSettle();

    expect(find.textContaining('王五'), findsWidgets);
    expect(find.textContaining('张总'), findsWidgets);
  });

  testWidgets('NC#3 Setting 声纹管理：5 常用自动识别槽位（槽位 1 本人+单独录音）、无限人物库与 matchFrequentOnly 算力边界', (
    tester,
  ) async {
    VoiceSampleCaptureDriver.debugOverrideCapture = ({
      required targetName,
      required deviceLabel,
      required sceneLabel,
    }) async => const VoiceSampleCaptureResult(
      ok: true,
      embedding: [1.0, 0.0, 0.0, 0.0],
      durationMs: 2800,
    );
    addTearDown(() => VoiceSampleCaptureDriver.debugOverrideCapture = null);

    final model = SummaryModel();
    final store = AppStore(
      events: const [],
      generator: await model.generator(),
      loadPersistedState: false,
    );
    final vp = store.voiceprintStore;
    // 填满其余 4 个常用槽位（2..5）+ 额外 2 个仅手动人物库档案（总非本人 6 人 > 5）
    vp.upsertPersonAndSample(
      name: '张总',
      embedding: const [0.0, 1.0, 0.0, 0.0],
      preferFrequentSlot: true,
    );
    vp.upsertPersonAndSample(
      name: '老陈',
      embedding: const [0.0, 0.0, 1.0, 0.0],
      preferFrequentSlot: true,
    );
    vp.upsertPersonAndSample(
      name: '李工',
      embedding: const [0.0, 0.0, 0.0, 1.0],
      preferFrequentSlot: true,
    );
    vp.upsertPersonAndSample(
      name: '王经理',
      embedding: const [0.5, 0.5, 0.0, 0.0],
      preferFrequentSlot: true,
    );
    final manualOnly = vp.upsertPersonAndSample(
      name: '外协小赵',
      embedding: const [0.0, 0.0, 0.7071, 0.7071],
      preferFrequentSlot: false,
    );
    vp.upsertPersonAndSample(
      name: '供应商周哥',
      preferFrequentSlot: false,
    );

    final cfg = AgentConfigStore();
    addTearDown(store.dispose);
    addTearDown(cfg.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: StoreScope(
          store: store,
          child: SettingSubPage(
            subId: 'voiceprint',
            agentConfig: cfg,
            standalone: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('vp-frequent-section')), findsOneWidget);
    expect(find.byKey(const Key('vp-library-section')), findsOneWidget);
    for (var slot = 1; slot <= 5; slot++) {
      expect(find.byKey(Key('vp-slot-$slot')), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('vp-slot-1')),
        matching: find.text('我的声音'),
      ),
      findsOneWidget,
    );

    // 槽位 1 单独录音增加个人声纹样本
    await tester.tap(find.byKey(const Key('vp-record-self-btn')));
    await tester.pumpAndSettle();
    expect(vp.selfProfile?.samples.length, 1);
    expect(
      find.descendant(
        of: find.byKey(const Key('vp-slot-1')),
        matching: find.textContaining('1 组样本'),
      ),
      findsOneWidget,
    );

    // 人物库 > 5 人；5 个常用槽位已满时禁止再自动晋升，直到移出空出槽位
    expect(vp.allPersons.where((p) => !p.isSelf).length, 6);
    expect(vp.promoteToFrequentSlot(manualOnly.id), isFalse);

    // matchFrequentOnly 仅扫描常用 5 槽位，绝不误扫手动人物库
    final selfMatch = vp.matchFrequentOnly(const [1.0, 0.0, 0.0, 0.0]);
    expect(selfMatch.confirmed?.isSelf, isTrue);
    expect(selfMatch.scannedSlots, 5);

    final ignoredManual = vp.matchFrequentOnly(const [0.0, 0.0, 0.7071, 0.7071]);
    expect(ignoredManual.confirmed?.name, isNot('外协小赵'));
  });
}
