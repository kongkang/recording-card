/// OAuth 2.0 客户端（Authorization Code + PKCE，public client）。
///
/// 只做「URL 构造 + HTTP 调用 + 响应解析」，**不持有任何 token 状态**；
/// 持久化由 [OAuthTokenStore] 负责，编排由 [AuthService] 负责。
/// 这样拆的好处：client 可以直接对着 mock http.Client 单测，无需平台通道。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'oauth_account.dart';
import 'oauth_config.dart';
import 'oauth_exception.dart';
import 'pkce.dart';

/// 一次授权请求的产物。
class OAuthAuthorizationRequest {
  const OAuthAuthorizationRequest({
    required this.url,
    required this.state,
    required this.pkce,
  });

  /// 要在系统浏览器里打开的授权页地址。
  final Uri url;

  /// CSRF 防护随机串，回调必须逐字符一致。
  final String state;

  /// 本次会话的 PKCE 参数（换码时回传 verifier）。
  final PkcePair pkce;
}

/// `/oauth/token` 响应。
class OAuthTokenResponse {
  const OAuthTokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.tokenType = 'Bearer',
    this.expiresIn,
    this.refreshExpiresIn,
    this.scope,
  });

  /// 访问令牌（必填）。
  final String accessToken;

  /// 刷新令牌；**轮换模式下每次刷新都会换新**，服务端不返回时沿用旧值。
  final String? refreshToken;

  /// 令牌类型（通常 Bearer）。
  final String tokenType;

  /// access_token 有效期；缺省由 [OAuthConfig.accessTokenDefaultTtl] 兜底。
  final Duration? expiresIn;

  /// refresh_token 有效期；缺省由 [OAuthConfig.refreshTokenDefaultTtl] 兜底。
  final Duration? refreshExpiresIn;

  /// 实际授予的 scope（可能与申请的不同）。
  final String? scope;

  /// 解析 token 响应；必需字段缺失抛 [OAuthServerException]（协议错误）。
  factory OAuthTokenResponse.fromJson(Map<String, dynamic> json) {
    final access = json['access_token'];
    if (access is! String || access.trim().isEmpty) {
      throw const OAuthServerException(
        code: 'invalid_response',
        message: '登录服务返回的数据不完整',
      );
    }
    final refresh = json['refresh_token'];
    return OAuthTokenResponse(
      accessToken: access.trim(),
      refreshToken:
          (refresh is String && refresh.trim().isNotEmpty) ? refresh.trim() : null,
      tokenType: (json['token_type'] as String?)?.trim() ?? 'Bearer',
      expiresIn: _seconds(json['expires_in']),
      refreshExpiresIn: _seconds(json['refresh_expires_in']),
      scope: (json['scope'] as String?)?.trim(),
    );
  }

  static Duration? _seconds(Object? raw) {
    if (raw is num && raw > 0) return Duration(seconds: raw.round());
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null && parsed > 0) return Duration(seconds: parsed);
    }
    return null;
  }
}

/// OAuth 客户端。
class OAuthClient {
  OAuthClient({
    required OAuthConfig config,
    http.Client? httpClient,
    Random? random,
  })  : _config = config,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _random = random ?? Random.secure();

  final OAuthConfig _config;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Random _random;

  /// 当前配置（只读）。
  OAuthConfig get config => _config;

  /// 构造授权请求。
  ///
  /// [pkceMethod] 默认 [PkceMethod.s256]。
  ///
  /// 服务端明确只接受 S256（`Only code_challenge_method=S256 is supported`），
  /// plain 会被直接拒绝，所以这里不能再用 plain 兜底。
  /// 调用方拿到结果后应立即打开 [OAuthAuthorizationRequest.url]，
  /// 并保存 state + verifier 以便回调校验。
  OAuthAuthorizationRequest createAuthorizationRequest({
    String? loginHint,
    String? prompt,
    String? loginType,
    PkceMethod pkceMethod = PkceMethod.s256,
  }) {
    if (!_config.isConfigured) {
      throw const OAuthNotConfiguredException();
    }
    String? normalizedLoginType;
    if (loginType != null && loginType.trim().isNotEmpty) {
      final tokens = loginType
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      for (final token in tokens) {
        if (!OAuthConfig.supportedLoginTypes.contains(token)) {
          throw ArgumentError.value(
            loginType,
            'loginType',
            'Unsupported login_type token: $token',
          );
        }
      }
      if (tokens.isNotEmpty) {
        normalizedLoginType = tokens.join(',');
      }
    }

    final pkce = generatePkcePair(random: _random, method: pkceMethod);
    final state = generateState(random: _random);

    final query = <String, String>{
      'response_type': 'code',
      'client_id': _config.clientId,
      'redirect_uri': _config.redirectUri,
      'state': state,
      'code_challenge': pkce.codeChallenge,
      'code_challenge_method': pkce.codeChallengeMethod,
      if (_config.scope.isNotEmpty) 'scope': _config.scope,
      if (loginHint != null && loginHint.trim().isNotEmpty)
        'login_hint': loginHint.trim(),
      if (prompt != null && prompt.trim().isNotEmpty) 'prompt': prompt.trim(),
      'login_type': ?normalizedLoginType,
    };

    final base = Uri.parse(_config.authUrl!);
    final url = base.replace(
      queryParameters: {...base.queryParameters, ...query},
    );
    return OAuthAuthorizationRequest(url: url, state: state, pkce: pkce);
  }

