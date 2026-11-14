/// 登录服务（应用内唯一鉴权入口）。
///
/// **本文件保留了旧版公开契约**，所以 `main.dart` / `login_page.dart` /
/// `dev_driver.dart` 不需要任何改动就能编译：
/// - `class AuthService extends ChangeNotifier`
/// - `bool get isSignedIn`、`AuthSession? get session`
/// - `String? signIn(String account, String password)`——返回 null 表示成功，
///   非 null 是可直接展示的中文错误文案
/// - `void signOut()`
///
/// 内部已经换成**真实 OAuth 2.0 授权码 + PKCE**：不再有「任意非空账号密码即通过」
/// 的假登录。`signIn` 是同步门面（为了兼容现有 UI 的同步调用），实际流程在
/// [signInWithOAuth] 里异步跑完；UI 侧建议改为 `await auth.signInWithOAuth()`。
///
/// 当前构建的已知缺口（需要在主线上决策）：
/// 1. `pubspec.yaml` 没有 `flutter_web_auth_2`，因此没有真实浏览器授权组件
///    （[UnavailableWebAuthLauncher]），`signIn` 会直接返回
///    「当前构建未内置浏览器授权组件…」；
/// 2. `RC_OAUTH_CLIENT_ID` 未配置时返回「未配置登录服务…」——**不再静默假登录**。
///
/// 这两条是刻意为之：宁可显式失败，也不要让用户以为登录成功了。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config/auth_mode.dart';
import '../core/config/remote/client_config.dart';
import '../core/storage/secure_store.dart';
import 'auth/auth.dart';
import 'net/authorized_http_client.dart';
import 'wechat_login/wechat_login_service.dart';

/// 当前登录流程的通道（UI 据此决定哪个按钮转圈）。
enum AuthChannel { none, oauth, wechat, apple, google }

/// 登录会话（进程内快照；真正的 token 在 [OAuthTokenStore] / 系统密钥库里）。
class AuthSession {
  const AuthSession({
    required this.account,
    required this.issuedAt,
    this.userId,
    this.email,
    this.avatarUrl,
  });

  /// 展示用账号名（显示名 > 邮箱 > 用户 ID）。
  final String account;

  /// 建立会话的时间。
  final DateTime issuedAt;

  /// 服务端用户 ID（未校验身份时为 null）。
  final String? userId;

  /// 邮箱（可能为 null）。
  final String? email;

  /// 头像地址（可能为 null）。
  final String? avatarUrl;
}

/// 一次授权流程的临时状态（内存级；进程被杀即失效）。
class _PendingAuthorization {
  const _PendingAuthorization({
    required this.state,
    required this.codeVerifier,
    required this.startedAt,
  });

  final String state;
  final String codeVerifier;
  final DateTime startedAt;
}

/// 鉴权服务。
class AuthService extends ChangeNotifier {
  AuthService({
    ClientConfig? config,
    OAuthConfig? oauthConfig,
    WebAuthLauncher? launcher,
    WechatLoginGateway? wechatGateway,
    OAuthClient? oauthClient,
    OAuthTokenStore? tokenStore,
    SecureStore? secureStore,
    Set<String>? initialSocialProviders,
    DateTime Function()? clock,
  })  : _config = config ?? ClientConfig.instance,
        _oauthConfig = oauthConfig ??
            OAuthConfig.fromEnvironment(clientConfig: config),
        _clock = clock ?? DateTime.now {
    _launcher = launcher ?? const FlutterWebAuthLauncher();
    final preset = initialSocialProviders ?? _oauthConfig.socialProvidersOverride;
    if (preset != null) {
      _cachedSocialProviders = Set<String>.unmodifiable(preset);
    }
    _wechat = wechatGateway ??
        WechatLoginService(
          wechatAppId: _oauthConfig.wechatAppId,
          universalLink: _oauthConfig.wechatUniversalLink,
        );
    final client = oauthClient ?? OAuthClient(config: _oauthConfig);
    _ownsOAuthClient = oauthClient == null;
    _client = client;
    _tokens = tokenStore ??
        OAuthTokenStore(
          secure: secureStore ?? KeychainSecureStore(),
          client: client,
          config: _oauthConfig,
          clock: _clock,
        );
    // 会话彻底失效（服务端判定 refresh token 已死）→ 本地同步登出，UI 回登录页。
    _tokens.onSessionInvalidated = _handleSessionInvalidated;
    _bootstrapFuture = _bootstrap();
  }

