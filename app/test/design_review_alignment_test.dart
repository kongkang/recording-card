/// Owner 设计审阅（2026-11-13）对齐专项验收：
/// 覆盖 1~6 条审阅修改项与交叉反馈 #1~#3（不含 TBC 超前功能）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/pages/status_sheet.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/auth/auth.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/wechat_login/wechat_login_service.dart';
import 'package:recording_card/services/net/api_exception.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/photos/photo_library_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/model_manager_controller.dart';
import 'package:recording_card/widgets/recording_status_block.dart';

import 'support/fake_gateway.dart';
import 'support/harness.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _FakePhoneMicBackend implements PhoneMicBackend {
  PhoneMicPermission permission = PhoneMicPermission.granted;
  bool capturing = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PhoneMicPermission> checkPermission() async => permission;

  @override
  Future<PhoneMicPermission> requestPermission() async => permission;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    startCalls += 1;
    capturing = true;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls += 1;
    capturing = false;
  }
}

class _FakeLiveActivityService extends LiveActivityService {
  _FakeLiveActivityService()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: true,
          supportsDynamicIsland: true,
          supportsActionButton: true,
          areActivitiesEnabled: true,
        ),
      );

  int startCount = 0;
  int stopCount = 0;

  @override
  Future<void> startLocalRecordingActivity({
    required DateTime startedAt,
  }) async {
    startCount += 1;
  }

  @override
  Future<void> stopLocalRecordingActivity() async {
    stopCount += 1;
  }
}

class _SilentHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class _TestWechatGateway implements WechatLoginGateway {
  @override
  bool get isSupported => true;

  @override
  bool get isConfigured => true;

  @override
  bool? get cachedIsInstalled => true;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<WechatAuthorizationCode> authorize() async =>
      const WechatAuthorizationCode(code: 'wx-code', lang: 'zh_CN');

  @override
  void cancelPendingAuthorization() {}
}

class _TestAuthService extends AuthService {
  _TestAuthService({required bool signedIn})
    : super(
        oauthConfig: kStubOAuthConfig.copyWith(
          wechatAppId: 'wxtest1234567890abcd',
        ),
        tokenStore: _FakeTokenStore(signedIn: signedIn),
        oauthClient: OAuthClient(
          config: kStubOAuthConfig,
          httpClient: _SilentHttpClient(),
        ),
        launcher: _MockLauncher(),
        wechatGateway: _TestWechatGateway(),
        initialSocialProviders: const {'apple'},
      );
}

class _FakeTokenStore extends OAuthTokenStore {
  _FakeTokenStore({required this.signedIn})
    : super(
        secure: InMemorySecureStore(),
        client: OAuthClient(
          config: kStubOAuthConfig,
          httpClient: _SilentHttpClient(),
        ),
        config: kStubOAuthConfig,
      );

  final bool signedIn;

  @override
  bool get hasSession => signedIn;

  @override
  OAuthAccount? get account => signedIn
      ? const OAuthAccount(
          userId: 'u-owner',
          name: 'owner@wainao.chat',
          email: 'owner@wainao.chat',
        )
      : null;

  @override
  String? get accessToken => signedIn ? 'test-access-token' : null;

  @override
  DateTime? get accessExpiresAt =>
      signedIn ? DateTime(2099, 1, 1) : null;

  @override
  bool get hasValidRefreshToken => signedIn;
}

class _MockLauncher implements WebAuthLauncher {
  @override
  bool get isSupported => true;

  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) {
    throw const OAuthCancelledException();
  }
}

