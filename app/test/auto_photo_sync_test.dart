// 每分钟实时切片自动拍照对齐（系统相册 PhotoKit + 点一机 V1 硬件抓拍）与权限/开关持久化验收。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/photos/photo_library_service.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _FakeEngine implements SpeechEngine {
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
  }) async {
    return AsrResult(
      text: '今天同步会议纪要与现场拍照对齐情况。',
      tokens: const [],
      timestampsMs: const [],
      audioMs: samples.length * 1000 ~/ sampleRate,
    );
  }

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    return [SpeechSpan(0, samples.length)];
  }

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    return const [1, 0, 0];
  }

  @override
  Future<void> dispose() async {}
}

class _FakeModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/models/asr.onnx',
    tokensPath: '/models/tokens.txt',
    vadPath: '/models/vad.onnx',
    speakerEmbeddingPath: '/models/spk.onnx',
  );
}

class _NoopChat implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async => jsonEncode([]);
}

class _NoIoLiveAudio extends LiveAudioRecorder {
  _NoIoLiveAudio(CardGateway gateway) : super(gateway: gateway);

  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<LiveSession?> stop() async {
    _running = false;
    return null;
  }
}

Future<String> _writeSpeechWav(Directory dir, String name) async {
  const sampleCount = 16000;
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = ((i % 80) - 40) / 80.0 * 0.4;
  }
  final path = '${dir.path}/$name';
  await File(path).writeAsBytes(encodeWav(samples), flush: true);
  return path;
}

Future<({
  Directory root,
  RecordingStore recStore,
  RecordingPipeline pipeline,
  AppStore store,
})> _createLiveStore({
  required FakeCardGateway gateway,
  required PhotoLibraryService photoLib,
  bool Function()? photoSyncEnabled,
}) async {
  final root = await Directory.systemTemp.createTemp('rc-auto-photo-');
  final recStore = RecordingStore(
    root: Directory('${root.path}/recordings'),
    jsonStore: JsonStore(store: InMemoryStore()),
  );
  final pipeline = RecordingPipeline(
    gateway: gateway,
    store: recStore,
    engine: _FakeEngine(),
    models: _FakeModels(),
    liveAudioBaseDir: Directory('${root.path}/live'),
    polish: SlicePolishService(chat: _NoopChat(), model: 'test-model'),
    segments: SegmentBuildService(chat: _NoopChat(), model: 'test-model'),
  );
  final model = SummaryModel();
  final store = AppStore(
    recordings: null,
    generator: await model.generator(),
    jsonStore: JsonStore(store: InMemoryStore()),
    loadPersistedState: false,
  );
  store.attachPipeline(
    pipeline: pipeline,
    store: recStore,
    generator: await model.generator(),
  );
  store.photoLibrary = photoLib;
  if (photoSyncEnabled != null) {
    store.photoSyncEnabled = photoSyncEnabled;
  }
  return (root: root, recStore: recStore, pipeline: pipeline, store: store);
}

