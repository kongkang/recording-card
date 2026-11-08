library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'core/config/model_gateway_config.dart';
import 'core/config/oauth_config.dart';
import 'core/dev/dev_driver.dart';
import 'core/storage/kv_store.dart';
import 'core/storage/shared_prefs_store.dart';
import 'core/store/app_store.dart';
import 'core/store/device_store.dart';
import 'core/store/settings_store.dart';
import 'core/theme/tokens.dart';
import 'pages/app_shell.dart';
import 'pages/login_page.dart';
import 'services/analysis/summary_article.dart';
import 'services/audio/recording_status.dart';
import 'services/auth_service.dart';
import 'services/model_gateway/authorized_client_adapter.dart';
import 'services/model_gateway/model_gateway_client.dart';
import 'services/oauth/auth_launcher.dart';
import 'services/oauth/authorized_http_client.dart';
import 'services/oauth/oauth_client.dart';
import 'services/oauth/oauth_login_coordinator.dart';
import 'services/oauth/oauth_token_store.dart';
import 'services/oauth/secure_store.dart';
import 'services/recordings/recording_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  KvStore storage;
  try {
    storage = SharedPreferencesKvStore(await SharedPreferences.getInstance());
  } catch (_) {
    // 平台通道不可用时退回进程内存储，保证 App 仍可启动
    storage = MemoryKvStore();
  }

  final oauthTokens = OAuthTokenStore(FlutterSecureStore());
  OAuthClient? oauthClient;
  OAuthSignIn? oauthLogin;
  final oauthConfig = OAuthConfig.fromEnvironment;
  if (oauthConfig.isConfigured &&
      Uri.parse(oauthConfig.redirectUri).scheme.isNotEmpty) {
    oauthClient = OAuthClient(config: oauthConfig);
    oauthLogin = OAuthLoginCoordinator(
      oauth: oauthClient,
      tokens: oauthTokens,
      launcher: const WebAuthLauncher(),
      callbackScheme: Uri.parse(oauthConfig.redirectUri).scheme,
    );
  }

  // 云端总结：只有 OAuth + 模型网关都配置时才启用；否则保持本地生成路径。
  SummaryArticleService? summaryService;
  final gatewayConfig = ModelGatewayConfig.fromEnvironment;
  final authClient = oauthClient;
  if (gatewayConfig.isConfigured && authClient != null) {
    final authorized = AuthorizedHttpClient(
      client: http.Client(),
      oauth: authClient,
      tokens: oauthTokens,
    );
    final gateway = ModelGatewayClient(
      modelsUri: gatewayConfig.modelsUri,
      chatCompletionsUri: gatewayConfig.chatCompletionsUri,
      headers: () async => const {},
      client: AuthorizedClientAdapter(authorized),
    );
    summaryService = CloudSummaryArticleService(
      gateway: gateway,
      model: gatewayConfig.textModel,
    );
  }

  runApp(RecordingCardApp(
    storage: storage,
    oauthLogin: oauthLogin,
    oauthTokens: oauthTokens,
    summaryService: summaryService,
  ));
}

class RecordingCardApp extends StatelessWidget {
  const RecordingCardApp({
    super.key,
    required this.storage,
    this.oauthLogin,
    this.oauthTokens,
    this.summaryService,
  });

  final KvStore storage;
  final OAuthSignIn? oauthLogin;
  final OAuthTokenStore? oauthTokens;
  final SummaryArticleService? summaryService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '录音卡',
      debugShowCheckedModeBanner: false,
      theme: buildRCTheme(),
      home: _HomeGate(
        storage: storage,
        oauthLogin: oauthLogin,
        oauthTokens: oauthTokens,
        summaryService: summaryService,
      ),
    );
  }
}

/// 截图锚点（dev 驱动取帧用；release 下无引用不产生开销）
final GlobalKey _shotKey = GlobalKey();

/// 开发期帧级自查驱动（详见 dev_driver.dart；release 恒为 null）
final DevDriver? dev = kDebugMode ? DevDriver(_shotKey) : null;

class _HomeGate extends StatefulWidget {
  const _HomeGate({
    required this.storage,
    this.oauthLogin,
    this.oauthTokens,
    this.summaryService,
  });

  final KvStore storage;
  final OAuthSignIn? oauthLogin;
  final OAuthTokenStore? oauthTokens;
  final SummaryArticleService? summaryService;

  @override
  State<_HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<_HomeGate> {
  late final _auth = AuthService(
    storage: widget.storage,
    oauthLogin: widget.oauthLogin,
    oauthTokens: widget.oauthTokens,
  );
  late final _recordings = RecordingRepository(widget.storage);
  late final _store = AppStore(
    storage: widget.storage,
    recordings: _recordings,
    summaryService: widget.summaryService,
  );
  late final _device = DeviceStore(storage: widget.storage);
  late final _settings = SettingsStore(storage: widget.storage);
  final _recordingStatus = RecordingStatusController();

  @override
  void initState() {
    super.initState();
    if (dev != null) {
      dev!
        ..store = _store
        ..device = _device
        ..auth = _auth;
    }
  }

  @override
  void dispose() {
    _device.dispose();
    _settings.dispose();
    _recordingStatus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _shotKey,
      child: ListenableBuilder(
        listenable: _auth,
        builder: (context, _) => _auth.isSignedIn
            ? AppShell(
                store: _store,
                device: _device,
                settings: _settings,
                recordingStatus: _recordingStatus,
              )
            : LoginPage(auth: _auth, onSignedIn: () {}),
      ),
    );
  }
}
