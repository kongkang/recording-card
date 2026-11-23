library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/model_stub.dart';

const bool _runLiveOmi = bool.fromEnvironment('RC_OMI_LIVE_E2E');
const bool _runStorageOmi = bool.fromEnvironment('RC_OMI_LIVE_STORAGE_E2E');
const String _artifactDir = String.fromEnvironment(
  'RC_OMI_E2E_ARTIFACT_DIR',
  defaultValue: '/tmp/omi_e2e_scratch',
);

class _NoopPhoneMicBackend implements PhoneMicBackend {
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
  }) async {}

  @override
  Future<void> stopCapture() async {}
}

class _TestLiveActivityService extends LiveActivityService {
  _TestLiveActivityService()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: false,
          supportsDynamicIsland: false,
          supportsActionButton: false,
          areActivitiesEnabled: false,
        ),
      );
}

class _EchoChat implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    final content = messages.last.content.trim();
    if (content.startsWith('[')) {
      final slices = jsonDecode(content) as List;
      return jsonEncode([
        for (final s in slices)
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
    return jsonEncode({
      'title': 'Omi 蓝牙硬件同步验证',
      'overview': '离线音频取回、转码、本地 VAD/ASR/声纹与分段验证',
    });
  }
}

class _AppAudioHarness {
  _AppAudioHarness({
    required this.device,
    required this.appStore,
    required this.recordingStatus,
    required this.liveAudio,
  }) {
    appStore.deviceConnected = () => device.isConnected;
    appStore.deviceRecording = () =>
        device.isRecording || device.isPhoneRecording;
    appStore.photoSyncEnabled = () => false;
    appStore.deviceGateway = () => device.gateway;
    appStore.flushActiveRecordingSlice = () async {
      if (liveAudio.isRunning) {
        return liveAudio.flushActiveSlice();
      }
      return false;
    };
    _sliceSub = liveAudio.slices.listen((slice) {
      final f = appStore.ingestLiveSlice(slice);
      _pendingIngests.add(f);
    });
    device.retainClock();
    device.addListener(_onDeviceChanged);
    _onDeviceChanged();
  }

  final DeviceStore device;
  final AppStore appStore;
  final RecordingStatusController recordingStatus;
  final LiveAudioRecorder liveAudio;

  late final StreamSubscription<LiveAudioSlice> _sliceSub;
  final List<Future<RecordingFile?>> _pendingIngests = [];
  bool _wasRecording = false;
  Future<void> _stopChain = Future<void>.value();

  void _onDeviceChanged() {
    final hwRecording = device.isRecording;
    final recording = hwRecording || device.isPhoneRecording;
    if (recording) {
      if (hwRecording && device.activeCapabilities.realtimeAudio) {
        liveAudio.updateDeviceSessionId(device.recordSession);
        if (!liveAudio.isRunning) {
          unawaited(liveAudio.start());
        }
      }
      if (!_wasRecording) {
        appStore.onLiveRecordingStarted();
        recordingStatus.startRecording();
      } else {
        recordingStatus.ensureRecording();
      }
      recordingStatus.updateElapsed(device.recSeconds);
    } else if (_wasRecording) {
      _wasRecording = false;
      _stopChain = _onStopped();
      return;
    }
    _wasRecording = recording;
  }

  Future<void> _drainPendingIngests() async {
    await liveAudio.pendingSliceWrites;
    while (_pendingIngests.isNotEmpty) {
      final batch = List<Future<RecordingFile?>>.of(_pendingIngests);
      _pendingIngests.clear();
      await Future.wait(batch);
    }
  }

  Future<void> _onStopped() async {
    final hadSamples = liveAudio.isRunning && liveAudio.recordedSeconds > 0;
    if (hadSamples) {
      recordingStatus.startSync(detail: '正在转写最后一段实时录音…');
    } else {
      recordingStatus.stopRecording();
    }
    await liveAudio.stop();
    await _drainPendingIngests();
    await appStore.finishLiveRecording();
    if (!device.isRecording) {
      recordingStatus.stopRecording();
    }
  }

  Future<void> waitForAllIngests() async {
    await _stopChain;
    await _drainPendingIngests();
  }

  Future<void> dispose() async {
    device.removeListener(_onDeviceChanged);
    device.releaseClock();
    await _sliceSub.cancel();
  }
}

DeviceStore _makeDeviceStore(
  CardGateway gateway,
  Directory tmpDir, {
  DateTime Function()? now,
}) {
  return DeviceStore(
    gateway: gateway,
    autoStart: false,
    now: now,
    phoneMicBackend: _NoopPhoneMicBackend(),
    liveActivityService: _TestLiveActivityService(),
    watchHardware: WatchHardwareService(
      backend: FakeWatchBridgeBackend(),
      historyFilePath: '${tmpDir.path}/watch_hist_${DateTime.now().microsecondsSinceEpoch}.json',
    ),
  );
}

Future<int?> _readOutputVolume() async {
  final res = await Process.run('osascript', [
    '-e',
    'output volume of (get volume settings)',
  ]);
  if (res.exitCode != 0) return null;
  return int.tryParse('${res.stdout}'.trim());
}

Future<void> _setOutputVolume(int vol) async {
  await Process.run('osascript', [
    '-e',
    'set volume output volume ${vol.clamp(0, 100)}',
  ]);
}

Future<int> _speak(String voice, String text) async {
  final sw = Stopwatch()..start();
  final res = await Process.run('say', [
    '-a',
    'Mac Studio扬声器',
    '-v',
    voice,
    text,
  ]);
  sw.stop();
  if (res.exitCode != 0) {
    throw StateError('say 失败 (${res.exitCode}): ${res.stderr}');
  }
  return sw.elapsedMilliseconds;
}

String _normalizeForCer(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
}

int _levenshtein(String a, String b) {
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final prev = List<int>.generate(b.length + 1, (j) => j);
  final curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    for (var j = 0; j <= b.length; j++) {
      prev[j] = curr[j];
    }
  }
  return prev[b.length];
}