  /// 查询服务端当前启用的社会化登录渠道（`/auth/social/providers`）。
  Future<Set<String>> fetchSocialProviders({Duration? timeout}) async {
    final url = _config.socialProvidersUrl;
    if (url == null) return const <String>{};
    final response = await _send(
      () => _httpClient.get(
        Uri.parse(url),
        headers: const {'Accept': 'application/json'},
      ),
      timeout: timeout ?? const Duration(seconds: 4),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OAuthServerException(
        code: 'social_providers_fetch_failed',
        message: '登录渠道查询失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final Map<String, dynamic> decodedMap;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      decodedMap = decoded;
    } catch (e) {
      throw OAuthServerException(
        code: 'social_providers_parse_failed',
        message: '登录渠道解析失败，请稍后重试',
        statusCode: response.statusCode,
        cause: e,
      );
    }
    final rawList = decodedMap['providers'];
    if (rawList is! List) return const <String>{};
    final providers = <String>{};
    for (final item in rawList) {
      if (item is String) {
        final token = item.trim().toLowerCase();
        if (OAuthConfig.supportedLoginTypes.contains(token)) {
          providers.add(token);
        }
      }
    }
    return Set<String>.unmodifiable(providers);
  }

  /// 用授权码换 token（`grant_type=authorization_code`）。
  Future<OAuthTokenResponse> exchangeCodeForToken({
    required String code,
    required String codeVerifier,
  }) {
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const OAuthServerException(
        code: 'invalid_request',
        message: '登录回调缺少授权码，请重新登录',
      );
    }
    return _postToken({
      'grant_type': 'authorization_code',
      'code': trimmedCode,
      'client_id': _config.clientId,
      'redirect_uri': _config.redirectUri,
      'code_verifier': codeVerifier,
    });
  }

  /// 用 refresh_token 续期。
  ///
  /// 服务端若启用 Token Rotation，会同时返回新的 refresh_token，
  /// 调用方必须立刻整体覆盖旧值（[OAuthTokenStore] 已按单条 JSON 原子写入）。
  Future<OAuthTokenResponse> refreshAccessToken(String refreshToken) {
    return _postToken({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': _config.clientId,
    });
  }