  final ClientConfig _config;
  final OAuthConfig _oauthConfig;
  late final OAuthClient _client;
  late final OAuthTokenStore _tokens;
  final DateTime Function() _clock;

  late final WebAuthLauncher _launcher;
  late final WechatLoginGateway _wechat;
  bool _ownsOAuthClient = false;

  AuthSession? _session;
  String? _lastError;
  bool _busy = false;
  bool _disposed = false;
  _PendingAuthorization? _pending;

  /// 当前在途流程的通道（none = 空闲）；UI 据此决定哪个按钮转圈。
  AuthChannel _activeChannel = AuthChannel.none;

  /// 已探测的线上可用社会化登录渠道（null = 未探测，避免显示失效按钮）。
  Set<String>? _cachedSocialProviders;

  /// 授权流程代次：登出会 +1，让在途流程的回调自我作废（防「登出后又被登录」）。
  int _authFlowEpoch = 0;

  AuthorizedHttpClient? _apiClient;

  late final Future<void> _bootstrapFuture;

  // ===== 兼容旧契约的公开面 =====

  /// 当前会话；null = 未登录。
  AuthSession? get session => _session;

  /// 是否已登录。
  bool get isSignedIn => _session != null;

  /// 是否处于「远端 OAuth 模式」（旧接口，语义保持：OAuth 模式且登录服务已配置）。
  bool get useRemoteOAuth =>
      kIsOAuthAuthMode && _oauthConfig.isConfigured && _config.hasRemoteBackend;

  /// 最近一次错误的用户可读文案（成功登录后清空）。
  String? get lastError => _lastError;

  /// 是否正在进行授权（UI 可用来转圈 / 禁用按钮）。
  bool get isBusy => _busy;

  /// 当前在途流程的通道；UI 据此决定哪个按钮显示转圈。
  AuthChannel get activeChannel => _activeChannel;

  /// 登录服务是否配置齐全（client id + 端点）。
  bool get isOAuthConfigured => _oauthConfig.isConfigured;

  /// 当前构建是否具备真实浏览器授权能力（无 flutter_web_auth_2 时为 false）。
  bool get isWebAuthAvailable => _launcher.isSupported;

  /// 登录前就能告诉用户「为什么登不了」的预检文案；null = 可以发起登录。
  ///
  /// UI 建议直接用：非空时把登录按钮置灰并展示该文案。
  String? get signInBlockedReason {
    if (!kIsOAuthAuthMode) return '当前构建未启用登录服务';
    if (!_oauthConfig.isConfigured) return '未配置登录服务，暂时无法登录';
    if (!_launcher.isSupported) return '当前构建未内置浏览器授权组件，暂时无法完成登录';
    return null;
  }

  /// 微信登录的预检文案；null = 可以发起微信登录。
  ///
  /// 门控拆分：OAuth 服务整体未配置时**连坐禁用**微信按钮（换 token 也走同一
  /// 端点/client_id）；仅浏览器组件缺失不连坐（不影响微信原生链路）。
  String? get wechatSignInBlockedReason {
    if (!kIsOAuthAuthMode) return '当前构建未启用登录服务';
    if (!_oauthConfig.isConfigured) return '未配置登录服务，暂时无法登录';
    if (!_wechat.isSupported) return '当前构建不支持微信登录';
    if (!_wechat.isConfigured) return '当前未配置微信登录，请使用上方方式登录';
    return null;
  }

