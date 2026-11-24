import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/core/store/voiceprint_library_store.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/recordings/speaker_profile_store.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/services/segment/rolling_clean_segment_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _CapturingChat implements ChatCompletion {
  _CapturingChat(this.responder);

  final String Function(
    int callIndex,
    Map<String, dynamic> userJson,
    String model,
  )
  responder;

  final List<({String model, Map<String, dynamic> userJson, String system})>
  calls = [];

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    final idx = calls.length;
    final system = messages.first.content;
    final decoded = jsonDecode(messages.last.content) as Map<String, dynamic>;
    calls.add((model: model, userJson: decoded, system: system));
    return responder(idx, decoded, model);
  }
}

class _NoopEngine implements SpeechEngine {
  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<void> dispose() async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async =>
      const AsrResult(text: '', tokens: [], timestampsMs: [], audioMs: 0);
}

class _NoopModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => null;
}

void main() {
  test('存量孤立句号与「实时切片 #N」脏数据在投影层折叠且可清洗落盘', () async {
    final tmp = await Directory.systemTemp.createTemp('rc-legacy-clean-');
    addTearDown(() => tmp.delete(recursive: true));

    final store = RecordingStore(
      root: tmp,
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    final now = DateTime.now().subtract(const Duration(hours: 2));
    final s1 = now.millisecondsSinceEpoch;
    final s2 = s1 + 120000;

    final dirtySilent1 = RecordingFile(
      deviceName: 'LIVE_0001.wav',
      session: 'SES_LEGACY',
      seq: 1,
      startAtMs: s1,
      apmPath: '${tmp.path}/l1.wav',
      createdAtMs: s1,
      durationMs: 120000,
      timeSynced: true,
      stage: RecordingStage.ready,
      slices: const [
        AudioSlice(
          id: '0001',
          index: 0,
          startMs: 0,
          endMs: 120000,
          wavPath: '',
        ),
      ],
      utterances: const [
        RawUtterance(
          id: '0001u0',
          sliceId: '0001',
          startMs: 500,
          endMs: 1200,
          text: '。',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 't0',
          startMs: 500,
          endMs: 1200,
          speakerLabel: '未区分',
          text: '。',
          srcUtteranceIds: ['0001u0'],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-legacy-1',
          sessionId: 'SES_LEGACY',
          index: 0,
          startAtMs: s1,
          endAtMs: s1 + 120000,
          title: '实时切片 #1',
          brief: '。',
          longText: '。',
          status: SegmentStatus.closed,
          sliceIds: const ['0001'],
          turnIds: const ['t0'],
        ),
      ],
    );
    final dirtySilent2 = RecordingFile(
      deviceName: 'LIVE_0002.wav',
      session: 'SES_LEGACY',
      seq: 2,
      startAtMs: s2,
      apmPath: '${tmp.path}/l2.wav',
      createdAtMs: s2,
      durationMs: 120000,
      timeSynced: true,
      stage: RecordingStage.ready,
      slices: const [
        AudioSlice(
          id: '0002',
          index: 0,
          startMs: 0,
          endMs: 120000,
          wavPath: '',
        ),
      ],
      utterances: const [
        RawUtterance(
          id: '0002u0',
          sliceId: '0002',
          startMs: 200,
          endMs: 900,
          text: '<|zh|>。',
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-legacy-2',
          sessionId: 'SES_LEGACY',
          index: 1,
          startAtMs: s2,
          endAtMs: s2 + 120000,
          title: '实时切片 #2',
          brief: '<|zh|>。',
          longText: '。',
          status: SegmentStatus.closed,
          sliceIds: const ['0002'],
        ),
      ],
    );

    // 投影层无需等磁盘重写即刻把两片纯句号幻觉折叠成无语音汇总卡
    final immediateProj = SegmentProjection.build([dirtySilent1, dirtySilent2]);
    expect(immediateProj.events.length, 1);
    expect(immediateProj.events.single.title, '未识别到语音');

    await store.save(dirtySilent1);
    await store.save(dirtySilent2);
    final pipeline = RecordingPipeline(
      gateway: FakeCardGateway(),
      store: store,
      engine: _NoopEngine(),
      models: _NoopModels(),
      settings: SettingsStore(store: InMemoryStore()),
    );

    final fixed = await pipeline.sanitizeLegacyDirtyRecordings();
    expect(fixed, 2);
    final reloaded = await store.loadAll(refresh: true);
    for (final f in reloaded) {
      expect(f.utterances, isEmpty);
      expect(f.turns, isEmpty);
      expect(f.segments.single.title, '未识别到语音');
    }
  });

  test('滚动语义+声纹联合清洗：跨说话人纠偏、段落合并、阶段概述与周期重叠承接', () async {
    final tmp = await Directory.systemTemp.createTemp('rc-rolling-clean-');
    addTearDown(() => tmp.delete(recursive: true));

    final store = RecordingStore(
      root: tmp,
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    final topicStore = TopicSegmentationStore(resolveRoot: store.root);
    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    await cfg.setCleanCycleMinutes(5);
    await cfg.setCleanOverlapMode('paragraphs');
    await cfg.setCleanOverlapParagraphs(2);

    // 写入会话声纹档案（仅允许上传簇间标量相似度，绝不上传原始 embedding）
    final rootDir = await store.root();
    final vpProfileStore = SpeakerProfileStore(root: rootDir);
    await vpProfileStore.save(
      const SpeakerProfileSet(
        session: 'SES_ROLL',
        profiles: [
          SpeakerProfile(index: 0, centroid: [1.0, 0.0, 0.0], speechMs: 24000),
          SpeakerProfile(
            index: 1,
            centroid: [0.85, 0.526, 0.0],
            speechMs: 8000,
          ),
        ],
      ),
    );
    final vpLib = VoiceprintLibraryStore();
    vpLib.recordFuzzyHint(
      session: 'SES_ROLL',
      speakerSlot: '说话人 1',
      candidateName: '老陈',
    );

    final baseStart = DateTime.now()
        .subtract(const Duration(minutes: 40))
        .millisecondsSinceEpoch;
    final recFile = RecordingFile(
      deviceName: 'REC_ROLL.APM',
      session: 'SES_ROLL',
      seq: 1,
      startAtMs: baseStart,
      apmPath: '${tmp.path}/roll.apm',
      createdAtMs: baseStart,
      durationMs: 12 * 60 * 1000,
      timeSynced: true,
      stage: RecordingStage.ready,
      slices: const [
        AudioSlice(
          id: '0001',
          index: 0,
          startMs: 0,
          endMs: 360000,
          wavPath: '',
        ),
        AudioSlice(
          id: '0002',
          index: 1,
          startMs: 360000,
          endMs: 720000,
          wavPath: '',
        ),
      ],
      utterances: [
        // 第一批（0..370s > 5分钟周期）：同一个人连续三句，中间一句误标成未区分且低置信度
        RawUtterance(
          id: '0001u0',
          sliceId: '0001',
          startMs: 1000,
          endMs: 25000,
          text: '老陈我们这周三前必须把',
          speakerLabel: '说话人 1',
          spkConfidence: 0.88,
        ),
        RawUtterance(
          id: '0001u1',
          sliceId: '0001',
          startMs: 26000,
          endMs: 52000,
          text: '接口联调环境搭好并完成压测，',
          speakerLabel: '未区分',
          spkConfidence: 0.31,
        ),
        // 噪音句号也混在旧数据里，应自动滤除
        RawUtterance(
          id: '0001u_noise',
          sliceId: '0001',
          startMs: 53000,
          endMs: 54000,
          text: '。',
          speakerLabel: '未区分',
          spkConfidence: 0.1,
        ),
        RawUtterance(
          id: '0001u2',
          sliceId: '0001',
          startMs: 55000,
          endMs: 315000,
          text: '不然周五客户端集成来不及。',
          speakerLabel: '说话人 1',
          spkConfidence: 0.84,
        ),
        // 第二批（365s..700s）：延续上一轮话题且合并尾部未完结段落
        RawUtterance(
          id: '0002u0',
          sliceId: '0002',
          startMs: 365000,
          endMs: 420000,
          text: '压测脚本和回归用例我也一起补充完，',
          speakerLabel: '说话人 2',
          spkConfidence: 0.56,
        ),
        RawUtterance(
          id: '0002u1',
          sliceId: '0002',
          startMs: 425000,
          endMs: 700000,
          text: '好，那周四下午我们一起过一遍监控指标。',
          speakerLabel: '说话人 2',
          spkConfidence: 0.89,
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-roll-0',
          sessionId: 'SES_ROLL',
          index: 0,
          startAtMs: baseStart,
          endAtMs: baseStart + 12 * 60 * 1000,
          title: '实时切片 #1',
          brief: '',
          status: SegmentStatus.closed,
          sliceIds: const ['0001', '0002'],
        ),
      ],
    );

    // 模拟真实情况：构造服务时 model 尚未发现（""），发现后动态生效
    var resolvedModel = '';
    var cloudReady = false;
    final chat = _CapturingChat((idx, payload, model) {
      if (idx.isEven) {
        return jsonEncode({
          'sections': [
            {
              'continuesPrevious': false,
              'mergesPreviousParagraph': false,
              'title': '本周联调与压测排期确认',
              'brief': '明确周三前完成接口联调与压测环境搭建。',
              'overview': '讨论了本周后端接口联调和压测的节点安排，要求在周三前准备就绪以避免影响客户端周五集成。',
              'tags': ['联调', '压测'],
              'paragraphs': [
                {
                  'uStart': 0,
                  'uEnd': 2,
                  'speaker': '说话人 1',
                  'text': '这周三前必须把接口联调环境搭好并完成压测，不然周五客户端集成来不及。',
                },
              ],
            },
          ],
        });
      }
      return jsonEncode({
        'sections': [
          {
            'continuesPrevious': true,
            'mergesPreviousParagraph': true,
            'title': '联调压测排期与回归分工确认',
            'brief': '周三完成压测与回归补充，周四复核监控指标。',
            'overview':
                '在确认周三联调与压测deadline基础上，补充压测脚本与回归用例准备安排，并约定周四下午共同核验监控指标。',
            'tags': ['联调', '压测', '监控'],
            'paragraphs': [
              {
                'uStart': 0,
                'uEnd': 0,
                'speaker': '说话人 1',
                'text': '压测脚本和回归用例我也一并补充完。',
              },
              {
                'uStart': 1,
                'uEnd': 1,
                'speaker': '说话人 2',
                'text': '好，那周四下午我们一起过一遍监控指标。',
              },
            ],
          },
        ],
      });
    });

    final cleaner = RollingCleanSegmentService(
      chat: chat,
      modelResolver: () => resolvedModel,
      ready: () => cloudReady,
      resolveRoot: store.root,
      voiceprintStore: vpLib,
      agentConfig: cfg,
    );

    expect(cleaner.isReady, isFalse);
    resolvedModel = 'qwen-plus';
    cloudReady = true;
    expect(cleaner.isReady, isTrue);

    final res = await cleaner.run([recFile], topicStore: topicStore);
    expect(res.evaluatedRuns, 1);
    expect(res.evaluatedBatches, 2);
    expect(chat.calls.length, 2);
    expect(chat.calls.first.model, 'qwen-plus');

    // 验证隐私红线：绝不上行原始 float centroid；但上行簇间相似度和候选提示
    final firstPayloadJson = jsonEncode(chat.calls.first.userJson);
    expect(firstPayloadJson.contains('0.526'), isFalse);
    final vpCtx =
        chat.calls.first.userJson['speaker_voiceprint_context']
            as Map<String, dynamic>;
    expect(vpCtx['cluster_similarities'], isNotEmpty);
    expect(vpCtx['voiceprint_weak_hints'], isNotEmpty);

    // 验证第二批准确携带了第一批的重叠段落上下文（paragraphs 模式）
    final secondOverlap =
        chat.calls[1].userJson['previous_organized_context']
            as Map<String, dynamic>;
    expect(secondOverlap['hasPrevious'], isTrue);
    expect(secondOverlap['overlapMode'], 'paragraphs');
    expect((secondOverlap['tailParagraphs'] as List).length, 1);

    // 投影输出检查：阶段标题/概述与合并后段落均正确呈现
    final proj = SegmentProjection.build([recFile], topicState: res.state);
    expect(proj.events.length, 1);
    final ev = proj.events.single;
    expect(ev.title, '联调压测排期与回归分工确认');
    expect(ev.longText, contains('周四下午共同核验监控指标'));
    expect(ev.dialog.length, 2);
    expect(ev.dialog.first.text, contains('这周三前必须把接口联调环境搭好'));
    expect(ev.dialog.first.text, contains('压测脚本和回归用例我也一并补充完'));
    expect(ev.dialog.last.spk, '说话人 2');

    // 再测试按分钟窗口模式（cleanOverlapMode == 'minutes'）
    await cfg.setCleanOverlapMode('minutes');
    await cfg.setCleanOverlapMinutes(4);
    final resMinutes = await cleaner.run(
      [recFile],
      topicStore: topicStore,
      forceRecleanAll: true,
    );
    expect(resMinutes.evaluatedBatches, 2);
    final minOverlap =
        chat.calls[3].userJson['previous_organized_context']
            as Map<String, dynamic>;
    expect(minOverlap['overlapMode'], 'minutes');
    expect((minOverlap['tailParagraphs'] as List), isNotEmpty);
  });

  testWidgets('详情页对话详情展示阶段概述并按说话人合并连续语段', (tester) async {
    final start = DateTime.now()
        .subtract(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    final file = RecordingFile(
      deviceName: 'DETAIL.APM',
      session: 'S_DET',
      seq: 1,
      startAtMs: start,
      apmPath: '/tmp/det.apm',
      createdAtMs: start,
      durationMs: 90000,
      timeSynced: true,
      stage: RecordingStage.ready,
      turns: const [
        PolishedTurn(
          id: 't0',
          startMs: 1000,
          endMs: 10000,
          speakerLabel: '说话人 1',
          text: '先把核心流程走通，',
          srcUtteranceIds: [],
        ),
        PolishedTurn(
          id: 't1',
          startMs: 11000,
          endMs: 25000,
          speakerLabel: '说话人 1',
          text: '再补齐异常分支。',
          srcUtteranceIds: [],
        ),
        PolishedTurn(
          id: 't2',
          startMs: 30000,
          endMs: 45000,
          speakerLabel: '说话人 2',
          text: '好的，我来写集成测试。',
          srcUtteranceIds: [],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-det-1',
          sessionId: 'S_DET',
          index: 0,
          startAtMs: start,
          endAtMs: start + 90000,
          title: '核心流程与测试分工',
          brief: '确定先跑通主干再补单测与集成测试。',
          longText: '本阶段明确先完成核心流程联调，随后由说话人 2 补齐集成测试覆盖。',
          speakerLabels: const ['说话人 1', '说话人 2'],
          speakerCount: 2,
          status: SegmentStatus.closed,
          turnIds: const ['t0', 't1', 't2'],
        ),
      ],
    );
    final proj = SegmentProjection.build([file]);
    final store = AppStore(events: proj.events)..segmentViews = proj.views;
    addTearDown(store.dispose);

    await tester.pumpWidget(
      StoreScope(
        store: store,
        child: MaterialApp(
          theme: testTheme(),
          home: const Scaffold(body: DetailPage(eventId: 'seg-det-1')),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('detail-overview-card')), findsOneWidget);
    expect(find.text('阶段概述'), findsOneWidget);
    // t0 与 t1 为同一说话人且无穿插图片，应合并为一个自然段气泡（只有 turn-spk-0 和 turn-spk-2）
    expect(find.byKey(const Key('turn-spk-0')), findsOneWidget);
    expect(find.byKey(const Key('turn-spk-1')), findsNothing);
    expect(find.byKey(const Key('turn-spk-2')), findsOneWidget);
    expect(find.textContaining('先把核心流程走通，再补齐异常分支。'), findsOneWidget);
  });

  testWidgets('设置页「开发者设置」：可调清洗周期、重叠策略并触发存量重洗', (tester) async {
    late Directory tmp;
    late RecordingStore rStore;
    late AgentConfigStore cfg;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('rc-dev-setting-');
      rStore = RecordingStore(
        root: tmp,
        jsonStore: JsonStore(store: InMemoryStore()),
      );
    });
    cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    addTearDown(() => tester.runAsync(() => tmp.delete(recursive: true)));

    final pipeline = RecordingPipeline(
      gateway: FakeCardGateway(),
      store: rStore,
      engine: _NoopEngine(),
      models: _NoopModels(),
      settings: SettingsStore(store: InMemoryStore()),
      agentConfig: cfg,
    );
    final auth = AuthService(secureStore: InMemorySecureStore());
    addTearDown(auth.dispose);
    final generator = SummaryGenerator(
      gateway: ModelGateway(client: auth.apiClient),
      agentConfig: cfg,
    );
    final store = AppStore(events: const [])
      ..attachPipeline(pipeline: pipeline, store: rStore, generator: generator);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      StoreScope(
        store: store,
        child: MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: store,
              builder: (_, _) {
                final top = store.stackTop;
                if (top?.type == 'setsub') {
                  return SettingSubPage(subId: top!.id, agentConfig: cfg);
                }
                return SettingPage(
                  settings: SettingsStore(store: InMemoryStore()),
                  agentConfig: cfg,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('set-developer')), findsNothing);
    await cfg.setDeveloperMode(true);
    await tester.pump();

    final entry = find.byKey(const Key('set-developer'));
    await tester.scrollUntilVisible(entry, 200);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(store.stackTop?.type, 'setsub');
    expect(store.stackTop?.id, 'dev');
    expect(find.byKey(const Key('dev-effective-model')), findsOneWidget);
    expect(find.text('短轮清洗'), findsNothing);
    final devScroll = find
        .descendant(
          of: find.byKey(const Key('setsub-scroll-dev')),
          matching: find.byType(Scrollable),
        )
        .first;
    final cycle = find.byKey(const Key('dev-cycle-preset-60'));
    await tester.scrollUntilVisible(cycle, 200, scrollable: devScroll);
    await tester.ensureVisible(cycle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dev-cycle-value')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('dev-cycle-value'))).data,
      '30 分钟',
    );

    await tester.tap(cycle);
    await tester.pump();
    expect(cfg.cleanCycleMinutes, 60);
    expect(
      tester.widget<Text>(find.byKey(const Key('dev-cycle-value'))).data,
      '1 小时',
    );
    expect(find.text('1 小时'), findsWidgets);

    final overlapMin = find.byKey(const Key('dev-overlap-mode-minutes'));
    await tester.scrollUntilVisible(overlapMin, 200, scrollable: devScroll);
    await tester.ensureVisible(overlapMin);
    await tester.pumpAndSettle();
    await tester.tap(overlapMin);
    await tester.pump();
    expect(cfg.cleanOverlapMode, 'minutes');

    final recleanBtn = find.byKey(const Key('dev-reclean-btn'));
    await tester.scrollUntilVisible(recleanBtn, 200, scrollable: devScroll);
    await tester.ensureVisible(recleanBtn);
    await tester.pumpAndSettle();
    await tester.tap(recleanBtn);
    for (var i = 0; i < 40 && store.isRecleaning; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(store.isRecleaning, isFalse);
    await tester.pump();
    expect(find.byKey(const Key('dev-reclean-status')), findsOneWidget);
  });
  test('短轮 payload 透传 emotion，且模型只回 summary 时映射到 brief/overview', () async {
    final tmp = await Directory.systemTemp.createTemp('rc-emotion-summary-');
    addTearDown(() => tmp.delete(recursive: true));
    final store = RecordingStore(
      root: tmp,
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    final topicStore = TopicSegmentationStore(resolveRoot: store.root);
    final start = DateTime.now()
        .subtract(const Duration(minutes: 20))
        .millisecondsSinceEpoch;
    final recFile = RecordingFile(
      deviceName: 'REC_EM.APM',
      session: 'SES_EM',
      seq: 1,
      startAtMs: start,
      apmPath: '\${tmp.path}/em.apm',
      createdAtMs: start,
      durationMs: 8 * 60 * 1000,
      timeSynced: true,
      stage: RecordingStage.ready,
      slices: const [
        AudioSlice(id: 's1', index: 0, startMs: 0, endMs: 480000, wavPath: ''),
      ],
      utterances: const [
        RawUtterance(
          id: 's1u0',
          sliceId: 's1',
          startMs: 1000,
          endMs: 8000,
          text: '今晚测试环境到底能不能用，我有点担心。',
          emotion: 'SAD',
          speakerLabel: '说话人 1',
          speakerCluster: 0,
          spkConfidence: 0.9,
        ),
        RawUtterance(
          id: 's1u1',
          sliceId: 's1',
          startMs: 9000,
          endMs: 16000,
          text: '应该可以，先跑登录和支付。',
          emotion: 'NEUTRAL',
          speakerLabel: '说话人 2',
          speakerCluster: 1,
          spkConfidence: 0.86,
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-em-0',
          sessionId: 'SES_EM',
          index: 0,
          startAtMs: start,
          endAtMs: start + 8 * 60 * 1000,
          title: '实时切片 #1',
          brief: '',
          status: SegmentStatus.closed,
          sliceIds: const ['s1'],
        ),
      ],
    );

    final chat = _CapturingChat((_, payload, _) {
      return jsonEncode({
        'sections': [
          {
            'continuesPrevious': false,
            'title': '下班前同步测试环境',
            'summary': '和同事确认测试环境今晚可用，用例先跑登录和支付。',
            'tags': ['测试'],
            'paragraphs': [
              {
                'uStart': 0,
                'uEnd': 0,
                'speaker': '说话人 1',
                'text': '今晚测试环境能不能用，有些担心。',
              },
              {
                'uStart': 1,
                'uEnd': 1,
                'speaker': '说话人 2',
                'text': '应该可以，先跑登录和支付。',
              },
            ],
          },
        ],
      });
    });
    final cleaner = RollingCleanSegmentService(
      chat: chat,
      modelResolver: () => 'qwen-plus',
      ready: () => true,
      resolveRoot: store.root,
    );
    final res = await cleaner.run([recFile], topicStore: topicStore);
    expect(res.evaluatedBatches, greaterThan(0));
    expect(chat.calls, isNotEmpty);

    final utterances = chat.calls.first.userJson['utterances'] as List;
    expect(utterances, isNotEmpty);
    expect(utterances.first['emotion'], 'SAD');
    expect(utterances.first['id'], 's1u0');
    expect(utterances.first['sliceId'], 's1');
    expect(utterances[1]['emotion'], 'NEUTRAL');
    expect(jsonEncode(chat.calls.first.userJson).contains('0.526'), isFalse);
    expect(chat.calls.first.system, contains('情绪仅供理解'));
    expect(chat.calls.first.system, contains('沉浸式大时段活动归拢'));
    expect(chat.calls.first.system, contains('lowValue'));

    // 原始记录仍保留情绪，不被清洗覆盖删除
    expect(recFile.utterances.first.emotion, 'SAD');
    expect(recFile.utterances.last.emotion, 'NEUTRAL');

    final proj = SegmentProjection.build([recFile], topicState: res.state);
    final ev = proj.events.single;
    expect(ev.title, '下班前同步测试环境');
    expect(ev.brief, '和同事确认测试环境今晚可用，用例先跑登录和支付。');
    expect(ev.longText, contains('和同事确认测试环境今晚可用'));
    expect(ev.brief.contains('SAD'), isFalse);
    expect(ev.longText.contains('SAD'), isFalse);
    expect(ev.dialog.any((t) => t.text.contains('SAD') || t.text.contains('情绪')), isFalse);
    expect(ev.note, isNull);
    expect(ev.note, isNot(equals('总结未完成')));

    final section = res.state.rollingByAnchor.values.single.sections.single;
    expect(section.summary, contains('测试环境今晚可用'));
    expect(section.brief, contains('测试环境今晚可用'));
    expect(section.overview, contains('测试环境今晚可用'));
    expect(section.evidenceSliceIds, contains('s1'));
  });
}
