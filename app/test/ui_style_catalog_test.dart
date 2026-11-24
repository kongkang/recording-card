// 可选 6 套界面风格目录、Apple-Hosted 资源包兼容层与双端同步回归测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/ui_style_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/transcribe/apple_asset_pack_client.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.reai.recordingcard/apple_assets');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('UIStyleStore 目录、持久化与 Apple 资源包降级', () {
    test('目录包含完整 6 套风格，现阶段全部 free 且仅 default 内置', () {
      final catalog = UIStyleDescriptor.catalog;
      expect(
        catalog.map((d) => d.id.wireId).toList(),
        <String>[
          'default',
          'braun_field',
          'chronos',
          'folio',
          'nocturne',
          'air',
        ],
      );
      expect(catalog.every((d) => d.tier == UIStyleTier.free), isTrue);
      expect(
        catalog.where((d) => d.builtin).map((d) => d.id).toList(),
        <RCUIStyleId>[RCUIStyleId.warmPaper],
      );
    });

    test('选择非内置风格支持 InMemoryStore 持久化回环与卸载恢复默认', () async {
      final kv = InMemoryStore();
      final tmpDir = await Directory.systemTemp.createTemp('rc-ui-style-test-');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      final client = AppleAssetPackClient(isIOSOverride: false);
      final store = UIStyleStore(
        store: kv,
        appleAssets: client,
        styleRootResolver: () async => tmpDir.path,
      );
      await store.load();
      expect(store.activeStyleId, RCUIStyleId.warmPaper);
      expect(store.isInstalled(RCUIStyleId.warmPaper), isTrue);
      expect(store.isInstalled(RCUIStyleId.nocturne), isFalse);

      // 不在 iOS Apple-Hosted 托管环境时，平滑回落客户端内置可编程模板
      await store.selectStyle(RCUIStyleId.nocturne);
      expect(store.activeStyleId, RCUIStyleId.nocturne);
      expect(store.isInstalled(RCUIStyleId.nocturne), isTrue);
      expect(store.lastError, isNull);
      expect(store.appleHostingAvailable, isFalse);

      // 重新实例化并 load，应准确恢复上次风格与已装清单
      final reloaded = UIStyleStore(
        store: kv,
        appleAssets: client,
        styleRootResolver: () async => tmpDir.path,
      );
      await reloaded.load();
      expect(reloaded.activeStyleId, RCUIStyleId.nocturne);
      expect(reloaded.isInstalled(RCUIStyleId.nocturne), isTrue);

      // 内置 default 不可移除
      await reloaded.removeStyle(RCUIStyleId.warmPaper);
      expect(reloaded.isInstalled(RCUIStyleId.warmPaper), isTrue);

      // 移除当前激活的非内置风格时自动退回 default
      await reloaded.removeStyle(RCUIStyleId.nocturne);
      expect(reloaded.isInstalled(RCUIStyleId.nocturne), isFalse);
      expect(reloaded.activeStyleId, RCUIStyleId.warmPaper);

      store.dispose();
      reloaded.dispose();
    });

    test('mock Apple-Hosted channel 就绪时调用 installAssetPack，未上架时平滑降级', () async {
      final calls = <MethodCall>[];
      var hostAvailable = true;
      var publishedPacks = <String>['com.reai.recordingcard.style.chronos'];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'isAvailable':
                return hostAvailable;
              case 'availablePackIds':
                return publishedPacks;
              case 'installAssetPack':
                return true;
              case 'removeAssetPack':
                return null;
            }
            return null;
          });

      final kv = InMemoryStore();
      final tmpDir = await Directory.systemTemp.createTemp('rc-ui-style-apple-');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      final store = UIStyleStore(
        store: kv,
        appleAssets: AppleAssetPackClient(isIOSOverride: true),
        styleRootResolver: () async => tmpDir.path,
      );
      await store.load();
      expect(store.appleHostingAvailable, isTrue);

      // 1) 清单内已发布 pack -> 真实调用 installAssetPack
      await store.selectStyle(RCUIStyleId.chronos);
      expect(store.activeStyleId, RCUIStyleId.chronos);
      expect(store.isInstalled(RCUIStyleId.chronos), isTrue);
      final installCalls =
          calls.where((c) => c.method == 'installAssetPack').toList();
      expect(installCalls, hasLength(1));
      expect(
        (installCalls.single.arguments as Map)['packId'],
        'com.reai.recordingcard.style.chronos',
      );

      // 2) 未出现在 Apple CDN 清单里的 pack -> 不强行报错，平滑使用内置样式表
      await store.selectStyle(RCUIStyleId.folio);
      expect(store.activeStyleId, RCUIStyleId.folio);
      expect(store.isInstalled(RCUIStyleId.folio), isTrue);
      expect(
        calls.where((c) => c.method == 'installAssetPack'),
        hasLength(1),
      );

      // 3) hosting 变为不可用时仍可顺畅切风格
      hostAvailable = false;
      await store.selectStyle(RCUIStyleId.air);
      expect(store.activeStyleId, RCUIStyleId.air);
      expect(store.lastError, isNull);

      store.dispose();
    });
  });

  group('设置页界面风格切换与 Watch 联动 Widget 测试', () {
    testWidgets('从 Setting 进入界面风格子页，校验 6 张卡片、底部留白与 iPhone+Watch 同步切换', (
      tester,
    ) async {
      final kv = InMemoryStore();
      final styleStore = UIStyleStore(
        store: kv,
        appleAssets: AppleAssetPackClient(isIOSOverride: false),
      );
      await styleStore.load();

      final model = SummaryModel();
      final appStore = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      final fakeWatch = FakeWatchBridgeBackend();
      final watchService = WatchHardwareService(backend: fakeWatch);
      final deviceStore = DeviceStore(
        gateway: FakeCardGateway(),
        watchHardware: watchService,
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(styleStore.dispose);
      addTearDown(deviceStore.dispose);
      addTearDown(watchService.dispose);
      addTearDown(appStore.dispose);

      await tester.pumpWidget(
        UIStyleScope(
          store: styleStore,
          child: ListenableBuilder(
            listenable: styleStore,
            builder: (context, _) {
              final activeId = styleStore.activeStyleId;
              return MaterialApp(
                theme: buildRCThemeForStyle(
                  activeId,
                  brightness: Brightness.light,
                ),
                darkTheme: buildRCThemeForStyle(
                  activeId,
                  brightness: Brightness.dark,
                ),
                themeMode: themeModeForStyle(activeId),
                scrollBehavior: const RCScrollBehavior(),
                home: AppShell(
                  store: appStore,
                  device: deviceStore,
                  uiStyle: styleStore,
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      Future<void> scrollAndTap(Finder finder) async {
        await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
        await tester.pump();
        await tester.tap(finder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
      }

      // 1) 进入 Setting -> 点击「界面风格」
      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pump();
      await scrollAndTap(find.byKey(const Key('set-ui-style')));

      // 验证二级子页底部留白 >= RCDims.pageBottomPad (48px)
      final subScroll = find.byKey(const Key('setsub-scroll-style'));
      expect(subScroll, findsOneWidget);
      final subListView = tester.widget<ListView>(subScroll);
      expect(
        (subListView.padding! as EdgeInsets).bottom,
        greaterThanOrEqualTo(RCDims.pageBottomPad),
      );

      // 验证全部 6 张模板卡均已渲染
      for (final d in UIStyleDescriptor.catalog) {
        expect(find.byKey(Key('style-card-${d.id.wireId}')), findsOneWidget);
      }

      // 2) 切换到「暗房 nocturne」并验证暗色 ThemeData、RCStyleSpec 与 Watch 同步
      await scrollAndTap(find.byKey(const Key('style-apply-nocturne')));

      final ctxAfterNocturne = tester.element(subScroll);
      expect(Theme.of(ctxAfterNocturne).brightness, Brightness.dark);
      expect(ctxAfterNocturne.rcStyle.styleId, RCUIStyleId.nocturne);
      expect(fakeWatch.lastUiStyleId, 'nocturne');

      // 3) 切换到「声波仪 braun_field」并验证样式表与 Watch 同步
      await scrollAndTap(find.byKey(const Key('style-apply-braun_field')));

      final ctxAfterBraun = tester.element(subScroll);
      expect(Theme.of(ctxAfterBraun).brightness, Brightness.light);
      expect(ctxAfterBraun.rcStyle.styleId, RCUIStyleId.braunField);
      expect(ctxAfterBraun.rcStyle.cardRadius, 8);
      expect(fakeWatch.lastUiStyleId, 'braun_field');

      // 4) 切回「静纸声录 default」
      await scrollAndTap(find.byKey(const Key('style-apply-default')));

      final ctxAfterDefault = tester.element(subScroll);
      expect(Theme.of(ctxAfterDefault).brightness, Brightness.light);
      expect(ctxAfterDefault.rcStyle.styleId, RCUIStyleId.warmPaper);
      expect(fakeWatch.lastUiStyleId, 'default');
      expect(
        fakeWatch.syncedUiStyles,
        <String>['nocturne', 'braun_field', 'default'],
      );
    });

    testWidgets('5 套非默认风格在 Timeline、Detail 与 OS1 呈现真实差异化结构且可恢复默认', (
      tester,
    ) async {
      final kv = InMemoryStore();
      final styleStore = UIStyleStore(
        store: kv,
        appleAssets: AppleAssetPackClient(isIOSOverride: false),
      );
      await styleStore.load();

      final model = SummaryModel();
      final appStore = AppStore(
        events: seedEvents,
        generator: await model.generator(),
        loadPersistedState: false,
      );
      final fakeWatch = FakeWatchBridgeBackend();
      final watchService = WatchHardwareService(backend: fakeWatch);
      final deviceStore = DeviceStore(
        gateway: FakeCardGateway(),
        watchHardware: watchService,
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(styleStore.dispose);
      addTearDown(deviceStore.dispose);
      addTearDown(watchService.dispose);
      addTearDown(appStore.dispose);

      await tester.pumpWidget(
        UIStyleScope(
          store: styleStore,
          child: ListenableBuilder(
            listenable: styleStore,
            builder: (context, _) {
              final activeId = styleStore.activeStyleId;
              return MaterialApp(
                theme: buildRCThemeForStyle(
                  activeId,
                  brightness: Brightness.light,
                ),
                darkTheme: buildRCThemeForStyle(
                  activeId,
                  brightness: Brightness.dark,
                ),
                themeMode: themeModeForStyle(activeId),
                scrollBehavior: const RCScrollBehavior(),
                home: AppShell(
                  store: appStore,
                  device: deviceStore,
                  uiStyle: styleStore,
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 0) 默认 warmPaper：底部三键 + OS1 旭日球 + 默认顶栏/时间轴列表
      expect(find.byKey(const Key('app-header')), findsOneWidget);
      expect(find.byKey(const Key('bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('nav-ai-sunrise-orb')), findsOneWidget);
      expect(find.byKey(const Key('timeline-list')), findsOneWidget);

      Future<void> switchStyle(RCUIStyleId id) async {
        await styleStore.selectStyle(id);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      // 1) Braun Field：示波屏 + 3D 实体双键 + 悬浮底座 + 详情去头像卡片
      await switchStyle(RCUIStyleId.braunField);
      expect(find.byKey(const Key('braun-lcd-panel')), findsOneWidget);
      expect(find.byKey(const Key('braun-key-pair')), findsOneWidget);
      expect(find.byKey(const Key('braun-dock')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('braun-turn-e1-0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 2) Chronos：日段切换条 + 时长比例轴 + 底部 4 槽栏 + 时间账本
      await switchStyle(RCUIStyleId.chronos);
      expect(find.byKey(const Key('chronos-day-bar')), findsOneWidget);
      expect(find.byKey(const Key('chronos-axis-list')), findsOneWidget);
      expect(find.byKey(const Key('chronos-bottom-bar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('chronos-ledger-turn-e1-0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 3) Folio：报纸刊头 + 头版引文 + 日刊底栏 + 右侧边栏批注
      await switchStyle(RCUIStyleId.folio);
      expect(find.byKey(const Key('folio-masthead')), findsOneWidget);
      expect(find.byKey(const Key('folio-lead-quote')), findsOneWidget);
      expect(find.byKey(const Key('folio-bottom-nav')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('folio-marginalia-turn-e1-0')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 4) Nocturne：遥测条 + 14 柱声学频谱 + 暗房拇指坞 + 详情点选条
      await switchStyle(RCUIStyleId.nocturne);
      expect(find.byKey(const Key('nocturne-telemetry-strip')), findsOneWidget);
      expect(find.byKey(const Key('nocturne-spectrum-e1')), findsOneWidget);
      expect(find.byKey(const Key('nocturne-thumb-dock')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('nocturne-detail-scrub')), findsOneWidget);
      expect(find.byKey(const Key('nocturne-turn-e1-0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 5) Air：珊瑚/青绿渐变状态胶囊 + 磨砂浮岛 + 软阴影卡片 + 珊瑚 OS1 轻聊
      await switchStyle(RCUIStyleId.air);
      expect(find.byKey(const Key('air-state-pill')), findsOneWidget);
      expect(find.byKey(const Key('air-float-nav')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('air-turn-e1-0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('nav-ai-sunrise')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('ai-space')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai-mode-chat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('ai-space')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai-space-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 6) 恢复默认 warmPaper：默认结构完好无损
      await switchStyle(RCUIStyleId.warmPaper);
      expect(find.byKey(const Key('bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('nav-ai-sunrise-orb')), findsOneWidget);
      expect(find.byKey(const Key('braun-dock')), findsNothing);
    });
  });
}