  /// 登录页是否展示微信按钮：
  /// - 平台支持微信 SDK；
  /// - 微信开放平台审核通过配置 AppID 前（`!_wechat.isConfigured`）仍展示按钮，
  ///   由 [wechatSignInBlockedReason] 使其保持 disabled 状态；
  /// - 已配置 AppID 后，若明确探测到本机未安装微信（`cachedIsInstalled == false`）则隐藏（App Store 4.2.3）。
  bool get shouldShowWechatSignIn =>
      _wechat.isSupported &&
      (!_wechat.isConfigured || _wechat.cachedIsInstalled != false);

  /// 已探测的线上可用社会化登录渠道（null = 尚未完成探测）。
  Set<String>? get cachedSocialProviders => _cachedSocialProviders;

  /// 登录页是否展示「通过 Apple 登录」按钮（具备系统浏览器授权能力时常驻展示，未开通时置为 disabled）。
  bool get shouldShowAppleSignIn => _launcher.isSupported;

  /// 「通过 Apple 登录」当前是否可点击（登录服务已就绪且服务端已开启 `apple`）。
  bool get isAppleSignInEnabled =>
      signInBlockedReason == null &&
      (_cachedSocialProviders?.contains('apple') ?? false);

  /// 登录页是否展示「通过 Google 登录」按钮（具备系统浏览器授权能力时常驻展示，未开通时置为 disabled）。
  bool get shouldShowGoogleSignIn => _launcher.isSupported;

  /// 「通过 Google 登录」当前是否可点击（登录服务已就绪且服务端已开启 `google`）。
  bool get isGoogleSignInEnabled =>
      signInBlockedReason == null &&
      (_cachedSocialProviders?.contains('google') ?? false);

  /// 首次本地会话恢复完成（测试里 `await auth.ready` 可拿到确定的初始状态）。
  Future<void> get ready => _bootstrapFuture;

  /// 登录（**同步门面**，保持旧契约）。
  ///
  /// 返回 null 表示「登录流程已被接受」；非 null 是错误文案。
  ///
  /// 因为真实 OAuth 必须异步完成，这里对需要浏览器交互的情况会启动
  /// [signInWithOAuth]（fire-and-forget），结果通过 [lastError] +
  /// `notifyListeners()` 通知 UI。**新 UI 请直接 `await signInWithOAuth()`**，
  /// 才能拿到确定的成败。
  String? signIn(String account, String password) {
    final a = account.trim();
    if (a.isEmpty) return _fail('请输入账号');
    if (password.isEmpty) return _fail('请输入密码');

    final blocked = signInBlockedReason;
    if (blocked != null) return _fail(blocked);

    unawaited(signInWithOAuth(loginHint: a));
    return null;
  }

