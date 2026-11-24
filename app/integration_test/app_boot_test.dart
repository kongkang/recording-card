// 真机启动冒烟：App 真的能在设备上冷启动、走完鉴权恢复、落到登录页，
// 且未配置登录服务时按钮是「禁用 + 有原因」而不是静默失败。
//
// 这个用例故意做得很短（不驱动长流程、不抢用户手机），只回答一个问题：
// "打出来的包在真机上能不能正常起来"。
//
// 跑法：cd app && flutter test integration_test/app_boot_test.dart -d <deviceId>
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:recording_card/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('冷启动 → 落到登录页（未配置登录服务时按钮禁用且有原因）', (tester) async {
    await app.main();

    // 启动态：先出 splash，再进登录页
    await tester.pump();
    expect(find.byKey(const Key('app-splash')), findsOneWidget);

    // 等鉴权恢复（读 Keychain）+ 本地数据装载
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const Key('login-title')).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(
      find.byKey(const Key('login-title')),
      findsOneWidget,
      reason: 'App 应停在登录页；如果这里失败，说明冷启动就崩了',
    );
    expect(
      find.byKey(const Key('login-account')),
      findsNothing,
      reason: '重构后的首页登录页不应再有可选账号输入框',
    );
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    // 第三方入口仅在配置就绪或服务端启用时渲染，未启用时自动隐藏。
    // ignore: avoid_print
    print('[boot] 已到登录页（主登录入口已渲染，无多余账号框）');

    final blocked = find.byKey(const Key('login-blocked'));
    if (blocked.evaluate().isNotEmpty) {
      final text = tester.widget<Text>(blocked).data ?? '';
      // ignore: avoid_print
      print('[boot] 登录被门控：$text');
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('login-submit')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: '未配置登录服务时按钮应禁用，避免用户点了没反应',
      );
    } else {
      // ignore: avoid_print
      print('[boot] 登录服务已配置');
      final submitButton = tester.widget<FilledButton>(
        find.byKey(const Key('login-submit')),
      );
      expect(submitButton.onPressed, isNotNull);

      for (final entry in const [
        ('微信', 'login-wechat'),
        ('Apple', 'login-apple'),
        ('Google', 'login-google'),
      ]) {
        final finder = find.byKey(Key(entry.$2));
        if (finder.evaluate().isNotEmpty) {
          final btn = tester.widget<OutlinedButton>(finder);
          // ignore: avoid_print
          print('[boot] ${entry.$1}登录按钮 shown=true enabled=${btn.onPressed != null}');
        } else {
          // ignore: avoid_print
          print('[boot] ${entry.$1}登录按钮 shown=false');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