  /// 用微信一次性授权码换 token（后端扩展 grant：
  /// `grant_type=urn:wainao:params:oauth:grant-type:wechat`）。
  ///
  /// 客户端只上送 `code`；后端拿 AppID/AppSecret 与微信交换 openid/unionid
  /// 并签发本服务 token（客户端不持有 AppSecret）。`wechat_app_id` 仅在
  /// 配置了合法 AppID 时上送，供后端在多微信应用场景下路由对应的 Secret。
  Future<OAuthTokenResponse> exchangeWechatCodeForToken({
    required String code,
    String? lang,
  }) {
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const OAuthServerException(
        code: 'invalid_request',
        message: '微信授权码缺失，请重新登录',
      );
    }
    return _postToken({
      'grant_type': OAuthConfig.wechatGrantType,
      'client_id': _config.clientId,
      'code': trimmedCode,
      'app_type': OAuthConfig.wechatAppType,
      if (_config.wechatScope.trim().isNotEmpty)
        'scope': _config.wechatScope.trim(),
      if (lang != null && lang.trim().isNotEmpty) 'lang': lang.trim(),
      if (_config.isWechatConfigured) 'wechat_app_id': _config.wechatAppId,
    });
  }

  /// 撤销 token（RFC 7009，服务端通常恒返回 200）。
  ///
  /// 尽力而为：登出时即使失败也不该阻塞用户退出，调用方可吞掉异常。
  Future<void> revoke({
    required String token,
    String tokenTypeHint = 'access_token',
  }) async {
    final url = _config.revokeUrl;
    if (url == null) return;
    final response = await _send(
      () => _httpClient.post(
        Uri.parse(url),
        headers: const {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {
          'token': token,
          'token_type_hint': tokenTypeHint,
          'client_id': _config.clientId,
        },
      ),
    );
    // 撤销售后无条件成功：令牌已作废或本就不存在（400/401）都不影响本地登出。
    if (response.statusCode >= 500) {
      throw OAuthServerException(
        code: 'revoke_failed',
        message: '退出登录时服务端暂不可用',
        statusCode: response.statusCode,
      );
    }
  }

  /// 拉取 `/profile` 做身份校验（登录成功后立即调用一次）。
  Future<OAuthAccount> fetchProfile(String accessToken) async {
    final url = _config.profileUrl;
    if (url == null) {
      throw const OAuthNotConfiguredException();
    }
    final response = await _send(
      () => _httpClient.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/json',
        },
      ),
    );
    if (response.statusCode == 401) {
      throw const OAuthAuthRequiredException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OAuthServerException(
        code: 'profile_fetch_failed',
        message: '登录信息读取失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      body = decoded;
    } catch (e) {
      throw OAuthServerException(
        code: 'profile_parse_failed',
        message: '登录信息解析失败，请稍后重试',
        statusCode: response.statusCode,
        cause: e,
      );
    }
    try {
      return OAuthAccount.fromProfile(body);
    } on FormatException catch (e) {
      throw OAuthServerException(
        code: 'profile_parse_failed',
        message: '登录信息不完整，请稍后重试',
        statusCode: response.statusCode,
        cause: e,
      );
    }
  }

  /// 释放内部创建的 http.Client（外部注入的由调用方负责）。
  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  // ===== 内部 =====

  Future<OAuthTokenResponse> _postToken(Map<String, String> body) async {
    if (!_config.isConfigured) {
      throw const OAuthNotConfiguredException();
    }
    final response = await _send(
      () => _httpClient.post(
        Uri.parse(_config.tokenUrl!),
        headers: const {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: body,
      ),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('响应不是 JSON 对象');
        }
        json = decoded;
      } catch (e) {
        throw OAuthServerException(
          code: 'parse_failed',
          message: '登录服务返回的数据无法解析',
          statusCode: response.statusCode,
          cause: e,
        );
      }
      return OAuthTokenResponse.fromJson(json);
    }

    // 错误响应：{error, error_description} 或 {message}
    var code = 'server_error';
    var detail = '';
    if (response.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          code = (decoded['error'] ?? code).toString();
          detail = (decoded['error_description'] ?? decoded['message'] ?? '')
              .toString();
        }
      } catch (_) {
        // 非 JSON 错误响应：保留默认码，不因解析失败再抛一层
      }
    }
    throw OAuthServerException(
      code: code,
      message: _userMessage(code, detail, response.statusCode),
      statusCode: response.statusCode,
    );
  }

  /// 统一把 OAuth 错误码翻成用户能看懂的中文。
  static String _userMessage(String code, String detail, int statusCode) {
    switch (code) {
      case 'invalid_grant':
        return '登录已过期，请重新登录';
      case 'invalid_client':
      case 'unauthorized_client':
        return '登录服务配置有误';
      case 'unsupported_grant_type':
        // 后端环境未给该 client_id 放行微信扩展 grant 时兜底，不让英文透出。
        return '当前客户端未开通微信登录';
      case 'access_denied':
        return '已取消登录';
      case 'invalid_request':
        return '登录请求不被接受，请稍后重试';
    }
    if (statusCode >= 500) return '登录服务暂时不可用，请稍后重试';
    if (detail.trim().isNotEmpty) return detail.trim();
    return '登录失败，请稍后重试';
  }

  /// 统一超时与网络错误归一。
  Future<http.Response> _send(
    Future<http.Response> Function() send, {
    Duration? timeout,
  }) async {
    try {
      return await send().timeout(timeout ?? _config.requestTimeout);
    } on TimeoutException catch (e) {
      throw OAuthNetworkException('请求超时，请检查网络后重试', e);
    } on OAuthException {
      rethrow;
    } catch (e) {
      throw OAuthNetworkException('网络异常，请检查网络后重试', e);
    }
  }
}
