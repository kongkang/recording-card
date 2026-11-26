import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';

import 'support/fake_gateway.dart';

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
    text: '测试转写片段。',
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
  }) async => const [1.0, 0.0, 0.0];

  @override
  Future<void> dispose() async {}
}

class _StubModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/models/asr.onnx',
    tokensPath: '/models/tokens.txt',
    vadPath: '/models/vad.onnx',
    speakerEmbeddingPath: '/models/spk.onnx',
  );
}

class _SpyPhoneMicBackend implements PhoneMicBackend {
  bool capturing = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    capturing = true;
    startCalls++;
  }

  @override
  Future<void> stopCapture() async {
    capturing = false;
    stopCalls++;
  }
}

void main() {
  group('Batch 1 CardV2 可靠性修复', () {
    test('Plan-F1: 25 段同 session 1024s RTC1 回绕文件按 seq 排序并重建单调时间轴', () async {
      final root = await Directory.systemTemp.createTemp('rc-batch1-wrap-');
      addTearDown(() => root.delete(recursive: true));

      const baseSec = 1764040000; // 2025-11-25 某时刻
      const wrapPeriod = 1024;
      // 构造 25 段（~4h10m），模拟固件每 600s 切片且 RTC1 每 1024s 回绕
      final wrappedFiles = <CardFile>[
        for (var seq = 25; seq >= 1; seq--)
          CardFile(
            name: 'SEG${seq.toString().padLeft(2, '0')}.APM',
            size: 600 * 8000,
            session: '0140A9CA',
            seq: seq,
            startAtSec: baseSec + (((seq - 1) * 600) % wrapPeriod),
            synced: true,
          ),
      ];

      // 1) orderCardFilesForSync 必须保持同 session 内 seq = 1..25 升序，而非回绕后的假时间序
      final ordered = RecordingPipeline.orderCardFilesForSync(wrappedFiles);
      expect(
        ordered.map((f) => f.seq).toList(),
        [for (var seq = 1; seq <= 25; seq++) seq],
      );

      // 2) 通过 pipeline.sync() 同步并转码 6 段跨回绕边界文件，验证真实管线排序+转码+重建
      final gw = FakeCardGateway(deviceFiles: wrappedFiles.sublist(wrappedFiles.length - 6))
        ..writeDownload = true
        ..transcodeSeconds = 2;
      final store = RecordingStore(
        root: root,
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final pipeline = RecordingPipeline(
        gateway: gw,
        store: store,
        engine: _StubEngine(),
        models: _StubModels(),
      );

      final res = await pipeline.sync();
      expect(res.downloaded, 6);
      expect(res.failed, 0);

      final saved = List<RecordingFile>.of(await store.loadAll(refresh: true));
      expect(saved.length, 6);
      saved.sort((a, b) => a.seq.compareTo(b.seq));
      expect(saved.first.startAtMs, baseSec * 1000);
      for (var i = 1; i < saved.length; i++) {
        final expected = baseSec * 1000 + i * 2000;
        expect(
          saved[i].startAtMs,
          expected,
          reason: 'seq=${saved[i].seq} 应从回绕时间恢复为单调递增起点',
        );
        expect(
          saved[i].timeSynced,
          isFalse,
          reason: '顺序重建的时间戳应标记 timeSynced=false 以守住诚实边界',
        );
      }

      // 3) 对真实 600s (10分钟×25段 = 4h10m) 场景直接校验 reconcileSessionTimestamps
      final fullScale = [
        for (var seq = 1; seq <= 25; seq++)
          RecordingFile(
            deviceName: 'FULL_${seq.toString().padLeft(2, '0')}.APM',
            session: '0140A9CA',
            seq: seq,
            startAtMs: (baseSec + (((seq - 1) * 600) % wrapPeriod)) * 1000,
            durationMs: 600 * 1000,
            timeSynced: true,
            apmPath: '/tmp/FULL_$seq.APM',
            createdAtMs: baseSec * 1000,
          ),
      ];
      RecordingPipeline.reconcileSessionTimestamps(fullScale);
      expect(fullScale[1].startAtMs, baseSec * 1000 + 600 * 1000);
      expect(fullScale[1].timeSynced, isTrue, reason: 'seq=2 (600s < 1024s) 尚未回绕，保留真实同步标记');
      for (var i = 2; i < fullScale.length; i++) {
        expect(fullScale[i].startAtMs, baseSec * 1000 + i * 600 * 1000);
        expect(fullScale[i].timeSynced, isFalse);
      }
    });

    test('Plan-R2/R3: CardDownload 保留 session/seq 且对 ≤0.3.19 传 15578Hz 重采样', () async {
      final dl = CardDownload.fromJson({
        'path': '/tmp/20261125-100000_SEG02.apm',
        'bytesWritten': 12345,
        'originalName': 'synced_1764040600_0140A9CA_02.apm',
        'startAt': 1764040600,
        'timeSynced': true,
        'session': '0140A9CA',
        'seq': 2,
      });
      expect(dl.session, '0140A9CA');
      expect(dl.seq, 2);

      // Fallback parsing from originalName even if session/seq omitted
      final dlFallback = CardDownload.fromJson({
        'path': '/tmp/test.apm',
        'bytesWritten': 1024,
        'originalName': 'synced_1764040600_a1b2c3d4_07.apm',
      });
      expect(dlFallback.session, 'A1B2C3D4');
      expect(dlFallback.seq, 7);

      final root = await Directory.systemTemp.createTemp('rc-batch1-rate-');
      addTearDown(() => root.delete(recursive: true));

      final gw = FakeCardGateway(
        initialSnapshot: const CardSnapshot(
          batteryLevel: 80,
          isCharging: false,
          wifiOpen: false,
          recording: false,
          fwVersion: '0.3.17',
          fwVersionCode: 317,
          wifiVersion: '0.1.4',
          wifiVersionCode: 104,
          deviceName: 'DYJV2_TEST',
          deviceId: 'card-v2-1',
        ),
        deviceFiles: const [
          CardFile(
            name: 'DRIFT01.APM',
            size: 16000,
            session: 'BEEF0001',
            seq: 1,
            startAtSec: 1764050000,
            synced: true,
          ),
        ],
      )
        ..writeDownload = true
        ..transcodeSeconds = 10;

      final deviceStore = DeviceStore(gateway: gw);
      addTearDown(deviceStore.dispose);
      await deviceStore.restoreLink();
      await deviceStore.connectTo(
        const CardDevice(id: 'card-v2-1', name: 'DYJV2_TEST'),
      );

      final store = RecordingStore(
        root: root,
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final pipeline = RecordingPipeline(
        gateway: gw,
        store: store,
        engine: _StubEngine(),
        models: _StubModels(),
        apmSourceSampleRateResolver: deviceStore.apmSourceSampleRateHzFor,
      );

      await pipeline.sync();
      expect(gw.lastTranscodeSourceSampleRateHz, 15578.0);

      // 升级到 0.3.20 (versionCode 320) 后不再叠加频偏补偿
      gw.current = const CardSnapshot(
        batteryLevel: 80,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '0.3.20',
        fwVersionCode: 320,
        wifiVersion: '0.1.4',
        wifiVersionCode: 104,
        deviceName: 'DYJV2_TEST',
        deviceId: 'card-v2-1',
      );
      await deviceStore.refreshFromDevice();
      expect(
        deviceStore.apmSourceSampleRateHzFor(
          RecordingFile(
            deviceName: 'NEW.APM',
            session: 'BEEF0002',
            seq: 1,
            startAtMs: 1764060000000,
            timeSynced: true,
            apmPath: '/tmp/NEW.APM',
            createdAtMs: 1764060000000,
          ),
        ),
        isNull,
      );
    });

    testWidgets('Plan-F2: CardV2 电量跌至 ≤5% 且未充电时先接力兜底并主动 stopRecording 封存 SD', (
      tester,
    ) async {
      final micRoot = Directory.systemTemp.createTempSync('rc-batch1-mic-');
      addTearDown(() => micRoot.deleteSync(recursive: true));
      final spyBackend = _SpyPhoneMicBackend();
      final gw = FakeCardGateway(
        initialSnapshot: const CardSnapshot(
          batteryLevel: 12,
          isCharging: false,
          wifiOpen: false,
          recording: true,
          fwVersion: '0.3.17',
          fwVersionCode: 317,
          wifiVersion: '0.1.4',
          wifiVersionCode: 104,
          deviceName: 'DYJV2_LOW',
          deviceId: 'dev-low',
        ),
      );
      final store = DeviceStore(
        gateway: gw,
        autoStart: false,
        phoneMicBackend: spyBackend,
        phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => micRoot),
      );

      await store.connectTo(
        const CardDevice(id: 'dev-low', name: 'DYJV2_LOW'),
      );
      expect(store.isRecording, isTrue);
      expect(gw.recordCalls, isEmpty);

      // 电量掉至 5%：应触发低电量安全停录 + 手机麦克风接力
      gw.pushPowerEvent(level: 5, charging: false);
      await store.pollEventsNow();
      await tester.pump(const Duration(milliseconds: 50));

      expect(gw.recordCalls, contains('stop'));
      expect(store.isRecording, isFalse);
      expect(spyBackend.startCalls, 1);
      expect(store.hardwareSafetyNotice, contains('5%'));

      // 重复推送 4% 不应重复发送 stopRecording
      final stopCountAfterFirst =
          gw.recordCalls.where((c) => c == 'stop').length;
      gw.pushPowerEvent(level: 4, charging: false);
      await store.pollEventsNow();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        gw.recordCalls.where((c) => c == 'stop').length,
        stopCountAfterFirst,
      );

      await store.stopPhoneRecording();
      store.dispose();
      await tester.pump();
    });

    test('Plan-R1: apFiles 与 apDownload 只读校验接口契约正常', () async {
      final gw = FakeCardGateway(
        deviceFiles: const [
          CardFile(
            name: 'SEG01.APM',
            size: 64,
            session: 'ABCD1234',
            seq: 1,
            startAtSec: 1764040000,
            synced: true,
          ),
        ],
      )..writeDownload = true;
      final dir = await Directory.systemTemp.createTemp('rc-batch1-ap-');
      addTearDown(() => dir.delete(recursive: true));

      final listed = await gw.apFiles();
      expect(listed.single.name, 'SEG01.APM');

      final dlKeep = await gw.apDownload(
        'SEG01.APM',
        dir.path,
        expectedSize: 64,
        deleteAfterVerify: false,
      );
      expect(File(dlKeep.path).existsSync(), isTrue);
      expect(gw.deletedFiles, isEmpty);

      await gw.apDownload(
        'SEG01.APM',
        dir.path,
        expectedSize: 64,
        deleteAfterVerify: true,
      );
      expect(gw.deletedFiles, ['SEG01.APM']);
    });
  });
}