  /// 走完真实 OAuth 登录：拉起浏览器授权 → 校验 state → 换 token → 拉 profile →
  /// 落密钥库 → 建立会话。
  ///
  /// [loginType] 透传外脑 `/oauth/authorize` 白名单（如 `'apple'` / `'google'`），
  /// 用于在授权页直接聚焦单一登录入口；[channel] 决定 UI 哪个按钮显示转圈。
  /// 返回 null 表示登录成功；非 null 是可直接展示的错误文案。
  /// 不论成功失败都会 `notifyListeners()`。
  Future<String?> signInWithOAuth({
    String? loginHint,
    String? loginType,
    AuthChannel channel = AuthChannel.oauth,
  }) async {
    if (_busy) return '登录正在进行中，请稍候';
    final blocked = signInBlockedReason;
    if (blocked != null) return _fail(blocked);

    final epoch = ++_authFlowEpoch;
    _busy = true;
    _activeChannel = channel == AuthChannel.none ? AuthChannel.oauth : channel;
    _lastError = null;
    _notify();

    try {
      final request = _client.createAuthorizationRequest(
        loginHint: loginHint,
        loginType: loginType,
      );
      _pending = _PendingAuthorization(
        state: request.state,
        codeVerifier: request.pkce.codeVerifier,
        startedAt: _clock(),
      );

      final callback = await _launcher.launch(
        authorizeUrl: request.url,
        callbackScheme: _oauthConfig.callbackScheme,
      );
      if (epoch != _authFlowEpoch) return null; // 期间已登出 / 已有新流程

      final code = _extractAuthorizationCode(callback);
      final tokenResponse = await _client.exchangeCodeForToken(
        code: code,
        codeVerifier: request.pkce.codeVerifier,
      );
      if (epoch != _authFlowEpoch) return null;

      // 换到 token 后立刻用 /profile 确认身份（也验证 token 真的可用）。
      final account = await _client.fetchProfile(tokenResponse.accessToken);
      if (epoch != _authFlowEpoch) {
        // 期间登出：把刚拿到的 token 落库反而会「复活」会话，直接丢弃。
        unawaited(_revokeQuietly(tokenResponse.refreshToken ?? tokenResponse.accessToken));
        return null;
      }

      await _tokens.saveTokens(tokenResponse, account: account);
      _applySession(account);
      _lastError = null;
      return null;
    } on OAuthCancelledException {
      // 用户主动取消：不当错误提示，UI 静默留在登录页并清空旧错误。
      _lastError = null;
      return null;
    } on OAuthException catch (e) {
      if (epoch != _authFlowEpoch) return null;
      final message = e.message;
      _lastError = message;
      return message;
    } catch (e) {
      if (epoch != _authFlowEpoch) return null;
      // 兜底：不吞异常语义，给用户一个明确文案，细节只进日志。
      debugPrint('[AuthService] 登录异常: $e');
      const message = '登录失败，请稍后重试';
      _lastError = message;
      return message;
    } finally {
      _pending = null;
      if (epoch == _authFlowEpoch) {
        _busy = false;
        _activeChannel = AuthChannel.none;
      }
      _notify();
    }
  }

  /// 借用外脑 OAuth 流程（`login_type=apple`）通过 Apple 登录。
  Future<String?> signInWithApple() =>
      signInWithOAuth(loginType: 'apple', channel: AuthChannel.apple);

  /// 借用外脑 OAuth 流程（`login_type=google`）通过 Google 登录。
  Future<String?> signInWithGoogle() =>
      signInWithOAuth(loginType: 'google', channel: AuthChannel.google);

  /// 启动预热：探测服务端已启用的社会化登录渠道（`/auth/social/providers`）。
  ///
  /// 异常一律吞掉（弱网/离线/未配置时不阻塞启动），编译期覆盖（`RC_SOCIAL_PROVIDERS`）优先。
  Future<void> prewarmSocialProviders() async {
    if (_disposed) return;
    final override = _oauthConfig.socialProvidersOverride;
    if (override != null) {
      _cachedSocialProviders = override;
      _notify();
      return;
    }
    if (_oauthConfig.socialProvidersUrl == null) return;
    try {
      final providers = await _client.fetchSocialProviders(
        timeout: const Duration(seconds: 4),
      );
      if (!_disposed) {
        _cachedSocialProviders = providers;
      }
    } catch (e) {
      debugPrint('[AuthService] 社会化登录渠道探测跳过: $e');
    }
    _notify();
  }

