import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/recordings/multi_track_reconciler.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/fake_gateway.dart';
import 'support/fake_recordings.dart';
import 'support/model_stub.dart';

class _StubChatCompletion implements ChatCompletion {
  _StubChatCompletion(this.responder);

  final String Function(List<ChatMessage> messages) responder;
  int calls = 0;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.2,
    int maxTokens = 2048,
  }) async {
    calls++;
    return responder(messages);
  }
}

class _StubModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/fake/asr.onnx',
    tokensPath: '/fake/tokens.txt',
    vadPath: '/fake/vad.onnx',
  );
}

class _StubEngine implements SpeechEngine {
  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => AsrResult(
    text: '这是测试转写内容。',
    tokens: const [],
    timestampsMs: const [],
    audioMs: samples.length * 1000 ~/ sampleRate,
  );

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => [SpeechSpan(0, samples.length)];

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1, 0, 0];

  @override
  Future<void> dispose() async {}
}

RecordingFile _makeTrackFile({
  required String id,
  required String lane,
  required String devLabel,
  required int startAtMs,
  required int durationMs,
  required String title,
  required String text,
  String wavPath = '',
}) {
  final segId = '${id}_seg0';
  final hasSpeech = text.trim().isNotEmpty;
  return RecordingFile(
    deviceName: '${lane.toUpperCase()}_$id',
    session: 'ses_$id',
    seq: 0,
    startAtMs: startAtMs,
    apmPath: '',
    wavPath: wavPath.isEmpty ? '/tmp/$id.wav' : wavPath,
    createdAtMs: startAtMs,
    durationMs: durationMs,
    timeSynced: true,
    stage: RecordingStage.ready,
    sourceLane: lane,
    sourceDeviceLabel: devLabel,
    slices: [
      AudioSlice(
        id: '0001',
        index: 0,
        startMs: 0,
        endMs: durationMs,
        wavPath: wavPath.isEmpty ? '/tmp/$id.wav' : wavPath,
        stage: SliceStage.polished,
      ),
    ],
    utterances: hasSpeech
        ? [
            RawUtterance(
              id: 'u0',
              sliceId: '0001',
              startMs: 0,
              endMs: durationMs - 500,
              text: text,
              speakerLabel: '说话人 1',
            ),
          ]
        : const [],
    turns: hasSpeech
        ? [
            PolishedTurn(
              id: 't0',
              startMs: 0,
              endMs: durationMs - 500,
              speakerLabel: '说话人 1',
              text: text,
              srcUtteranceIds: const ['u0'],
            ),
          ]
        : const [],
    segments: [
      SegmentRecord(
        id: segId,
        sessionId: 'ses_$id',
        index: 0,
        startAtMs: startAtMs,
        endAtMs: startAtMs + durationMs,
        title: title,
        brief: text,
        longText: text,
        speakerLabels: hasSpeech ? const ['说话人 1'] : const [],
        speakerCount: hasSpeech ? 1 : 0,
        status: SegmentStatus.closed,
        sliceIds: const ['0001'],
        turnIds: hasSpeech ? const ['t0'] : const [],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Test 1: 一路为空/杂音、另一路完整时保留完整权威文本，两份原始文件均完整保留', () async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-reconcile-empty-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final store = RecordingStore(root: tmpDir);
    final now = DateTime.now();
    final t0 = DateTime(now.year, now.month, now.day, 10, 0).millisecondsSinceEpoch;

    final bleFile = _makeTrackFile(
      id: 'ble1',
      lane: 'ble',
      devLabel: '录音卡 V2',
      startAtMs: t0,
      durationMs: 60000,
      title: '空片段',
      text: '嗯。',
    );
    final phoneFile = _makeTrackFile(
      id: 'ph1',
      lane: 'phone',
      devLabel: '手机本机',
      startAtMs: t0,
      durationMs: 60000,
      title: '产品需求同步',
      text: '我们需要把蓝牙断连兜底、手表接力与双路比对合并上线并补充完整验收用例。',
    );
    await store.save(bleFile);
    await store.save(phoneFile);

    final state = await MultiTrackReconciler().reconcile(
      [bleFile, phoneFile],
      previous: const MultiTrackReconciliationState(),
    );

    expect(state.decisions, hasLength(1));
    expect(state.decisions.single.outcome, TrackOverlapOutcome.keepNonEmpty);
    expect(state.decisions.single.primarySegmentId, 'ph1_seg0');
    expect(state.decisions.single.secondarySegmentId, 'ble1_seg0');
    expect(state.hiddenSegmentIds, contains('ble1_seg0'));
    expect(state.hiddenSegmentIds.contains('ph1_seg0'), isFalse);

    // 冗余原始音频与索引必须完整保留不删除
    final onDisk = await store.loadAll(refresh: true);
    expect(onDisk, hasLength(2));
  });

  test('Test 2: 双路文本一致时去重隐藏副本，优先保留文本更完整/更近用户设备（BLE > Watch > Phone），原始文件均保留', () async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-reconcile-dedup-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final store = RecordingStore(root: tmpDir);
    final now = DateTime.now();
    final t0 = DateTime(now.year, now.month, now.day, 11, 0).millisecondsSinceEpoch;

    final bleFile = _makeTrackFile(
      id: 'ble2',
      lane: 'ble',
      devLabel: '录音卡 V2',
      startAtMs: t0,
      durationMs: 60000,
      title: '项目周会确认',
      text: '下周三完成接口联调，周五发布灰度版本并盯守监控指标。',
    );
    final watchFile = _makeTrackFile(
      id: 'w2',
      lane: 'watch',
      devLabel: 'Apple Watch',
      startAtMs: t0 + 1000,
      durationMs: 58000,
      title: '项目周会确认',
      text: '下周三完成接口联调，周五发布灰度版本并盯守监控指标。',
    );
    await store.save(bleFile);
    await store.save(watchFile);

    final state = await MultiTrackReconciler().reconcile(
      [bleFile, watchFile],
      previous: const MultiTrackReconciliationState(),
    );

    expect(state.decisions, hasLength(1));
    expect(state.decisions.single.outcome, TrackOverlapOutcome.dedupKeepPrimary);
    expect(state.decisions.single.primarySegmentId, 'ble2_seg0');
    expect(state.decisions.single.secondarySegmentId, 'w2_seg0');
    expect(state.hiddenSegmentIds, contains('w2_seg0'));
    expect(await store.loadAll(refresh: true), hasLength(2));
  });

  test('Test 3: 模糊相似度区间走云端语义判定，离线时确定性回退本地阈值', () async {
    final now = DateTime.now();
    final t0 = DateTime(now.year, now.month, now.day, 14, 0).millisecondsSinceEpoch;

    // 构造相似度落在 (0.14, 0.58) 模糊区间的两条重叠记录
    final bleFile = _makeTrackFile(
      id: 'ble3',
      lane: 'ble',
      devLabel: '录音卡 V2',
      startAtMs: t0,
      durationMs: 60000,
      title: 'A 路记录',
      text: '今天下午讨论项目排期以及周五接口联调发布计划',
    );
    final phoneFile = _makeTrackFile(
      id: 'ph3',
      lane: 'phone',
      devLabel: '手机本机',
      startAtMs: t0,
      durationMs: 60000,
      title: 'B 路记录',
      text: '下午会场补充测试环境验收标准和排期接口联调确认单',
    );

    // 3a) 云端判定 relation: different -> 分叉双列
    final forkChat = _StubChatCompletion(
      (_) => '{"relation": "different", "preferred": "A", "reason": "关注点不同"}',
    );
    final forkState = await MultiTrackReconciler(
      chat: forkChat,
      modelResolver: () => 'gpt-test',
      ready: () => true,
    ).reconcile(
      [bleFile, phoneFile],
      previous: const MultiTrackReconciliationState(),
    );
    expect(forkChat.calls, 1);
    expect(forkState.decisions.single.outcome, TrackOverlapOutcome.forkParallel);

    // 3b) 云端判定 relation: same -> 去重合并
    final sameChat = _StubChatCompletion(
      (_) => '{"relation": "same", "preferred": "A", "reason": "同一场排期会"}',
    );
    final sameState = await MultiTrackReconciler(
      chat: sameChat,
      modelResolver: () => 'gpt-test',
      ready: () => true,
    ).reconcile(
      [bleFile, phoneFile],
      previous: const MultiTrackReconciliationState(),
    );
    expect(sameChat.calls, 1);
    expect(sameState.decisions.single.outcome, TrackOverlapOutcome.dedupKeepPrimary);

    // 3c) 离线回退（ready=false）不抛异常、不阻塞并产出确定结果
    final offlineState = await MultiTrackReconciler(
      chat: sameChat,
      modelResolver: () => 'gpt-test',
      ready: () => false,
    ).reconcile(
      [bleFile, phoneFile],
      previous: const MultiTrackReconciliationState(),
    );
    expect(offlineState.decisions, hasLength(1));
  });

  testWidgets(
    'Test 4: 语义不同分叉双列 -> SegmentProjection 不跨路吞并 -> 375px Timeline 双列卡片与 Detail 对照交互零溢出',
    (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-fork-ui-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final recStore = RecordingStore(root: tmpDir);
      final now = DateTime.now();
      final t0 = DateTime(now.year, now.month, now.day, 11, 30).millisecondsSinceEpoch;

      final bleFile = _makeTrackFile(
        id: 'ble_call',
        lane: 'ble',
        devLabel: '录音卡 V2 · 外出接电话',
        startAtMs: t0,
        durationMs: 120000,
        title: '临时客户来电报价沟通',
        text: '客户电话要求下周提交正式商业合同与技术方案报价清单。',
      );
      final phoneFile = _makeTrackFile(
        id: 'ph_room',
        lane: 'phone',
        devLabel: '手机本机 · 会议室讨论',
        startAtMs: t0,
        durationMs: 120000,
        title: '会议室内部排期评审',
        text: '研发与测试在会议室敲定数据库索引重构方案和上线窗口。',
      );
      late AppStore appStore;
      late String forkId;
      late ProjectionResult projected;

      await tester.runAsync(() async {
        await recStore.save(bleFile);
        await recStore.save(phoneFile);

        final reconciler = MultiTrackReconciler();
        final reconciliation = await reconciler.reconcile(
          [bleFile, phoneFile],
          previous: const MultiTrackReconciliationState(),
        );
        await MultiTrackReconciliationStore(
          resolveRoot: recStore.root,
        ).save(reconciliation);

        expect(
          reconciliation.decisions.single.outcome,
          TrackOverlapOutcome.forkParallel,
        );
        forkId = reconciliation.decisions.single.forkGroupId!;

        // 验证 SegmentProjection 不跨通道误合并，保留双路 forkGroupId
        projected = SegmentProjection.build(
          [bleFile, phoneFile],
          reconciliation: reconciliation,
        );

        final pipeline = RecordingPipeline(
          gateway: FakeCardGateway(),
          store: recStore,
          engine: _StubEngine(),
          models: _StubModels(),
          multiTrackReconciler: reconciler,
        );
        final fakeSync = await FakeRecordingSync.create(localEvents: const []);
        final gen = await SummaryModel().generator();
        appStore = AppStore(
          recordings: fakeSync,
          generator: gen,
          loadPersistedState: false,
        );
        appStore.attachPipeline(
          pipeline: pipeline,
          store: recStore,
          generator: gen,
        );
        await appStore.refreshFromStore();
      });
      addTearDown(appStore.dispose);

      expect(projected.events, hasLength(2));
      expect(projected.events.every((e) => e.forkGroupId == forkId), isTrue);

      final todayItems = appStore.feedGroups.first.items;
      final forkPairs = todayItems.whereType<ForkedEventPair>().toList();
      expect(forkPairs, hasLength(1));
      expect(forkPairs.single.left.id, 'ble_call_seg0');
      expect(forkPairs.single.right.id, 'ph_room_seg0');

      // 在 375px 窄屏渲染 TimelinePage 并捕获任何布局溢出错误
      final flutterErrors = <FlutterErrorDetails>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        flutterErrors.add(details);
      };
      addTearDown(() => FlutterError.onError = prevOnError);

      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        StoreScope(
          store: appStore,
          child: MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: appStore,
                builder: (context, _) => appStore.stackTop?.type == 'detail'
                    ? DetailPage(eventId: appStore.stackTop!.id)
                    : const TimelinePage(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(Key('fork-card-$forkId')), findsOneWidget);
      expect(find.byKey(const Key('fork-col-left-ble_call_seg0')), findsOneWidget);
      expect(find.byKey(const Key('fork-col-right-ph_room_seg0')), findsOneWidget);
      expect(find.text('录音卡 V2 · 外出接电话'), findsOneWidget);
      expect(find.text('手机本机 · 会议室讨论'), findsOneWidget);

      // 勾选模式支持双列分别勾选
      appStore.startSummary();
      await tester.pump();
      await tester.tap(find.byKey(const Key('chk-ble_call_seg0')));
      await tester.pump();
      expect(appStore.selIds, contains('ble_call_seg0'));
      appStore.cancelSummary();
      await tester.pump();

      // 点左侧「详情 ›」进入 DetailPage 并测试对照与切换对侧设备
      await tester.tap(find.byKey(const Key('fork-detail-ble_call_seg0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('dt-device-label')), findsOneWidget);
      expect(find.byKey(const Key('detail-fork-banner')), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail-fork-compare-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('detail-fork-compare-panel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail-fork-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('会议室内部排期评审'), findsWidgets);

      expect(
        flutterErrors,
        isEmpty,
        reason: '375px 窄屏双列分叉 UI 与详情对照不得产生任何布局溢出或渲染错误',
      );
    },
  );

  test(
    'Test 5: 手机本机与 Watch 实时切片不得阻止同步管线从蓝牙设备补拉同时间段离线 .APM 文件',
    () async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-apm-guard-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final recStore = RecordingStore(root: tmpDir);
      final now = DateTime.now();
      final t0 = DateTime(now.year, now.month, now.day, 15, 0).millisecondsSinceEpoch;

      final wavPath = '${tmpDir.path}/companion.wav';
      File(wavPath).writeAsBytesSync(
        encodeWav(Float32List(16000 * 10), sampleRate: 16000),
      );

      final gw = FakeCardGateway(
        initialSnapshot: defaultSnapshot,
        writeDownload: true,
        transcodeSeconds: 10,
        deviceFiles: [
          CardFile(
            name: 'REC_BLE.APM',
            size: 32000,
            session: 'ble_ses',
            seq: 1,
            createdAtSec: t0 ~/ 1000,
            startAtSec: t0 ~/ 1000,
            synced: false,
          ),
        ],
      );

      final pipeline = RecordingPipeline(
        gateway: gw,
        store: recStore,
        engine: _StubEngine(),
        models: _StubModels(),
      );

      // 先写入同时间窗的手机与手表切片
      await pipeline.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'LIVE_PHONE_1',
          sliceIndex: 0,
          startAtMs: t0,
          durationMs: 30000,
          wavPath: wavPath,
          sourceLane: 'phone',
          sourceDeviceLabel: '手机本机',
        ),
      );
      await pipeline.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'watch_w1',
          sliceIndex: 0,
          startAtMs: t0 + 30000,
          durationMs: 30000,
          wavPath: wavPath,
          sourceLane: 'watch',
          sourceDeviceLabel: 'Apple Watch',
        ),
      );

      // 即使存在完全覆盖同时间段的手机和手表切片，BLE 离线文件 REC_BLE.APM 仍必须被真实拉取下载
      final res = await pipeline.sync();
      expect(gw.downloadCalls, 1);
      expect(res.downloaded, 1);

      final allFiles = await recStore.loadAll(refresh: true);
      expect(
        allFiles.any((f) => f.deviceName == 'REC_BLE.APM'),
        isTrue,
      );
      expect(jsonEncode(allFiles.map((e) => e.toJson()).toList()), contains('REC_BLE.APM'));
    },
  );

  test(
    'Test 6: 静音占位文案不触发假 forkParallel，旧版 v1 脏缓存启动加载时自动自愈，绝不让同设备拆出双路并发',
    () async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-self-heal-v1-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final recStore = RecordingStore(root: tmpDir);
      final now = DateTime.now();
      final t0 = DateTime(now.year, now.month, now.day, 20, 58).millisecondsSinceEpoch;
      const durMs = 300000;

      // 1) 点一机 V1 5 分钟真实语音，被话题切分拆为 3 张话题卡
      final bleSegId = 'seg-rec-audio202611242058025836271504amr-0';
      final bleFile = RecordingFile(
        deviceName: 'audio_20261124-205802_58362715_04.amr',
        session: '58362715',
        seq: 4,
        startAtMs: t0,
        apmPath: '',
        wavPath: '/tmp/amr04.wav',
        createdAtMs: t0,
        durationMs: durMs,
        timeSynced: true,
        stage: RecordingStage.ready,
        sourceLane: 'ble',
        sourceDeviceLabel: '点一机 V1 Q2M34R',
        slices: const [
          AudioSlice(
            id: '0001',
            index: 0,
            startMs: 0,
            endMs: durMs,
            wavPath: '/tmp/amr04.wav',
            stage: SliceStage.polished,
          ),
        ],
        utterances: const [
          RawUtterance(
            id: 'u0',
            sliceId: '0001',
            startMs: 0,
            endMs: 90000,
            text: '首先检查外脑默认模型设置与配置提示异常。',
            speakerLabel: '说话人 1',
          ),
          RawUtterance(
            id: 'u1',
            sliceId: '0001',
            startMs: 95000,
            endMs: 190000,
            text: '其次排查杀后台后蓝牙断连和内存占用偏高问题。',
            speakerLabel: '说话人 1',
          ),
          RawUtterance(
            id: 'u2',
            sliceId: '0001',
            startMs: 195000,
            endMs: 295000,
            text: '最后加上蓝牙心跳检测机制并降低兜底误触发概率。',
            speakerLabel: '说话人 1',
          ),
        ],
        turns: const [
          PolishedTurn(
            id: 't0',
            startMs: 0,
            endMs: 90000,
            speakerLabel: '说话人 1',
            text: '首先检查外脑默认模型设置与配置提示异常。',
            srcUtteranceIds: ['u0'],
          ),
          PolishedTurn(
            id: 't1',
            startMs: 95000,
            endMs: 190000,
            speakerLabel: '说话人 1',
            text: '其次排查杀后台后蓝牙断连和内存占用偏高问题。',
            srcUtteranceIds: ['u1'],
          ),
          PolishedTurn(
            id: 't2',
            startMs: 195000,
            endMs: 295000,
            speakerLabel: '说话人 1',
            text: '最后加上蓝牙心跳检测机制并降低兜底误触发概率。',
            srcUtteranceIds: ['u2'],
          ),
        ],
        segments: [
          SegmentRecord(
            id: bleSegId,
            sessionId: '58362715',
            index: 0,
            startAtMs: t0,
            endAtMs: t0 + durMs,
            title: '配置修复协助',
            brief: '梳理默认配置、后台蓝牙断开与心跳兜底问题。',
            longText: '首先检查外脑默认模型设置；其次排查后台蓝牙断开；最后增加心跳检测。',
            speakerLabels: const ['说话人 1'],
            speakerCount: 1,
            status: SegmentStatus.closed,
            sliceIds: const ['0001'],
            turnIds: const ['t0', 't1', 't2'],
          ),
        ],
      );

      // 2) 两段同窗口的手机静音切片：utterances/turns 为空，仅含占位文案
      RecordingFile makeSilentPhoneSlice(String id, int startOffsetMs, int lenMs) {
        return RecordingFile(
          deviceName: 'LIVE_PHONE_$id.WAV',
          session: 'LIVE_PHONE_SES',
          seq: 1,
          startAtMs: t0 + startOffsetMs,
          apmPath: '',
          wavPath: '/tmp/$id.wav',
          createdAtMs: t0 + startOffsetMs,
          durationMs: lenMs,
          timeSynced: true,
          stage: RecordingStage.ready,
          sourceLane: 'phone',
          sourceDeviceLabel: '手机本机',
          slices: [
            AudioSlice(
              id: '0001',
              index: 0,
              startMs: 0,
              endMs: lenMs,
              wavPath: '/tmp/$id.wav',
              stage: SliceStage.polished,
            ),
          ],
          segments: [
            SegmentRecord(
              id: 'seg-rec-livephone-$id-0',
              sessionId: 'LIVE_PHONE_SES',
              index: 0,
              startAtMs: t0 + startOffsetMs,
              endAtMs: t0 + startOffsetMs + lenMs,
              title: '未识别到语音',
              brief: '本段未检测到有效人声，原始录音已保存在本机。',
              longText: '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。',
              status: SegmentStatus.closed,
              sliceIds: const ['0001'],
            ),
          ],
        );
      }

      final phone1 = makeSilentPhoneSlice('0001', 160000, 17600);
      final phone2 = makeSilentPhoneSlice('0002', 177600, 13200);
      await recStore.save(bleFile);
      await recStore.save(phone1);
      await recStore.save(phone2);

      // 写入话题分段，将单段 5 分钟 BLE 文件拆为 3 张话题卡
      final runKey = FastTopicSegmentAgent.buildRunKey(bleSegId, t0, t0 + durMs);
      final topicStore = TopicSegmentationStore(resolveRoot: recStore.root);
      await topicStore.save(
        TopicSegmentationState(
          runsByKey: {
            runKey: TopicRunSegmentation(
              runKey: runKey,
              startAtMs: t0,
              endAtMs: t0 + durMs,
              evaluatedAtMs: t0 + durMs,
              sections: const [
                TopicSectionOverride(
                  title: '配置修复协助',
                  brief: '外脑默认模型配置问题定位',
                  startTurnIndex: 0,
                  endTurnIndex: 0,
                ),
                TopicSectionOverride(
                  title: '后台蓝牙丢失与内存问题',
                  brief: '分析后台蓝牙断开与内存优化',
                  startTurnIndex: 1,
                  endTurnIndex: 1,
                ),
                TopicSectionOverride(
                  title: '心跳检测与录音兜底建议',
                  brief: '建立蓝牙心跳防止误进本机兜底',
                  startTurnIndex: 2,
                  endTurnIndex: 2,
                ),
              ],
            ),
          },
        ),
      );

      // 直接验证 MultiTrackReconciler 本身：静音占位文案应判定为 keepNonEmpty，零 forkParallel
      final directState = await MultiTrackReconciler().reconcile(
        [bleFile, phone1, phone2],
        previous: const MultiTrackReconciliationState(),
      );
      expect(directState.forks, isEmpty);
      expect(directState.decisions, hasLength(2));
      expect(
        directState.decisions.every(
          (d) => d.outcome == TrackOverlapOutcome.keepNonEmpty,
        ),
        isTrue,
      );
      expect(
        directState.hiddenSegmentIds,
        containsAll([phone1.segments.single.id, phone2.segments.single.id]),
      );

      // 模拟用户手机上已落盘的旧版 v1 脏缓存（把两段静音误判成 forkParallel）
      final reconFile = File('${tmpDir.path}/${MultiTrackReconciliationStore.fileName}');
      await reconFile.writeAsString(
        jsonEncode({
          'v': 1,
          'dec': [
            {
              'pk': '$bleSegId::${phone1.segments.single.id}',
              'fp': 'stale-fp-1',
              'out': 'forkParallel',
              'p': bleSegId,
              's': phone1.segments.single.id,
              'rs': '双路文本差异较大，并行保留各自记录',
              'fk': 'fork-$bleSegId-${phone1.segments.single.id}',
            },
            {
              'pk': '$bleSegId::${phone2.segments.single.id}',
              'fp': 'stale-fp-2',
              'out': 'forkParallel',
              'p': bleSegId,
              's': phone2.segments.single.id,
              'rs': '双路文本差异较大，并行保留各自记录',
              'fk': 'fork-$bleSegId-${phone2.segments.single.id}',
            },
          ],
        }),
      );

      final pipeline = RecordingPipeline(
        gateway: FakeCardGateway(),
        store: recStore,
        topicStore: topicStore,
        engine: _StubEngine(),
        models: _StubModels(),
      );
      final fakeSync = await FakeRecordingSync.create(localEvents: const []);
      final gen = await SummaryModel().generator();
      final appStore = AppStore(
        recordings: fakeSync,
        generator: gen,
        loadPersistedState: false,
      );
      addTearDown(appStore.dispose);
      appStore.attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: gen,
      );

      // 启动加载 refreshFromStore()：应自动发现 v1 并重算升级到 v2
      await appStore.refreshFromStore();

      final upgradedJson =
          jsonDecode(await reconFile.readAsString()) as Map<String, dynamic>;
      expect(upgradedJson['v'], MultiTrackReconciliationState.currentSchemaVersion);
      expect(appStore.multiTrackReconciliation.needsReconcile, isFalse);
      expect(appStore.multiTrackReconciliation.forks, isEmpty);

      final allItems = [for (final g in appStore.feedGroups) ...g.items];
      expect(allItems.whereType<ForkedEventPair>(), isEmpty);

      final singleEvents = allItems.whereType<RecordEvent>().toList();
      expect(
        singleEvents.map((e) => e.title),
        containsAll(['配置修复协助', '后台蓝牙丢失与内存问题', '心跳检测与录音兜底建议']),
      );
      expect(singleEvents.where((e) => e.title == '未识别到语音'), isEmpty);
    },
  );

  test(
    'Test 7: 多话题拆分只把 forkGroupId 赋给实际重叠的那一个话题段，且 Timeline 绝不将同通道/同设备卡片配对',
    () async {
      final tmpDir = Directory.systemTemp.createTempSync('rc-topic-fork-only-one-');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final now = DateTime.now();
      final t0 = DateTime(now.year, now.month, now.day, 16, 0).millisecondsSinceEpoch;
      const durMs = 300000;

      // 7a) BLE 5 分钟录了 3 个话题，手机仅在中间第 2 话题窗口录到另一场完全不同的真实对话
      final bleFile = RecordingFile(
        deviceName: 'BLE_MULTI_TOPIC',
        session: 'ses_ble_mt',
        seq: 0,
        startAtMs: t0,
        apmPath: '',
        wavPath: '/tmp/ble_mt.wav',
        createdAtMs: t0,
        durationMs: durMs,
        timeSynced: true,
        stage: RecordingStage.ready,
        sourceLane: 'ble',
        sourceDeviceLabel: '点一机 V1 Q2M34R',
        utterances: const [
          RawUtterance(
            id: 'bu0',
            sliceId: '0001',
            startMs: 0,
            endMs: 85000,
            text: '早上确定新版本发布节奏以及灰度名单。',
            speakerLabel: '说话人 1',
          ),
          RawUtterance(
            id: 'bu1',
            sliceId: '0001',
            startMs: 95000,
            endMs: 205000,
            text: '客户电话沟通年度服务器扩容报价和交付周期。',
            speakerLabel: '说话人 1',
          ),
          RawUtterance(
            id: 'bu2',
            sliceId: '0001',
            startMs: 215000,
            endMs: 295000,
            text: '晚上安排团队聚餐地点和采购清单。',
            speakerLabel: '说话人 1',
          ),
        ],
        turns: const [
          PolishedTurn(
            id: 'bt0',
            startMs: 0,
            endMs: 85000,
            speakerLabel: '说话人 1',
            text: '早上确定新版本发布节奏以及灰度名单。',
            srcUtteranceIds: ['bu0'],
          ),
          PolishedTurn(
            id: 'bt1',
            startMs: 95000,
            endMs: 205000,
            speakerLabel: '说话人 1',
            text: '客户电话沟通年度服务器扩容报价和交付周期。',
            srcUtteranceIds: ['bu1'],
          ),
          PolishedTurn(
            id: 'bt2',
            startMs: 215000,
            endMs: 295000,
            speakerLabel: '说话人 1',
            text: '晚上安排团队聚餐地点和采购清单。',
            srcUtteranceIds: ['bu2'],
          ),
        ],
        segments: [
          SegmentRecord(
            id: 'ble_mt_seg0',
            sessionId: 'ses_ble_mt',
            index: 0,
            startAtMs: t0,
            endAtMs: t0 + durMs,
            title: '全天事项沟通',
            brief: '包含发版、客户报价与晚间安排。',
            longText: '包含发版、客户报价与晚间安排。',
            speakerLabels: const ['说话人 1'],
            speakerCount: 1,
            status: SegmentStatus.closed,
            sliceIds: const ['0001'],
            turnIds: const ['bt0', 'bt1', 'bt2'],
          ),
        ],
      );

      final phoneFile = _makeTrackFile(
        id: 'ph_mid',
        lane: 'phone',
        devLabel: '手机本机',
        startAtMs: t0 + 110000,
        durationMs: 70000,
        title: '会议室前端重构方案',
        text: '测试团队在会议室验收前端组件重绘性能基线与动画帧率。',
      );

      final reconState = await MultiTrackReconciler().reconcile(
        [bleFile, phoneFile],
        previous: const MultiTrackReconciliationState(),
      );
      expect(reconState.decisions.single.outcome, TrackOverlapOutcome.forkParallel);
      final forkId = reconState.decisions.single.forkGroupId!;

      final runKey = FastTopicSegmentAgent.buildRunKey(
        'ble_mt_seg0',
        t0,
        t0 + durMs,
      );
      final topicState = TopicSegmentationState(
        runsByKey: {
          runKey: TopicRunSegmentation(
            runKey: runKey,
            startAtMs: t0,
            endAtMs: t0 + durMs,
            evaluatedAtMs: t0 + durMs,
            sections: const [
              TopicSectionOverride(
                title: '版本灰度节奏',
                brief: '灰度名单',
                startTurnIndex: 0,
                endTurnIndex: 0,
              ),
              TopicSectionOverride(
                title: '客户扩容报价',
                brief: '服务器扩容',
                startTurnIndex: 1,
                endTurnIndex: 1,
              ),
              TopicSectionOverride(
                title: '团队聚餐清单',
                brief: '聚餐地点',
                startTurnIndex: 2,
                endTurnIndex: 2,
              ),
            ],
          ),
        },
      );

      final proj = SegmentProjection.build(
        [bleFile, phoneFile],
        topicState: topicState,
        reconciliation: reconState,
      );
      final bleTopic1 = proj.events.singleWhere((e) => e.title == '版本灰度节奏');
      final bleTopic2 = proj.events.singleWhere((e) => e.title == '客户扩容报价');
      final bleTopic3 = proj.events.singleWhere((e) => e.title == '团队聚餐清单');
      final phoneEv = proj.events.singleWhere((e) => e.title == '会议室前端重构方案');

      expect(bleTopic1.forkGroupId, isNull);
      expect(bleTopic3.forkGroupId, isNull);
      expect(bleTopic2.forkGroupId, forkId);
      expect(phoneEv.forkGroupId, forkId);

      // 同时验证滚动清洗分支（rollingByAnchor）也只挂到实际重叠的那 1 张卡上
      final rollingTopicState = TopicSegmentationState(
        rollingByAnchor: {
          'ble_mt_seg0': TopicRunSegmentation(
            runKey: 'rolling-ble_mt_seg0',
            startAtMs: t0,
            endAtMs: t0 + durMs,
            evaluatedAtMs: t0 + durMs,
            coveredUtteranceEndMs: t0 + durMs,
            coveredUtteranceIds: const {'bu0', 'bu1', 'bu2'},
            sections: [
              TopicSectionOverride(
                title: '版本灰度节奏',
                brief: '灰度名单',
                startTurnIndex: 0,
                endTurnIndex: 0,
                startAtMs: t0,
                endAtMs: t0 + 85000,
                paragraphs: [
                  TopicParagraph(
                    speaker: '说话人 1',
                    text: '早上确定新版本发布节奏以及灰度名单。',
                    startAtMs: t0,
                    endAtMs: t0 + 85000,
                    srcUtteranceIds: const ['bu0'],
                  ),
                ],
              ),
              TopicSectionOverride(
                title: '客户扩容报价',
                brief: '服务器扩容',
                startTurnIndex: 1,
                endTurnIndex: 1,
                startAtMs: t0 + 95000,
                endAtMs: t0 + 205000,
                paragraphs: [
                  TopicParagraph(
                    speaker: '说话人 1',
                    text: '客户电话沟通年度服务器扩容报价和交付周期。',
                    startAtMs: t0 + 95000,
                    endAtMs: t0 + 205000,
                    srcUtteranceIds: const ['bu1'],
                  ),
                ],
              ),
              TopicSectionOverride(
                title: '团队聚餐清单',
                brief: '聚餐地点',
                startTurnIndex: 2,
                endTurnIndex: 2,
                startAtMs: t0 + 215000,
                endAtMs: t0 + 295000,
                paragraphs: [
                  TopicParagraph(
                    speaker: '说话人 1',
                    text: '晚上安排团队聚餐地点和采购清单。',
                    startAtMs: t0 + 215000,
                    endAtMs: t0 + 295000,
                    srcUtteranceIds: const ['bu2'],
                  ),
                ],
              ),
            ],
          ),
        },
      );
      final rollingProj = SegmentProjection.build(
        [bleFile, phoneFile],
        topicState: rollingTopicState,
        reconciliation: reconState,
      );
      expect(
        rollingProj.events.singleWhere((e) => e.title == '版本灰度节奏').forkGroupId,
        isNull,
      );
      expect(
        rollingProj.events.singleWhere((e) => e.title == '客户扩容报价').forkGroupId,
        forkId,
      );
      expect(
        rollingProj.events.singleWhere((e) => e.title == '团队聚餐清单').forkGroupId,
        isNull,
      );

      // 7b) 纵深防御：即使两条同通道/同设备事件错误共用 forkGroupId，AppStore 也绝不组成双路并发卡
      final fakeSync = await FakeRecordingSync.create(localEvents: const []);
      final gen = await SummaryModel().generator();
      final appStore = AppStore(
        recordings: fakeSync,
        generator: gen,
        loadPersistedState: false,
      );
      addTearDown(appStore.dispose);
      appStore.events = [
        RecordEvent(
          id: 'same_dev_a',
          dayOffset: 0,
          title: '配置修复与模型检查',
          brief: '讨论外脑默认模型配置提示与默认参数加载链路。',
          longText: '讨论外脑默认模型配置提示与默认参数加载链路，并验证本地缓存同步逻辑。',
          time: '21:00',
          dur: '2分00秒',
          speakers: '说话人 1',
          mark: '',
          srcMap: '',
          dialog: const [
            TurnLine('说话人 1', '先检查外脑默认模型设置是否在启动后正确生效并回填端点地址。', '21:00'),
          ],
          raw: const [
            TurnLine('说话人 1', '先检查外脑默认模型设置是否在启动后正确生效并回填端点地址。', '21:00'),
          ],
          sourceLane: 'ble',
          sourceDeviceLabel: '点一机 V1 Q2M34R',
          forkGroupId: 'fk-same-dev',
        ),
        RecordEvent(
          id: 'same_dev_b',
          dayOffset: 0,
          title: '蓝牙保活与心跳机制',
          brief: '分析蓝牙后台心跳保活机制与断连兜底切换策略。',
          longText: '分析蓝牙后台心跳保活机制与断连兜底切换策略，避免误入手机本机录音。',
          time: '21:02',
          dur: '2分00秒',
          speakers: '说话人 1',
          mark: '',
          srcMap: '',
          dialog: const [
            TurnLine('说话人 1', '再核对后台蓝牙心跳检测周期与异常断连之后的本机兜底录音切换条件。', '21:02'),
          ],
          raw: const [
            TurnLine('说话人 1', '再核对后台蓝牙心跳检测周期与异常断连之后的本机兜底录音切换条件。', '21:02'),
          ],
          sourceLane: 'ble',
          sourceDeviceLabel: '点一机 V1 Q2M34R',
          forkGroupId: 'fk-same-dev',
        ),
      ];
      final items = [for (final g in appStore.feedGroups) ...g.items];
      expect(items.whereType<ForkedEventPair>(), isEmpty);
      expect(items.whereType<RecordEvent>(), hasLength(2));
      expect(appStore.siblingForkEventFor('same_dev_a'), isNull);
      expect(appStore.siblingForkEventFor('same_dev_b'), isNull);

      // 7c) fromDecisions 1-to-many forkParallel 不互相覆盖导致孤立
      final multiForkState = MultiTrackReconciliationState.fromDecisions(const [
        TrackPairDecision(
          pairKey: 'ble_a::ph_1',
          fingerprint: 'fp1',
          outcome: TrackOverlapOutcome.forkParallel,
          primarySegmentId: 'ble_a',
          secondarySegmentId: 'ph_1',
          reason: 'r1',
          forkGroupId: 'fk1',
        ),
        TrackPairDecision(
          pairKey: 'ble_a::ph_2',
          fingerprint: 'fp2',
          outcome: TrackOverlapOutcome.forkParallel,
          primarySegmentId: 'ble_a',
          secondarySegmentId: 'ph_2',
          reason: 'r2',
          forkGroupId: 'fk2',
        ),
      ]);
      expect(multiForkState.forkGroupBySegmentId['ble_a'], 'fk1');
      expect(multiForkState.forkGroupBySegmentId['ph_1'], 'fk1');
      expect(multiForkState.forkGroupBySegmentId.containsKey('ph_2'), isFalse);
      expect(multiForkState.forks.keys, ['fk1']);
    },
  );
}
