/// 退出登录自动关闭本机/硬件录音与灵动岛回归测试。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/auth/auth.dart';
import 'package:recording_card/services/auth_service.dart';
import 'package:recording_card/services/photos/photo_library_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _FakePhoneMicBackend implements PhoneMicBackend {
  PhoneMicPermission permission = PhoneMicPermission.granted;
  bool capturing = false;
  int startCalls = 0;
  int stopCalls = 0;
  void Function(Uint8List pcm16Mono16k)? onPcmCallback;

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
    onPcmCallback = onPcm;
  }

  @override
  Future<void> stopCapture() async {
    stopCalls += 1;
    capturing = false;
    onPcmCallback = null;
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

class _FakeTokenStore extends OAuthTokenStore {
  _FakeTokenStore({required bool signedIn})
    : _signedIn = signedIn,
      super(
        secure: InMemorySecureStore(),
        client: OAuthClient(
          config: kStubOAuthConfig,
          httpClient: _SilentHttpClient(),
        ),
        config: kStubOAuthConfig,
      );

  bool _signedIn;

  @override
  bool get hasSession => _signedIn;

  @override
  OAuthAccount? get account => _signedIn
      ? const OAuthAccount(
          userId: 'u-owner',
          name: 'owner@wainao.chat',
          email: 'owner@wainao.chat',
        )
      : null;

  @override
  String? get accessToken => _signedIn ? 'test-access-token' : null;

  @override
  DateTime? get accessExpiresAt =>
      _signedIn ? DateTime(2099, 1, 1) : null;

  @override
  bool get hasValidRefreshToken => _signedIn;

  @override
  Future<void> clear({bool clearAccount = true}) async {
    _signedIn = false;
  }
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

class _TestAuthService extends AuthService {
  _TestAuthService({required bool signedIn})
    : super(
        tokenStore: _FakeTokenStore(signedIn: signedIn),
        oauthClient: OAuthClient(
          config: kStubOAuthConfig,
          httpClient: _SilentHttpClient(),
        ),
        launcher: _MockLauncher(),
      );
}

class _FailingStopGateway extends FakeCardGateway {
  _FailingStopGateway({super.initialSnapshot});

  @override
  Future<void> stopRecording() async {
    recordCalls.add('stop');
    callLog.add('record.stop');
    throw CardException.disconnected('蓝牙停录失败');
  }
}

Future<void> _openAuthSubPage(
  WidgetTester tester, {
  required AppStore store,
  required DeviceStore device,
  required AgentConfigStore agentConfig,
  required AuthService auth,
}) async {
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
        photoLibrary: PhotoLibraryService(
          statusOverride: () async => PhotoPermissionState.denied,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('nav-setting')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('set-auth-entry')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('1. 非录音态点退出登录直接登出，不弹录音确认弹窗', (tester) async {
    final auth = _TestAuthService(signedIn: true);
    addTearDown(auth.dispose);
    await auth.ready;

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    final store = AppStore(
      events: seedEvents,
      generator: await SummaryModel().generator(),
      loadPersistedState: false,
    );
    final device = DeviceStore(gateway: FakeCardGateway());
    addTearDown(agentConfig.dispose);
    addTearDown(store.dispose);
    addTearDown(device.dispose);

    await _openAuthSubPage(
      tester,
      store: store,
      device: device,
      agentConfig: agentConfig,
      auth: auth,
    );

    expect(auth.isSignedIn, isTrue);
    await tester.tap(find.byKey(const Key('auth-signout-btn')));
    await tester.pump();

    expect(
      find.byKey(const Key('signout-recording-confirm-dialog')),
      findsNothing,
    );
    expect(auth.isSignedIn, isFalse);
  });

  testWidgets('2. 本机录音中退出登录：弹窗提示，取消继续录音，确认后停录+关灵动岛+刷尾片并登出', (
    tester,
  ) async {
    final auth = _TestAuthService(signedIn: true);
    addTearDown(auth.dispose);
    await auth.ready;

    final tmpDir = Directory.systemTemp.createTempSync('rc-signout-phone-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final micBackend = _FakePhoneMicBackend();
    final liveAct = _FakeLiveActivityService();
    final recorder = PhoneMicRecorder(sliceRootDir: () async => tmpDir);
    final device = DeviceStore(
      gateway: FakeCardGateway(),
      phoneMicBackend: micBackend,
      phoneMicRecorder: recorder,
      liveActivityService: liveAct,
    );
    final agentConfig = AgentConfigStore(store: InMemoryStore());
    final store = AppStore(
      events: seedEvents,
      generator: await SummaryModel().generator(),
      loadPersistedState: false,
    );
    addTearDown(agentConfig.dispose);
    addTearDown(store.dispose);
    addTearDown(device.dispose);

    await _openAuthSubPage(
      tester,
      store: store,
      device: device,
      agentConfig: agentConfig,
      auth: auth,
    );

    expect(await device.startPhoneRecording(), isTrue);
    micBackend.onPcmCallback?.call(Uint8List(3200));
    await tester.pump();
    expect(device.isPhoneRecording, isTrue);
    expect(liveAct.startCount, 1);

    await tester.tap(find.byKey(const Key('auth-signout-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const Key('signout-recording-confirm-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('自动关闭录音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('signout-recording-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(device.isPhoneRecording, isTrue);
    expect(micBackend.capturing, isTrue);
    expect(auth.isSignedIn, isTrue);

    await tester.tap(find.byKey(const Key('auth-signout-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('signout-recording-confirm')));
    for (var i = 0; i < 15 && (device.isPhoneRecording || auth.isSignedIn); i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(device.isPhoneRecording, isFalse);
    expect(micBackend.capturing, isFalse);
    expect(micBackend.stopCalls, greaterThanOrEqualTo(1));
    expect(liveAct.stopCount, greaterThanOrEqualTo(1));
    expect(auth.isSignedIn, isFalse);

    final wavFiles = tmpDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.WAV'))
        .toList();
    expect(wavFiles, isNotEmpty);
  });

  testWidgets('3. 硬件录音中退出登录：弹窗提示，确认后先发停录命令再登出', (tester) async {
    final auth = _TestAuthService(signedIn: true);
    addTearDown(auth.dispose);
    await auth.ready;

    final gateway = FakeCardGateway(initialSnapshot: defaultSnapshot);
    final liveAct = _FakeLiveActivityService();
    final device = DeviceStore(gateway: gateway, liveActivityService: liveAct);
    await device.connectTo(const CardDevice(id: 'rec-1', name: 'DYJV2_TEST'));

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    final store = AppStore(
      events: seedEvents,
      generator: await SummaryModel().generator(),
      loadPersistedState: false,
    );
    addTearDown(agentConfig.dispose);
    addTearDown(store.dispose);
    addTearDown(device.dispose);

    await _openAuthSubPage(
      tester,
      store: store,
      device: device,
      agentConfig: agentConfig,
      auth: auth,
    );

    expect(device.isConnected, isTrue);
    expect(device.isRecording, isTrue);

    await tester.tap(find.byKey(const Key('auth-signout-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const Key('signout-recording-confirm-dialog')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('signout-recording-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(gateway.recordCalls, contains('stop'));
    expect(device.isRecording, isFalse);
    expect(auth.isSignedIn, isFalse);
  });

  testWidgets('4. 蓝牙停录异常不阻塞 stopAllRecordingsForSignOut，AppShell 卸载清空侧边按钮回调', (
    tester,
  ) async {
    final gateway = _FailingStopGateway(initialSnapshot: defaultSnapshot);
    final micBackend = _FakePhoneMicBackend();
    final liveAct = _FakeLiveActivityService();
    final tmpDir = Directory.systemTemp.createTempSync('rc-signout-fail-');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final device = DeviceStore(
      gateway: gateway,
      phoneMicBackend: micBackend,
      phoneMicRecorder: PhoneMicRecorder(sliceRootDir: () async => tmpDir),
      liveActivityService: liveAct,
    );
    await device.connectTo(const CardDevice(id: 'rec-1', name: 'DYJV2_TEST'));

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    final store = AppStore(
      events: seedEvents,
      generator: await SummaryModel().generator(),
      loadPersistedState: false,
    );
    addTearDown(agentConfig.dispose);
    addTearDown(store.dispose);
    addTearDown(device.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: store,
          device: device,
          agentConfig: agentConfig,
        ),
      ),
    );
    await tester.pump();
    expect(device.liveActivityService.onActionButtonToggle, isNotNull);

    expect(await device.startPhoneRecording(), isTrue);
    await device.stopAllRecordingsForSignOut();

    expect(device.isPhoneRecording, isFalse);
    expect(micBackend.stopCalls, greaterThanOrEqualTo(1));
    expect(gateway.recordCalls, contains('stop'));
    expect(device.recordingError, isNotNull);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(device.liveActivityService.onActionButtonToggle, isNull);
  });
}
