// 端到端回归测试：Omi/外部硬件 BLE 重连看门狗顺延、时间轴原始时间戳与分段对齐、
// 顶部录音状态块单行防抖动，以及下拉刷新不卡转圈（2026-11-22 修复）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/widgets/recording_status_block.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';

class _TestSpeechEngine implements SpeechEngine {
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
    text: '这是一条录音测试转写内容。',
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

class _TestModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/models/asr.onnx',
    tokensPath: '/models/tokens.txt',
    vadPath: '/models/vad.onnx',
    speakerEmbeddingPath: '/models/spk.onnx',
  );
}

class _TestChat implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    final content = messages.last.content.trim();
    if (!content.startsWith('[')) {
      return jsonEncode({'title': '离线对话记录', 'overview': '离线摘要'});
    }
    final payload = jsonDecode(content) as List;
    return jsonEncode([
      for (final s in payload)
        {
          'id': s['id'],
          'turns': [
            for (final t in (s['turns'] as List))
              {
                'src': [t['id']],
                'startMs': t['startMs'],
                'endMs': t['endMs'],
                'speaker': t['speaker'],
                'text': t['text'],
              },
          ],
          'boundary': 'none',
        },
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. 时间戳规范化与多段解析', () {
    test('CardFile 与 CardDownload 过滤无效 1970/越界时间戳并兼容毫秒', () {
      final zeroStart = CardFile.fromJson({
        'name': 'OMI_RING_100_200.WAV',
        'size': 2048,
        'start_at': 0,
        'created_at': 1763700000000,
      });
      expect(zeroStart.startAtSec, isNull);
      expect(zeroStart.createdAtSec, 1763700000);

      final dl = CardDownload.fromJson({
        'path': '/tmp/p0.wav',
        'bytesWritten': 3200,
        'originalName': 'OMI_RING_100_200.WAV',
        'startAt': 1763680000,
        'timeSynced': true,
        'parts': [
          {
            'path': '/tmp/p0.wav',
            'bytesWritten': 1600,
            'startAt': 1763680000,
            'timeSynced': true,
            'durationSecs': 5.0,
          },
          {
            'path': '/tmp/p1.wav',
            'bytesWritten': 1600,
            'startAt': 1763690000000,
            'timeSynced': true,
            'durationSecs': 5.0,
          },
        ],
      });
      expect(dl.startAtSec, 1763680000);
      expect(dl.timeSynced, isTrue);
      expect(dl.parts.length, 2);
      expect(dl.parts[1].startAtSec, 1763690000);
    });
  });

  group('2. OMI_RING 排序、多段拆分、环推进与礼让暂停', () {
    late Directory root;
    late FakeCardGateway gateway;
    late RecordingStore store;
    late RecordingPipeline pipeline;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rc-omi-stabilize-');
      gateway = FakeCardGateway()
        ..writeDownload = true
        ..transcodeSeconds = 6;
      store = RecordingStore(
        root: Directory('${root.path}/store'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final chat = _TestChat();
      pipeline = RecordingPipeline(
        gateway: gateway,
        store: store,
        engine: _TestSpeechEngine(),
        models: _TestModels(),
        polish: SlicePolishService(chat: chat, model: 'test-model'),
        segments: SegmentBuildService(chat: chat, model: 'test-model'),
        liveAudioBaseDir: root,
      );
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('OMI_RING 按起始 seq 升序同步、保留 download.startAtSec 且拆出子段并安全 deleteFile', () async {
      const part0Ts = 1763600000;
      const part1Ts = 1763650000;
      const secondChunkTs = 1763700000;

      gateway.deviceFiles = const [
        CardFile(name: 'OMI_RING_100_200.WAV', size: 4096, synced: false),
        CardFile(name: 'OMI_RING_0_100.WAV', size: 4096, synced: false),
      ];
      gateway.downloadOverrides['OMI_RING_0_100.WAV'] = CardDownload(
        path: '${root.path}/omi_0_p0.wav',
        bytesWritten: 2048,
        originalName: 'OMI_RING_0_100.WAV',
        startAtSec: part0Ts,
        timeSynced: true,
        parts: [
          CardDownloadPart(
            path: '${root.path}/omi_0_p0.wav',
            bytesWritten: 1024,
            startAtSec: part0Ts,
            timeSynced: true,
            durationSecs: 6.0,
          ),
          CardDownloadPart(
            path: '${root.path}/omi_0_p1.wav',
            bytesWritten: 1024,
            startAtSec: part1Ts,
            timeSynced: true,
            durationSecs: 6.0,
          ),
        ],
      );
      gateway.downloadOverrides['OMI_RING_100_200.WAV'] = CardDownload(
        path: '${root.path}/omi_1_p0.wav',
        bytesWritten: 2048,
        originalName: 'OMI_RING_100_200.WAV',
        startAtSec: secondChunkTs,
        timeSynced: true,
      );

      final seenFiles = <String>[];
      final res = await pipeline.sync(
        onFileReady: (f) async => seenFiles.add(f.deviceName),
      );

      expect(res.downloaded, 2);
      expect(res.failed, 0);
      expect(gateway.deletedFiles, [
        'OMI_RING_0_100.WAV',
        'OMI_RING_100_200.WAV',
      ]);
      expect(seenFiles, [
        'OMI_RING_0_100.WAV',
        'OMI_RING_0_100.WAV#p1',
        'OMI_RING_100_200.WAV',
      ]);

      final f0 = await store.load('OMI_RING_0_100.WAV');
      final f0p1 = await store.load('OMI_RING_0_100.WAV#p1');
      final f1 = await store.load('OMI_RING_100_200.WAV');
      expect(f0?.stage, RecordingStage.ready);
      expect(f0?.startAtMs, part0Ts * 1000);
      expect(f0?.timeSynced, isTrue);
      expect(f0p1?.stage, RecordingStage.ready);
      expect(f0p1?.startAtMs, part1Ts * 1000);
      expect(f0p1?.timeSynced, isTrue);
      expect(f1?.stage, RecordingStage.ready);
      expect(f1?.startAtMs, secondChunkTs * 1000);
    });

    test('requestSyncPauseForLiveRecording 在当前文件落盘后礼让暂停不阻塞', () async {
      gateway.deviceFiles = const [
        CardFile(name: 'OMI_RING_0_100.WAV', size: 2048),
        CardFile(name: 'OMI_RING_100_200.WAV', size: 2048),
      ];
      gateway.downloadDelay = const Duration(milliseconds: 20);

      final syncFuture = pipeline.sync(
        onProgress: (PipelineProgress p) {
          if (p.stage == PipelineStage.downloading && p.fileIndex == 0) {
            pipeline.requestSyncPauseForLiveRecording();
          }
        },
      );
      final result = await syncFuture;
      expect(result.pausedForLiveRecording, isTrue);
      expect(result.downloaded, 1);
      expect(gateway.deletedFiles, ['OMI_RING_0_100.WAV']);
    });
  });

  group('3. RecordingStatusBlock 单行防抖动与文案简化', () {
    testWidgets('录音期间后台批量同步仅刷新 已存 done/total 段，不换 phase、不换行、高度稳定', (
      tester,
    ) async {
      final controller = RecordingStatusController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 340,
              child: RecordingStatusBlock(controller: controller),
            ),
          ),
        ),
      );

      controller.startRecording();
      controller.updateElapsed(205); // 00:03:25
      await tester.pump();

      final boxBefore = tester.getSize(
        find.byKey(const Key('recording-status-block')),
      );

      // 模拟管道逐段推送同步进度：即使文案较长也不切回 syncing、只显示 已存 156/159 段
      controller.updateSync('正在取回 00:28 这段（157/159）', done: 156, total: 159);
      await tester.pump();

      expect(controller.phase, RecordingPhase.recording);
      expect(find.text('正在录音'), findsOneWidget);
      expect(find.textContaining('00:03:25'), findsOneWidget);
      expect(find.textContaining('已存 156/159 段'), findsOneWidget);
      expect(find.textContaining('00:28 这段'), findsNothing);

      final subtitleWidget = tester.widget<Text>(
        find.byKey(const Key('recording-status-subtitle')),
      );
      expect(subtitleWidget.maxLines, 1);
      expect(subtitleWidget.softWrap, isFalse);

      // AppShell 下一秒触发 ensureRecording：保持同一高度不跳动
      controller.ensureRecording();
      controller.updateElapsed(206);
      await tester.pump();
      final boxAfter = tester.getSize(
        find.byKey(const Key('recording-status-block')),
      );
      expect(boxAfter.height, equals(boxBefore.height));
      expect(find.textContaining('已存 156/159 段'), findsOneWidget);
    });
  });

  group('4. DeviceStore 看门狗同步顺延与手动重连抢占', () {
    testWidgets('isExternalBleSyncBusy 为 true 时看门狗顺延不误判掉线', (tester) async {
      const dev = CardDevice(id: 'omi-1', name: 'Omi Dev', rssi: -55);
      final gw = FakeCardGateway(
        initialSnapshot: const CardSnapshot(
          batteryLevel: 90,
          isCharging: false,
          wifiOpen: false,
          recording: false,
          fwVersion: '3.0.20',
          fwVersionCode: 30020,
          wifiVersion: '',
          wifiVersionCode: 0,
          deviceName: 'Omi Dev',
          deviceId: 'omi-1',
        ),
        devices: const [dev],
      );
      var busy = true;
      final store = DeviceStore(gateway: gw, autoStart: true)
        ..isExternalBleSyncBusy = () => busy;
      addTearDown(store.dispose);

      await store.restoreLink();
      await store.connectTo(dev);
      await tester.pump(const Duration(milliseconds: 200));

      final baseSnapshots = gw.snapshotCalls;
      gw.failSnapshot = CardException.disconnected();

      // 空闲超过 40s，但因外部同步管线正忙，心跳不发 probe，链路不断开
      await tester.pump(const Duration(seconds: 40));
      expect(store.linkState, LinkState.connected);
      expect(gw.snapshotCalls, baseSnapshots);

      // 管线结束后继续空闲 35s，恢复正常探测并能感知真断连
      busy = false;
      await tester.pump(const Duration(seconds: 35));
      expect(gw.snapshotCalls, greaterThan(baseSnapshots));
    });

    testWidgets('手动 connectTo 会抢占失效退避中的后台重连并保持最终连接态', (
      tester,
    ) async {
      const dev = CardDevice(id: 'omi-2', name: 'Omi Dev', rssi: -52);
      final gw = FakeCardGateway(
        initialSnapshot: defaultSnapshot,
        devices: const [dev],
      );
      final store = DeviceStore(
        gateway: gw,
        autoStart: true,
        backgroundReconnectDelays: const [Duration(milliseconds: 500)],
      );
      addTearDown(store.dispose);

      await store.restoreLink();
      await store.connectTo(dev);
      await tester.pump(const Duration(milliseconds: 200));

      // 模拟看门狗初次失败触发后台自动重连（先让第 1 次重连也失败以进入 500ms 退避等待）
      gw.failSnapshot = CardException.disconnected();
      gw.failConnect = const CardException(CardErrorKind.device, 'busy');
      await tester.pump(const Duration(seconds: 35));
      await tester.pump(const Duration(milliseconds: 200));

      // 此时恢复设备并手动重连
      gw.failSnapshot = null;
      gw.failConnect = null;
      await store.connectTo(dev);
      await tester.pump(const Duration(seconds: 1));
      expect(store.linkState, LinkState.connected);
    });
  });

  group('5. AppStore.pullToRefresh 不卡死并支持增量刷新与安全销毁', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rc-pull-refresh-');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('长同步超出 maxWait 时 pullToRefresh 先返回解除转圈，后台继续完成且无残留 Timer', () async {
      final gw = FakeCardGateway()
        ..writeDownload = true
        ..transcodeSeconds = 4
        ..downloadDelay = const Duration(milliseconds: 120)
        ..deviceFiles = [
          CardFile(
            name: 'OMI_RING_0_100.WAV',
            size: 1024,
            startAtSec: 1763700000,
            synced: true,
          ),
          CardFile(
            name: 'OMI_RING_100_200.WAV',
            size: 1024,
            startAtSec: 1763700500,
            synced: true,
          ),
        ];
      final recStore = RecordingStore(
        root: Directory('${root.path}/store'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final chat = _TestChat();
      final pipeline = RecordingPipeline(
        gateway: gw,
        store: recStore,
        engine: _TestSpeechEngine(),
        models: _TestModels(),
        polish: SlicePolishService(chat: chat, model: 'test-model'),
        segments: SegmentBuildService(chat: chat, model: 'test-model'),
        liveAudioBaseDir: root,
      );
      final status = RecordingStatusController();
      final generator = await SummaryModel().generator();
      final appStore = AppStore(
        status: status,
        jsonStore: JsonStore(store: InMemoryStore()),
        loadPersistedState: false,
      );
      appStore.deviceConnected = () => true;
      appStore.photoSyncEnabled = () => false;
      appStore.attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: generator,
        status: status,
      );

      final sw = Stopwatch()..start();
      final msg = await appStore.pullToRefresh(
        maxWait: const Duration(milliseconds: 50),
      );
      sw.stop();

      expect(msg, isNull);
      expect(sw.elapsedMilliseconds, lessThan(200));
      expect(appStore.isSyncInFlight, isTrue);

      // 重复触发复用同一个在途同步，不报错「同步已在进行中」
      final second = await appStore.pullToRefresh(
        maxWait: const Duration(milliseconds: 50),
      );
      expect(second, isNull);
      expect(gw.downloadCalls, lessThanOrEqualTo(2));

      // 等后台同步完成
      for (var i = 0; i < 40 && appStore.isSyncInFlight; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(appStore.isSyncInFlight, isFalse);
      expect(appStore.syncError, isNull);
      expect(appStore.recordingFiles.length, 2);

      appStore.dispose();
      status.dispose();
    });
  });
}
