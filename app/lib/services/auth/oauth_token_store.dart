/// OAuth token 持久化（唯一 token 真相源）。
///
/// 关键设计（沿用参考工程 reai_mobile_app 的成熟做法）：
///
/// 1. **单条 JSON 一次性写入**：access / refresh / 过期时间 / 账号合成一个
///    bundle 存进系统密钥库。服务端轮换（rotation）时新旧 token 一旦分批写、
///    进程被杀就会留下「新 access + 旧 refresh」的错配，一小时后必然掉登录。
/// 2. **generation 代次**：登出（[clear]）与保存都会 +1。在途 refresh 写回前
///    比对代次，代次变了就丢弃结果，避免「登出后会话被旧 refresh 复活」。
/// 3. **identityEpoch 身份代次**：只在登录 / 登出递增（refresh 不递增）。
///    网络层用它识别「请求发出 → 收到 401」期间用户已切换，
///    从而不会把 A 的请求重放到 B 的账号上。
/// 4. **inflight refresh 去重**：多个并发 401 只触发一次刷新。
/// 5. **损坏数据不致命**：bundle 解析失败即视为未登录并清掉，不让一条坏记录
///    卡死启动。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/storage/secure_store.dart';
import 'oauth_account.dart';
import 'oauth_client.dart';
import 'oauth_config.dart';
import 'oauth_exception.dart';

/// Token 存储。
class OAuthTokenStore {
  OAuthTokenStore({
    required SecureStore secure,
    required OAuthClient client,
    OAuthConfig? config,
    DateTime Function()? clock,
  })  : _secure = secure,
        _client = client,
        _config = config ?? client.config,
        _clock = clock ?? DateTime.now;

  /// 唯一存储 key（bundle 内是四个字段的 JSON）。
  static const String bundleKey = 'rc_oauth_token_bundle';

  /// 过期前提前量：避免「刚好 1 毫秒到期」的请求带着废 token 出去。
  static const Duration _expirySkew = Duration(seconds: 30);

  final SecureStore _secure;
  final OAuthClient _client;
  final OAuthConfig _config;
  final DateTime Function() _clock;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessExpiresAt;
  DateTime? _refreshExpiresAt;
  OAuthAccount? _account;

  /// inflight refresh 去重。
  Future<String?>? _inflightRefresh;

  /// 代次：登出 / 保存成功 +1，用于在途 refresh 的竞态校验。
  int _generation = 0;
  int get generation => _generation;

  /// 身份代次：仅登录 / 登出递增，网络层用它识别用户切换。
  int _identityEpoch = 0;
  int get identityEpoch => _identityEpoch;

  /// 服务端权威判定 refresh token 已失效时触发（`invalid_grant` 等）。
  ///
  /// 由 [AuthService] 注入做「会话过期 → 回登录页」的全局处理；
  /// 本类不依赖 Flutter UI 层。仅服务端明确拒绝时触发，
  /// 网络错误 / 代次竞态 / 无 refresh token 一律不触发。
  void Function()? onSessionInvalidated;

  /// 启动时把 bundle 读进内存。
  ///
  /// 存储层异常（如测试环境无平台通道）会向上抛，由调用方决定降级方式；
  /// 数据损坏（JSON 坏 / 字段类型坏）则在本类内部清掉并当作未登录。
  Future<void> bootstrap() async {
    final raw = await _secure.readJson(bundleKey);
    if (raw == null) {
      _clearMemory();
      return;
    }
    final access = _string(raw['access_token']);
    final refresh = _string(raw['refresh_token']);
    if (access == null && refresh == null) {
      // 半截 bundle：没有可用 token，直接清掉。
      await _secure.delete(bundleKey);
      _clearMemory();
      return;
    }
    _accessToken = access;
    _refreshToken = refresh;
    _accessExpiresAt = _date(raw['expires_at']);
    _refreshExpiresAt = _date(raw['refresh_expires_at']);
    _account = _parseAccount(raw['account']);
  }

  // ===== 读 =====

  /// 当前 access token（可能已过期，网络层请用 [getValidAccessToken]）。
  String? get accessToken => _accessToken;