double _charErrorRate(String expected, String actual) {
  final e = _normalizeForCer(expected);
  final a = _normalizeForCer(actual);
  if (e.isEmpty) return 0.0;
  final dist = _levenshtein(e, a);
  return double.parse((dist / e.length).toStringAsFixed(4));
}

Future<CardDevice> _scanForOmi(CardGateway gateway) async {
  final devices = await gateway.scan(timeoutMs: 8000);
  final omi = devices.where((d) => d.deviceKind == DeviceKind.omiCv1).firstOrNull;
  expect(omi, isNotNull, reason: '扫描结果中必须包含 Omi 设备 (严禁回退连接到 DYJV2)');
  return omi!;
}

Future<void> _safeDisconnect(CardGateway gateway) async {
  try {
    await gateway.closeRealtime();
  } on Object {
    // ignore
  }
  try {
    await gateway.stopRecording();
  } on Object {
    // ignore
  }
  try {
    await gateway.disconnect();
  } on Object {
    // ignore
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final evidenceDir = Directory('$_artifactDir/evidence');
  final modelsDir = Directory('$_artifactDir/models');
  late Directory workRoot;
  int? initialVolume;

  setUpAll(() async {
    await evidenceDir.create(recursive: true);
    workRoot = Directory('$_artifactDir/dart_e2e_work');
    if (await workRoot.exists()) {
      await workRoot.delete(recursive: true);
    }
    await workRoot.create(recursive: true);

    if (_runLiveOmi || _runStorageOmi) {
      initialVolume = await _readOutputVolume();
      await _setOutputVolume(55);
    }
  });

  tearDownAll(() async {
    if (_runLiveOmi || _runStorageOmi) {
      final gw = RealCardGateway.maybe();
      if (gw != null) {
        await _safeDisconnect(gw);
      }
      if (initialVolume != null) {
        await _setOutputVolume(initialVolume!);
      }
    }
  });

  group(
    'Omi 实时流与项目全链路端到端测试 (macOS CoreBluetooth + FFI + SenseVoice/Campplus)',
    skip: _runLiveOmi ? null : '需传入 --dart-define=RC_OMI_LIVE_E2E=true 连接真实 Omi 硬件执行',
    () {
      final reportFile = File('${evidenceDir.path}/phase2_dart_pipeline.json');
      final existingTests = <String, dynamic>{};
      if (reportFile.existsSync()) {
        try {
          final prev = jsonDecode(reportFile.readAsStringSync());
          if (prev is Map && prev['tests'] is Map) {
            existingTests.addAll(Map<String, dynamic>.from(prev['tests'] as Map));
          }
        } on Object {
          // ignore malformed prior file
        }
      }
      final report = <String, dynamic>{
        'generatedAtIso': DateTime.now().toIso8601String(),
        'platform': Platform.operatingSystem,
        'tests': existingTests,
      };

      void saveReport() {
        report['generatedAtIso'] = DateTime.now().toIso8601String();
        reportFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report),
        );
      }

      test('2.1 扫描过滤门控、型号识别与 60s 扫描过期机制 (DeviceStore)', () async {
        final gateway = RealCardGateway.maybe();
        expect(gateway, isNotNull, reason: 'RC_CARD_BRIDGE_LIB 应成功加载 libcard_bridge.dylib');
        expect(gateway!.bridgeVersion, contains('card_bridge/'));
        expect(gateway.bridgeVersion, contains('omi/'));

        var fakeOffset = Duration.zero;
        final tmp = await workRoot.createTemp('t21_');
        final store = _makeDeviceStore(
          gateway,
          tmp,
          now: () => DateTime.now().add(fakeOffset),
        );

        // 1) 默认关闭 Omi 开关时，扫描应过滤掉 Omi（且若周围有 DYJV2 则只见自研）
        final rawScan = await gateway.scan(timeoutMs: 7000);
        expect(
          rawScan.any((d) => d.deviceKind == DeviceKind.omiCv1),
          isTrue,
          reason: '底层 BLE 扫描应实际发现 Omi',
        );

        await store.startScan();
        expect(
          store.discovered.any((d) => d.deviceKind == DeviceKind.omiCv1),
          isFalse,
          reason: 'omiLinkEnabled=false 时 DeviceStore 必须屏蔽 Omi',
        );

        // 2) 开启 Omi 联动并重新扫描
        await store.setExtHardwareEnabled(omi: true);
        await store.startScan();
        final omi = store.discovered
            .where((d) => d.deviceKind == DeviceKind.omiCv1)
            .firstOrNull;
        expect(omi, isNotNull, reason: 'omiLinkEnabled=true 后扫描列表必须出现 Omi');
        expect(omi!.modelLabel, 'Omi 录音器');
        expect(omi.rssi, isNotNull);
        expect(omi.resolvedCapabilities.realtimeAudio, isTrue);
        expect(omi.resolvedCapabilities.hasOnboardStorage, isTrue);
        expect(omi.resolvedCapabilities.hasFileSync, isTrue);
        expect(omi.resolvedCapabilities.hasWifiConfig, isFalse);
        expect(omi.resolvedCapabilities.hasCameraMedia, isFalse);
        expect(omi.resolvedCapabilities.hasRemoteRecordControl, isTrue);
        expect(omi.resolvedCapabilities.hasMarkButton, isTrue);
        expect(omi.resolvedCapabilities.hasConfigurableButtons, isTrue);
        expect(omi.resolvedCapabilities.otaMode, 'none');

        // 3) 60s 过期校验：48s 时未过期，推进到 62s 后过期并阻止连接
        expect(store.isBleScanExpired, isFalse);
        fakeOffset = const Duration(seconds: 48);
        expect(store.isBleScanExpired, isFalse);
        expect(store.isDeviceScanExpired(omi), isFalse);
        fakeOffset = const Duration(seconds: 62);
        expect(store.isBleScanExpired, isTrue);
        expect(store.isDeviceScanExpired(omi), isTrue);

        await store.connectTo(omi);
        expect(store.isConnected, isFalse);
        expect(store.linkError, '蓝牙设备列表已过期，请重新扫描');

        store.dispose();
        report['tests']['2_1_scan_gating_expiry'] = {
          'passed': true,
          'bridgeVersion': gateway.bridgeVersion,
          'rawDiscoveredCount': rawScan.length,
          'omiId': omi.id,
          'omiName': omi.name,
          'omiRssi': omi.rssi,
          'filteredWhenDisabled': true,
          'visibleWhenEnabled': true,
          'expiredAfter60s': true,
        };
        saveReport();
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('2.2 CardGateway / card_bridge 全命令接口契约与防御边界验证', () async {
        final gateway = RealCardGateway.maybe()!;
        final tmp = await workRoot.createTemp('t22_');
        final device = _makeDeviceStore(gateway, tmp);
        await device.setExtHardwareEnabled(omi: true);

        final metrics = <String, dynamic>{};
        Future<T> timed<T>(String key, Future<T> Function() fn) async {
          final sw = Stopwatch()..start();
          final res = await fn();
          sw.stop();
          metrics[key] = {'ok': true, 'ms': sw.elapsedMilliseconds};
          return res;
        }

        await timed('scan', () => device.startScan());
        final omi = device.discovered
            .where((d) => d.deviceKind == DeviceKind.omiCv1)
            .first;

        await timed('connect', () => device.connectTo(omi));
        expect(device.isConnected, isTrue, reason: device.linkError ?? '建连失败');
        expect(device.activeKind, DeviceKind.omiCv1);
        expect(device.battery, greaterThan(0));
        expect(device.fwVersion, isNotEmpty);
        expect(device.batteryLevelText.contains('%'), isFalse);
        expect(device.batteryLevelText.contains('已充满'), isFalse);
        expect(device.deviceSubtitleText, '固件 ${device.fwVersion}');

        final snap = await timed('snapshot', () => gateway.snapshot());
        expect(snap.effectiveKind, DeviceKind.omiCv1);
        expect(snap.resolvedCapabilities.hasConfigurableButtons, isTrue);
        expect(snap.batteryLevel, greaterThan(0));

        final ringFiles = await timed('files', () => gateway.files());
        for (final f in ringFiles) {
          expect(f.name, startsWith('OMI_RING_'));
        }

        await timed('syncTime', () => gateway.syncTime());

        await timed('startRecording', () => gateway.startRecording());
        final snapRec = await gateway.snapshot();
        expect(snapRec.recording, isTrue);
        expect(snapRec.recordSession, startsWith('OMI_'));

        final batch = await timed('pullEvents', () => gateway.pullEvents());
        expect(batch.recordEvents, isNotEmpty);

        await timed('mark', () => gateway.mark());

        await timed('stopRecording', () => gateway.stopRecording());
        final snapStop = await gateway.snapshot();
        expect(snapStop.recording, isFalse);

        await timed('record_toggle_on', () => gateway.record('toggle'));
        expect((await gateway.snapshot()).recording, isTrue);
        await timed('record_toggle_off', () => gateway.record('toggle'));
        expect((await gateway.snapshot()).recording, isFalse);

        // 双重订阅 realtime.open 单例防竞态测试
        final sub1Events = <RealtimeAudioKind>[];
        final sub2Events = <RealtimeAudioKind>[];
        final sub1Opened = Completer<void>();
        final sub2Opened = Completer<void>();
        final sub1 = gateway.realtimeAudio().listen((e) {
          sub1Events.add(e.kind);
          if (e.kind == RealtimeAudioKind.open && !sub1Opened.isCompleted) {
            sub1Opened.complete();
          }
        });
        await sub1Opened.future.timeout(const Duration(seconds: 5));
        final sub2 = gateway.realtimeAudio().listen((e) {
          sub2Events.add(e.kind);
          if (e.kind == RealtimeAudioKind.open && !sub2Opened.isCompleted) {
            sub2Opened.complete();
          }
        });
        await sub2Opened.future.timeout(const Duration(seconds: 5));
        await timed('closeRealtime', () => gateway.closeRealtime());
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await sub1.cancel();
        await sub2.cancel();
        expect(sub1Events, contains(RealtimeAudioKind.open));
        expect(sub2Events, contains(RealtimeAudioKind.open));

        // 能力门控/防御接口全覆盖
        expect(await timed('scanWifi', () => gateway.scanWifi()), isEmpty);
        expect(
          await timed(
            'wifiCredentials_passive',
            () => gateway.wifiCredentials(passive: true),
          ),
          isEmpty,
        );
        expect(
          await timed(
            'wifiCredentials_active',
            () => gateway.wifiCredentials(passive: false),
          ),
          isEmpty,
        );
        await timed('openWifi', () => gateway.openWifi());
        await timed('closeWifi', () => gateway.closeWifi());
        await timed('forgetWifi', () => gateway.forgetWifi('TestSSID'));
        await expectLater(
          gateway.connectWifi('TestSSID', '12345678'),
          throwsA(isA<CardException>()),
        );
        metrics['connectWifi_rejected'] = {'ok': true};
        expect(
          await timed('syncCameraPhotos', () => gateway.syncCameraPhotos(tmp.path)),
          isEmpty,
        );
        await timed('startSync', () => gateway.startSync());
        final st = await timed('syncStatus', () => gateway.syncStatus());
        expect(st.running, isFalse);
        await expectLater(
          gateway.invokeBridgeCommand('ap.start'),
          throwsA(isA<CardException>()),
        );
        metrics['apStart_rejected'] = {'ok': true};
        await timed('apStop', () => gateway.invokeBridgeCommand('ap.stop'));

        // 断开并重连验证（确认 CoreBluetooth 断开不再挂起，< 3.5s 完成释放）
        await timed('disconnectSafely', () => device.disconnectSafely());
        expect(device.isConnected, isFalse);
        expect(
          (metrics['disconnectSafely'] as Map<String, dynamic>)['ms'] as int,
          lessThan(3500),
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        await timed('rescan', () => device.startScan());
        final omi2 = device.discovered
            .where((d) => d.deviceKind == DeviceKind.omiCv1)
            .firstOrNull;
        expect(omi2, isNotNull, reason: '断开后 Omi 应恢复广播');
        await timed('reconnect', () => device.connectTo(omi2!));
        expect(device.isConnected, isTrue);
        await device.disconnectSafely();
        device.dispose();

        report['tests']['2_2_gateway_contract'] = {
          'passed': true,
          'snapshot': {
            'deviceName': snap.deviceName,
            'fwVersion': snap.fwVersion,
            'battery': snap.batteryLevel,
            'isCharging': snap.isCharging,
          },
          'commands': metrics,
        };
        saveReport();
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('2.3 多场景声学发音 → Omi 拾音 → 本地 VAD + SenseVoice + Campplus 准确率测试', () async {
        final gateway = RealCardGateway.maybe()!;
        final installer = ModelInstaller(root: modelsDir);
        expect((await installer.status(sileroVadSpec)).installed, isTrue);
        expect((await installer.status(senseVoiceSpec)).installed, isTrue);
        expect((await installer.status(campplusEmbeddingSpec)).installed, isTrue);

        final omi = await _scanForOmi(gateway);
        await gateway.connect(
          omi.id,
          name: omi.name,
          deviceKind: omi.deviceKind.code,
        );

        final storeDir = await workRoot.createTemp('t23_store_');
        final liveDir = await workRoot.createTemp('t23_live_');
        final store = RecordingStore(
          root: storeDir,
          jsonStore: JsonStore(store: InMemoryStore()),
        );
        final asr = LocalAsrService();
        final pipeline = RecordingPipeline(
          gateway: gateway,
          store: store,
          engine: asr,
          models: InstalledSpeechModelProvider(installer),
          liveAudioBaseDir: liveDir,
        );

        final corpora = <({
          String id,
          String expectedText,
          List<String> keywords,
          List<({String voice, String text, int pauseAfterMs})> turns,
        })>[
          (
            id: 'A_zh_daily',
            expectedText: '今天是十一月十九日，我们正在进行欧米蓝牙硬件端到端自动化测试，验证实时音频流与本地语音转写是否准确。',
            keywords: ['十一月十九', '蓝牙', '硬件', '测试', '音频', '转写'],
            turns: [
              (
                voice: 'Flo (中文（中国大陆）)',
                text: '今天是十一月十九日，我们正在进行欧米蓝牙硬件端到端自动化测试，验证实时音频流与本地语音转写是否准确。',
                pauseAfterMs: 1200,
              ),
            ],
          ),
          (
            id: 'B_zh_numbers',
            expectedText: '请记录一下，明天上午十点三十分召开产品评审会议，研发预算控制在五万八千元以内。',
            keywords: ['明天', '上午', '十点', '三十分', '评审', '预算'],
            turns: [
              (
                voice: 'Eddy (中文（中国大陆）)',
                text: '请记录一下，明天上午十点三十分召开产品评审会议，研发预算控制在五万八千元以内。',
                pauseAfterMs: 1200,
              ),
            ],
          ),
          (
            id: 'C_en_tech',
            expectedText:
                'Bluetooth audio streaming and local speech recognition test completed successfully.',
            keywords: ['bluetooth', 'audio', 'speech', 'recognition', 'test', 'completed'],
            turns: [
              (
                voice: 'Flo (英语（美国）)',
                text:
                    'Bluetooth audio streaming and local speech recognition test completed successfully.',
                pauseAfterMs: 1200,
              ),
            ],
          ),
          (
            id: 'D_multi_speaker',
            expectedText:
                '你好，请问蓝牙实时切片和声纹聚类的联调准备好了吗？已经全部准备好了，采样率是一万六千赫兹，单声道十六位编码。非常好，那我们把完整的测试数据和音频保存下来。',
            keywords: ['你好', '蓝牙', '切片', '声纹', '采样率', '保存'],
            turns: [
              (
                voice: 'Flo (中文（中国大陆）)',
                text: '你好，请问蓝牙实时切片和声纹聚类的联调准备好了吗？',
                pauseAfterMs: 1400,
              ),
              (
                voice: 'Eddy (中文（中国大陆）)',
                text: '已经全部准备好了，采样率是一万六千赫兹，单声道十六位编码。',
                pauseAfterMs: 1400,
              ),
              (
                voice: 'Flo (中文（中国大陆）)',
                text: '非常好，那我们把完整的测试数据和音频保存下来。',
                pauseAfterMs: 1200,
              ),
            ],
          ),
        ];

        final corpusResults = <String, dynamic>{};

        for (final c in corpora) {
          final recorder = LiveAudioRecorder(
            gateway: gateway,
            baseDir: liveDir,
            sliceDuration: const Duration(minutes: 1),
          );
          final slices = <LiveAudioSlice>[];
          final sub = recorder.slices.listen(slices.add);

          await gateway.startRecording();
          await recorder.start();
          await Future<void>.delayed(const Duration(milliseconds: 500));

          for (final t in c.turns) {
            await _speak(t.voice, t.text);
            await Future<void>.delayed(Duration(milliseconds: t.pauseAfterMs));
          }
          // 等待 Omi VAD hang-time 排空尾部包
          await Future<void>.delayed(const Duration(seconds: 2));

          final recSecs = recorder.recordedSeconds;
          final session = await recorder.stop();
          await gateway.stopRecording();
          await recorder.pendingSliceWrites;
          await sub.cancel();
          recorder.dispose();

          expect(slices, isNotEmpty, reason: '${c.id} 应至少封口 1 个切片');
          RecordingFile? processed;
          for (final s in slices) {
            processed = await pipeline.ingestLiveSlice(s);
          }
          expect(processed, isNotNull);
          expect(processed!.stage, RecordingStage.ready);
          expect(processed.utterances, isNotEmpty, reason: '${c.id} SenseVoice 应识别出文本');

          final fullTranscript =
              processed.utterances.map((u) => u.text.trim()).join(' ');
          final cer = _charErrorRate(c.expectedText, fullTranscript);
          final lowerFull = fullTranscript.toLowerCase();
          final hitCount =
              c.keywords.where((k) => lowerFull.contains(k.toLowerCase())).length;

          corpusResults[c.id] = {
            'expected': c.expectedText,
            'transcript': fullTranscript,
            'cer': cer,
            'keywordHits': hitCount,
            'keywordTotal': c.keywords.length,
            'recordedSeconds': double.parse(recSecs.toStringAsFixed(2)),
            'gapCount': session?.gapCount ?? 0,
            'vadSlices': processed.slices.length,
            'utterances': [
              for (final u in processed.utterances)
                {
                  'startMs': u.startMs,
                  'endMs': u.endMs,
                  'text': u.text,
                  'lang': u.lang,
                  'emotion': u.emotion,
                  'speakerCluster': u.speakerCluster,
                  'speakerLabel': u.speakerLabel,
                  'spkConfidence': u.spkConfidence,
                },
            ],
          };
          expect(
            hitCount,
            greaterThanOrEqualTo(2),
            reason: '${c.id} 关键词命中过低: "$fullTranscript"',
          );
        }

        await asr.dispose();
        await _safeDisconnect(gateway);

        report['tests']['2_3_asr_and_speaker_accuracy'] = {
          'passed': true,
          'corpora': corpusResults,
        };
        saveReport();
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('2.4 录音进行中下拉刷新手动冲刷切片 (AppStore.syncRecordings + flushActiveSlice + 紧邻合并)', () async {
        final gateway = RealCardGateway.maybe()!;
        final tmp = await workRoot.createTemp('t24_');
        final device = _makeDeviceStore(gateway, tmp);
        await device.setExtHardwareEnabled(omi: true);

        final installer = ModelInstaller(root: modelsDir);
        final asr = LocalAsrService();
        final store = RecordingStore(
          root: Directory('${tmp.path}/recordings'),
          jsonStore: JsonStore(store: InMemoryStore()),
        );
        final liveDir = Directory('${tmp.path}/live');
        final pipeline = RecordingPipeline(
          gateway: gateway,
          store: store,
          engine: asr,
          models: InstalledSpeechModelProvider(installer),
          liveAudioBaseDir: liveDir,
        );
        final appStore = AppStore(
          jsonStore: JsonStore(store: InMemoryStore()),
          loadPersistedState: false,
        );
        final recStatus = RecordingStatusController();
        appStore.attachPipeline(
          pipeline: pipeline,
          store: store,
          generator: await SummaryModel().generator(),
          status: recStatus,
        );
        final liveAudio = LiveAudioRecorder(
          gateway: gateway,
          baseDir: liveDir,
          sliceDuration: const Duration(minutes: 1),
        );
        final harness = _AppAudioHarness(
          device: device,
          appStore: appStore,
          recordingStatus: recStatus,
          liveAudio: liveAudio,
        );
        addTearDown(() async {
          await harness.dispose();
          liveAudio.dispose();
          if (device.isConnected) {
            await device.disconnectSafely();
          }
          device.dispose();
          appStore.dispose();
          recStatus.dispose();
          await asr.dispose();
        });

        await device.startScan();
        final omi = device.discovered
            .where((d) => d.deviceKind == DeviceKind.omiCv1)
            .first;
        await device.connectTo(omi);
        expect(device.isConnected, isTrue);

        await device.toggleRecording();
        expect(device.isRecording, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(liveAudio.isRunning, isTrue);

        // 刚开录且尚无足够语音缓冲 (<0.5s) 时下拉，应触发防碎片提示
        final sync0DebounceMsg = await appStore.syncRecordings();
        expect(sync0DebounceMsg, '当前语音刚同步，继续说话后可随时下拉转写');
        await Future<void>.delayed(const Duration(milliseconds: 250));

        // 第 1 段语音
        await _speak(
          'Flo (中文（中国大陆）)',
          '第一段实时录音测试，验证不断流状态下下拉刷新立刻转写。',
        );
        await Future<void>.delayed(const Duration(milliseconds: 2000));
        expect(device.isRecording, isTrue);
        expect(liveAudio.isRunning, isTrue);

        // 下拉刷新冲刷第 1 片（不中断录音）
        final sync1Err = await appStore.syncRecordings();
        expect(sync1Err, isNull);
        await harness.waitForAllIngests();
        expect(device.isRecording, isTrue, reason: '手动冲刷切片不得停止正在进行的录音');
        expect(liveAudio.isRunning, isTrue);
        final filesAfterFlush = await store.loadAll(refresh: true);
        expect(filesAfterFlush.length, greaterThanOrEqualTo(1));
        expect(filesAfterFlush.first.stage, RecordingStage.ready);
        expect(appStore.events, isNotEmpty);

        // 第 2 段紧邻语音（间隔 <30s）
        await _speak(
          'Eddy (中文（中国大陆）)',
          '第二段实时录音测试，停录后冲刷尾片并与前一片紧邻合并。',
        );
        await Future<void>.delayed(const Duration(milliseconds: 2500));

        // 停止录音，等待尾片冲刷转写完成
        await device.toggleRecording();
        expect(device.isRecording, isFalse);
        await harness.waitForAllIngests();

        final filesAfterStop = await store.loadAll(refresh: true);
        expect(filesAfterStop.length, greaterThanOrEqualTo(2));
        expect(filesAfterStop.every((f) => f.stage == RecordingStage.ready), isTrue);

        final mergedEventCount = appStore.events.length;
        final mergedView = appStore.segmentViewFor(appStore.events.first.id);
        final mergedChildrenCount = mergedView?.mergedChildren.length ?? 1;

        await device.disconnectSafely();

        expect(mergedEventCount, 1, reason: '<30s 紧邻两段有声切片应在 Timeline 合并为 1 条记录');
        expect(mergedChildrenCount, filesAfterStop.length);

        report['tests']['2_4_flush_and_merge'] = {
          'passed': true,
          'sync1Error': sync1Err,
          'sync2DebounceHint': sync0DebounceMsg,
          'storedSliceFiles': filesAfterStop.map((f) => f.deviceName).toList(),
          'timelineMergedEventsCount': mergedEventCount,
          'mergedChildrenCount': mergedChildrenCount,
          'mergedTitle': appStore.events.first.title,
          'mergedUtteranceCount': mergedView?.utterances.length ?? 0,
        };
        saveReport();
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('2.5 >2 分钟连续滚动切片 + 尾片冲刷 + 100s+ 长流稳定性 (macOS)', () async {
        final gateway = RealCardGateway.maybe()!;
        final tmp = await workRoot.createTemp('t25_');
        final device = _makeDeviceStore(gateway, tmp);
        await device.setExtHardwareEnabled(omi: true);

        final installer = ModelInstaller(root: modelsDir);
        final asr = LocalAsrService();
        final store = RecordingStore(
          root: Directory('${tmp.path}/recordings'),
          jsonStore: JsonStore(store: InMemoryStore()),
        );
        final liveDir = Directory('${tmp.path}/live');
        final pipeline = RecordingPipeline(
          gateway: gateway,
          store: store,
          engine: asr,
          models: InstalledSpeechModelProvider(installer),
          liveAudioBaseDir: liveDir,
        );
        final appStore = AppStore(
          jsonStore: JsonStore(store: InMemoryStore()),
          loadPersistedState: false,
        );
        final recStatus = RecordingStatusController();
        appStore.attachPipeline(
          pipeline: pipeline,
          store: store,
          generator: await SummaryModel().generator(),
          status: recStatus,
        );
        final liveAudio = LiveAudioRecorder(
          gateway: gateway,
          baseDir: liveDir,
          sliceDuration: const Duration(minutes: 1),
        );
        final harness = _AppAudioHarness(
          device: device,
          appStore: appStore,
          recordingStatus: recStatus,
          liveAudio: liveAudio,
        );
        addTearDown(() async {
          await harness.dispose();
          liveAudio.dispose();
          if (device.isConnected) {
            await device.disconnectSafely();
          }
          device.dispose();
          appStore.dispose();
          recStatus.dispose();
          await asr.dispose();
        });

        await device.startScan();
        final omi = device.discovered
            .where((d) => d.deviceKind == DeviceKind.omiCv1)
            .first;
        await device.connectTo(omi);
        await device.toggleRecording();
        expect(device.isRecording, isTrue);

        // 连续朗读 6 句较长段落，持续 ~135 秒以突破 100s 临界点且积累 >120s 实录 PCM（触发 3 个滚动切片）
        final paragraphs = [
          (
            voice: 'Flo (中文（中国大陆）)',
            text:
                '第一段长流稳定性测试开始。现在测试的是跨一分钟滚动切片与端侧实时语音识别能力。我们正在验证蓝牙低功耗链路在持续音频传输时的稳定性、帧序号连续性以及声学编码质量，一二三四五六七八九十。',
          ),
          (
            voice: 'Eddy (中文（中国大陆）)',
            text:
                '第二段测试语音接续播报。现在已经进入三十秒左右的音频积累区间，即将接近第一分钟自动封口门限。系统会在满六十秒时把当前内存缓冲中的一万六千赫兹单声道音频写入切片文件并立即送去转写。',
          ),
          (
            voice: 'Flo (中文（中国大陆）)',
            text:
                '第三段测试继续进行，目前录音时长已经跨越一分钟节点。我们继续用标准普通话朗读长句子，验证第二片实时音频的连续接收是否流畅，同时检测声纹聚类和时间戳相对偏移的计算是否正确无误。',
          ),
          (
            voice: 'Eddy (中文（中国大陆）)',
            text:
                '第四段测试正在跨越一百秒关键窗口。此前在安卓旧版本上曾经观察到大约一百秒后断流的疑似现象，现在我们在苹果桌面平台持续发声超过两分钟，全面验证核心蓝牙与俄米固件的长时音频推流表现。',
          ),
          (
            voice: 'Flo (中文（中国大陆）)',
            text:
                '第五段测试即将触发第二个六十秒切片封口，同时为最终尾片积累足够的可识别语料。现在复述一遍关键校验指标，采样率一万六千，单声道十六比特，丢包率为零，切片连续无中断。',
          ),
          (
            voice: 'Eddy (中文（中国大陆）)',
            text:
                '第六段也是最后一段尾片测试语音。即将执行停止录音指令，系统应当立刻关闭实时音频通道，冲刷封口第三片尾部音频，并把三段切片全部完成本地识别并合并展示在时间轴上。',
          ),
        ];

        final telemetry = <Map<String, dynamic>>[];
        final testSw = Stopwatch()..start();
        final timer = Timer.periodic(const Duration(seconds: 10), (_) {
          telemetry.add({
            'wallSec': testSw.elapsed.inSeconds,
            'recordedSeconds':
                double.parse(liveAudio.recordedSeconds.toStringAsFixed(2)),
            'gapCount': liveAudio.session?.gapCount ?? 0,
            'sealedSlices': liveAudio.session?.sliceKeys.length ?? 0,
          });
        });

        for (var i = 0; i < paragraphs.length; i++) {
          await _speak(paragraphs[i].voice, paragraphs[i].text);
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
        // 确保累计时间至少 125s 并且如果 receivedSeconds < 123s 再补播短语（设安全上限防死循环）
        var extraLoops = 0;
        while ((testSw.elapsed.inSeconds < 125 ||
                liveAudio.recordedSeconds < 123.0) &&
            extraLoops < 10 &&
            testSw.elapsed.inSeconds < 210) {
          extraLoops++;
          await _speak(
            'Flo (中文（中国大陆）)',
            '补充连续语音窗口，确保实录有效音频超过两分钟，触发完整三切片滚动验证。',
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        timer.cancel();
        testSw.stop();

        final totalWallSec = testSw.elapsed.inSeconds;
        final totalRecordedSec = liveAudio.recordedSeconds;
        final sessionId = liveAudio.session?.id;

        await device.toggleRecording();
        await harness.waitForAllIngests();

        expect(sessionId, isNotNull);
        final persistedSession =
            await LiveAudioRecorder.readSession(sessionId!, baseDir: liveDir);
        expect(persistedSession, isNotNull);
        expect(
          persistedSession!.sliceKeys.length,
          greaterThanOrEqualTo(3),
          reason: '>120s 实录 PCM 应产生至少 3 个滚动切片（2 个 60s 整片 + 1 个尾片）',
        );

        final storedFiles = await store.loadAll(refresh: true);
        expect(storedFiles.length, persistedSession.sliceKeys.length);
        for (final f in storedFiles) {
          expect(f.stage, RecordingStage.ready);
          expect(f.wavPath, isNotNull);
          final wav = parseWav(File(f.wavPath!).readAsBytesSync());
          expect(wav.sampleRate, 16000);
          expect(wav.isMono16, isTrue);
          expect(wav.frames, greaterThan(0));
        }

        final mainWavPath =
            await LiveAudioRecorder.audioPathOf(sessionId, baseDir: liveDir);
        expect(mainWavPath, isNotNull);
        final fullWav = parseWav(File(mainWavPath!).readAsBytesSync());

        final discSnap = device.isConnected;
        expect(discSnap, isTrue);
        await device.disconnectSafely();
        expect(device.isConnected, isFalse);

        final finalEvents = appStore.events;
        final firstView =
            finalEvents.isNotEmpty ? appStore.segmentViewFor(finalEvents.first.id) : null;

        report['tests']['2_5_long_rolling_slices'] = {
          'passed': true,
          'wallElapsedSec': totalWallSec,
          'recordedPcmSec': double.parse(totalRecordedSec.toStringAsFixed(2)),
          'fullWavDurationMs': fullWav.durationMs,
          'gapCount': persistedSession.gapCount,
          'spansCount': persistedSession.spans.length,
          'sliceKeys': persistedSession.sliceKeys,
          'telemetryEvery10s': telemetry,
          'slices': [
            for (final f in storedFiles.reversed)
              {
                'deviceName': f.deviceName,
                'durationMs': f.durationMs,
                'utterances': f.utterances.map((u) => u.text).join(' '),
              },
          ],
          'timelineEventsCount': finalEvents.length,
          'mergedViewChildren': firstView?.mergedChildren.length ?? 1,
        };
        saveReport();
      }, timeout: const Timeout(Duration(minutes: 6)));
    },
  );

  group(
    'Omi 板载存储离线同步端到端测试 (files → download → transcode → ASR → deleteFile)',
    skip: _runStorageOmi
        ? null
        : '需传入 --dart-define=RC_OMI_LIVE_STORAGE_E2E=true 执行板载存储测试',
    () {
      test('4B.1 离线 Ring Buffer 文件列表、下载转码、端侧转写分段与游标推进', () async {
        final gateway = RealCardGateway.maybe()!;
        final installer = ModelInstaller(root: modelsDir);
        await _speak(
          'Flo (中文（中国大陆）)',
          '现在进行欧米离线板载存储录制测试，验证环形缓冲下载转码与本地转写闭环。',
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        final omi = await _scanForOmi(gateway);
        await gateway.connect(
          omi.id,
          name: omi.name,
          deviceKind: omi.deviceKind.code,
        );

        var fileList = await gateway.files();
        if (fileList.isEmpty) {
          await _speak(
            'Flo (中文（中国大陆）)',
            '补充录制板载存储测试语音，验证离线同步下载转码与本地转写闭环。',
          );
          await Future<void>.delayed(const Duration(seconds: 2));
          fileList = await gateway.files();
        }
        expect(fileList, isNotEmpty, reason: 'Omi Ring Buffer 应存在待同步录音条目');
        final target = fileList.first;
        expect(target.name, startsWith('OMI_RING_'));
        expect(target.isWav, isTrue);
        expect(target.isAudioRecording, isTrue);
        expect(target.size, greaterThan(0));

        final storeDir = await workRoot.createTemp('t4b_store_');
        final store = RecordingStore(
          root: storeDir,
          jsonStore: JsonStore(store: InMemoryStore()),
        );
        final asr = LocalAsrService();
        final chat = _EchoChat();
        final pipeline = RecordingPipeline(
          gateway: gateway,
          store: store,
          engine: asr,
          models: InstalledSpeechModelProvider(installer),
          polish: SlicePolishService(chat: chat, model: 'echo'),
          segments: SegmentBuildService(chat: chat, model: 'echo'),
        );

        final sw = Stopwatch()..start();
        final syncRes = await pipeline.sync(maxFiles: 1);
        sw.stop();
        expect(syncRes.downloaded, 1);
        expect(syncRes.ready, 1);
        expect(syncRes.failed, 0);

        final syncedFiles = await store.loadAll(refresh: true);
        expect(syncedFiles, isNotEmpty);
        final f = syncedFiles.first;
        expect(f.stage, RecordingStage.ready);
        expect(f.durationMs, greaterThan(0));
        if (f.slices.isNotEmpty) {
          expect(f.utterances, isNotEmpty);
          expect(f.turns, isNotEmpty);
          expect(f.segments, isNotEmpty);
        }

        // 删除(推进游标)并验证 files() 更新
        await gateway.deleteFile(target.name);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final afterDelete = await gateway.files();
        expect(
          afterDelete.any((item) => item.name == target.name),
          isFalse,
          reason: 'deleteFile 推进 read_seq 后旧文件范围不应再重复返回',
        );

        // Omi 仅在未连蓝牙（离线态）向板载 Ring Buffer 写入新记录：先断连播报再重连测试 takeOldestFile
        await gateway.disconnect();
        await Future<void>.delayed(const Duration(seconds: 2));
        await _speak(
          'Eddy (中文（中国大陆）)',
          '测试离线态板载存储写入，重连后验证原子取回最旧文件并自动推进游标功能。',
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        final omiRe = await _scanForOmi(gateway);
        await gateway.connect(
          omiRe.id,
          name: omiRe.name,
          deviceKind: omiRe.deviceKind.code,
        );
        final beforeTake = await gateway.files();
        Map<String, dynamic>? takeResult;
        if (beforeTake.isNotEmpty) {
          final dlDir = await workRoot.createTemp('t4b_take_');
          final taken = await gateway.takeOldestFile(dlDir.path);
          final wavOut = '${taken.path}.norm.wav';
          final transcoded = await gateway.transcode(taken.path, wavOut);
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final afterTake = await gateway.files();
          takeResult = {
            'takenName': taken.originalName,
            'bytesWritten': taken.bytesWritten,
            'transcodedSamples': transcoded.samples,
            'transcodedDurationSecs': transcoded.durationSecs,
            'afterTakeCount': afterTake.length,
          };
          expect(taken.bytesWritten, greaterThan(0));
          expect(transcoded.samples, greaterThan(0));
        }

        await asr.dispose();
        await _safeDisconnect(gateway);

        final outJson = {
          'generatedAtIso': DateTime.now().toIso8601String(),
          'targetFile': {'name': target.name, 'size': target.size},
          'syncElapsedMs': sw.elapsedMilliseconds,
          'recordingFile': {
            'durationMs': f.durationMs,
            'slices': f.slices.length,
            'utterances': [for (final u in f.utterances) u.text],
            'turnsCount': f.turns.length,
            'segments': [
              for (final s in f.segments) {'title': s.title, 'brief': s.brief},
            ],
          },
          'afterDeleteFiles': [for (final it in afterDelete) it.name],
          'takeOldestFile': takeResult,
        };
        File('${evidenceDir.path}/phase4b_dart_storage.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(outJson),
        );
      }, timeout: const Timeout(Duration(minutes: 5)));
    },
  );
}
