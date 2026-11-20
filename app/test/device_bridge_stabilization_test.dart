// 硬件桥与 DeviceStore 稳定性回归单测（TDD）：
//
// 1. DYJ V2 物理按键事件（CardV2Event::Button）归一化手势（single->click, double->double_click,
//    long->long_press, long_release->long_press_end）并保留原始 button / rawGesture / action 字段；
// 2. DYJ V1 `dyj_tts_speak` 前向兼容探测：0.8.14 固件返回 code=1001 时透传清晰 `unsupported` 错误且不断连；
// 3. DYJ V2 下载活跃度看门狗（75s 无进度超时，有进度续期）：突破旧版硬编码 10 分钟上限（如 10m30s 正常完成），
//    零进度卡死满 75 秒准时超时；
// 4. 录音中快速掉线保底接力（recordingHeartbeatIdle <= 12s）：蓝牙静默断链在 12 秒内拉起手机麦克风保底，
//    实时音频流持续收包期间零额外抢占探测。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';

import 'support/fake_gateway.dart';

class _FakePhoneMicBackend implements PhoneMicBackend {
  PhoneMicPermission permission = PhoneMicPermission.granted;
  int startCaptureCalls = 0;
  int stopCaptureCalls = 0;
  bool capturing = false;

  @override
  Future<PhoneMicPermission> checkPermission() async => permission;

  @override
  Future<PhoneMicPermission> requestPermission() async => permission;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcmBytes) onData, {
    void Function(String message)? onError,
  }) async {
    startCaptureCalls++;
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    stopCaptureCalls++;
    capturing = false;
  }
}

const _v2Card = CardDevice(id: 'v2-dev', name: 'DYJV2_9920', rssi: -50);

CardSnapshot _v2Snap({bool recording = false}) => CardSnapshot(
  batteryLevel: 85,
  isCharging: false,
  wifiOpen: false,
  recording: recording,
  fwVersion: '0.3.16',
  fwVersionCode: 316,
  wifiVersion: '0.1.4',
  wifiVersionCode: 104,
  deviceName: 'DYJV2_9920',
  deviceId: 'v2-dev',
);

