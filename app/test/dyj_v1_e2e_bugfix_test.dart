// 点译机 V1 iPhone 13 mini 真机全流程实测暴露出的三处 Bug 回归测试：
// 1. BLE 重连后 / 续跑待处理结束后，AppStore 顶部「正在读取录音卡文件列表…」横幅必须清空，不能永久卡死；
// 2. AppShell 断连浮条（ble-disconnect-toast）贴近底部浮现，不遮挡顶部「全部 / 记录 / 总结」筛选栏；
// 3. 在状态弹层打开状态下主动断开连接且扫描缓存已过期时，自动清除过期缓存并立即触发重新扫描。
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
import 'support/harness.dart';
import 'support/model_stub.dart';

class _FakeSpeechEngine implements SpeechEngine {
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
    text: '点一机 V1 端到端测试录音文本。',
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

class _FakeSpeechModels implements SpeechModelProvider {
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

class _ScriptedFilesGateway extends FakeCardGateway {
  Object? nextFilesError;

  @override
  Future<List<CardFile>> files() async {
    final err = nextFilesError;
    if (err != null) {
      nextFilesError = null;
      throw err;
    }
    return super.files();
  }
}

Future<({Directory root, RecordingStore recStore, AppStore store})>
_createStoreWithPipeline(FakeCardGateway gateway) async {
  final root = await Directory.systemTemp.createTemp('rc-dyj-bugfix-');
  final recStore = RecordingStore(
    root: Directory('${root.path}/recordings'),
    jsonStore: JsonStore(store: InMemoryStore()),
  );
  final pipeline = RecordingPipeline(
    gateway: gateway,
    store: recStore,
    engine: _FakeSpeechEngine(),
    models: _FakeSpeechModels(),
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
  return (root: root, recStore: recStore, store: store);
}

void main() {
  test(
    'syncAfterBleReconnect 在 0 个设备文件完成与 listFiles 断连抛错时均清空同步横幅',
    () async {
      final gw = _ScriptedFilesGateway();
      final env = await _createStoreWithPipeline(gw);
      addTearDown(() async {
        env.store.dispose();
        await env.root.delete(recursive: true);
      });

      // Case A: gateway.files() 返回 0 个文件
      await env.store.syncAfterBleReconnect(pullBleFiles: true);
      expect(env.store.syncStage, isNull);
      expect(env.store.syncText, isEmpty);
      expect(env.store.syncProgress, 0);

      // Case B: gateway.files() 抛出断连异常
      gw.nextFilesError = CardException.disconnected('低电量断开');
      await env.store.syncAfterBleReconnect(pullBleFiles: true);
      expect(env.store.syncStage, isNull);
      expect(env.store.syncText, isEmpty);
      expect(env.store.syncProgress, 0);
    },
  );

  test('processPendingRecordings 完成后清空正在读取录音卡文件列表横幅', () async {
    final gw = _ScriptedFilesGateway();
    final env = await _createStoreWithPipeline(gw);
    addTearDown(() async {
      env.store.dispose();
      await env.root.delete(recursive: true);
    });

    final wavPath = '${env.root.path}/pending.wav';
    await File(wavPath).writeAsBytes(encodeWav(Float32List(16000)), flush: true);
    final startAtMs = DateTime(2026, 11, 23, 0, 1).millisecondsSinceEpoch;
    await env.recStore.save(
      RecordingFile(
        deviceName: 'audio_20261123-000100_TEST_01.amr',
        session: 'TEST',
        seq: 1,
        startAtMs: startAtMs,
        apmPath: '${env.root.path}/pending.amr',
        createdAtMs: startAtMs,
        wavPath: wavPath,
        durationMs: 1000,
        stage: RecordingStage.queued,
      ),
    );

    gw.nextFilesError = CardException.disconnected('设备已断开');
    await env.store.processPendingRecordings();
    expect(env.store.syncStage, isNull);
    expect(env.store.syncText, isEmpty);
    expect(env.store.syncProgress, 0);
  });

  testWidgets('断连浮条位于底部导航上方且不遮挡顶部筛选栏（全部 / 记录 / 总结）', (tester) async {
    final gw = FakeCardGateway(
      devices: const [
        CardDevice(
          id: 'dyj-q2m34r',
          name: 'DYJ_Q2M34R',
          rssi: -52,
          kind: DeviceKind.dyjV1,
        ),
      ],
    );
    final device = DeviceStore(gateway: gw);
    await device.connectTo(gw.devices.first);
    await pumpShell(tester, device: device, size: const Size(375, 812));

    // 模拟意外低电量断连
    gw.failConnect = CardException.disconnected('设备电量耗尽或过低');
    gw.pushDisconnectedEvent();
    await device.pollEventsNow();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final toast = find.byKey(const Key('ble-disconnect-toast'));
    final allFilter = find.text('全部');
    expect(toast, findsOneWidget);
    expect(allFilter, findsOneWidget);

    final toastRect = tester.getRect(toast);
    final filterRect = tester.getRect(allFilter);
    // 浮条必须严格在筛选栏下方、无任何垂直区域重叠
    expect(toastRect.top, greaterThan(filterRect.bottom + 200));
    expect(toastRect.overlaps(filterRect), isFalse);

    // 仍支持关闭与点开弹层
    await tester.tap(find.byKey(const Key('ble-disconnect-toast-close')));
    await tester.pump();
    expect(find.byKey(const Key('ble-disconnect-toast')), findsNothing);
  });

  testWidgets('打开状态弹层超过 60 秒后主动断开连接，自动清过期缓存并触发新扫描', (tester) async {
    var fakeNow = DateTime(2026, 11, 23, 0, 0, 0);
    final gw = FakeCardGateway(
      devices: const [
        CardDevice(
          id: 'dyj-q2m34r',
          name: 'DYJ_Q2M34R',
          rssi: -50,
          kind: DeviceKind.dyjV1,
        ),
      ],
    );
    final device = DeviceStore(gateway: gw, now: () => fakeNow);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();
    expect(gw.scanCalls, 1);

    // 连接 DYJ_Q2M34R 并经过 90 秒（已超过 60 秒扫描缓存 TTL）
    await tester.tap(find.byKey(const Key('dev-item-dyj-q2m34r')));
    await tester.pump();
    await tester.pump();
    expect(device.isConnected, isTrue);

    fakeNow = fakeNow.add(const Duration(seconds: 90));
    await tester.pump(const Duration(seconds: 1));

    // 在弹层打开期间点右上角断开图标并确认断开
    await tester.tap(find.byKey(const Key('dev-disconnect')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('disconnect-confirm')));
    await tester.pump();
    await tester.pump();

    expect(device.isConnected, isFalse);
    expect(find.byKey(const Key('dev-scan-expired-hint')), findsNothing);
    expect(gw.scanCalls, 2);
  });
}