void main() {
  test(
    '1. 1 分钟实时切片入库时静默自动对齐系统相册照片（promptIfNeeded == false）',
    () async {
      final gateway = FakeCardGateway();
      final seenPrompts = <bool>[];
      final now = DateTime.now();
      final t0 = now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch;
      final capturedMs = t0 + 20000;

      late AppStore store;
      final photoLib = PhotoLibraryService(
        importOverride: (windows, {bool promptIfNeeded = false}) async {
          seenPrompts.add(promptIfNeeded);
          final target = windows.first;
          return PhotoImportReport(
            authorized: true,
            photos: [
              ImportedAlbumPhoto(
                id: 'alb_auto_1',
                eventId: target.eventId,
                path: '/tmp/alb_auto_1.jpg',
                capturedAtMs: capturedMs,
              ),
            ],
          );
        },
      );

      final ctx = await _createLiveStore(gateway: gateway, photoLib: photoLib);
      addTearDown(() async {
        ctx.store.dispose();
        if (await ctx.root.exists()) await ctx.root.delete(recursive: true);
      });
      store = ctx.store;

      final wavPath = await _writeSpeechWav(ctx.root, 'slice0.wav');
      final saved = await store.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'sess-photo-1',
          sliceIndex: 0,
          startAtMs: t0,
          durationMs: 60000,
          wavPath: wavPath,
        ),
      );
      expect(saved, isNotNull);
      expect(seenPrompts, equals([false]));
      expect(store.events, hasLength(1));
      final photos = store.activePhotosForEvent(store.events.first);
      expect(photos, hasLength(1));
      expect(photos.first.id, 'alb_auto_1');
      expect(photos.first.source, 'system_album');
    },
  );

  test(
    '2. 相邻 1 分钟切片边界 ±5s 快门容差跨片自动迁移去重，且尊重用户手动排除',
    () async {
      final gateway = FakeCardGateway();
      final now = DateTime.now();
      final t0 = now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch;
      final t1 = t0 + 60000;
      // 拍摄时刻落在切片 2 开头，仅以 +2s 落入切片 1 的 ±5s 容差
      final boundaryShotMs = t1 + 2000;

      final photoLib = PhotoLibraryService(
        importOverride: (windows, {bool promptIfNeeded = false}) async {
          final photos = <ImportedAlbumPhoto>[];
          for (final w in windows) {
            if (boundaryShotMs >= w.startMs - 5000 &&
                boundaryShotMs <= w.endMs + 5000) {
              photos.add(
                ImportedAlbumPhoto(
                  id: 'alb_boundary',
                  eventId: w.eventId,
                  path: '/tmp/alb_boundary.jpg',
                  capturedAtMs: boundaryShotMs,
                ),
              );
            }
          }
          return PhotoImportReport(authorized: true, photos: photos);
        },
      );

      final ctx = await _createLiveStore(gateway: gateway, photoLib: photoLib);
      addTearDown(() async {
        ctx.store.dispose();
        if (await ctx.root.exists()) await ctx.root.delete(recursive: true);
      });
      final store = ctx.store;

      final wav0 = await _writeSpeechWav(ctx.root, 's0.wav');
      final f0 = await store.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'sess-boundary',
          sliceIndex: 0,
          startAtMs: t0,
          durationMs: 60000,
          wavPath: wav0,
        ),
      );
      final id0 = f0!.segments.single.id;
      expect(
        store.activePhotosForEvent(store.eventByIdOrNull(id0)!).map((p) => p.id),
        ['alb_boundary'],
      );

      // 切片 2 入库：照片迁移到严格匹配的切片 2，切片 1 中移除，不重复保留两份
      final wav1 = await _writeSpeechWav(ctx.root, 's1.wav');
      final f1 = await store.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'sess-boundary',
          sliceIndex: 1,
          startAtMs: t1,
          durationMs: 60000,
          wavPath: wav1,
        ),
      );
      final id1 = f1!.segments.single.id;
      expect(store.activePhotosForEvent(store.eventByIdOrNull(id0)!), isEmpty);
      expect(
        store.activePhotosForEvent(store.eventByIdOrNull(id1)!).map((p) => p.id),
        ['alb_boundary'],
      );

      // 若用户手动从切片 2 排除该照片，后续自动同步不得重新挂回切片 1 或切片 2
      store.excludePhoto(id1, 'alb_boundary');
      await store.syncPhotosAutomatically(recentOnly: false);
      expect(store.activePhotosForEvent(store.eventByIdOrNull(id0)!), isEmpty);
      expect(store.activePhotosForEvent(store.eventByIdOrNull(id1)!), isEmpty);
    },
  );

  test(
    '3. 点一机 V1（hasCameraMedia）在 1 分钟切片入库时自动拉取硬件抓拍照片 + Rust bytes 字段与文件名时间解析',
    () async {
      final t0 = DateTime.now()
          .subtract(const Duration(minutes: 2))
          .millisecondsSinceEpoch;
      final shotSec = (t0 + 18000) ~/ 1000;

      final parsedRustJson = CameraSyncItem.fromJson({
        'name': 'CAM_20261113_161000.JPG',
        'path': '/tmp/CAM_20261113_161000.JPG',
        'bytes': 4096,
      });
      expect(parsedRustJson.bytesWritten, 4096);
      expect(
        parsedRustJson.capturedAtSec,
        DateTime(2026, 11, 13, 16, 10, 0).millisecondsSinceEpoch ~/ 1000,
      );
      final parsedEpochName = CameraSyncItem.fromJson({
        'name': 'CAM_1731500000.JPG',
        'path': '/tmp/CAM_1731500000.JPG',
        'bytes': 2048,
      });
      expect(parsedEpochName.capturedAtSec, 1731500000);

      final gateway = FakeCardGateway(
        cameraPhotos: [
          CameraSyncItem(
            name: 'SHOT_1.JPG',
            path: '/tmp/SHOT_1.JPG',
            bytesWritten: 1024,
            capturedAtSec: shotSec,
          ),
        ],
      );
      late Directory root;
      final photoLib = PhotoLibraryService(
        directoryOverride: () async => Directory('${root.path}/photos'),
        importOverride: (windows, {bool promptIfNeeded = false}) async =>
            const PhotoImportReport(authorized: true, photos: []),
      );

      final ctx = await _createLiveStore(gateway: gateway, photoLib: photoLib);
      root = ctx.root;
      addTearDown(() async {
        ctx.store.dispose();
        if (await ctx.root.exists()) await ctx.root.delete(recursive: true);
      });

      final store = ctx.store;
      store.deviceConnected = () => true;
      store.deviceHasCameraMedia = () => true;
      store.deviceGateway = () => gateway;

      final wavPath = await _writeSpeechWav(ctx.root, 'dyj_s0.wav');
      await store.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'sess-dyj',
          sliceIndex: 0,
          startAtMs: t0,
          durationMs: 60000,
          wavPath: wavPath,
        ),
      );
      expect(gateway.syncCameraCalls, 1);
      final photos = store.activePhotosForEvent(store.events.first);
      expect(photos.map((p) => p.id), ['dyj_SHOT_1.JPG']);
      expect(photos.first.source, 'dyj_camera');
    },
  );

  testWidgets(
    '4. AppShell 在首次开始录音上升沿按需请求一次相册权限（notDetermined → granted），后续更新不重复弹窗',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const idleSnapshot = CardSnapshot(
        batteryLevel: 88,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '2.2.0',
        fwVersionCode: 22,
        wifiVersion: '1.5.0',
        wifiVersionCode: 15,
        deviceName: 'DYJV2_TEST',
        deviceId: 'test-device',
      );
      const card = CardDevice(
        id: 'test-device',
        name: 'DYJV2_TEST',
        rssi: -42,
      );
      final gateway = FakeCardGateway(
        initialSnapshot: idleSnapshot,
        devices: const [card],
      );
      final device = DeviceStore(gateway: gateway, autoStart: false);
      await device.startScan();
      await device.connectTo(device.discovered.single);
      expect(device.isConnected, isTrue);
      expect(device.isRecording, isFalse);

      final agentConfig = AgentConfigStore(store: InMemoryStore());
      await agentConfig.load();
      final model = SummaryModel();
      final store = AppStore(
        events: const [],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      final recStatus = RecordingStatusController();
      final liveAudio = _NoIoLiveAudio(gateway);

      var status = PhotoPermissionState.notDetermined;
      var reqCount = 0;
      final photoLib = PhotoLibraryService(
        statusOverride: () async => status,
        requestOverride: () async {
          reqCount += 1;
          status = PhotoPermissionState.granted;
          return status;
        },
      );

      addTearDown(() {
        liveAudio.dispose();
        recStatus.dispose();
        store.dispose();
        agentConfig.dispose();
        device.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: store,
            device: device,
            recordingStatus: recStatus,
            agentConfig: agentConfig,
            liveAudio: liveAudio,
            photoLibrary: photoLib,
            supportsDynamicIslandOverride: false,
          ),
        ),
      );
      await tester.pump();
      expect(reqCount, 0);

      // 触发首次开始录音上升沿：仅请求一次权限
      await device.toggleRecording();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(device.isRecording, isTrue);
      expect(reqCount, 1);

      // 再次停录 → 再开录：本会话内已授予过权限，不得重复请求
      await device.toggleRecording();
      await tester.pump();
      await device.toggleRecording();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(reqCount, 1);
    },
  );

  test(
    '5. 关闭开关跳过每分钟自动照片同步，且 AgentConfigStore 可持久化 false 状态',
    () async {
      final backing = InMemoryStore();
      final first = AgentConfigStore(store: backing);
      addTearDown(first.dispose);
      await first.load();
      expect(first.photoLinkEnabled, isTrue);
      expect(first.isExtensionOn('tl-photo'), isTrue);

      await first.setPhotoLinkEnabled(false);
      expect(first.photoLinkEnabled, isFalse);
      expect(first.isExtensionOn('tl-photo'), isFalse);

      final reopened = AgentConfigStore(store: backing);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.photoLinkEnabled, isFalse);
      expect(reopened.isExtensionOn('tl-photo'), isFalse);

      // 关闭状态下切片入库跳过系统相册与硬件拍照拉取
      final gateway = FakeCardGateway(
        cameraPhotos: const [
          CameraSyncItem(
            name: 'SKIP.JPG',
            path: '/tmp/SKIP.JPG',
            bytesWritten: 512,
          ),
        ],
      );
      var importCalls = 0;
      final photoLib = PhotoLibraryService(
        importOverride: (windows, {bool promptIfNeeded = false}) async {
          importCalls++;
          return const PhotoImportReport(authorized: true, photos: []);
        },
      );
      final ctx = await _createLiveStore(
        gateway: gateway,
        photoLib: photoLib,
        photoSyncEnabled: () => reopened.photoLinkEnabled,
      );
      addTearDown(() async {
        ctx.store.dispose();
        if (await ctx.root.exists()) await ctx.root.delete(recursive: true);
      });
      ctx.store.deviceConnected = () => true;
      ctx.store.deviceHasCameraMedia = () => true;
      ctx.store.deviceGateway = () => gateway;

      final wavPath = await _writeSpeechWav(ctx.root, 'skip.wav');
      await ctx.store.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'sess-skip',
          sliceIndex: 0,
          startAtMs: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          durationMs: 60000,
          wavPath: wavPath,
        ),
      );
      expect(importCalls, 0);
      expect(gateway.syncCameraCalls, 0);
      expect(ctx.store.activePhotosForEvent(ctx.store.events.first), isEmpty);
    },
  );
}
