/// 微信原生登录服务（fluwx 5.7.7 封装）。
///
/// 分层（移植自 reai_mobile_app 并按本仓约束修订）：
/// - [WechatLoginGateway]：UI / `AuthService` 只依赖该接口，单测注入 fake；
/// - [WechatSdkAdapter] / [FluwxWechatSdkAdapter]：隔离 fluwx 平台通道，
///   **Fluwx 实例懒创建**——构造本文件任何类都不会触碰 MethodChannel，
///   纯 Dart 测试（无 Flutter Binding）可直接实例化；
/// - [WechatLoginService]：注册、安装探测缓存、授权编排。
///
/// 安全边界：客户端只拿一次性微信授权 `code`（`snsapi_userinfo`），换 token
/// 由后端完成（客户端不持有 AppSecret，不碰微信 access_token/openid）。
///
/// 平台守卫：仅 iOS / Android 视为支持（[isSupported]）；桌面 / Web / 测试 VM
/// 一律 false，`AuthService` 不会在这类平台发起微信授权。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fluwx/fluwx.dart';

import '../auth/oauth_config.dart';

enum WechatLoginFailureKind {
  notConfigured,
  registrationFailed,
  notInstalled,
  launchFailed,
  cancelled,
  denied,
  timedOut,
  invalidResponse,
}

class WechatLoginException implements Exception {
  final WechatLoginFailureKind kind;
  final String? details;

  const WechatLoginException(this.kind, [this.details]);

  @override
  String toString() => 'WechatLoginException($kind)';
}

class WechatAuthorizationCode {
  final String code;
  final String? lang;

  const WechatAuthorizationCode({required this.code, this.lang});
}

/// 登录入口网关（`AuthService` 收口持有，UI 不直接接触 fluwx）。
abstract interface class WechatLoginGateway {
  /// 当前构建是否具备微信原生能力（iOS / Android 真机）。
  bool get isSupported;

  /// 是否配置了合法 AppID（`wx` 前缀；空串与 xcconfig 占位符均为 false）。
  bool get isConfigured;

  /// 微信安装探测缓存（三态）：null = 未探测（预热超时 / 纯测试环境），
  /// true = 已安装，false = 明确未安装（登录页据此隐藏按钮，App Store 4.2.3）。
  bool? get cachedIsInstalled;

  /// 注册 AppID 到 OpenSDK（幂等；同时刷新安装缓存）。
  Future<void> initialize();

  /// 拉起微信授权，拿到一次性 `code`；取消抛 [WechatLoginFailureKind.cancelled]。
  Future<WechatAuthorizationCode> authorize();
}

abstract interface class WechatSdkAdapter {
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  });

  Future<bool> get isInstalled;

  Future<bool> requestAuth({required String scope, required String state});

  void addResponseListener(
    void Function(WechatSdkAuthResponse response) listener,
  );

  void removeResponseListener(
    void Function(WechatSdkAuthResponse response) listener,
  );
}

class WechatSdkAuthResponse {
  final int? errorCode;
  final String? errorMessage;
  final String? code;
  final String? state;
  final String? lang;

  const WechatSdkAuthResponse({
    required this.errorCode,
    this.errorMessage,
    this.code,
    this.state,
    this.lang,
  });
}

class FluwxWechatSdkAdapter implements WechatSdkAdapter {
  /// 懒创建：`Fluwx()` 构造即绑 MethodChannel，必须延迟到真正调用时。
  Fluwx? _fluwxInstance;

  Fluwx get _fluwx => _fluwxInstance ??= Fluwx();

  final Map<void Function(WechatSdkAuthResponse), WeChatResponseSubscriber>
      _subscribers = {};

  @override
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  }) =>
      _fluwx.registerApi(appId: appId, universalLink: universalLink);

  @override
  Future<bool> get isInstalled => _fluwx.isWeChatInstalled;

  @override
  Future<bool> requestAuth({required String scope, required String state}) =>
      _fluwx.authBy(which: NormalAuth(scope: scope, state: state));

  @override
  void addResponseListener(
    void Function(WechatSdkAuthResponse response) listener,
  ) {
    void subscriber(WeChatResponse response) {
      if (response is! WeChatAuthResponse) return;
      listener(
        WechatSdkAuthResponse(
          errorCode: response.errCode,
          errorMessage: response.errStr,
          code: response.code,
          state: response.state,
          lang: response.lang,
        ),
      );
    }

    _subscribers[listener] = subscriber;
    _fluwx.addSubscriber(subscriber);
  }

  @override
  void removeResponseListener(
    void Function(WechatSdkAuthResponse response) listener,
  ) {
    final subscriber = _subscribers.remove(listener);
    if (subscriber != null) _fluwx.removeSubscriber(subscriber);
  }
}