void main() {
  testWidgets('1&2. 扫码徽章置前分色 + 已连接顶栏精简 + 无边框断链确认 + 充电闪电呼吸图标', (
    tester,
  ) async {
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(id: 'd1', name: 'DYJ_A1B2C3', rssi: -45),
        CardDevice(id: 'd2', name: 'DYJV2_X9Y8Z7', rssi: -55),
        CardDevice(id: 'd3', name: 'REAI_VB_K1M2N3', rssi: -65),
      ],
    );
    final device = DeviceStore(gateway: gateway);
    await pumpShell(tester, device: device);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    await tester.pump();

    // 扫描列表中产品代际徽章置前，名称去掉前缀+下划线，仅保留蓝牙编号
    expect(find.byKey(const Key('dev-kind-d1')), findsOneWidget);
    expect(find.byKey(const Key('dev-kind-d2')), findsOneWidget);
    expect(find.byKey(const Key('dev-kind-d3')), findsOneWidget);
    expect(find.text('A1B2C3'), findsOneWidget);
    expect(find.text('X9Y8Z7'), findsOneWidget);
    expect(find.text('K1M2N3'), findsOneWidget);
    expect(find.text('DYJ_A1B2C3'), findsNothing);

    final badgeRect = tester.getRect(find.byKey(const Key('dev-kind-d1')));
    final nameRect = tester.getRect(find.text('A1B2C3'));
    expect(badgeRect.left, lessThan(nameRect.left));

    // 点击连接 d2 → 顶部显示徽章 + 编号 + 无边框断链 icon + 蓝牙 icon + 固件，不显示「已连接」和「可用」容量
    gateway.current = const CardSnapshot(
      batteryLevel: 68,
      isCharging: true,
      wifiOpen: false,
      recording: false,
      fwVersion: '3.13',
      fwVersionCode: 313,
      wifiVersion: '1.5.0',
      wifiVersionCode: 15,
      deviceName: 'DYJV2_X9Y8Z7',
      deviceId: 'd2',
    );
    await tester.tap(find.byKey(const Key('dev-item-d2')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('dev-main')), findsOneWidget);
    expect(find.byKey(const Key('dev-header-kind')), findsOneWidget);
    expect(find.byKey(const Key('dev-disconnect')), findsOneWidget);
    expect(find.byKey(const Key('dev-bt-icon')), findsOneWidget);
    expect(find.text('X9Y8Z7'), findsOneWidget);
    expect(find.textContaining('固件 3.13'), findsOneWidget);
    expect(find.textContaining('已连接'), findsNothing);
    expect(find.textContaining('可用'), findsNothing);

    // 充电状态显示闪电标识（顶栏胶囊 + 弹层电量行）
    expect(find.byKey(const Key('batt-bolt')), findsNWidgets(2));

    // 断链图标弹出二次确认弹窗
    await tester.tap(find.byKey(const Key('dev-disconnect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('disconnect-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('disconnect-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(device.isConnected, isTrue);

    device.closeSheet();
    await tester.pump();
  });

  testWidgets('3. 未连卡开启本机录音 + 硬件录音中点升级确认无缝切本机录音与恢复', (
    tester,
  ) async {
    final gateway = FakeCardGateway(
      devices: const [
        CardDevice(id: 'rec-1', name: 'DYJV2_REC01'),
      ],
      initialSnapshot: const CardSnapshot(
        batteryLevel: 88,
        isCharging: false,
        wifiOpen: false,
        recording: true,
        fwVersion: '3.12',
        fwVersionCode: 312,
        wifiVersion: '1.5.0',
        wifiVersionCode: 15,
        deviceName: 'DYJV2_REC01',
        deviceId: 'rec-1',
      ),
      mainOta: const CardOtaInfo(
        version: '3.13',
        versionCode: 313,
        url: 'https://ota.example.com/313.bin',
      ),
      mainProgress: const [
        CardProgress(stage: 'dfu', percent: 40, text: '写入主控…'),
        CardProgress(stage: 'dfu', percent: 100, text: '完成'),
      ],
      progressDelay: const Duration(milliseconds: 50),
      postMainOtaSnapshot: const CardSnapshot(
        batteryLevel: 88,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '3.13',
        fwVersionCode: 313,
        wifiVersion: '1.5.0',
        wifiVersionCode: 15,
        deviceName: 'DYJV2_REC01',
        deviceId: 'rec-1',
      ),
    );
    final micBackend = _FakePhoneMicBackend();
    final liveAct = _FakeLiveActivityService();
    final tmpDir = Directory.systemTemp.createTempSync('rc-phone-mic-test-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    // A) 未连卡时，可独立开关本机录音，胶囊展示「本机录音」并同步灵动岛
    final standaloneDevice = DeviceStore(
      gateway: FakeCardGateway(),
      phoneMicBackend: micBackend,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: liveAct,
    );
    await pumpShell(tester, device: standaloneDevice);

    await tester.tap(find.byKey(const Key('hw-capsule')));
    await tester.pump();
    expect(find.byKey(const Key('phone-rec-row')), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone-rec-toggle')));
    await tester.pump();
    expect(standaloneDevice.isPhoneRecording, isTrue);
    expect(micBackend.capturing, isTrue);
    expect(liveAct.startCount, 1);
    expect(find.byKey(const Key('capsule-phone-rec')), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone-rec-toggle')));
    await tester.pump();
    expect(standaloneDevice.isPhoneRecording, isFalse);
    expect(liveAct.stopCount, 1);
    standaloneDevice.closeSheet();
    await tester.pump();

    // B) 硬件录音中进入固件升级：弹出确认弹窗，确认后自动停硬件、开本机录音，重连后关闭本机录音
    final otaMic = _FakePhoneMicBackend();
    final otaDevice = DeviceStore(
      gateway: gateway,
      phoneMicBackend: otaMic,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: _FakeLiveActivityService(),
    );
    addTearDown(otaDevice.dispose);
    await otaDevice.connectTo(
      const CardDevice(id: 'rec-1', name: 'DYJV2_REC01'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: Stack(children: [StatusSheetOverlay(store: otaDevice)]),
        ),
      ),
    );
    otaDevice.openSheet();
    await tester.pump();
    await tester.tap(find.byKey(const Key('fw-update')));
    await tester.pump();
    expect(find.byKey(const Key('dev-upg')), findsOneWidget);
    await tester.tap(find.byKey(const Key('upg-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ota-rec-confirm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ota-rec-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(otaDevice.isPhoneRecording, isTrue);
    expect(otaMic.startCalls, 1);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(otaDevice.fwStage, FwStage.done);
    expect(otaDevice.isPhoneRecording, isFalse);
    expect(otaMic.stopCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('4. Setting 顶部「云端账号授权」与第三方绑定页（外脑 / 微信 / Apple，过滤未上线入口）', (
    tester,
  ) async {
    final auth = _TestAuthService(signedIn: true);
    addTearDown(auth.dispose);
    await auth.ready;

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    addTearDown(agentConfig.dispose);
    final store = AppStore(
      events: seedEvents,
      generator: await SummaryModel().generator(),
      loadPersistedState: false,
    );
    final device = DeviceStore(gateway: FakeCardGateway());
    addTearDown(store.dispose);
    addTearDown(device.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: store,
          device: device,
          agentConfig: agentConfig,
          authService: auth,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();

    expect(find.text('账号与云端鉴权'), findsOneWidget);
    expect(find.byKey(const Key('set-auth-entry')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-auth'))).data,
      'owner@wainao.chat',
    );

    await tester.tap(find.byKey(const Key('set-auth-entry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-signout-btn')), findsOneWidget);
    expect(find.byKey(const Key('auth-bind-wechat')), findsOneWidget);
    expect(find.byKey(const Key('auth-bind-apple')), findsOneWidget);
    expect(find.byKey(const Key('auth-bind-github')), findsNothing);
    expect(find.byKey(const Key('auth-bind-facebook')), findsNothing);
  });

  testWidgets('5. 本地语音三引擎：移除校验、就绪隐藏下载、卡片右上角垃圾桶删除前必弹风险确认框', (
    tester,
  ) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('rc-local-engine-'),
    );
    addTearDown(() => root?.deleteSync(recursive: true));

    final installer = ModelInstaller(root: root);
    for (final spec in const [
      senseVoiceSpec,
      sileroVadSpec,
      campplusEmbeddingSpec,
    ]) {
      final dir = await tester.runAsync(() => installer.dirFor(spec));
      dir!.createSync(recursive: true);
      for (final f in spec.files) {
        final file = File('${dir.path}/${f.relPath}');
        file.parent.createSync(recursive: true);
        final raf = file.openSync(mode: FileMode.write);
        raf.truncateSync(f.sizeBytes > 0 ? f.sizeBytes : 1024);
        raf.closeSync();
      }
    }

    final controller = ModelManagerController(
      installer: installer,
      baseUrl: 'https://models.example.com',
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.refresh);
    expect(controller.allReady, isTrue);

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    addTearDown(agentConfig.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: SettingSubPage(
          subId: 'local',
          agentConfig: agentConfig,
          modelManager: controller,
          standalone: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('local-verify-btn')), findsNothing);
    expect(find.byKey(const Key('model-install-all')), findsNothing);
    expect(find.text('本地转写已就绪'), findsOneWidget);

    final delFinder = find.byKey(Key('model-delete-${senseVoiceSpec.id}'));
    expect(delFinder, findsOneWidget);
    await tester.tap(delFinder);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('model-delete-confirm-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('重新下载'), findsOneWidget);

    await tester.tap(find.byKey(const Key('model-delete-confirm-btn')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
    expect(controller.statusFor(senseVoiceSpec)?.installed, isFalse);
  });

  testWidgets('6. 云端模型默认外脑，服务商配置按需显示', (tester) async {
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: SettingPage(settings: settings, agentConfig: config),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('set-cloud-model')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cloud-provider-wainao')), findsOneWidget);
    expect(find.byKey(const Key('cloud-enable-switch')), findsNothing);
    expect(find.byKey(const Key('cloud-provider-key')), findsNothing);
    await tester.tap(find.byKey(const Key('cloud-provider-openai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-provider-key')), findsOneWidget);
    expect(find.byKey(const Key('cloud-provider-url')), findsNothing);
    await tester.tap(find.byKey(const Key('cloud-provider-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-provider-url')), findsOneWidget);
  });

  test('迁移后等待用户选择模型服务时不发送请求', () async {
    final tokens = await buildSignedInTokenStore();
    final gateway = ModelGateway(
      client: AuthorizedHttpClient(
        tokenStore: tokens,
        httpClient: MockClient((_) async => throw StateError('不应发送请求')),
      ),
      config: kStubModelConfig,
      enabledCheck: () => false,
    );
    await expectLater(
      gateway.chat([const ChatMessage.user('hi')]),
      throwsA(isA<ApiNotConfiguredException>()),
    );
  });

  testWidgets('交叉反馈 #1~#3：相册权限弹窗确认、灵动岛按机型隐藏、Timeline 录音状态块对齐原型', (
    tester,
  ) async {
    final agentConfig = AgentConfigStore(store: InMemoryStore());
    addTearDown(agentConfig.dispose);
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);

    var reqCount = 0;
    final photoLib = PhotoLibraryService(
      statusOverride: () async => PhotoPermissionState.notDetermined,
      requestOverride: () async {
        reqCount += 1;
        return PhotoPermissionState.granted;
      },
    );

    // 1) supportsDynamicIsland=false（例如 iPhone 13 mini）时隐藏「灵动岛与操作按钮」
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: SettingPage(
            settings: settings,
            agentConfig: agentConfig,
            photoLibrary: photoLib,
            supportsDynamicIsland: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('set-dynamic-island')), findsNothing);

    // 关联录音期间系统相册照片：默认开启；先关闭再重新开启时弹权限说明框，授权后恢复开启
    await tester.scrollUntilVisible(
      find.byKey(const Key('set-photo-import')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(agentConfig.photoLinkEnabled, isTrue);
    expect(find.byKey(const Key('sw-photo-sync')), findsOneWidget);
    expect(find.text('已开启 · 每分钟随切片自动对齐'), findsOneWidget);
    await tester.tap(find.byKey(const Key('set-photo-import')));
    await tester.pumpAndSettle();
    expect(agentConfig.photoLinkEnabled, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const Key('set-photo-import')),
        matching: find.text('已关闭'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('set-photo-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-perm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-perm-grant')));
    await tester.pumpAndSettle();
    expect(reqCount, 1);
    expect(agentConfig.photoLinkEnabled, isTrue);
    expect(find.text('已开启 · 每分钟随切片自动对齐'), findsOneWidget);

    // 2) supportsDynamicIsland=true 时展示「灵动岛与操作按钮」
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: SettingPage(
            settings: settings,
            agentConfig: agentConfig,
            supportsDynamicIsland: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('set-dynamic-island')), findsOneWidget);

    // 3) Timeline 录音状态块严格展示 7x7 圆点与「每满 15 分钟或查看时转写」
    final rec = RecordingStatusController();
    addTearDown(rec.dispose);
    rec.startRecording();
    rec.updateElapsed(75);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(body: RecordingStatusBlock(controller: rec)),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('recording-status-dot'))),
      const Size(7, 7),
    );
    expect(find.textContaining('每满 15 分钟或查看时转写'), findsOneWidget);
  });
}
