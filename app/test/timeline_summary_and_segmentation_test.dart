// 四项核心产品体验端到端验收：
// 1. 总结卡按覆盖范围的结尾时间点内联插入时间轴（非永远置顶）；
// 2. 低价值碎碎念/纯静音折叠为「无意义碎碎念」轻量胶囊并保留详情入口，持续工作段跨间隔归拢；
// 3. 录音期静默分片落盘 + 可配置 15/30/60 分钟批量/查看触发转写；
// 4. 总结勾选态基于最近标记起点的上下滚动 sticky「选到此处 / 选择到这儿」区间全选。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/services/segment/record_value_classifier.dart';
import 'package:recording_card/services/segment/rolling_clean_segment_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/utterance_builder.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _FakeSpeechEngine implements SpeechEngine {
  int transcribeCalls = 0;
  String nextText = '今天我们在写录音卡项目的增量清洗与沉浸式合并模块。';

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (samples.isEmpty) return const [];
    return [SpeechSpan(0, samples.length)];
  }

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    transcribeCalls++;
    return AsrResult(
      text: nextText,
      tokens: const [],
      timestampsMs: const [],
      audioMs: samples.length * 1000 ~/ sampleRate,
    );
  }

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1.0, 0.0, 0.0];

  @override
  Future<void> dispose() async {}
}

class _ReadyModels implements SpeechModelProvider {
  _ReadyModels(this.paths);
  final SpeechModelPaths paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

class _FakeChat implements ChatCompletion {
  _FakeChat(this.responder);
  final String Function(Map<String, dynamic> payload) responder;
  int callCount = 0;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    callCount++;
    final payload = jsonDecode(messages.last.content) as Map<String, dynamic>;
    return responder(payload);
  }
}

Future<String> _writeDummyWav(Directory dir, String name, int durationMs) async {
  const sampleRate = 16000;
  final sampleCount = (sampleRate * durationMs / 1000).round().clamp(
    1600,
    sampleRate * 4,
  );
  final dataLen = sampleCount * 2;
  final out = Uint8List(44 + dataLen);
  final view = ByteData.sublistView(out);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out[offset + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * 2, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < sampleCount; i++) {
    view.setInt16(44 + i * 2, ((i % 80) - 40) * 120, Endian.little);
  }
  final path = '${dir.path}/$name';
  await File(path).writeAsBytes(out);
  return path;
}