void main() {
  group('DYJ V2 Button Events & HardwareButtonEvent', () {
    test('HardwareButtonEvent.fromEvent 归一化 V2 手势并保留 button / rawGesture / action', () {
      final singleEv = HardwareButtonEvent.fromEvent({
        'kind': 'button',
        'button': {
          'name': 'main',
          'gesture': 'single',
          'action': 'record_mark',
        },
        'gesture': 'single',
        'rawGesture': 'single',
        'action': 'record_mark',
        'receivedAtMs': 1700000001000,
      });
      expect(singleEv.gesture, 'click');
      expect(singleEv.rawGesture, 'single');
      expect(singleEv.button, 'main');
      expect(singleEv.action, 'record_mark');
      expect(singleEv.receivedAtMs, 1700000001000);

      final doubleEv = HardwareButtonEvent.fromEvent({
        'kind': 'button',
        'button': 'main',
        'gesture': 'double',
        'action': 'record_toggle',
        'receivedAtMs': 1700000002000,
      });
      expect(doubleEv.gesture, 'double_click');
      expect(doubleEv.rawGesture, 'double');
      expect(doubleEv.button, 'main');
      expect(doubleEv.action, 'record_toggle');

      final longEv = HardwareButtonEvent.fromEvent({
        'kind': 'button',
        'button': {'name': 'side', 'key': 'long', 'action': 'none'},
        'gesture': 'long',
        'receivedAtMs': 1700000003000,
      });
      expect(longEv.gesture, 'long_press');
      expect(longEv.rawGesture, 'long');
      expect(longEv.button, 'side');
      expect(longEv.action, 'none');

      final releaseEv = HardwareButtonEvent.fromEvent({
        'kind': 'button',
        'button': {'name': 'main', 'gesture': 'long_release', 'action': 'none'},
        'gesture': 'long_release',
        'receivedAtMs': 1700000004000,
      });
      expect(releaseEv.gesture, 'long_press_end');
      expect(releaseEv.rawGesture, 'long_release');
      expect(releaseEv.action, 'none');
    });

    testWidgets('DeviceStore 拉取 CardV2 按键事件流后完整透传给订阅者', (tester) async {
      final gw = FakeCardGateway(
        initialSnapshot: _v2Snap(recording: true),
        devices: const [_v2Card],
      );
      final store = DeviceStore(gateway: gw);
      addTearDown(store.dispose);
      await store.restoreLink();

      final received = <HardwareButtonEvent>[];
      final sub = store.hardwareButtonEvents.listen(received.add);
      addTearDown(sub.cancel);

      gw.deviceEvents.addAll([
        {
          'seq': 1,
          'event': {
            'kind': 'button',
            'button': {
              'name': 'main',
              'gesture': 'single',
              'action': 'record_mark',
            },
            'gesture': 'click',
            'rawGesture': 'single',
            'action': 'record_mark',
            'receivedAtMs': 1700000010000,
          },
        },
        {
          'seq': 2,
          'event': {
            'kind': 'button',
            'button': {
              'name': 'main',
              'gesture': 'double',
              'action': 'none',
            },
            'gesture': 'double',
            'action': 'none',
            'receivedAtMs': 1700000011000,
          },
        },
      ]);
      // 推进 FakeCardGateway 内部序号，使 pullEvents 返回新增的 2 条事件
      gw.pushPowerEvent(level: 85, charging: false);

      await store.pollEventsNow();
      await tester.pump();

      expect(received, hasLength(2));
      expect(received[0].gesture, 'click');
      expect(received[0].rawGesture, 'single');
      expect(received[0].button, 'main');
      expect(received[0].action, 'record_mark');
      expect(received[1].gesture, 'double_click');
      expect(received[1].rawGesture, 'double');
      expect(received[1].action, 'none');
    });
  });

  group('DYJ V1 dyj_tts_speak Forward Compatibility', () {
    testWidgets('0.8.14 固件返回 unsupported (code 1001) 时保留清晰 unsupported 错误且不断开会话', (
      tester,
    ) async {
      final dispatched = <String>[];
      final ffiGw = RealCardGateway.forTesting(
        dispatch: (kind, payload, emit) {
          dispatched.add(kind);
          if (kind == 'snapshot') {
            emit({
              'ok': true,
              'data': {
                'deviceKind': 'dyj_v1',
                'displayModel': '点一机 V1',
                'deviceName': 'DYJ_001A',
                'battery': {'level': 80, 'isCharging': false},
                'state': {'wifiOpen': true, 'recording': false},
                'info': {
                  'version': '0.8.14',
                  'versionCode': 814,
                  'deviceName': 'DYJ_001A',
                  'deviceId': 'DYJ001A',
                },
                'record': {'isRecording': false},
              },
              'final': true,
            });
            return;
          }
          if (kind == 'dyj_tts_speak') {
            emit({
              'ok': false,
              'error':
                  'unsupported: 点一机当前固件 (v0.8.14) 暂不支持 tts.speak (code: 1001)',
              'detail': {
                'code': 'unsupported',
                'unsupported': true,
                'deviceCode': 1001,
              },
              'final': true,
            });
            return;
          }
          emit({'ok': true, 'data': const <String, dynamic>{}, 'final': true});
        },
      );
      final store = DeviceStore(gateway: ffiGw);
      addTearDown(store.dispose);
      addTearDown(ffiGw.dispose);

      await store.restoreLink();
      expect(store.isConnected, isTrue);
      expect(store.activeKind, DeviceKind.dyjV1);

      CardException? caught;
      try {
        await store.gateway.invokeBridgeCommand('dyj_tts_speak', {
          'text': '你好，已为您记下重点',
        });
      } on CardException catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(caught!.kind, CardErrorKind.device);
      expect(caught.message.toLowerCase(), contains('unsupported'));
      expect(store.isConnected, isTrue, reason: '不支持 tts.speak 绝不能破坏当前连接状态');
    });
  });

  group('DYJ V2 Progress-Aware Download Watchdog', () {
    testWidgets('持续推进进度的 10 分 30 秒大文件下载不会在 10 分钟被误杀，正常落盘返回', (
      tester,
    ) async {
      void Function(Map<String, dynamic>)? activeEmit;
      final gw = RealCardGateway.forTesting(
        dispatch: (kind, payload, emit) {
          if (kind == 'download') {
            activeEmit = emit;
          }
        },
      );
      addTearDown(gw.dispose);

      CardDownload? completed;
      Object? downloadErr;
      unawaited(
        gw.download('059F19DF.APM', '/tmp/rc-dl').then(
          (v) => completed = v,
          onError: (Object e) => downloadErr = e,
        ),
      );
      await tester.pump();
      expect(activeEmit, isNotNull);

      // 每 30 秒推进一次真实字节进度，总计 21 步 = 630 秒（10 分 30 秒 > 旧版 10 分钟硬上限）
      for (var step = 1; step <= 21; step++) {
        await tester.pump(const Duration(seconds: 30));
        expect(downloadErr, isNull, reason: '第 ${step * 30}s 有进度推进，不应超时');
        activeEmit!({
          'ok': true,
          'progress': {
            'stage': 'download',
            'name': '059F19DF.APM',
            'bytesWritten': step * 96 * 1024,
          },
          'final': false,
        });
        await tester.pump();
      }

      activeEmit!({
        'ok': true,
        'data': {
          'path': '/tmp/rc-dl/20261119-180000_059F19DF.apm',
          'bytesWritten': 21 * 96 * 1024,
          'originalName': '059F19DF.APM',
        },
        'final': true,
      });
      await tester.pump();

      expect(downloadErr, isNull);
      expect(completed, isNotNull);
      expect(completed!.bytesWritten, 21 * 96 * 1024);
      expect(completed!.originalName, '059F19DF.APM');
    });

    testWidgets('下载零进度卡死满 75 秒准时触发超时，且后续队列不楔死', (tester) async {
      void Function(Map<String, dynamic>)? activeEmit;
      final gw = RealCardGateway.forTesting(
        dispatch: (kind, payload, emit) {
          if (kind == 'download') {
            activeEmit = emit;
          } else if (kind == 'files') {
            emit({'ok': true, 'data': const <dynamic>[], 'final': true});
          }
        },
      );
      addTearDown(gw.dispose);

      Object? downloadErr;
      unawaited(
        gw.download('STUCK.APM', '/tmp/rc-dl').then(
          (_) {},
          onError: (Object e) => downloadErr = e,
        ),
      );
      await tester.pump();

      // 第 20s 收到首包进度（重置 75s 看门狗，新截止时间 = 95s）
      await tester.pump(const Duration(seconds: 20));
      activeEmit!({
        'ok': true,
        'progress': {'stage': 'download', 'bytesWritten': 4096},
        'final': false,
      });
      await tester.pump();

      // 第 50s 收到字节数未增长的重复心跳（不应续命看门狗！）
      await tester.pump(const Duration(seconds: 30));
      activeEmit!({
        'ok': true,
        'progress': {'stage': 'download', 'bytesWritten': 4096},
        'final': false,
      });
      await tester.pump();

      // 到第 94s（距上次真实进度 74s）尚未超时
      await tester.pump(const Duration(seconds: 44));
      expect(downloadErr, isNull);

      // 到第 95s（距上次真实进度满 75s）准时触发超时
      await tester.pump(const Duration(seconds: 1));
      expect(downloadErr, isA<CardException>());
      expect((downloadErr as CardException).kind, CardErrorKind.timeout);

      // 串行队列未楔死，后续命令立即可用
      final files = await gw.files();
      expect(files, isEmpty);
    });
  });

  group('Fast Disconnect Standby Failover (<= 12s)', () {
    testWidgets('录音中蓝牙静默断链在 <= 12 秒内触发本机麦克风保底接力（无需苦等 2 分钟）', (
      tester,
    ) async {
      final mic = _FakePhoneMicBackend();
      final gw = FakeCardGateway(
        initialSnapshot: _v2Snap(recording: true),
        devices: const [_v2Card],
      );
      final store = DeviceStore(
        gateway: gw,
        autoStart: true,
        phoneMicBackend: mic,
      );

      await store.restoreLink();
      await store.connectTo(_v2Card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(store.isConnected, isTrue);
      expect(store.isRecording, isTrue);
      expect(store.isPhoneStandbyArmed, isTrue);
      expect(store.isPhoneRecording, isFalse);
      expect(
        DeviceStore.recordingHeartbeatIdle <= const Duration(seconds: 12),
        isTrue,
        reason: '录音中心跳盲窗必须 <= 12 秒',
      );

      // 蓝牙意外失联且无法重连
      gw.failSnapshot = CardException.disconnected();
      gw.failConnect = CardException.disconnected();

      // 推进 12 秒（拆分为 5s 节拍）
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 2));

      expect(mic.startCaptureCalls, 1, reason: '12 秒内必须自动拉起手机麦克风保底');
      expect(store.isPhoneRecording, isTrue);
      expect(store.isFailoverPhoneRecording, isTrue);

      await store.stopPhoneRecording();
      store.dispose();
    });

    testWidgets('实时音频流持续收包时自动顺延探测（零额外抢占），断流掉线后 <= 12s 立即接力', (
      tester,
    ) async {
      final mic = _FakePhoneMicBackend();
      final gw = FakeCardGateway(
        initialSnapshot: _v2Snap(recording: true),
        devices: const [_v2Card],
      );
      final audioCtrl = StreamController<RealtimeAudioEvent>.broadcast();
      addTearDown(audioCtrl.close);

      final store = DeviceStore(
        gateway: _StreamingFakeGateway(gw, audioCtrl.stream),
        autoStart: true,
        phoneMicBackend: mic,
      );

      await store.restoreLink();
      await store.connectTo(_v2Card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final sub = store.gateway.realtimeAudio().listen((_) {});
      addTearDown(sub.cancel);
      final snapshotsBeforeStream = gw.snapshotCalls;

      // 连续 20 秒每 4 秒收到实时 PCM 音频包：看门狗不应额外发 snapshot 抢占蓝牙带宽
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 4));
        audioCtrl.add(
          RealtimeAudioEvent(
            kind: RealtimeAudioKind.audio,
            pcm: Uint8List(640),
            receivedSamples: (i + 1) * 320,
          ),
        );
        await tester.pump();
      }
      expect(
        gw.snapshotCalls,
        snapshotsBeforeStream,
        reason: '实时 PCM 正常到达期间不应额外发 snapshot 查询抢占链路',
      );
      expect(store.isPhoneRecording, isFalse);

      // 此刻设备超出距离断连，PCM 停止到达
      gw.failSnapshot = CardException.disconnected();
      gw.failConnect = CardException.disconnected();

      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 2));

      expect(mic.startCaptureCalls, 1);
      expect(store.isPhoneRecording, isTrue);
      expect(store.isFailoverPhoneRecording, isTrue);

      await store.stopPhoneRecording();
      store.dispose();
    });
  });
}

class _StreamingFakeGateway extends FakeCardGateway {
  _StreamingFakeGateway(this._delegate, this._audioStream);

  final FakeCardGateway _delegate;
  final Stream<RealtimeAudioEvent> _audioStream;

  @override
  bool get available => _delegate.available;

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() => _audioStream;

  @override
  Future<CardSnapshot> snapshot() => _delegate.snapshot();

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) =>
      _delegate.scan(timeoutMs: timeoutMs);

  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) => _delegate.connect(deviceId, name: name, deviceKind: deviceKind);

  @override
  Future<CardDisconnectReport> disconnect() => _delegate.disconnect();

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) =>
      _delegate.pullEvents(after: after);

  @override
  Future<List<CardWifiCredential>> wifiCredentials({bool passive = false}) =>
      _delegate.wifiCredentials(passive: passive);

  @override
  Future<CardOtaInfo> otaInfo(String module) => _delegate.otaInfo(module);
}
