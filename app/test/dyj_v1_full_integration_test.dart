// 点一机 V1（dyj_v1 / DYJ_Q2M34R）端到端全套联动验收：
// ① 扫描识别与负 RSSI 排序 + < 0.8.0 旧固件明确提示与自动断连 + 连接失败/超时链路释放；
// ② 连后快照字段映射（电量/充电态、版本 0.8.15、存储余量、Wi-Fi 计数、单芯片固件入口）；
// ③ 录音开关启停 + 16kHz PCM 实时流切片（LiveAudioRecorder → RecordingPipeline → Timeline）；
// ④ 离线 .amr 文件发现 → 下载 → transcode WAV → 本地 ASR → Timeline / 详情 / 总结三处对齐；
// ⑤ 硬件拍照事件 kind:'camera' → 自动拉取 dyj_camera 照片 → 缩略图 + 详情内联 + 总结含 X 张图片；
// ⑥ Wi-Fi 2.4GHz 扫描、配网成功、密码错误就地红字报错、忘记已保存网络；
// ⑦ 单芯片 single_ota：未连 Wi-Fi 引导去配网、已连 Wi-Fi 单阶段升级、重连并刷新版本号。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/photos/photo_library_service.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';
import 'support/model_stub.dart';

class _V1FakeEngine implements SpeechEngine {
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
      text: '点一机实时与离线音频完成转写，准备同步现场拍照记录。',
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

class _V1FakeModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/models/asr.onnx',
    tokensPath: '/models/tokens.txt',
    vadPath: '/models/vad.onnx',
    speakerEmbeddingPath: '/models/spk.onnx',
  );
}

class _FallbackChat implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async => jsonEncode([]);
}

