// 统一顶部单行状态条验收（TDD）—— 只做状态展示、不可操作；idle 收起；
// 全状态等高单行、条内轻量进度提示、Timeline 统一顶部留白、防 syncStage 残留卡死。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/recording_sync_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/widgets/recording_status_block.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

Widget _host(RecordingStatusController controller) => MaterialApp(
  theme: testTheme(),
  home: Scaffold(body: RecordingStatusBlock(controller: controller)),
);

class _StubSpeechEngine implements SpeechEngine {
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
  }) async => AsrResult(
    text: '第一片本地语音测试内容',
    tokens: const [],
    timestampsMs: const [],
    audioMs: samples.length * 1000 ~/ sampleRate,
  );

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1.0, 0.0, 0.0];

  @override
  Future<void> dispose() async {}
}

class _StubModels implements SpeechModelProvider {
  _StubModels(this.paths);
  final SpeechModelPaths paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

void main() {
  testWidgets('idle 不占布局；录音/转写/错误/结束状态正确', (tester) async {
    final controller = RecordingStatusController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    expect(find.byKey(const Key('recording-status-block')), findsNothing);

    controller.startRecording();
    await tester.pump();
    expect(find.byKey(const Key('recording-status-block')), findsOneWidget);
    expect(find.text('正在录音'), findsOneWidget);

    controller.onSliceReceived();
    controller.onTranscriptionStarted();
    await tester.pump();
    expect(find.text('正在转写'), findsOneWidget);
    expect(find.text('剩余 1 段'), findsOneWidget);

    controller.onTranscriptionCompleted();
    await tester.pump();
    expect(find.text('正在录音'), findsOneWidget);
    expect(find.text('剩余 1 段'), findsNothing);

    controller.onError('网络中断');
    await tester.pump();
    expect(find.text('录音整理中断'), findsOneWidget);
    expect(find.textContaining('网络中断'), findsOneWidget);

    controller.stopRecording();
    await tester.pump();
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
  });

  testWidgets('状态块不可点击（IgnorePointer）', (tester) async {
    final controller = RecordingStatusController()..startRecording();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    await tester.pump();

    final block = find.byKey(const Key('recording-status-block'));
    final ignore = tester.widget<IgnorePointer>(
      find.ancestor(of: block, matching: find.byType(IgnorePointer)).first,
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('录音显示正计时；停止后同步态显示的阶段文案', (tester) async {
    final controller = RecordingStatusController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    controller.startRecording();
    controller.updateElapsed(65);
    await tester.pump();
    expect(find.text('正在录音'), findsOneWidget);
    expect(find.textContaining('已录 00:01:05'), findsOneWidget);

    controller.startSync(detail: '正在下载最新录音…');
    await tester.pump();
    expect(find.text('正在同步'), findsOneWidget);
    expect(find.text('正在下载最新录音…'), findsOneWidget);

    controller.updateSync('正在转写 1/2', remaining: 1);
    await tester.pump();
    expect(find.text('正在转写 1/2'), findsOneWidget);

    // 同步完成且不在录音会话中 → 收起
    controller.updateQueue(remaining: 0, active: false);
    await tester.pump();
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
  });

  testWidgets('全状态严格单行等高（40px）且条内轻量进度不影响高度', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = RecordingStatusController();
    addTearDown(controller.dispose);

    double assertSingleLineAndHeight() {
      final blockFinder = find.byKey(const Key('recording-status-block'));
      expect(blockFinder, findsOneWidget);
      final h = tester.getSize(blockFinder).height;
      expect((h - 40.0).abs(), lessThanOrEqualTo(0.5), reason: '高度应恒定 40px');
      final labelText = tester.widget<Text>(
        find.byKey(const Key('recording-status-text')),
      );
      final subText = tester.widget<Text>(
        find.byKey(const Key('recording-status-subtitle')),
      );
      expect(labelText.maxLines, 1);
      expect(subText.maxLines, 1);
      return h;
    }

    // 1. 录音（短副标题与超长副标题）
    controller.startRecording();
    await tester.pumpWidget(_host(controller));
    final hRecShort = assertSingleLineAndHeight();
    expect(find.byKey(const Key('recording-status-progress')), findsNothing);

    controller.setRecordingDetail(
      '这是一段非常非常长的实时转写进度说明文案用于验证不会换行也不会撑高单行状态条',
    );
    await tester.pump();
    final hRecLong = assertSingleLineAndHeight();
    expect((hRecLong - hRecShort).abs(), lessThanOrEqualTo(0.5));

    // 2. 同步无进度
    controller.startSync(detail: '正在整理最近一段…');
    await tester.pump();
    final hSyncNoProg = assertSingleLineAndHeight();
    expect((hSyncNoProg - hRecShort).abs(), lessThanOrEqualTo(0.5));
    expect(find.byKey(const Key('recording-status-progress')), findsNothing);

    // 3. 同步带进度（0.0 / 0.5 / 1.0）
    for (final p in [0.0, 0.5, 1.0]) {
      controller.updateSync('正在本地转写第 1 片（1/2）', progress: p);
      await tester.pump();
      final hSyncProg = assertSingleLineAndHeight();
      expect((hSyncProg - hRecShort).abs(), lessThanOrEqualTo(0.5));
      final progWidget = tester.widget<AnimatedFractionallySizedBox>(
        find.byKey(const Key('recording-status-progress')),
      );
      expect(progWidget.widthFactor, p);
    }

    // 4. 转写态
    controller.onSliceReceived();
    controller.onTranscriptionStarted();
    await tester.pump();
    final hTrans = assertSingleLineAndHeight();
    expect((hTrans - hRecShort).abs(), lessThanOrEqualTo(0.5));

    // 5. 错误态（超长错误描述 + 不展示进度提示）
    controller.onError(
      '蓝牙链路长时间波动且本机模型推理超时，请检查录音卡电量与距离后稍后重试处理这段录音文件',
    );
    await tester.pump();
    final hErr = assertSingleLineAndHeight();
    expect((hErr - hRecShort).abs(), lessThanOrEqualTo(0.5));
    expect(find.byKey(const Key('recording-status-progress')), findsNothing);

    // 6. 装载态（无 controller，仅 loadingActive）
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: RecordingStatusBlock(loadingActive: true),
        ),
      ),
    );
    final hLoad = assertSingleLineAndHeight();
    expect((hLoad - hRecShort).abs(), lessThanOrEqualTo(0.5));
    expect(find.text('正在加载'), findsOneWidget);
    expect(find.text('正在读取本地录音…'), findsOneWidget);
  });