  /// 微信原生登录：拉起微信授权 → 换 token → 拉 profile → 落密钥库 → 建立会话。
  ///
  /// 与 [signInWithOAuth] 共用 `_busy` / `_authFlowEpoch` / 门控，
  /// 在途期间浏览器登录按钮同样被禁用（防双通道并发）。
  /// 返回 null 表示成功或用户取消（取消静默、并清空旧错误文案）；
  /// 非 null 是可直接展示的错误文案。
  Future<String?> signInWithWechat() async {
    if (_busy) return '登录正在进行中，请稍候';
    final blocked = wechatSignInBlockedReason;
    if (blocked != null) return _fail(blocked);

    final epoch = ++_authFlowEpoch;
    _busy = true;
    _activeChannel = AuthChannel.wechat;
    _lastError = null;
    _notify();

    try {
      final authorization = await _wechat.authorize();
      if (epoch != _authFlowEpoch) return null; // 期间已登出 / 已有新流程
      return await _completeWechatLogin(
        epoch,
        code: authorization.code,
        lang: authorization.lang,
      );
    } on WechatLoginException catch (e) {
      if (epoch != _authFlowEpoch) return null;
      return _failWechat(e);
    } catch (e) {
      if (epoch != _authFlowEpoch) return null;
      debugPrint('[AuthService] 微信登录异常: $e');
      const message = '登录失败，请稍后重试';
      _lastError = message;
      return message;
    } finally {
      if (epoch == _authFlowEpoch) {
        _busy = false;
        _activeChannel = AuthChannel.none;
      }
      _notify();
    }
  }

  /// 用已取得的微信授权码完成登录（[signInWithWechat] 的后半段；
  /// 公开给单测直接注入 code 验证换 token 链路）。
  Future<String?> signInWithWechatCode({
    required String code,
    String? lang,
  }) async {
    if (_busy) return '登录正在进行中，请稍候';
    final blocked = wechatSignInBlockedReason;
    if (blocked != null) return _fail(blocked);

    final epoch = ++_authFlowEpoch;
    _busy = true;
    _activeChannel = AuthChannel.wechat;
    _lastError = null;
    _notify();
    try {
      return await _completeWechatLogin(epoch, code: code, lang: lang);
    } finally {
      if (epoch == _authFlowEpoch) {
        _busy = false;
        _activeChannel = AuthChannel.none;
      }
      _notify();
    }
  }

  Future<String?> _completeWechatLogin(
    int epoch, {
    required String code,
    String? lang,
  }) async {
    try {
      final tokenResponse = await _client.exchangeWechatCodeForToken(
        code: code,
        lang: lang,
      );
      if (epoch != _authFlowEpoch) return null;

      // 换到 token 后立刻用 /profile 确认身份（也验证 token 真的可用）。
      final account = await _client.fetchProfile(tokenResponse.accessToken);
      if (epoch != _authFlowEpoch) {
        // 期间登出：把刚拿到的 token 落库反而会「复活」会话，直接丢弃。
        unawaited(
          _revokeQuietly(tokenResponse.refreshToken ?? tokenResponse.accessToken),
        );
        return null;
      }

      await _tokens.saveTokens(tokenResponse, account: account);
      _applySession(account);
      _lastError = null;
      return null;
    } on OAuthException catch (e) {
      if (epoch != _authFlowEpoch) return null;
      final message = e.message;
      _lastError = message;
      return message;
    } catch (e) {
      if (epoch != _authFlowEpoch) return null;
      debugPrint('[AuthService] 微信登录换票异常: $e');
      const message = '登录失败，请稍后重试';
      _lastError = message;
      return message;
    }
  }

  /// 启动预热：注册微信 SDK 并探测是否安装（更新 [WechatLoginGateway.cachedIsInstalled]，
  /// 登录页据此决定微信按钮显隐）。
  ///
  /// 异常一律吞掉（未配置 / 无通道 / 超时都不阻塞 App 启动）——预热的唯一
  /// 目的是降低首次点击微信登录的延迟与提供按钮显隐依据。
  Future<void> prewarmWechat() async {
    final gateway = _wechat;
    if (_disposed || !gateway.isSupported || !gateway.isConfigured) return;
    try {
      await gateway.initialize().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[AuthService] 微信预注册跳过: $e');
    }
    _notify();
  }

