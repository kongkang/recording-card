// 录音状态块与设备态绑定验收 —— 硬件 isRecording=true 时 Timeline 顶部出现
// 只读状态块；停止录音后收起。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _RecordingDevice extends DeviceStore {
  _RecordingDevice({required this.recording})
      : super(gateway: FakeCardGateway(available: false));

  final bool recording;

  @override
  bool get isRecording => recording;
}

void main() {
  testWidgets('设备录音态驱动 Timeline 顶部状态块', (tester) async {
    final controller = RecordingStatusController();
    final device = _RecordingDevice(recording: true);
    final store = AppStore(events: const [], loadPersistedState: false);
    addTearDown(controller.dispose);
    addTearDown(device.dispose);
    addTearDown(store.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: testTheme(),
      home: AppShell(
        store: store,
        device: device,
        recordingStatus: controller,
      ),
    ));
    await tester.pump();

    expect(controller.phase, RecordingPhase.recording);
    expect(find.byKey(const Key('recording-status-block')), findsOneWidget);
    expect(find.text('正在录音'), findsOneWidget);
  });

  testWidgets('设备未录音时状态块收起', (tester) async {
    final controller = RecordingStatusController();
    final device = _RecordingDevice(recording: false);
    final store = AppStore(events: const [], loadPersistedState: false);
    addTearDown(controller.dispose);
    addTearDown(device.dispose);
    addTearDown(store.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: testTheme(),
      home: AppShell(
        store: store,
        device: device,
        recordingStatus: controller,
      ),
    ));
    await tester.pump();

    expect(controller.phase, RecordingPhase.idle);
    expect(find.byKey(const Key('recording-status-block')), findsNothing);
  });
}