RecordEvent _makeEvent({
  required String id,
  required int dayOffset,
  required String time,
  required String dur,
  required String title,
  required String brief,
  String? speakers,
  String mark = '',
  bool lowValue = false,
  List<EventPhoto> photos = const [],
}) {
  final who = speakers ?? '说话人 1（推测）';
  return RecordEvent(
    id: id,
    dayOffset: dayOffset,
    title: title,
    brief: brief,
    longText: brief,
    time: time,
    dur: dur,
    speakers: who,
    mark: mark,
    srcMap: '来源 $time',
    dialog: brief.isEmpty ? const [] : [TurnLine(who, brief, time)],
    raw: brief.isEmpty ? const [] : [TurnLine(who, brief, time)],
    photos: photos,
    lowValue: lowValue,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1. 总结卡按覆盖区间结尾时间点插入对应位置，且支持 JSON 持久化还原', () async {
    final model = SummaryModel();
    final events = [
      _makeEvent(
        id: 'ev1',
        dayOffset: 0,
        time: '20:00',
        dur: '30分',
        title: '晚间代码评审',
        brief: '晚上团队一起评审了增量合并逻辑并确定发版时间。',
      ),
      _makeEvent(
        id: 'ev2',
        dayOffset: 0,
        time: '16:00',
        dur: '20分',
        title: '下午核心接口联调',
        brief: '与后端完成转写与总结接口字段对齐联调。',
      ),
      _makeEvent(
        id: 'ev3',
        dayOffset: 0,
        time: '14:00',
        dur: '15分',
        title: '午后架构需求对齐',
        brief: '讨论了时间轴折叠以及区间勾选方案。',
      ),
    ];
    final store = AppStore(
      events: events,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    addTearDown(store.dispose);

    // 只选 ev2 和 ev3：结尾时间为 ev2 结束时间 (16:20)，应插在 ev1(20:00) 和 ev2(16:00) 之间
    store.startSummary();
    store.toggleSel('ev2');
    store.toggleSel('ev3');
    store.genSummary();
    await Future<void>.delayed(Duration.zero);
    model.release();
    for (var i = 0; i < 10 && store.summaries.single.state != SummaryState.done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final sum = store.summaries.single;
    expect(sum.state, SummaryState.done);
    expect(sum.endAtMs, isNotNull);
    expect(sum.rangeLabel, isNotEmpty);

    final items = store.feedGroups.first.items;
    final iEv1 = items.indexWhere((x) => x is RecordEvent && x.id == 'ev1');
    final iSum = items.indexWhere((x) => identical(x, sum));
    final iEv2 = items.indexWhere((x) => x is RecordEvent && x.id == 'ev2');
    final iEv3 = items.indexWhere((x) => x is RecordEvent && x.id == 'ev3');
    expect(iEv1, 0);
    expect(iSum, 1, reason: '覆盖 14:00~16:20 的总结应插入到 16:20 位置（ev1 之下、ev2 之上）');
    expect(iEv2, 2);
    expect(iEv3, 3);

    // 同毫秒边界 tie-break：若恰好在 16:20 开始新事件 evNext，事件应在 16:20 总结之上
    final nextAtExactEnd = _makeEvent(
      id: 'evNext',
      dayOffset: 0,
      time: '16:20',
      dur: '10分',
      title: '16点20开始的后续讨论',
      brief: '接着前一段继续讨论部署与监控细节。',
    );
    final storeTie = AppStore(
      events: [...events, nextAtExactEnd],
      loadPersistedState: false,
    )..summaries.add(SummaryCard.fromJson(sum.toJson()));
    addTearDown(storeTie.dispose);
    final tieItems = storeTie.feedGroups.first.items;
    final tieNextIdx = tieItems.indexWhere(
      (x) => x is RecordEvent && x.id == 'evNext',
    );
    final tieSumIdx = tieItems.indexWhere((x) => x is SummaryCard);
    expect(tieNextIdx, lessThan(tieSumIdx));

    // 删除来源后依赖持久化的 endAtMs 仍能准确落位
    final restored = SummaryCard.fromJson(sum.toJson());
    expect(restored.endAtMs, sum.endAtMs);
    expect(restored.rangeLabel, sum.rangeLabel);
  });

  testWidgets('2a. 低价值“我正在说话”/单字“我”/静音段折迭成紧凑胶囊，照片与重点打点受保护，点击可入详情', (
    tester,
  ) async {
    final model = SummaryModel();
    final events = [
      _makeEvent(
        id: 'work1',
        dayOffset: 0,
        time: '18:00',
        dur: '45分',
        title: '持续编写录制链路与提示词调试',
        brief: '集中完成时间轴内联总结与批量转写逻辑编写并跑通单测。',
      ),
      _makeEvent(
        id: 'triv1',
        dayOffset: 0,
        time: '17:10',
        dur: '45秒',
        title: '我正在说话',
        brief: '我正在说话',
      ),
      _makeEvent(
        id: 'triv2',
        dayOffset: 0,
        time: '17:08',
        dur: '45秒',
        title: '我',
        brief: '我',
      ),
      _makeEvent(
        id: 'triv3',
        dayOffset: 0,
        time: '17:04',
        dur: '2分',
        speakers: '无语音',
        title: '未识别到语音',
        brief: '',
      ),
      _makeEvent(
        id: 'photoProtected',
        dayOffset: 0,
        time: '16:55',
        dur: '35秒',
        title: '白板拍照瞬间',
        brief: '嗯',
        photos: const [EventPhoto(id: 'p1', time: '16:55')],
      ),
      _makeEvent(
        id: 'markProtected',
        dayOffset: 0,
        time: '16:50',
        dur: '40秒',
        title: '临时关键标记',
        brief: '嗯',
        mark: '手动标记',
      ),
    ];

    expect(buildReadableFallbackTitle('我正在说话'), isNot('我'));
    expect(buildReadableFallbackTitle('我'), '简短语音');

    final store = AppStore(
      events: events,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    await pumpShell(tester, store: store, model: model);

    // 验证 Feed 聚合结构
    final feed = store.feedGroups.first.items;
    expect(feed[0], isA<RecordEvent>());
    expect((feed[0] as RecordEvent).id, 'work1');
    expect(feed[1], isA<TrivialClusterCard>());
    final cluster = feed[1] as TrivialClusterCard;
    expect(cluster.count, 3);
    expect(feed[2], isA<RecordEvent>());
    expect((feed[2] as RecordEvent).id, 'photoProtected',
        reason: '有现场照片的记录受保护不得折叠');
    expect(feed[3], isA<RecordEvent>());
    expect((feed[3] as RecordEvent).id, 'markProtected',
        reason: '有物理打点的片段受保护不得折叠');

    // 页面中出现紧凑胶囊「无意义碎碎念 · 3 段」，而不直接铺开 triv1 / triv2
    expect(find.byKey(Key('trivial-cluster-${cluster.id}')), findsOneWidget);
    expect(find.textContaining('无意义碎碎念 · 3 段'), findsOneWidget);
    expect(find.byKey(const Key('card-triv1')), findsNothing);
    expect(find.byKey(const Key('card-triv2')), findsNothing);

    // 点开胶囊弹出列表，并点其中一项跳转进独立详情页
    await tester.tap(find.byKey(Key('trivial-cluster-${cluster.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trivial-sheet')), findsOneWidget);
    expect(find.byKey(const Key('trivial-item-triv1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('trivial-item-triv1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dt-h3')), findsOneWidget);

    // 勾选「今日」时跳过被折叠的碎碎念，仅勾选有价值与受保护记录
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chip-today')));
    await tester.pump();
    expect(
      store.selIds,
      containsAll(['work1', 'photoProtected', 'markProtected']),
    );
    expect(store.selIds, isNot(contains('triv1')));
    expect(store.selIds, isNot(contains('triv2')));
    expect(store.selIds, isNot(contains('triv3')));
  });

  test('2b. SegmentProjection 与 RollingCleanSegmentService 跨短静默间隔归拢同一工作状态', () async {
    final root = await Directory.systemTemp.createTemp('rc-imm-group-');
    addTearDown(() => root.delete(recursive: true));
    final t0 = DateTime(2026, 11, 21, 10, 0).millisecondsSinceEpoch;

    RecordingFile buildFile(
      String id,
      int seq,
      int offsetMin,
      int durMin,
      List<String> lines,
    ) {
      final start = t0 + offsetMin * 60 * 1000;
      final end = start + durMin * 60 * 1000;
      return RecordingFile(
        deviceName: '$id.WAV',
        session: 'SES_IMM',
        seq: seq,
        startAtMs: start,
        apmPath: '${root.path}/$id.wav',
        wavPath: '${root.path}/$id.wav',
        createdAtMs: end,
        durationMs: durMin * 60 * 1000,
        stage: RecordingStage.ready,
        slices: [
          AudioSlice(
            id: id,
            index: seq - 1,
            startMs: 0,
            endMs: durMin * 60 * 1000,
            wavPath: '${root.path}/$id.wav',
          ),
        ],
        utterances: [
          for (var i = 0; i < lines.length; i++)
            RawUtterance(
              id: '${id}u$i',
              sliceId: id,
              startMs: i * 10000,
              endMs: (i + 1) * 10000,
              speakerLabel: '说话人 1',
              speakerCluster: 0,
              spkConfidence: 0.9,
              text: lines[i],
            ),
        ],
        segments: [
          SegmentRecord(
            id: 'seg-$id',
            sessionId: 'SES_IMM',
            index: seq - 1,
            startAtMs: start,
            endAtMs: end,
            title: '实时切片 #$seq',
            brief: '',
            status: SegmentStatus.closed,
            sliceIds: [id],
          ),
        ],
      );
    }

    // s1 (10:00-10:05) + s2 静默(10:05-10:08) + s3 仅间隔 8 分钟(10:13-10:20) -> 应归并同一活动组
    // s4 间隔 45 分钟(11:05-11:10) -> 拆成第 2 组
    final files = [
      buildFile('s1', 1, 0, 5, ['正在编写时间轴批量转写逻辑，把模型调用改为按周期运行。']),
      buildFile('s2', 2, 5, 3, const []), // 中途静默敲代码
      buildFile('s3', 3, 13, 7, ['继续写沉浸式活动归纳的提示词并修改测试断言。']),
      buildFile('s4', 4, 65, 5, ['我正在说话。']),
    ];

    final groups = SegmentProjection.collectActivityGroups(files);
    expect(groups.length, 2, reason: '前 3 片间隔 <30 分钟应归为同一活动组，45 分钟休息后另起一组');
    expect(
      groups.first.views.map((v) => v.segment.id).toList(),
      ['seg-s1', 'seg-s3'],
    );
    expect(
      groups.last.views.map((v) => v.segment.id).toList(),
      ['seg-s4'],
    );

    final chat = _FakeChat((payload) {
      final utterances = payload['utterances'] as List;
      final firstSlice = utterances.isNotEmpty
          ? '${utterances.first['sliceId']}'
          : '';
      if (firstSlice == 's1') {
        expect((utterances[1]['gapSincePrevSec'] as num).toInt(), greaterThan(300));
        return jsonEncode({
          'sections': [
            {
              'continuesPrevious': false,
              'lowValue': false,
              'title': '研发时间轴批量转写与活动合并',
              'summary': '持续专注编码，完成按周期批量转写和活动跨间隔归拢提示词改造。',
              'tags': ['研发'],
              'paragraphs': [
                for (var i = 0; i < utterances.length; i++)
                  {
                    'uStart': i,
                    'uEnd': i,
                    'speaker': '说话人 1',
                    'text': utterances[i]['text'],
                  },
              ],
            },
          ],
        });
      }
      return jsonEncode({
        'sections': [
          {
            'continuesPrevious': false,
            'lowValue': true,
            'title': '简短语音',
            'summary': '我正在说话。',
            'tags': [],
            'paragraphs': [
              {
                'uStart': 0,
                'uEnd': 0,
                'speaker': '说话人 1',
                'text': '我正在说话。',
              },
            ],
          },
        ],
      });
    });

    final recStore = RecordingStore(
      root: Directory('${root.path}/rec'),
      jsonStore: JsonStore(store: InMemoryStore()),
    );
    final topicStore = TopicSegmentationStore(resolveRoot: recStore.root);
    final cleaner = RollingCleanSegmentService(
      chat: chat,
      modelResolver: () => 'qwen-plus',
      ready: () => true,
      resolveRoot: recStore.root,
    );
    final res = await cleaner.run(files, topicStore: topicStore);
    final proj = SegmentProjection.build(files, topicState: res.state);

    // 中间 3 分钟静默 s2 已被活动主线吸收，不会单独占一条卡；结果只含 1 张沉浸工作卡 + 1 张 lowValue 卡
    expect(proj.events.length, 2);
    final ordered = [...proj.events]..sort((a, b) => a.time.compareTo(b.time));
    expect(ordered.first.title, '研发时间轴批量转写与活动合并');
    expect(ordered.first.lowValue, isFalse);
    expect(ordered.last.lowValue, isTrue);
    expect(
      RecordValueClassifier.isLowValueForTimeline(
        ordered.last,
        hasActivePhotos: false,
      ),
      isTrue,
    );
  });

  testWidgets('3. 静默缓存切片 → 满 15 分钟自动或查看/停录/设置触发转写与整理', (tester) async {
    late Directory root;
    late RecordingStore recStore;
    late AgentConfigStore cfg;
    late _FakeSpeechEngine engine;
    late RecordingPipeline pipeline;
    late RecordingStatusController status;
    late AppStore appStore;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('rc-batch-asr-');
      recStore = RecordingStore(
        root: Directory('${root.path}/rec'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      engine = _FakeSpeechEngine();
      final models = _ReadyModels(
        SpeechModelPaths(
          asrModelPath: '${root.path}/m.onnx',
          tokensPath: '${root.path}/t.txt',
          vadPath: '${root.path}/v.onnx',
          speakerEmbeddingPath: '${root.path}/s.onnx',
        ),
      );
      pipeline = RecordingPipeline(
        gateway: FakeCardGateway(),
        store: recStore,
        engine: engine,
        models: models,
        liveAudioBaseDir: root,
      );
      cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      status = RecordingStatusController();
      appStore = AppStore(status: status, loadPersistedState: false)
        ..deferredBatchTranscription = true
        ..transcribeCycleMinutes = cfg.transcribeCycleMinutes
        ..attachPipeline(
          pipeline: pipeline,
          store: recStore,
          generator: await SummaryModel().generator(),
          status: status,
        );
      expect(cfg.transcribeCycleMinutes, 15);

      // 1) 静默写入第 1 片 5 分钟（未满 15 分钟）：不调用本地 ASR
      final wav1 = await _writeDummyWav(root, 's1.wav', 5 * 60 * 1000);
      await appStore.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'SES_B',
          sliceIndex: 0,
          startAtMs: DateTime(2026, 11, 21, 9, 0).millisecondsSinceEpoch,
          durationMs: 5 * 60 * 1000,
          wavPath: wav1,
          isFinal: false,
        ),
      );
      expect(engine.transcribeCalls, 0);
      expect(appStore.pendingLocalAudioCount, 1);
      expect(appStore.pendingLocalAudioDurationMs, 5 * 60 * 1000);
      expect(appStore.events, isEmpty);

      // 2) 静默写入第 2 片 10 分钟：累计 15 分钟到达周期阈值，自动触发批量转写！
      final wav2 = await _writeDummyWav(root, 's2.wav', 10 * 60 * 1000);
      await appStore.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'SES_B',
          sliceIndex: 1,
          startAtMs: DateTime(2026, 11, 21, 9, 5).millisecondsSinceEpoch,
          durationMs: 10 * 60 * 1000,
          wavPath: wav2,
          isFinal: false,
        ),
      );
      for (var i = 0; i < 60 && appStore.pendingLocalAudioCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.transcribeCalls, 2);
      expect(appStore.pendingLocalAudioCount, 0);
      expect(appStore.events, isNotEmpty);

      // 3) 再录入第 3 片 3 分钟并模拟用户切换回 Timeline 查看触发批量转写
      final wav3 = await _writeDummyWav(root, 's3.wav', 3 * 60 * 1000);
      await appStore.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'SES_B',
          sliceIndex: 2,
          startAtMs: DateTime(2026, 11, 21, 9, 15).millisecondsSinceEpoch,
          durationMs: 3 * 60 * 1000,
          wavPath: wav3,
          isFinal: false,
        ),
      );
      expect(engine.transcribeCalls, 2);
      expect(appStore.pendingLocalAudioCount, 1);

      await appStore.transcribeAndOrganizePending(reason: 'view-resume');
      expect(engine.transcribeCalls, 3);
      expect(appStore.pendingLocalAudioCount, 0);
    });
    addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
    addTearDown(status.dispose);
    addTearDown(appStore.dispose);

    // 4) 验证 Setting「批量转写周期」可切为 30 分钟并实时更新 RecordingStatusController
    final dev = DeviceStore(gateway: FakeCardGateway());
    addTearDown(dev.dispose);
    cfg.addListener(() {
      appStore.transcribeCycleMinutes = cfg.transcribeCycleMinutes;
      status.transcribeCycleMinutes = cfg.transcribeCycleMinutes;
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        scrollBehavior: const RCScrollBehavior(),
        home: AppShell(
          store: appStore,
          device: dev,
          settings: SettingsStore(store: InMemoryStore()),
          agentConfig: cfg,
          recordingStatus: status,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pumpAndSettle();
    final cycleRow = find.byKey(const Key('set-transcribe-cycle'));
    await tester.ensureVisible(cycleRow);
    await tester.tap(cycleRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cycle-opt-30')));
    await tester.pumpAndSettle();

    expect(cfg.transcribeCycleMinutes, 30);
    expect(appStore.transcribeCycleMinutes, 30);
    expect(status.transcribeCycleMinutes, 30);
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-transcribe-cycle'))).data,
      '每 30 分钟',
    );
  });

  testWidgets('4. 总结勾选态：标记起点后下滑出底栏「选到此处」、上滑出顶栏「选择到这儿」区间全选', (
    tester,
  ) async {
    final events = <RecordEvent>[
      for (var i = 0; i < 12; i++)
        _makeEvent(
          id: 'ev${i.toString().padLeft(2, '0')}',
          dayOffset: 0,
          time: '${(20 - i).toString().padLeft(2, '0')}:10',
          dur: '25分',
          title: '工作时段记录 ${i.toString().padLeft(2, '0')}',
          brief:
              '这是一段较长的工作上下文摘要，包含代码讨论、文档梳理与验证计划，用于撑开列表高度以触发滚动区间选择 #$i。',
        ),
    ];
    final model = SummaryModel();
    final store = AppStore(
      events: events,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    await pumpShell(tester, store: store, model: model);

    // 进入勾选模式并标记最上方第 1 条 ev00 为起点
    await tester.tap(find.byKey(const Key('summary-start')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sticky-select-top')), findsNothing);
    expect(find.byKey(const Key('sticky-select-bottom')), findsNothing);

    await tester.tap(find.byKey(const Key('selbox-ev00')));
    await tester.pumpAndSettle();
    expect(store.selAnchorId, 'ev00');
    expect(find.byKey(const Key('sel-anchor-badge-ev00')), findsOneWidget);
    expect(find.byKey(const Key('sticky-select-bottom')), findsNothing);

    // 向下滑动列表，使起点 ev00 滚出视口上方
    await tester.drag(
      find.byKey(const Key('timeline-list')),
      const Offset(0, -650),
    );
    await tester.pumpAndSettle();

    final bottomBtn = find.byKey(const Key('sticky-select-bottom'));
    expect(bottomBtn, findsOneWidget);
    expect(find.textContaining('选到此处'), findsOneWidget);

    await tester.tap(bottomBtn);
    await tester.pumpAndSettle();
    expect(store.selCount, greaterThan(3));
    expect(store.selIds, contains('ev00'));
    expect(store.selIds, contains(store.selAnchorId));
    expect(find.byKey(const Key('sticky-select-bottom')), findsNothing);

    // 清空重来：滚到最底部，标记最后一条 ev11，随后向上回滑，顶部出现「选择到这儿」
    await tester.tap(find.byKey(const Key('chip-none')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('timeline-list')),
      const Offset(0, -1400),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('selbox-ev11')));
    await tester.pumpAndSettle();
    expect(store.selAnchorId, 'ev11');
    expect(find.byKey(const Key('sel-anchor-badge-ev11')), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('timeline-list')),
      const Offset(0, 950),
    );
    await tester.pumpAndSettle();

    final topBtn = find.byKey(const Key('sticky-select-top'));
    expect(topBtn, findsOneWidget);
    expect(find.textContaining('选择到这儿'), findsOneWidget);

    await tester.tap(topBtn);
    await tester.pumpAndSettle();
    expect(store.selCount, greaterThan(3));
    expect(store.selIds, contains('ev11'));
    expect(store.selIds, contains(store.selAnchorId));
    expect(find.byKey(const Key('sticky-select-top')), findsNothing);
  });
}