  /// 当前 refresh token。
  String? get refreshToken => _refreshToken;

  /// access token 到期时间（null = 未知，按需刷新）。
  DateTime? get accessExpiresAt => _accessExpiresAt;

  /// refresh token 到期时间。
  DateTime? get refreshExpiresAt => _refreshExpiresAt;

  /// 已登录账号（未登录 / bundle 无账号时为 null）。
  OAuthAccount? get account => _account;

  /// 是否存在任何可用会话（access 或 refresh 任一存在）。
  bool get hasSession => _accessToken != null || _refreshToken != null;

  /// refresh token 是否仍未过期（启动判断「要不要进登录页」用）。
  bool get hasValidRefreshToken {
    if (_refreshToken == null) return false;
    final expires = _refreshExpiresAt;
    if (expires == null) return true; // 服务端没给有效期，兜底视为有效
    return expires.isAfter(_clock());
  }

  /// 取一个可用的 access token；必要时自动刷新。
  ///
  /// - 未登录（无任何 token）→ null
  /// - access 未过期 → 直接返回
  /// - access 过期 / 未知 → 用 refresh 换新（[OAuthAuthRequiredException] 表示必须重新登录）
  Future<String?> getValidAccessToken() async {
    if (!hasSession) return null;
    final access = _accessToken;
    final expires = _accessExpiresAt;
    if (access != null &&
        expires != null &&
        expires.subtract(_expirySkew).isAfter(_clock())) {
      return access;
    }
    if (_refreshToken == null) {
      // 只有过期的 access：没有续期手段，等同于需要重新登录。
      return null;
    }
    return refresh();
  }

  // ===== 刷新 =====

  /// 强制刷新（业务接口 401 时调用）。并发调用共享同一个请求。
  Future<String?> refresh() {
    final inflight = _inflightRefresh;
    if (inflight != null) return inflight;

    final completer = Completer<String?>();
    _inflightRefresh = completer.future;

    () async {
      final capturedGeneration = _generation;
      final capturedRefresh = _refreshToken;
      try {
        if (capturedRefresh == null) {
          throw const OAuthAuthRequiredException();
        }
        final OAuthTokenResponse response;
        try {
          response = await _client.refreshAccessToken(capturedRefresh);
        } on OAuthServerException catch (e) {
          if (_isFatalRefreshError(e.code)) {
            // 服务端权威信号：刷新令牌已死。先通知全局，再抛「需要重新登录」。
            try {
              onSessionInvalidated?.call();
            } catch (callbackError) {
              debugPrint('[OAuthTokenStore] onSessionInvalidated 回调异常: $callbackError');
            }
            throw const OAuthAuthRequiredException();
          }
          rethrow;
        }

        // 写回前竞态校验：期间用户登出 / 换账号 → 丢弃本次结果。
        if (_generation != capturedGeneration ||
            (_refreshToken != null && _refreshToken != capturedRefresh)) {
          throw const OAuthAuthRequiredException();
        }
        await _persist(
          response,
          accessExpiresAt: _clock().add(
            response.expiresIn ?? _config.accessTokenDefaultTtl,
          ),
          refreshExpiresAt: _clock().add(
            response.refreshExpiresIn ?? _config.refreshTokenDefaultTtl,
          ),
          // 轮换响应可能不带 refresh_token，那就沿用旧的。
          refreshToken: response.refreshToken ?? capturedRefresh,
          expectedGeneration: capturedGeneration,
        );
        completer.complete(response.accessToken);
      } catch (e, stack) {
        completer.completeError(e, stack);
      } finally {
        _inflightRefresh = null;
      }
    }();

    return completer.future;
  }

  // ===== 写 =====

  /// 登录成功后保存 token（会递增 generation 与 identityEpoch）。
  Future<void> saveTokens(
    OAuthTokenResponse response, {
    OAuthAccount? account,
  }) async {
    _identityEpoch++;
    await _persist(
      response,
      accessExpiresAt: _clock().add(
        response.expiresIn ?? _config.accessTokenDefaultTtl,
      ),
      refreshExpiresAt: _clock().add(
        response.refreshExpiresIn ?? _config.refreshTokenDefaultTtl,
      ),
      refreshToken: response.refreshToken,
      account: account ?? _account,
    );
    _generation++;
  }