  testWidgets('TimelinePage 顶部状态条在空列表与有列表、录音/同步/加载态下顶部间距完全一致（12px）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<double> measureGap({
      required List<dynamic> events,
      required RecordingStatusController status,
      bool loading = false,
      SyncStage? syncStage,
      String syncText = '',
      double syncProgress = 0,
    }) async {
      final store = AppStore(
        events: events.cast(),
        status: status,
        loadPersistedState: false,
      )
        ..loading = loading
        ..syncStage = syncStage
        ..syncText = syncText
        ..syncProgress = syncProgress;
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: StoreScope(
            store: store,
            child: Scaffold(
              body: TimelinePage(recordingStatus: status),
            ),
          ),
        ),
      );
      await tester.pump();

      final tabsBottom =
          tester.getBottomLeft(find.byKey(const Key('timeline-tabs-bar'))).dy;
      final barTop =
          tester.getTopLeft(find.byKey(const Key('recording-status-block'))).dy;
      return barTop - tabsBottom;
    }

    // 空列表 + 录音中
    final recEmpty = RecordingStatusController()..startRecording();
    addTearDown(recEmpty.dispose);
    final gapEmptyRec = await measureGap(events: const [], status: recEmpty);
    expect(gapEmptyRec, 12.0);

    // 非空列表 + 录音中
    final recList = RecordingStatusController()..startRecording();
    addTearDown(recList.dispose);
    final gapListRec = await measureGap(events: seedEvents, status: recList);
    expect(gapListRec, 12.0);

    // 非空列表 + 同步态（仅 AppStore syncStage 驱动）
    final syncIdle = RecordingStatusController();
    addTearDown(syncIdle.dispose);
    final gapListSync = await measureGap(
      events: seedEvents,
      status: syncIdle,
      syncStage: SyncStage.downloading,
      syncText: '正在同步第 1 片…',
      syncProgress: 0.45,
    );
    expect(gapListSync, 12.0);

    // 空列表 + 加载态
    final loadIdle = RecordingStatusController();
    addTearDown(loadIdle.dispose);
    final gapEmptyLoad = await measureGap(
      events: const [],
      status: loadIdle,
      loading: true,
    );
    expect(gapEmptyLoad, 12.0);
  });

  test('回归：processPendingRecordings 完成后彻底清理 syncStage/syncText 且 done 进度为 1.0', () async {
    expect(
      const PipelineProgress(
        stage: PipelineStage.done,
        fileIndex: 0,
        fileTotal: 1,
        text: '第 1 片已转写保存',
      ).progress,
      1.0,
    );

    final root = await Directory.systemTemp.createTemp('rc-pending-clear-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final recStore = RecordingStore(root: Directory('${root.path}/store'));
    final models = _StubModels(
      SpeechModelPaths(
        asrModelPath: '${root.path}/model.onnx',
        tokensPath: '${root.path}/tokens.txt',
        vadPath: '${root.path}/vad.onnx',
        speakerEmbeddingPath: '${root.path}/spk.onnx',
      ),
    );
    final gateway = FakeCardGateway();
    final pipeline = RecordingPipeline(
      gateway: gateway,
      store: recStore,
      engine: _StubSpeechEngine(),
      models: models,
      liveAudioBaseDir: root,
    );
    final status = RecordingStatusController();
    addTearDown(status.dispose);
    final appStore = AppStore(status: status, loadPersistedState: false)
      ..attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: await SummaryModel().generator(),
        status: status,
      );
    addTearDown(appStore.dispose);
    appStore.deviceConnected = () => true;
    appStore.deviceRecording = () => false;

    final wavPath = '${root.path}/live_1.wav';
    final samples = Float32List(16000)..fillRange(0, 16000, 0.08);
    await File(wavPath).writeAsBytes(encodeWav(samples), flush: true);

    await recStore.save(
      RecordingFile(
        deviceName: 'LIVE_TEST_0',
        session: 'S_TEST',
        seq: 1,
        startAtMs: DateTime.now().millisecondsSinceEpoch - 60000,
        apmPath: '',
        wavPath: wavPath,
        createdAtMs: DateTime.now().millisecondsSinceEpoch - 60000,
        durationMs: 1000,
        timeSynced: true,
        stage: RecordingStage.transcribing,
      ),
    );

    await appStore.processPendingRecordings();

    expect(appStore.syncStage, isNull);
    expect(appStore.syncText, isEmpty);
    expect(appStore.syncProgress, 0);
    expect(status.phase, RecordingPhase.idle);
    expect(status.progress, isNull);
  });
}