  /// 微信失败枚举 → 用户文案；取消返回 null 且清空旧错误（静默）。
  String? _failWechat(WechatLoginException e) {
    switch (e.kind) {
      case WechatLoginFailureKind.cancelled:
        _lastError = null;
        return null;
      case WechatLoginFailureKind.notConfigured:
        return _fail('当前未配置微信登录，请使用上方方式登录');
      case WechatLoginFailureKind.notInstalled:
        return _fail('未检测到微信，请使用上方方式登录');
      case WechatLoginFailureKind.denied:
        return _fail('微信授权已拒绝，请重试或使用上方方式登录');
      case WechatLoginFailureKind.timedOut:
        return _fail('微信授权超时，请重试');
      case WechatLoginFailureKind.registrationFailed:
      case WechatLoginFailureKind.launchFailed:
      case WechatLoginFailureKind.invalidResponse:
        return _fail('无法拉起微信授权，请稍后重试或使用上方方式登录');
    }
  }

  /// 校验当前会话是否仍然有效（拉一次 `/profile`）。
  ///
  /// 返回 false 且已本地登出时，UI 应回登录页。
  Future<bool> validateSession() async {
    if (!_tokens.hasSession) {
      _dropSessionLocally();
      return false;
    }
    try {
      final token = await _tokens.getValidAccessToken();
      if (token == null) {
        _dropSessionLocally();
        return false;
      }
      final account = await _client.fetchProfile(token);
      await _tokens.updateAccount(account);
      _applySession(account);
      return true;
    } on OAuthAuthRequiredException {
      _dropSessionLocally();
      return false;
    } on OAuthException catch (e) {
      // 网络类问题不代表会话失效；保留会话，把文案交给 UI 决定是否提示。
      _lastError = e.message;
      _notify();
      return _session != null;
    }
  }

  /// 登出（同步门面，保持旧契约）。
  ///
  /// 立即清空本地会话并通知 UI，随后在后台尽力撤销服务端 token。
  void signOut() {
    // 让在途授权流程的回调自我作废，并解除「登录中」状态。
    _authFlowEpoch++;
    _busy = false;
    _activeChannel = AuthChannel.none;
    _wechat.cancelPendingAuthorization();
    _dropSessionLocally();
    unawaited(_revokeAndClearRemote());
  }

  /// 网络客户端（其他模块用它发起带鉴权的请求）。
  ///
  /// 生命周跟随本服务；[dispose] 后不可再用。典型用法：
  /// ```dart
  /// final gateway = ModelGateway(client: auth.apiClient);
  /// ```
  AuthorizedHttpClient get apiClient {
    final existing = _apiClient;
    if (existing != null) return existing;
    final client = AuthorizedHttpClient(tokenStore: _tokens);
    client.onAuthRequired = _handleAuthRequired;
    _apiClient = client;
    return client;
  }

  @override
  void dispose() {
    _disposed = true;
    _wechat.cancelPendingAuthorization();
    _apiClient?.close();
    _apiClient = null;
    if (_ownsOAuthClient) _client.close();
    super.dispose();
  }

  // ===== 内部 =====

