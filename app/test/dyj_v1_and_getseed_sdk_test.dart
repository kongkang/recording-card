import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';
import 'support/fake_gateway.dart';

class _IdlePhoneMic implements PhoneMicBackend {
  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcmBytes) onData, {
    void Function(String message)? onError,
  }) async {}

  @override
  Future<void> stopCapture() async {}
}

class _StubLiveActivity extends LiveActivityService {
  _StubLiveActivity()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: false,
          supportsDynamicIsland: false,
          supportsActionButton: false,
          areActivitiesEnabled: false,
        ),
      );
}

void main() {
  test('DyjV1HardwareCommands 按协议封装全部传感器/定位/相机/振动/音量/ASR 扩展指令', () async {
    final calls = <(String, Map<String, dynamic>?)>[];
    final gw = FakeCardGateway()
      ..onBridgeCommand = (kind, payload) async {
        calls.add((kind, payload));
        return {
          'ok': true,
          'data': {'cmd': kind, 'echo': payload},
          'final': true,
        };
      };

    await gw.startRecordingSegment(segmentMinutes: 1);
    await gw.dyjDeviceInfo(verbose: true);
    await gw.dyjDeviceTime(epochMs: 1700000000000);
    await gw.dyjDeviceReboot(confirm: false);
    await gw.dyjOtaConfigGet();
    await gw.dyjOtaConfigSet('http://127.0.0.1:18900/ota/manifest.json');
    await gw.dyjSensorStatus();
    await gw.dyjSensorRead(types: const ['pressure', 'magnetic']);
    await gw.dyjSensorStreamStart(types: const ['pressure'], intervalMs: 500);
    await gw.dyjSensorStreamStop();
    await gw.dyjLocationStatus();
    await gw.dyjLocationGet(timeoutS: 8);
    await gw.dyjLocationStreamStart(minIntervalS: 5);
    await gw.dyjLocationStreamStop();
    await gw.dyjCameraStatus();
    await gw.dyjCameraCapture();
    await gw.dyjCameraRecordStart(maxS: 12, segmentS: 5);
    await gw.dyjCameraRecordStop();
    await gw.dyjCameraRecordStatus();
    await gw.dyjCameraDelete('img_01.jpg');
    await gw.dyjVibratorOnce(durationMs: 200, amplitude: 128);
    await gw.dyjVibratorCancel();
    await gw.dyjVolumeGet();
    await gw.dyjVolumeSet('music', 7);
    await gw.dyjLedStatus();
    await gw.dyjLedSet('breathe', brightness: 'mid', priority: 850, timeoutS: 3);
    await gw.dyjLedClear();
    await gw.dyjButtonBindGet();
    await gw.dyjButtonBindSet('long_press', 'event_only');
    await gw.dyjAsrStatus();
    await gw.dyjAsrConfigGet();
    await gw.dyjAsrConfigSet(attach: false, partial: true);
    await gw.dyjAsrStart(mode: 'continuous', partial: true, maxS: 60);
    await gw.dyjAsrStop();

    expect(calls.length, 34);
    expect(calls[0].$1, 'record.start');
    expect(calls[0].$2, {'segmentMin': 1});
    expect(calls[7].$1, 'dyj.sensor.read');
    expect(calls[7].$2, {
      'types': ['pressure', 'magnetic'],
    });
    expect(calls[16].$1, 'dyj.camera.record.start');
    expect(calls[16].$2, {'maxS': 12, 'segmentS': 5});
    expect(calls[23].$1, 'dyj.volume.set');
    expect(calls[23].$2, {'stream': 'music', 'value': 7});
    expect(calls[32].$1, 'dyj.asr.start');
    expect(calls[32].$2, {'mode': 'continuous', 'partial': true, 'maxS': 60});
  });

  test('DeviceEventBatch 解析 sensor / location / asr / record_segment 事件', () {
    const batch = DeviceEventBatch(
      seq: 42,
      events: [
        {
          'seq': 39,
          'event': {
            'kind': 'record_segment',
            'ts': 100,
            'data': {'seq': 1},
          },
        },
        {
          'seq': 40,
          'event': {
            'kind': 'sensor',
            'evt': 'sensor.data',
            'data': {'pressure_hpa': 1012.5},
          },
        },
        {
          'seq': 41,
          'event': {
            'kind': 'location',
            'evt': 'location.fix',
            'data': {'has_fix': false},
          },
        },
        {
          'seq': 42,
          'event': {
            'kind': 'asr',
            'evt': 'asr.final',
            'data': {'text': '测试识别'},
          },
        },
      ],
    );

    expect(batch.recordSegmentEvents.single['event']['data']['seq'], 1);
    expect(batch.sensorEvents.single['event']['data']['pressure_hpa'], 1012.5);
    expect(batch.locationEvents.single['event']['data']['has_fix'], isFalse);
    expect(batch.asrEvents.single['event']['data']['text'], '测试识别');
  });

  test('CardSnapshot.fromJson 与 isLikely5GhzSsid 按真实固件能力/频段识别', () {
    final snap087 = CardSnapshot.fromJson({
      'deviceKind': 'dyj_v1',
      'displayModel': '点一机 V1',
      'capabilities': {
        'realtimeAudio': true,
        'hasOnboardStorage': true,
        'hasFileSync': true,
        'hasWifiConfig': true,
        'hasCameraMedia': false,
        'hasPhysicalRecordToggle': true,
        'hasRemoteRecordControl': true,
        'hasMarkButton': false,
        'hasConfigurableButtons': true,
        'otaMode': 'single_ota',
      },
      'battery': {'level': 90, 'isCharging': true},
      'state': {'wifiOpen': true, 'recording': false},
      'info': {'version': '0.8.7', 'versionCode': 807, 'deviceName': 'DYJ_YKAUP3'},
      'record': {'isRecording': false},
    });
    expect(snap087.resolvedCapabilities.hasCameraMedia, isFalse);
    expect(snap087.isCharging, isTrue);

    final snap0815 = CardSnapshot.fromJson({
      'deviceKind': 'dyj_v1',
      'capabilities': {'hasCameraMedia': true},
      'battery': {'level': 88, 'isCharging': false},
      'state': {'wifiOpen': true, 'recording': false},
      'info': {'version': '0.8.15', 'versionCode': 815, 'deviceName': 'DYJ_YKAUP3'},
      'record': {'isRecording': false},
    });
    expect(snap0815.resolvedCapabilities.hasCameraMedia, isTrue);

    expect(isLikely5GhzSsid('KK2BY_5G'), isTrue);
    expect(isLikely5GhzSsid('Studio-5GHz'), isTrue);
    expect(isLikely5GhzSsid('Home 5G'), isTrue);
    expect(isLikely5GhzSsid('Wi-Fi「KK2BY_5G」连接超时'), isTrue);
    expect(isLikely5GhzSsid('KK2BY'), isFalse);
    expect(isLikely5GhzSsid('Office-2.4G'), isFalse);
  });

  testWidgets('Wi-Fi 配网面板选中疑似 5GHz 网络时显示 2.4GHz 频段提醒', (tester) async {
    final gw = FakeCardGateway(
      initialSnapshot: const CardSnapshot(
        batteryLevel: 85,
        isCharging: false,
        wifiOpen: true,
        recording: false,
        fwVersion: '0.8.15',
        fwVersionCode: 815,
        wifiVersion: '',
        wifiVersionCode: 0,
        deviceName: 'DYJ_YKAUP3',
        deviceId: 'DYJ_YKAUP3',
        deviceKind: DeviceKind.dyjV1,
        capabilities: HardwareCapabilities.dyjV1,
      ),
      wifiNetworks: const [
        CardWifiNetwork(ssid: 'KK2BY_5G', rssi: -55, secured: true),
        CardWifiNetwork(ssid: 'KK2BY', rssi: -58, secured: true),
      ],
    );
    final store = DeviceStore(
      gateway: gw,
      autoStart: false,
      phoneMicBackend: _IdlePhoneMic(),
      liveActivityService: _StubLiveActivity(),
      watchHardware: WatchHardwareService(backend: FakeWatchBridgeBackend()),
    );
    addTearDown(store.dispose);

    await store.refreshFromDevice();
    store.openSheet();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildRCTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              StatusSheetOverlay(store: store, islandEnabled: false),
            ],
          ),
        ),
      ),
    );
    store.showView(DeviceView.wifi);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('witem-KK2BY_5G')));
    await tester.pump();
    expect(find.byKey(const Key('wifi-5g-hint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('wifi-cancel')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('witem-KK2BY')));
    await tester.pump();
    expect(find.byKey(const Key('wifi-5g-hint')), findsNothing);
  });

  testWidgets('Setting 第三方硬件页仅保留 Omi 与飞书录音豆（不含 Get 笔记卡蓝牙）', (tester) async {
    final cfg = AgentConfigStore();
    addTearDown(cfg.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRCTheme(),
        home: SettingSubPage(
          subId: 'exthw',
          agentConfig: cfg,
          standalone: true,
        ),
      ),
    );
    expect(find.byKey(const Key('ext-getseed-card')), findsNothing);
    expect(find.byKey(const Key('ext-omi-card')), findsOneWidget);
    expect(find.byKey(const Key('ext-feishu-card')), findsOneWidget);
  });
}
