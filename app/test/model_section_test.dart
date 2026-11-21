import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/model_manager_controller.dart';

import 'support/test_transitions.dart';

void main() {
  testWidgets('Setting 模型区块：未配置下载地址时展示状态且下载禁用', timeout: const Timeout(Duration(seconds: 30)), (tester) async {
    // testWidgets 的 fake async 区不跑真实 IO：临时目录与模型状态检查
    // 必须在 runAsync 里完成，否则 await 会永远等不到。
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('rc-model-ui-'),
    );
    addTearDown(() {
      try {
        root!.deleteSync(recursive: true);
      } on Object {
        // 忽略清理失败
      }
    });
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    final controller = ModelManagerController(
      installer: ModelInstaller(root: root),
      baseUrl: '',
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.refresh);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: SettingPage(settings: settings, modelManager: controller),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('set-local-model')), findsOneWidget);
    await tester.tap(find.byKey(const Key('set-local-model')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('model-row-sensevoice-small-int8')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('model-row-silero-vad')), findsNothing);
    expect(
      find.byKey(const Key('model-row-campplus-embedding')),
      findsOneWidget,
    );
    expect(find.textContaining('SenseVoice'), findsNothing);
    expect(find.textContaining('Silero VAD'), findsNothing);
    expect(find.textContaining('CAM++'), findsNothing);
    expect(find.text('下载服务暂不可用'), findsOneWidget);
    await tester.tap(find.byKey(const Key('local-engine-help')));
    await tester.pumpAndSettle();
    expect(find.textContaining('SenseVoice'), findsOneWidget);
    expect(find.textContaining('Silero VAD'), findsOneWidget);
    expect(find.textContaining('CAM++'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    // 滚到底部确认下载按钮因未配置被禁用
    await tester.scrollUntilVisible(
      find.byKey(const Key('model-install-all')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('model-install-all')),
    );
    expect(button.onPressed, isNull);
  });
}