  /// 启动时恢复本地会话（不发起网络请求）。
  ///
  /// - 密钥库读取失败（如无平台通道）→ 当作未登录，不影响 App 启动；
  /// - 有 token 且有账号 → 直接恢复会话（离线也能进主界面）；
  /// - 有 token 但缺账号（旧数据/半截写入）→ 尝试拉一次 profile，
  ///   失败则保持未登录（token 不删，下次启动还能再试）。
  Future<void> _bootstrap() async {
    try {
      await _tokens.bootstrap();
    } catch (e) {
      debugPrint('[AuthService] 读取本地登录态失败，按未登录处理: $e');
      return;
    }
    if (!_tokens.hasSession) return;

    // 会话已彻底过期（access 过期且 refresh 也过期/缺失）→ 不恢复，
    // 让用户走一次真实登录，而不是进主界面后每个接口都 401。
    final accessExpires = _tokens.accessExpiresAt;
    final accessUsable = _tokens.accessToken != null &&
        (accessExpires == null || accessExpires.isAfter(_clock()));
    if (!accessUsable && !_tokens.hasValidRefreshToken) return;

    final account = _tokens.account;
    if (account != null) {
      _applySession(account);
      return;
    }
    try {
      final token = await _tokens.getValidAccessToken();
      if (token == null) return;
      final fetched = await _client.fetchProfile(token);
      await _tokens.updateAccount(fetched);
      _applySession(fetched);
    } on OAuthException catch (e) {
      debugPrint('[AuthService] 恢复会话时校验身份失败: ${e.message}');
    } catch (e) {
      debugPrint('[AuthService] 恢复会话异常: $e');
    }
  }

  /// 后台登出：撤销服务端 token + 清密钥库。
  Future<void> _revokeAndClearRemote() async {
    final access = _tokens.accessToken;
    final refresh = _tokens.refreshToken;
    final client = _apiClient;
    client?.setLoggingOut(true);
    try {
      if (refresh != null) {
        await _client.revoke(token: refresh, tokenTypeHint: 'refresh_token');
      } else if (access != null) {
        await _client.revoke(token: access);
      }
    } catch (e) {
      // 撤销是尽力而为：服务端不可达不应阻塞用户退出。
      debugPrint('[AuthService] 撤销 token 失败（已忽略）: $e');
    } finally {
      await _tokens.clear();
      client?.setLoggingOut(false);
    }
  }

  Future<void> _revokeQuietly(String token) async {
    try {
      await _client.revoke(token: token, tokenTypeHint: 'refresh_token');
    } catch (e) {
      debugPrint('[AuthService] 撤销新签发 token 失败（已忽略）: $e');
    }
  }

  /// 从回调 URL 里取授权码，并做 state / error 校验。
  String _extractAuthorizationCode(Uri callback) {
    final pending = _pending;
    if (pending == null) {
      throw const OAuthPendingMissingException();
    }
    if (_clock().difference(pending.startedAt) >
        _oauthConfig.pendingAuthorizationTtl) {
      throw const OAuthPendingMissingException();
    }

    final params = callback.queryParameters;
    final error = params['error'];
    if (error != null && error.isNotEmpty) {
      throw OAuthServerException(
        code: error,
        message: error == 'access_denied'
            ? '已取消登录'
            : (params['error_description'] ?? '授权失败，请稍后重试'),
      );
    }
    if (params['state'] != pending.state) {
      throw const OAuthStateMismatchException();
    }
    final code = params['code'];
    if (code == null || code.trim().isEmpty) {
      throw const OAuthServerException(
        code: 'invalid_request',
        message: '登录回调缺少授权码，请重新登录',
      );
    }
    return code.trim();
  }

  void _applySession(OAuthAccount account) {
    _session = AuthSession(
      account: account.displayName,
      issuedAt: _clock(),
      userId: account.userId,
      email: account.email,
      avatarUrl: account.avatarUrl,
    );
    _lastError = null;
    _notify();
  }

  void _dropSessionLocally() {
    _session = null;
    _notify();
  }

  /// 服务端判定会话已死（refresh token 失效）。
  ///
  /// 除了本地登出，还要把密钥库里的 token 清掉：否则下次冷启动会照着残留
  /// bundle 把用户「恢复」成一个用不了任何接口的登录态。
  void _handleSessionInvalidated() {
    _lastError = '登录已过期，请重新登录';
    _dropSessionLocally();
    unawaited(_tokens.clear());
  }

  /// 业务请求 401 且刷新失败（网络层的全局回调）。
  void _handleAuthRequired() {
    _handleSessionInvalidated();
  }

  String _fail(String message) {
    _lastError = message;
    _notify();
    return message;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