class WechatLoginService implements WechatLoginGateway {
  final WechatSdkAdapter _sdk;
  final String _appId;
  final String _universalLink;
  final Duration _timeout;
  final String Function() _stateGenerator;

  Future<void>? _initialization;
  bool _registered = false;
  bool _authorizing = false;
  bool? _cachedIsInstalled;

  WechatLoginService({
    WechatSdkAdapter? sdk,
    required this.wechatAppId,
    String? universalLink,
    Duration timeout = const Duration(minutes: 2),
    String Function()? stateGenerator,
  })  : _sdk = sdk ?? FluwxWechatSdkAdapter(),
        _appId = wechatAppId.trim(),
        _universalLink =
            universalLink ?? OAuthConfig.defaultWechatUniversalLink,
        _timeout = timeout,
        _stateGenerator = stateGenerator ?? _generateState;

  /// 构造后只读保留原始入参（供测试断言）；逻辑一律走 [_appId]。
  final String wechatAppId;

  @override
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  bool get isConfigured => _appId.startsWith('wx') && _appId.length > 2;

  @override
  bool? get cachedIsInstalled => _cachedIsInstalled;

  @override
  Future<void> initialize() {
    if (!isConfigured) {
      return Future.error(
        const WechatLoginException(WechatLoginFailureKind.notConfigured),
      );
    }
    if (!isSupported) {
      // 桌面 / 测试 VM 没有原生通道：注册必失败，直接按未配置收口。
      return Future.error(
        const WechatLoginException(WechatLoginFailureKind.notConfigured),
      );
    }
    if (_registered) {
      final pending = _initialization;
      if (pending != null) return pending.then((_) => _refreshInstallCache());
      return _refreshInstallCache();
    }
    return _initialization ??= _register();
  }

  Future<void> _register() async {
    try {
      final ok = await _sdk.registerApi(
        appId: _appId,
        universalLink: _universalLink,
      );
      if (!ok) {
        throw const WechatLoginException(
          WechatLoginFailureKind.registrationFailed,
        );
      }
      _registered = true;
    } catch (error) {
      _initialization = null;
      if (error is WechatLoginException) rethrow;
      throw WechatLoginException(
        WechatLoginFailureKind.registrationFailed,
        '$error',
      );
    }
    await _refreshInstallCache();
  }

  /// 刷新安装缓存；探测失败（无通道 / 超时）保持 null，不猜。
  Future<void> _refreshInstallCache() async {
    try {
      _cachedIsInstalled = await _sdk.isInstalled;
    } catch (_) {
      _cachedIsInstalled = null;
    }
  }

  @override
  Future<WechatAuthorizationCode> authorize() async {
    if (_authorizing) {
      throw const WechatLoginException(WechatLoginFailureKind.launchFailed);
    }
    _authorizing = true;
    try {
      await initialize();
      if (!await _sdk.isInstalled) {
        _cachedIsInstalled = false;
        throw const WechatLoginException(WechatLoginFailureKind.notInstalled);
      }
      _cachedIsInstalled = true;

      final state = _stateGenerator();
      final completer = Completer<WechatAuthorizationCode>();

      void listener(WechatSdkAuthResponse response) {
        if (completer.isCompleted) return;
        // 成功回调必须严格校验 state，避免消费上一次授权的迟到 code。
        // 微信在取消/拒绝时可能不回传 state；这类失败响应不携带 code，且服务已
        // 通过 _authorizing 保证单实例只有一个在途请求，因此允许空 state 及时收尾。
        final responseState = response.state?.trim();
        final stateMatches = responseState == state;
        final isFailureWithoutState =
            response.errorCode != 0 &&
            (responseState == null || responseState.isEmpty);
        if (!stateMatches && !isFailureWithoutState) return;
        final code = response.code?.trim();
        if (response.errorCode == 0 && code != null && code.isNotEmpty) {
          completer.complete(
            WechatAuthorizationCode(code: code, lang: response.lang),
          );
          return;
        }
        if (response.errorCode == -2) {
          completer.completeError(
            const WechatLoginException(WechatLoginFailureKind.cancelled),
          );
          return;
        }
        completer.completeError(
          WechatLoginException(
            response.errorCode == -4
                ? WechatLoginFailureKind.denied
                : WechatLoginFailureKind.invalidResponse,
            response.errorMessage,
          ),
        );
      }

      _sdk.addResponseListener(listener);
      try {
        final launched = await _sdk.requestAuth(
          scope: 'snsapi_userinfo',
          state: state,
        );
        if (!launched) {
          throw const WechatLoginException(WechatLoginFailureKind.launchFailed);
        }
        return await completer.future.timeout(
          _timeout,
          onTimeout: () =>
              throw const WechatLoginException(WechatLoginFailureKind.timedOut),
        );
      } finally {
        _sdk.removeResponseListener(listener);
      }
    } finally {
      _authorizing = false;
    }
  }

  static String _generateState() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