  /// 登录后补充/更新账号信息（如重新拉了一次 `/profile`）。
  Future<void> updateAccount(OAuthAccount account) async {
    _account = account;
    await _writeBundle();
  }

  /// 清除全部 token（登出）。
  ///
  /// 先清内存再 +代次，最后删存储：即使删除失败，内存里也不再有会话，
  /// 且代次已递增，在途 refresh 无法把会话「复活」。
  Future<void> clear() async {
    _clearMemory();
    _generation++;
    _identityEpoch++;
    try {
      await _secure.delete(bundleKey);
    } catch (e) {
      // 清内存已生效，删除失败只影响下次冷启动（顶多多一次重新登录）。
      debugPrint('[OAuthTokenStore] 清除 token 失败: $e');
    }
  }

  // ===== 内部 =====

  /// 写入 bundle + 提交内存（唯一写路径）。
  ///
  /// 顺序：**先 storage 后内存**——storage 失败时内存不会被写成「看起来登录了」。
  Future<void> _persist(
    OAuthTokenResponse response, {
    required DateTime accessExpiresAt,
    required DateTime refreshExpiresAt,
    String? refreshToken,
    OAuthAccount? account,
    int? expectedGeneration,
  }) async {
    Future<void> ensureStable() async {
      if (expectedGeneration == null) return;
      if (_generation != expectedGeneration) {
        // 期间被登出：把可能已写入的 bundle 删掉，确保无残留。
        await _secure.delete(bundleKey);
        throw const OAuthAuthRequiredException();
      }
    }

    await ensureStable();

    final newAccess = response.accessToken;
    final newRefresh = refreshToken ?? _refreshToken;
    // 刷新时调用方不传账号，这里沿用内存里的账号，避免把 bundle 的 account 字段写丢。
    final newAccount = account ?? _account;

    await _secure.writeJson(bundleKey, {
      'access_token': newAccess,
      'refresh_token': ?newRefresh,
      'expires_at': accessExpiresAt.toIso8601String(),
      'refresh_expires_at': refreshExpiresAt.toIso8601String(),
      if (newAccount != null) 'account': newAccount.toJson(),
      'token_type': response.tokenType,
      if (response.scope != null) 'scope': response.scope,
      'issued_at': _clock().toIso8601String(),
    });

    await ensureStable();

    _accessToken = newAccess;
    _refreshToken = newRefresh;
    _accessExpiresAt = accessExpiresAt;
    _refreshExpiresAt = refreshExpiresAt;
    if (newAccount != null) _account = newAccount;
  }

  /// 只重写当前内存态（更新账号信息用）。
  Future<void> _writeBundle() async {
    final access = _accessToken;
    final refresh = _refreshToken;
    if (access == null && refresh == null) return;
    await _secure.writeJson(bundleKey, {
      'access_token': ?access,
      'refresh_token': ?refresh,
      if (_accessExpiresAt != null)
        'expires_at': _accessExpiresAt!.toIso8601String(),
      if (_refreshExpiresAt != null)
        'refresh_expires_at': _refreshExpiresAt!.toIso8601String(),
      if (_account != null) 'account': _account!.toJson(),
    });
  }

  void _clearMemory() {
    _accessToken = null;
    _refreshToken = null;
    _accessExpiresAt = null;
    _refreshExpiresAt = null;
    _account = null;
  }

  /// 服务端明确判定 refresh token 失效的错误码。
  static bool _isFatalRefreshError(String code) =>
      code == 'invalid_grant' ||
      code == 'invalid_token' ||
      code == 'unauthorized_client';

  static String? _string(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _date(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  static OAuthAccount? _parseAccount(Object? raw) {
    if (raw is! Map) return null;
    try {
      return OAuthAccount.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('[OAuthTokenStore] account 解析失败，按缺失处理: $e');
      return null;
    }
  }
}
