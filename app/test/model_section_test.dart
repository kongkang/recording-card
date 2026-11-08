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

    expect(
      find.byKey(const Key('model-row-sensevoice-small-int8')),
      findsOneWidget,
    );
    expect(find.text('模型下载服务未配置'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('model-install-all')),
    );
    expect(button.onPressed, isNull);
  });
}
