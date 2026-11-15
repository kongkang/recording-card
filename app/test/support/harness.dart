/// 界面测试统一装配：固定数据集 + 真实 AppStore + 可控的模型后端。
///
/// 约定（对齐这一轮的真实链路）：
/// - `AppStore(events: seedEvents, loadPersistedState: false)`：不读 shared_preferences，
///   也不去设备取数据，测试拿到的是确定的 6 条记录；
/// - 生成走真实 `SummaryGenerator`（HTTP 被 MockClient 顶掉，见 model_stub.dart）；
/// - `DeviceStore(autoStart: false)`：心跳定时器不开，测试不会悬挂。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/recording_status.dart';

import 'fake_gateway.dart';
import 'fake_recordings.dart';
import 'model_stub.dart';
import 'test_transitions.dart';

/// 装配结果：测试通常只用到 store / device / model。
class ShellHarness {
  ShellHarness({
    required this.store,
    required this.device,
    required this.model,
  });

  final AppStore store;
  final DeviceStore device;
  final SummaryModel model;
}

/// 起一个应用外壳。默认：窄屏 390×844、6 条设计样例记录、未连接设备、模型后端可用。
Future<ShellHarness> pumpShell(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  AppStore? store,
  DeviceStore? device,
  SummaryModel? model,
  FakeRecordingSync? recordings,
  RecordingStatusController? recordingStatus,
  LiveAudioRecorder? liveAudio,
  bool pumpTwice = true,
}) async {
  final m = model ?? SummaryModel();
  final s =
      store ??
      AppStore(
        events: seedEvents,
        recordings: recordings,
        generator: await m.generator(),
        loadPersistedState: false,
      );
  final d = device ?? DeviceStore(gateway: FakeCardGateway());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(d.dispose);
  addTearDown(s.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      scrollBehavior: const RCScrollBehavior(),
      home: AppShell(
        store: s,
        device: d,
        recordingStatus: recordingStatus,
        liveAudio: liveAudio,
      ),
    ),
  );
  await tester.pump();
  if (pumpTwice) await tester.pump();
  return ShellHarness(store: s, device: d, model: m);
}

/// 进入勾选模式并选「本周」。
Future<void> startWeekSummary(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('summary-start')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('chip-week')));
  await tester.pump();
}

/// 点「生成总结」：此时真实请求已发出但被 [SummaryModel] 挂住（autoReply: false）。
Future<void> tapGenerate(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('generate-summary')));
  await tester.pump();
  await tester.pump();
}

/// 放行模型返回并推进到生成结束。
///
/// 真实链路是异步的：这里给足帧让 HTTP → 解析 → notifyListeners 走完。
Future<void> finishGeneration(
  WidgetTester tester,
  SummaryModel model, {
  bool pumpAfter = true,
}) async {
  model.release();
  await tester.pump();
  await tester.pump();
  if (pumpAfter) await tester.pump();
}

/// 「进入勾选模式 → 选本周 → 生成完成」的常用整段流程。
Future<void> generateWeekSummary(
  WidgetTester tester,
  SummaryModel model,
) async {
  await startWeekSummary(tester);
  await tapGenerate(tester);
  await finishGeneration(tester, model);
}

/// 结果页/详情页深处元素：拖动滚动区直到可命中再点。
Future<void> tapInScroll(
  WidgetTester tester,
  Finder target, {
  Key scrollKey = const Key('sum-scroll'),
  int guardLimit = 20,
}) async {
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < guardLimit) {
    final c = tester.getCenter(target, warnIfMissed: false);
    await tester.drag(
      find.byKey(scrollKey),
      Offset(0, c.dy < 400 ? 300 : -300),
    );
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
}

/// 横向 Tab 栏可能滚动裁剪：拖到可命中再点。
Future<void> tapTab(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  var guard = 0;
  while (!tester.any(target.hitTestable()) && guard++ < 10) {
    await tester.drag(
      find.byKey(const Key('stab-strip')),
      const Offset(-120, 0),
      warnIfMissed: false,
    );
    await tester.pump();
  }
  await tester.tap(target.hitTestable().first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

/// 点击后是否处于禁用态（FilledButton / OutlinedButton / TextButton）。
bool disabledOf(WidgetTester tester, Key key) {
  final w = tester.widget<Widget>(find.byKey(key));
  return switch (w) {
    FilledButton b => b.onPressed == null,
    OutlinedButton b => b.onPressed == null,
    TextButton b => b.onPressed == null,
    _ => false,
  };
}