const _v1Dev = CardDevice(
  id: 'dyj-q2m34r',
  name: 'DYJ_Q2M34R',
  rssi: -52,
  kind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

CardSnapshot _v1Snapshot({
  int battery = 78,
  bool charging = true,
  bool recording = false,
  bool wifiOpen = true,
  String fwVersion = '0.8.15',
  int fwVersionCode = 815,
}) => CardSnapshot(
  batteryLevel: battery,
  isCharging: charging,
  wifiOpen: wifiOpen,
  recording: recording,
  fwVersion: fwVersion,
  fwVersionCode: fwVersionCode,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_Q2M34R',
  deviceId: 'C5F96AD5895ADF02',
  storageTotalMb: 16384,
  storageFreeMb: 12288,
  deviceKind: DeviceKind.dyjV1,
  displayModel: '点一机 V1',
  capabilities: HardwareCapabilities.dyjV1,
);

Future<
  ({
    Directory root,
    RecordingStore recStore,
    RecordingPipeline pipeline,
    AppStore store,
    SummaryModel model,
  })
>
_buildPipelineStore({
  required FakeCardGateway gateway,
  required PhotoLibraryService photoLib,
}) async {
  final root = await Directory.systemTemp.createTemp('rc-dyj-v1-');
  final recStore = RecordingStore(
    root: Directory('${root.path}/recordings'),
    jsonStore: JsonStore(store: InMemoryStore()),
  );
  final pipeline = RecordingPipeline(
    gateway: gateway,
    store: recStore,
    engine: _V1FakeEngine(),
    models: _V1FakeModels(),
    liveAudioBaseDir: Directory('${root.path}/live'),
    polish: SlicePolishService(chat: _FallbackChat(), model: 'test-model'),
    segments: SegmentBuildService(chat: _FallbackChat(), model: 'test-model'),
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
  store.deviceConnected = () => true;
  store.deviceHasCameraMedia = () => true;
  store.deviceGateway = () => gateway;
  return (
    root: root,
    recStore: recStore,
    pipeline: pipeline,
    store: store,
    model: model,
  );
}

void main() {
  testWidgets(
    '①② 扫描排序、legacy < 0.8.0 升级提示、连后快照双键兼容与失败主动释放 GATT',
    (tester) async {
      // 1) JSON 契约回归：Rust bridge 回包的双键形态均正确映射到 CardSnapshot / CardFile / CardOtaInfo
      final parsedSnap = CardSnapshot.fromJson({
        'deviceKind': 'dyj_v1',
        'displayModel': '点一机 V1',
        'deviceName': 'DYJ_Q2M34R',
        'battery': {'level': 82, 'charging': true},
        'state': {'wifiEnabled': true, 'recording': true},
        'info': {
          'firmwareVersion': '0.8.15',
          'versionCode': 815,
          'deviceId': 'C5F96AD5895ADF02',
        },
        'storage': {'total': 16384, 'used': 4096},
        'record': {'recording': true, 'realtimeEnabled': true, 'session': 'A1B2C3D4'},
      });
      expect(parsedSnap.batteryLevel, 82);
      expect(parsedSnap.isCharging, isTrue);
      expect(parsedSnap.wifiOpen, isTrue);
      expect(parsedSnap.recording, isTrue);
      expect(parsedSnap.realtimeEnabled, isTrue);
      expect(parsedSnap.fwVersion, '0.8.15');
      expect(parsedSnap.fwVersionCode, 815);
      expect(parsedSnap.storageTotalMb, 16384);
      expect(parsedSnap.storageFreeMb, 12288);
      expect(parsedSnap.resolvedCapabilities.hasSingleOta, isTrue);

      final parsedAmr = CardFile.fromJson({
        'name': 'audio_20261116-193000_A1B2C3D4_01.amr',
        'size': 48000,
        'created_at': 1763292660,
        'session': 'A1B2C3D4',
        'seq': 1,
      });
      expect(parsedAmr.isAmr, isTrue);
      expect(parsedAmr.isAudioRecording, isTrue);
      expect(
        parsedAmr.startAtSec,
        DateTime(2026, 11, 16, 19, 30, 0).millisecondsSinceEpoch ~/ 1000,
      );

      final otaWithNeed = CardOtaInfo.fromJson({
        'version': '0.8.16',
        'versionCode': 816,
        'url': 'https://ota.example/v1.apk',
        'needUpdate': true,
      });
      expect(otaWithNeed.isNewerThan(816), isTrue, reason: '遵循设备 needUpdate=true');
      final otaNoNeed = CardOtaInfo.fromJson({
        'version': '0.8.15',
        'versionCode': 815,
        'url': '',
        'needUpdate': false,
      });
      expect(otaNoNeed.isNewerThan(814), isFalse);

      // 2) legacy < 0.8.0 连接失败时提示清晰，且主动调 disconnect 释放单连接广播
      final gwLegacy = FakeCardGateway(
        devices: const [
          CardDevice(id: 'weak', name: 'DYJ_OTHER', rssi: -78),
          _v1Dev,
        ],
      )..failConnect = const CardException(
          CardErrorKind.device,
          '检测到点一机固件版本过低（v0.7.2），请先升级至 v0.8.12 及以上版本后再连接',
        );
      final devLegacy = DeviceStore(gateway: gwLegacy);
      await pumpShell(tester, device: devLegacy);
      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump();

      expect(devLegacy.discovered.map((d) => d.id).toList(), ['dyj-q2m34r', 'weak']);
      expect(find.byKey(const Key('dev-kind-dyj-q2m34r')), findsOneWidget);
      expect(find.text('Q2M34R'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dev-item-dyj-q2m34r')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('v0.7.2'), findsOneWidget);
      expect(gwLegacy.disconnectCalls, greaterThanOrEqualTo(1));

      // 3) 0.8.15 正常连接：展示电量、可录至、同步、Wi-Fi、单芯片固件行（无 Wi-Fi 芯片行）
      final gwOk = FakeCardGateway(
        initialSnapshot: _v1Snapshot(battery: 82, charging: true, recording: false),
        devices: const [_v1Dev],
        wifiCredentials: const [CardWifiCredential(ssid: 'CloudOS.com')],
      );
      final devOk = DeviceStore(gateway: gwOk);
      await devOk.connectTo(_v1Dev);
      await tester.pump();
      expect(devOk.isConnected, isTrue);
      expect(devOk.fwVersion, '0.8.15');
      expect(devOk.fwVersionText, '0.8.15');
      expect(devOk.deviceSubtitleText, '固件 0.8.15');
    },
  );

  test(
    '③④⑤ 实时音频流切片 + 离线 .amr 转码入库 + 硬件拍照事件驱动三处联动（Timeline / 详情 / 总结）',
    () async {
      final gw = FakeCardGateway(
        initialSnapshot: _v1Snapshot(recording: false),
        devices: const [_v1Dev],
        deviceFiles: [
          CardFile(
            name: 'audio_20261116-193000_A1B2C3D4_01.amr',
            size: 64000,
            createdAtSec:
                DateTime(2026, 11, 16, 19, 31, 0).millisecondsSinceEpoch ~/ 1000,
            session: 'A1B2C3D4',
            seq: 1,
          ),
        ],
        writeDownload: true,
        transcodeSeconds: 2,
        cameraPhotos: [
          CameraSyncItem(
            name: 'img_20261116-193020-001.jpg',
            path: '/tmp/v1_cam_shot.jpg',
            bytesWritten: 24576,
            capturedAtSec:
                DateTime(2026, 11, 16, 19, 30, 20).millisecondsSinceEpoch ~/ 1000,
            source: 'dyj_camera',
          ),
        ],
      );

      late Directory root;
      final photoLib = PhotoLibraryService(
        directoryOverride: () async => Directory('${root.path}/photos'),
        importOverride: (windows, {bool promptIfNeeded = false}) async =>
            const PhotoImportReport(authorized: true, photos: []),
      );
      final ctx = await _buildPipelineStore(gateway: gw, photoLib: photoLib);
      root = ctx.root;
      addTearDown(() async {
        ctx.store.dispose();
        if (await ctx.root.exists()) await ctx.root.delete(recursive: true);
      });

      final devStore = DeviceStore(gateway: gw, autoStart: false);
      addTearDown(devStore.dispose);
      await devStore.connectTo(_v1Dev);

      var cameraSyncEvents = 0;
      devStore.onHardwarePhotoCaptured = () {
        cameraSyncEvents++;
        unawaited(ctx.store.syncHardwareCameraPhotos(gw));
      };

      // ③ 开关开始录音 + 实时 16kHz PCM 流落地切片 → RecordingPipeline → Timeline
      final recErr = await devStore.toggleRecording();
      expect(recErr, isNull);
      expect(devStore.isRecording, isTrue);

      final pcm1s = Uint8List(32000); // 16000 samples * 2 bytes = 1s @ 16kHz mono
      gw.realtimeEvents.addAll([
        const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
        RealtimeAudioEvent(
          kind: RealtimeAudioKind.audio,
          pcm: pcm1s,
          receivedSamples: 16000,
        ),
        const RealtimeAudioEvent(kind: RealtimeAudioKind.closed),
      ]);
      final liveSlices = <LiveAudioSlice>[];
      final live = LiveAudioRecorder(
        gateway: gw,
        baseDir: Directory('${root.path}/live'),
        onSliceReady: liveSlices.add,
      );
      addTearDown(live.dispose);
      await live.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final liveSession = await live.stop();
      expect(liveSession, isNotNull);
      expect(liveSession!.receivedSamples, 1000);
      expect(liveSlices, hasLength(1));
      await ctx.store.ingestLiveSlice(liveSlices.single);

      // ④ 离线 .amr 下载 → transcode WAV → ASR → 入库 Timeline
      final syncRes = await ctx.pipeline.sync();
      expect(syncRes.downloaded, 1);
      expect(syncRes.ready, 1);
      expect(syncRes.failed, 0);
      expect(gw.downloadCalls, 1);
      expect(gw.transcodeCalls, 1);

      await ctx.store.refreshEvents();
      expect(ctx.store.events.length, greaterThanOrEqualTo(2));

      // ⑤ 硬件拍照事件触发 camera.sync → 按拍摄时间戳自动迁入 19:30 的 .amr 记录，来源标注 dyj_camera
      expect(gw.syncCameraCalls, 1, reason: '切片入库时自动拉取过一次硬件抓拍');
      gw.pushCameraEvent(name: 'img_20261116-193020-001.jpg');
      await devStore.pollEventsNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cameraSyncEvents, 1);
      expect(gw.syncCameraCalls, 2, reason: '硬件拍照事件再次触发增量拉取');
      final amrEvent = ctx.store.events.firstWhere(
        (e) => e.time.startsWith('19:30'),
      );
      final attached = ctx.store.activePhotosForEvent(amrEvent);
      expect(attached, hasLength(1));
      expect(attached.first.source, 'dyj_camera');
      expect(attached.first.id, 'dyj_img_20261116-193020-001.jpg');
    },
  );

  testWidgets(
    '⑥⑦ Wi-Fi 2.4GHz 配网 / 密码错误重试 / 忘记网络 + single_ota 全流程（引导配网 & 升级重连刷新）',
    (tester) async {
      final otaModules = <String>[];
      late FakeCardGateway gw;
      gw = FakeCardGateway(
        initialSnapshot: _v1Snapshot(
          wifiOpen: false,
          fwVersion: '0.8.12',
          fwVersionCode: 812,
        ),
        devices: const [_v1Dev],
        wifiNetworks: const [
          CardWifiNetwork(ssid: 'Studio-2.4G', rssi: -45, secured: true),
          CardWifiNetwork(ssid: 'Guest-2.4G', rssi: -68, secured: true),
        ],
        wifiCredentials: const [CardWifiCredential(ssid: 'Studio-2.4G')],
        postMainOtaSnapshot: _v1Snapshot(
          wifiOpen: true,
          fwVersion: '0.8.15',
          fwVersionCode: 815,
        ),
        clearAfterMainOta: true,
        mainProgress: const [
          CardProgress(stage: 'downloading', percent: 40, text: '正在下载系统固件…'),
          CardProgress(stage: 'installing', percent: 90, text: '正在安装系统固件并重启设备…'),
        ],
        progressDelay: Duration.zero,
      );
      gw.otaInfoOverride = (mod) async {
        otaModules.add(mod);
        if (gw.current?.wifiOpen != true) {
          throw const CardException(
            CardErrorKind.device,
            '点一机检查固件更新需要先连接 Wi-Fi 网络',
          );
        }
        return const CardOtaInfo(
          version: '0.8.15',
          versionCode: 815,
          url: 'https://ota.example/dyj-0.8.15.apk',
          needUpdate: true,
          currentVersionCode: 812,
        );
      };

      final dev = DeviceStore(gateway: gw);
      await pumpShell(tester, device: dev);
      await dev.connectTo(_v1Dev);
      await tester.pump(const Duration(milliseconds: 350));

      // 首页打开 StatusSheet：预检失败被 silent 模式吸收，主弹层仍干净
      await tester.tap(find.byKey(const Key('hw-capsule')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('fw-update')), findsOneWidget);
      expect(dev.fwStage, isNot(FwStage.failed));

      // ⑦-A 未连 Wi-Fi 进固件更新页：显示错误并给出「去设置 Wi-Fi ›」引导
      await tester.tap(find.byKey(const Key('fw-update')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('fw-error')), findsOneWidget);
      expect(find.byKey(const Key('upg-goto-wifi')), findsOneWidget);
      expect(find.byKey(const Key('fw-wifi-ver')), findsNothing);

      // 点击「去设置 Wi-Fi ›」跳入 Wi-Fi 视图
      await tester.tap(find.byKey(const Key('upg-goto-wifi')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('dev-wifi')), findsOneWidget);

      // ⑥ Wi-Fi 密码错误就地红字提示 → 输入正确密码重试成功 → 忘记网络
      gw.failWifiConnect = const CardException(
        CardErrorKind.device,
        'Wi-Fi「Guest-2.4G」密码错误，请核对后重试',
      );
      await tester.tap(find.byKey(const Key('witem-Guest-2.4G')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('wifi-pwd')), 'wrong-pwd');
      await tester.tap(find.byKey(const Key('wifi-connect')));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('wifi-error'))).data,
        contains('密码错误'),
      );

      gw.failWifiConnect = null;
      await tester.enterText(find.byKey(const Key('wifi-pwd')), 'correct-pwd');
      await tester.tap(find.byKey(const Key('wifi-connect')));
      await tester.pump();
      await tester.pump();
      expect(dev.wifiError, isNull);
      expect(dev.wifiLast, 'Guest-2.4G');

      await dev.wifiForget('Studio-2.4G');
      expect(dev.wifiSaved.any((w) => w.name == 'Studio-2.4G'), isFalse);

      await tester.tap(find.byKey(const Key('wifi-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('dev-upg')), findsOneWidget);

      // ⑦-B 配网后再回到固件更新页：展示 0.8.12 → 0.8.15，单阶段升级完成并自动重连刷新版本
      expect(
        tester.widget<Text>(find.byKey(const Key('fw-main-ver'))).data,
        '0.8.12 → 0.8.15',
      );
      expect(find.byKey(const Key('fw-wifi-ver')), findsNothing);
      expect(otaModules, everyElement('main'));

      final done = dev.startFwUpdate();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await done;
      await tester.pump();

      expect(gw.callLog, contains('ota.main'));
      expect(gw.callLog, isNot(contains('ota.wifi')));
      expect(dev.fwVersion, '0.8.15');
      expect(dev.fwVersionCode, 815);
      expect(dev.devStateText, '已更新到 0.8.15');
    },
  );

  testWidgets(
    '⑧ 三处 UI 对齐：点一机照片与记录在 Timeline (45px 缩略图) / 详情 (点一机抓拍) / 总结 (含 1 张图片) 呈现',
    (tester) async {
      final model = SummaryModel();
      const event = RecordEvent(
        id: 'v1-amr-1',
        dayOffset: 0,
        title: '点一机线下讨论',
        brief: '点一机实时与离线音频完成转写，准备同步现场拍照记录。',
        longText: '点一机实时与离线音频完成转写，准备同步现场拍照记录。',
        time: '19:30',
        dur: '01分00秒',
        speakers: '说话人 1（推测）',
        mark: '',
        srcMap: '来源 19:30—19:31',
        dialog: [
          TurnLine('说话人 1（推测）', '点一机离线音频已完成转写。', '19:30:10'),
        ],
        raw: [
          TurnLine('说话人 1（推测）', '点一机离线音频已完成转写。', '19:30:10'),
        ],
      );
      final store = AppStore(
        events: [event],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      store.eventPhotos[event.id] = const [
        EventPhoto(
          id: 'dyj_img_20261116-193020-001.jpg',
          path: '/nonexistent/dyj_cam.jpg',
          time: '19:30:20',
          source: 'dyj_camera',
        ),
      ];

      await pumpShell(tester, store: store, model: model);

      // 1) Timeline 45x45 缩略图
      final thumbFinder = find.byKey(Key('pics-${event.id}'));
      expect(thumbFinder, findsOneWidget);
      final thumbSize = tester.getSize(thumbFinder);
      expect(thumbSize.width, 45);
      expect(thumbSize.height, 45);

      // 2) 总结页统计行 & 总结卡「含 1 张图片」
      await generateWeekSummary(tester, model);
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('sum-sub'))).data,
        contains('含 1 张图片'),
      );
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();

      final sumId = store.summaries.first.id;
      expect(find.byKey(Key('sumpics-$sumId')), findsOneWidget);

      // 3) 展开记录进详情页：呈现「点一机抓拍」内联照片与转写对话
      await tester.tap(find.byKey(Key('card-${event.id}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('detail-${event.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('dphoto-${event.id}-0')), findsOneWidget);
      expect(find.text('点一机抓拍 · 19:30:20'), findsOneWidget);
      expect(find.text('点一机离线音频已完成转写。'), findsOneWidget);
    },
  );
}
