/// 会员体系、月度 3,600 分钟本地转写额度与 StoreKit 2 购买状态机。
///
/// 核心原则：
/// - 免费版提供每月 3,600 分钟（60 小时）灵活总池，不设单日上限，每月 1 日 00:00 重置；
/// - 额度用尽时实行「柔和队列保护」：绝不中断录音，新音频安全保存在本机队列，等待次月 1 日恢复或升级解锁；
/// - Local Pro 解锁无限本地离线转写/声纹/导出（不含官方云端 AI 清洗与总结额度）；
/// - Cloud Basic / Cloud Pro 完整打包包含 Local Pro 权益并叠加云端算力额度；
/// - 权益真值由 Apple StoreKit 2 校验返回或经开发者调试覆盖，绝不伪造已购状态。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../services/billing/storekit_service.dart';
import '../models/recording.dart';
import '../storage/storage.dart';

enum MembershipTier { free, localPro, cloudBasic, cloudPro }

enum BillingCycle { monthly, yearly, lifetime }

@immutable
class PlanPriceFallback {
  const PlanPriceFallback({
    required this.cnyLabel,
    required this.usdHint,
    required this.unitLabel,
  });

  final String cnyLabel;
  final String usdHint;
  final String unitLabel;
}

class _BonusCreditPack {
  const _BonusCreditPack({
    required this.credits,
    required this.expiresAtMs,
    this.transactionId,
  });

  final int credits;
  final int expiresAtMs;
  final String? transactionId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'credits': credits,
    'expiresAtMs': expiresAtMs,
    if (transactionId != null && transactionId!.isNotEmpty) 'txId': transactionId,
  };

  static _BonusCreditPack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final credits = (raw['credits'] as num?)?.toInt() ?? 0;
    final exp = (raw['expiresAtMs'] as num?)?.toInt() ?? 0;
    if (credits <= 0 || exp <= 0) return null;
    return _BonusCreditPack(
      credits: credits,
      expiresAtMs: exp,
      transactionId: raw['txId'] as String?,
    );
  }
}

class MembershipStore extends ChangeNotifier {
  MembershipStore({
    KeyValueStore? store,
    StoreKitGateway? gateway,
    DateTime Function()? now,
  }) : _json = JsonStore(store: store ?? InMemoryStore()),
       _gateway = gateway,
       _now = now ?? DateTime.now {
    _quotaMonthKey = monthKeyFor(_now());
    _updatesSub = _gateway?.entitlementUpdates.listen((_) {
      unawaited(refreshStoreKit(loadCatalog: false));
    });
  }

  static const String storageKey = 'membership_v1';

  // App Store Connect Subscription Group 22614344 & IAP 商品编号
  static const String localProMonthly = 'com.reai.recordingcard.local_pro.monthly';
  static const String localProYearly = 'com.reai.recordingcard.local_pro.yearly';
  static const String localProLifetime = 'com.reai.recordingcard.local_pro.lifetime';
  static const String cloudBasicMonthly = 'com.reai.recordingcard.cloud_basic.monthly';
  static const String cloudBasicYearly = 'com.reai.recordingcard.cloud_basic.yearly';
  static const String cloudProMonthly = 'com.reai.recordingcard.cloud_pro.monthly';
  static const String cloudProYearly = 'com.reai.recordingcard.cloud_pro.yearly';
  static const String creditsPack500 = 'com.reai.recordingcard.credits.pack500';
  static const String creditsPack1200 = 'com.reai.recordingcard.credits.pack1200';

  static const List<String> allProductIds = <String>[
    localProMonthly,
    localProYearly,
    localProLifetime,
    cloudBasicMonthly,
    cloudBasicYearly,
    cloudProMonthly,
    cloudProYearly,
    creditsPack500,
    creditsPack1200,
  ];

  static const int freeMonthlyLimitMinutes = 3600;
  static const int freeMonthlyLimitMs = freeMonthlyLimitMinutes * 60 * 1000;
  static const int freeWarningThresholdMinutes = 3240; // 90%
  static const int cloudBasicMonthlyCredits = 500;
  static const int cloudProMonthlySummaries = 50;
  static const int cloudProMonthlyQa = 50;
  static const int creditPackValidityDays = 90;

  static const Map<String, PlanPriceFallback> priceFallbacks =
      <String, PlanPriceFallback>{
        localProMonthly: PlanPriceFallback(
          cnyLabel: '¥6',
          usdHint: r'$0.99',
          unitLabel: '/ 月',
        ),
        localProYearly: PlanPriceFallback(
          cnyLabel: '¥68',
          usdHint: r'$9.99',
          unitLabel: '/ 年',
        ),
        localProLifetime: PlanPriceFallback(
          cnyLabel: '¥198',
          usdHint: r'$29.99',
          unitLabel: '永久买断',
        ),
        cloudBasicMonthly: PlanPriceFallback(
          cnyLabel: '¥28',
          usdHint: r'$3.99',
          unitLabel: '/ 月',
        ),
        cloudBasicYearly: PlanPriceFallback(
          cnyLabel: '¥268',
          usdHint: r'$39.99',
          unitLabel: '/ 年',
        ),
        cloudProMonthly: PlanPriceFallback(
          cnyLabel: '¥88',
          usdHint: r'$12.99',
          unitLabel: '/ 月',
        ),
        cloudProYearly: PlanPriceFallback(
          cnyLabel: '¥848',
          usdHint: r'$119.99',
          unitLabel: '/ 年',
        ),
        creditsPack500: PlanPriceFallback(
          cnyLabel: '¥18',
          usdHint: r'$2.99',
          unitLabel: '90 天',
        ),
        creditsPack1200: PlanPriceFallback(
          cnyLabel: '¥38',
          usdHint: r'$4.99',
          unitLabel: '90 天',
        ),
      };

  static String monthKeyFor(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}';

  final JsonStore _json;
  final StoreKitGateway? _gateway;
  final DateTime Function() _now;
  StreamSubscription<void>? _updatesSub;
  bool _disposed = false;

  Set<String> _ownedProductIds = <String>{};
  int? _subscriptionExpiresAtMs;
  BillingCycle _selectedCycle = BillingCycle.monthly;
  late String _quotaMonthKey;
  int _usedLocalTranscribeMs = 0;
  int _monthlyCloudCreditsUsed = 0;
  int _proSummariesUsed = 0;
  int _proQaUsed = 0;
  int? _devQuotaOverrideMinutes;
  bool _backfilledForMonth = false;
  final List<_BonusCreditPack> _bonusPacks = <_BonusCreditPack>[];
  final Map<String, StoreProductInfo> _catalog = <String, StoreProductInfo>{};

  bool _loadingCatalog = false;
  bool _purchaseInFlight = false;
  String? _purchasingProductId;
  String? _lastError;
  String? _lastNotice;

  /// 当本机从「3,600 分钟耗尽状态」恢复为「允许转写」时触发，用于立即唤醒排队录音。
  VoidCallback? onLocalQuotaUnlocked;

  Set<String> get ownedProductIds => Set<String>.unmodifiable(_ownedProductIds);
  int? get subscriptionExpiresAtMs => _subscriptionExpiresAtMs;
  BillingCycle get selectedCycle => _selectedCycle;
  String get quotaMonthKey => _nowMonthKey();
  int get usedLocalTranscribeMs =>
      _nowMonthKey() == _quotaMonthKey ? _usedLocalTranscribeMs : 0;
  int? get devQuotaOverrideMinutes => _devQuotaOverrideMinutes;
  Map<String, StoreProductInfo> get catalog => Map.unmodifiable(_catalog);
  bool get loadingCatalog => _loadingCatalog;
  bool get purchaseInFlight => _purchaseInFlight;
  String? get purchasingProductId => _purchasingProductId;
  String? get lastError => _lastError;
  String? get lastNotice => _lastNotice;

  String _nowMonthKey() => monthKeyFor(_now());

  bool get lifetimeLocalPro => _ownedProductIds.contains(localProLifetime);

  MembershipTier get tier {
    if (_ownedProductIds.contains(cloudProMonthly) ||
        _ownedProductIds.contains(cloudProYearly)) {
      return MembershipTier.cloudPro;
    }
    if (_ownedProductIds.contains(cloudBasicMonthly) ||
        _ownedProductIds.contains(cloudBasicYearly)) {
      return MembershipTier.cloudBasic;
    }
    if (_ownedProductIds.contains(localProMonthly) ||
        _ownedProductIds.contains(localProYearly) ||
        _ownedProductIds.contains(localProLifetime)) {
      return MembershipTier.localPro;
    }
    return MembershipTier.free;
  }

  String get tierDisplayName => switch (tier) {
    MembershipTier.free => '免费版',
    MembershipTier.localPro => lifetimeLocalPro ? 'Local Pro · 永久版' : 'Local Pro',
    MembershipTier.cloudBasic => 'Cloud 基础版',
    MembershipTier.cloudPro => 'Cloud 专业版',
  };

  int get effectiveUsedMinutes {
    if (_devQuotaOverrideMinutes != null) {
      return _devQuotaOverrideMinutes!.clamp(0, 999999);
    }
    final ms = usedLocalTranscribeMs;
    if (ms <= 0) return 0;
    final floored = ms ~/ 60000;
    return floored == 0 ? 1 : floored;
  }

  bool get isUnlimitedLocal => tier != MembershipTier.free;

  bool get isLocalQuotaExhausted =>
      !isUnlimitedLocal && effectiveUsedMinutes >= freeMonthlyLimitMinutes;

  bool get isLocalQuotaWarning =>
      !isUnlimitedLocal &&
      !isLocalQuotaExhausted &&
      effectiveUsedMinutes >= freeWarningThresholdMinutes;

  bool get canTranscribeLocally => !isLocalQuotaExhausted;

  int get remainingFreeMinutes =>
      (freeMonthlyLimitMinutes - effectiveUsedMinutes).clamp(
        0,
        freeMonthlyLimitMinutes,
      );

  double get usageRatio => isUnlimitedLocal
      ? 1.0
      : (effectiveUsedMinutes / freeMonthlyLimitMinutes).clamp(0.0, 1.0);

  int get bonusCredits {
    final nowMs = _now().millisecondsSinceEpoch;
    var sum = 0;
    for (final pack in _bonusPacks) {
      if (pack.expiresAtMs > nowMs) sum += pack.credits;
    }
    return sum;
  }

  int get cloudCreditsRemaining {
    final sameMonth = _nowMonthKey() == _quotaMonthKey;
    final used = sameMonth ? _monthlyCloudCreditsUsed : 0;
    final base = tier == MembershipTier.cloudBasic
        ? (cloudBasicMonthlyCredits - used).clamp(0, cloudBasicMonthlyCredits)
        : 0;
    return base + bonusCredits;
  }

  int get cloudProSummariesRemaining {
    if (tier != MembershipTier.cloudPro) return 0;
    final used = _nowMonthKey() == _quotaMonthKey ? _proSummariesUsed : 0;
    return (cloudProMonthlySummaries - used).clamp(0, cloudProMonthlySummaries);
  }

  int get cloudProQaRemaining {
    if (tier != MembershipTier.cloudPro) return 0;
    final used = _nowMonthKey() == _quotaMonthKey ? _proQaUsed : 0;
    return (cloudProMonthlyQa - used).clamp(0, cloudProMonthlyQa);
  }

  String localProProductForCycle(BillingCycle cycle) => switch (cycle) {
    BillingCycle.monthly => localProMonthly,
    BillingCycle.yearly => localProYearly,
    BillingCycle.lifetime => localProLifetime,
  };

  String cloudBasicProductForCycle(BillingCycle cycle) => switch (cycle) {
    BillingCycle.monthly => cloudBasicMonthly,
    BillingCycle.yearly || BillingCycle.lifetime => cloudBasicYearly,
  };

  String cloudProProductForCycle(BillingCycle cycle) => switch (cycle) {
    BillingCycle.monthly => cloudProMonthly,
    BillingCycle.yearly || BillingCycle.lifetime => cloudProYearly,
  };

  bool ownsExactProduct(String productId) => _ownedProductIds.contains(productId);

  /// 优先返回 App Store Connect 真实拉取的本地化价格，未加载时回落到预设参考定价。
  ({String primaryPrice, String secondaryHint}) displayPriceFor(String productId) {
    final info = _catalog[productId];
    final fb = priceFallbacks[productId];
    if (info != null && info.displayPrice.trim().isNotEmpty) {
      return (
        primaryPrice: info.displayPrice.trim(),
        secondaryHint: fb?.unitLabel ?? '',
      );
    }
    if (fb == null) {
      return (primaryPrice: '--', secondaryHint: '');
    }
    return (
      primaryPrice: fb.cnyLabel,
      secondaryHint: '${fb.unitLabel} · 海外 ${fb.usdHint}',
    );
  }

  Future<void> load() async {
    final data = await _json.read(storageKey);
    if (_disposed) return;
    if (data != null) {
      final rawOwned = data['ownedProductIds'];
      if (rawOwned is List) {
        _ownedProductIds = <String>{
          for (final item in rawOwned)
            if (item is String &&
                item.trim().isNotEmpty &&
                !_isConsumable(item.trim()))
              item.trim(),
        };
      }
      _subscriptionExpiresAtMs = (data['subscriptionExpiresAtMs'] as num?)
          ?.toInt();
      final cycleName = data['selectedCycle'] as String?;
      _selectedCycle = BillingCycle.values
              .where((c) => c.name == cycleName)
              .firstOrNull ??
          BillingCycle.monthly;
      final storedMonth = data['quotaMonthKey'] as String?;
      _quotaMonthKey = (storedMonth != null && storedMonth.isNotEmpty)
          ? storedMonth
          : _nowMonthKey();
      _usedLocalTranscribeMs =
          (data['usedLocalTranscribeMs'] as num?)?.toInt() ?? 0;
      _monthlyCloudCreditsUsed =
          (data['monthlyCloudCreditsUsed'] as num?)?.toInt() ?? 0;
      _proSummariesUsed = (data['proSummariesUsed'] as num?)?.toInt() ?? 0;
      _proQaUsed = (data['proQaUsed'] as num?)?.toInt() ?? 0;
      _devQuotaOverrideMinutes = (data['devQuotaOverrideMinutes'] as num?)
          ?.toInt();
      _backfilledForMonth = data['backfilledForMonth'] == true;
      _bonusPacks.clear();
      final rawPacks = data['bonusPacks'];
      if (rawPacks is List) {
        for (final item in rawPacks) {
          final parsed = _BonusCreditPack.fromJson(item);
          if (parsed != null) _bonusPacks.add(parsed);
        }
      }
    }
    final rolled = _rolloverMonthIfNeeded();
    if (rolled) {
      await _save();
    }
    if (!_disposed) notifyListeners();
  }

  bool _isConsumable(String productId) =>
      productId == creditsPack500 || productId == creditsPack1200;

  bool _rolloverMonthIfNeeded() {
    final current = _nowMonthKey();
    var changed = false;
    if (_quotaMonthKey != current) {
      _quotaMonthKey = current;
      _usedLocalTranscribeMs = 0;
      _monthlyCloudCreditsUsed = 0;
      _proSummariesUsed = 0;
      _proQaUsed = 0;
      _backfilledForMonth = false;
      changed = true;
    }
    final nowMs = _now().millisecondsSinceEpoch;
    final beforeLen = _bonusPacks.length;
    _bonusPacks.removeWhere((p) => p.expiresAtMs <= nowMs);
    if (_bonusPacks.length != beforeLen) changed = true;
    return changed;
  }

  /// 用本机当月已转写录音回填统计，避免升级新版后当月已用量从 0 起算。
  Future<void> backfillCurrentMonthUsage(List<RecordingFile> files) async {
    if (_disposed) return;
    _rolloverMonthIfNeeded();
    if (_backfilledForMonth || _usedLocalTranscribeMs > 0) return;

    final now = _now();
    var sumMs = 0;
    for (final file in files) {
      if (file.isExternalImported) continue;
      if (file.stage != RecordingStage.ready) continue;
      if (file.utterances.isEmpty &&
          file.slices.isEmpty &&
          file.turns.isEmpty) {
        continue;
      }
      if (file.startAtMs <= 0 || file.durationMs <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(file.startAtMs);
      if (dt.year == now.year && dt.month == now.month) {
        sumMs += file.durationMs;
      }
    }
    _backfilledForMonth = true;
    if (sumMs > 0) {
      _usedLocalTranscribeMs = sumMs;
    }
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> recordLocalTranscriptionMs(int durationMs) async {
    if (_disposed || durationMs <= 0) return;
    final wasExhausted = isLocalQuotaExhausted;
    _rolloverMonthIfNeeded();
    _usedLocalTranscribeMs += durationMs;
    _backfilledForMonth = true;
    await _save();
    if (!_disposed) notifyListeners();
    if (wasExhausted && !isLocalQuotaExhausted) {
      onLocalQuotaUnlocked?.call();
    }
  }

  Future<void> setSelectedCycle(BillingCycle cycle) async {
    if (_selectedCycle == cycle) return;
    _selectedCycle = cycle;
    _lastNotice = null;
    if (!_disposed) notifyListeners();
    await _save();
  }

  /// 仅限开发者调试使用：覆盖本月已用分钟以验证 90% 预警条与 100% 队列保护状态。
  Future<void> setDevQuotaOverrideMinutes(int? minutes) async {
    final wasExhausted = isLocalQuotaExhausted;
    _devQuotaOverrideMinutes = minutes?.clamp(0, 999999);
    await _save();
    if (!_disposed) notifyListeners();
    if (wasExhausted && !isLocalQuotaExhausted) {
      onLocalQuotaUnlocked?.call();
    }
  }

  Future<void> refreshStoreKit({bool loadCatalog = true}) async {
    final gw = _gateway;
    if (gw == null || _disposed) return;

    final wasExhausted = isLocalQuotaExhausted;
    if (loadCatalog) {
      _loadingCatalog = true;
      if (!_disposed) notifyListeners();
      final catalogRes = await gw.loadProducts(allProductIds);
      if (_disposed) return;
      for (final p in catalogRes.products) {
        _catalog[p.id] = p;
      }
      _loadingCatalog = false;
      if (catalogRes.error != null && catalogRes.error!.trim().isNotEmpty) {
        _lastError = catalogRes.error!.trim();
      } else {
        _lastError = null;
      }
    }

    final entitlements = await gw.currentEntitlements();
    if (_disposed) return;
    if (gw.lastEntitlementCheckAuthoritative) {
      _applyAuthoritativeEntitlements(entitlements);
      await _save();
    }
    if (!_disposed) notifyListeners();
    if (wasExhausted && !isLocalQuotaExhausted) {
      onLocalQuotaUnlocked?.call();
    }
  }

  void _applyAuthoritativeEntitlements(List<StoreEntitlement> entitlements) {
    final nextOwned = <String>{};
    int? maxSubExp;
    for (final e in entitlements) {
      if (e.productId.isEmpty || _isConsumable(e.productId)) continue;
      nextOwned.add(e.productId);
      final exp = e.expirationDateMs;
      if (exp != null && (maxSubExp == null || exp > maxSubExp)) {
        maxSubExp = exp;
      }
    }
    _ownedProductIds = nextOwned;
    _subscriptionExpiresAtMs = maxSubExp;
  }

  Future<StorePurchaseResult> purchase(String productId) async {
    final gw = _gateway;
    if (gw == null) {
      const res = StorePurchaseResult(
        status: StorePurchaseStatus.unavailable,
        message: 'StoreKit 购买服务未装载',
      );
      _lastError = res.message;
      _lastNotice = null;
      if (!_disposed) notifyListeners();
      return res;
    }
    if (_purchaseInFlight) {
      return const StorePurchaseResult(
        status: StorePurchaseStatus.pending,
        message: '正在处理上一笔购买请求，请稍候',
      );
    }

    final wasExhausted = isLocalQuotaExhausted;
    _purchaseInFlight = true;
    _purchasingProductId = productId;
    _lastError = null;
    _lastNotice = null;
    if (!_disposed) notifyListeners();

    try {
      final result = await gw.purchase(productId);
      if (_disposed) return result;
      switch (result.status) {
        case StorePurchaseStatus.purchased:
          final id = (result.productId?.isNotEmpty == true)
              ? result.productId!
              : productId;
          if (_isConsumable(id)) {
            _grantConsumablePack(id, transactionId: result.transactionId);
            final pts = id == creditsPack1200 ? 1200 : 500;
            _lastNotice = '购买成功：已到账 $pts 点云端 AI 积分（90 天有效）';
          } else {
            _ownedProductIds = <String>{..._ownedProductIds, id};
            if (result.expirationDateMs != null) {
              _subscriptionExpiresAtMs = result.expirationDateMs;
            }
            _lastNotice = '已开通：$tierDisplayName';
            // 顺便拉一次权威当前权益（避免订阅升级仍保留旧级别标签）
            final ents = await gw.currentEntitlements();
            if (!_disposed &&
                gw.lastEntitlementCheckAuthoritative &&
                ents.isNotEmpty) {
              _applyAuthoritativeEntitlements(ents);
            }
          }
          await _save();
        case StorePurchaseStatus.cancelled:
          _lastNotice = '已取消本次购买';
        case StorePurchaseStatus.pending:
          _lastNotice = result.message ?? '购买正在等待系统批准';
        case StorePurchaseStatus.unverified:
          _lastError =
              '交易未能通过 Apple 签名校验：${result.message ?? '请稍后重试'}';
        case StorePurchaseStatus.unavailable:
          _lastError = result.message ?? '商品暂不可用';
        case StorePurchaseStatus.error:
          _lastError = result.message ?? '购买未完成，请稍后重试';
      }
      return result;
    } finally {
      _purchaseInFlight = false;
      _purchasingProductId = null;
      if (!_disposed) notifyListeners();
      if (wasExhausted && !isLocalQuotaExhausted) {
        onLocalQuotaUnlocked?.call();
      }
    }
  }

  void _grantConsumablePack(String productId, {String? transactionId}) {
    final txId = transactionId?.trim();
    if (txId != null &&
        txId.isNotEmpty &&
        _bonusPacks.any((p) => p.transactionId == txId)) {
      return;
    }
    final credits = productId == creditsPack1200 ? 1200 : 500;
    final expMs = _now()
        .add(const Duration(days: creditPackValidityDays))
        .millisecondsSinceEpoch;
    _bonusPacks.add(
      _BonusCreditPack(
        credits: credits,
        expiresAtMs: expMs,
        transactionId: txId,
      ),
    );
  }

  Future<StoreRestoreResult> restorePurchases() async {
    final gw = _gateway;
    if (gw == null) {
      const res = StoreRestoreResult(
        status: 'unavailable',
        message: 'StoreKit 服务未装载',
      );
      _lastError = res.message;
      _lastNotice = null;
      if (!_disposed) notifyListeners();
      return res;
    }
    if (_purchaseInFlight) {
      return const StoreRestoreResult(
        status: 'pending',
        message: '正在处理当前购买请求，请稍候',
      );
    }

    final wasExhausted = isLocalQuotaExhausted;
    _purchaseInFlight = true;
    _purchasingProductId = 'restore';
    _lastError = null;
    _lastNotice = null;
    if (!_disposed) notifyListeners();

    try {
      final res = await gw.restorePurchases();
      if (_disposed) return res;
      if (res.isSuccess) {
        _applyAuthoritativeEntitlements(res.entitlements);
        await _save();
        _lastNotice = _ownedProductIds.isEmpty
            ? '未发现可恢复的有效订阅或买断记录'
            : '已恢复购买：$tierDisplayName';
      } else {
        _lastError = res.message ?? '恢复购买未成功';
      }
      return res;
    } finally {
      _purchaseInFlight = false;
      _purchasingProductId = null;
      if (!_disposed) notifyListeners();
      if (wasExhausted && !isLocalQuotaExhausted) {
        onLocalQuotaUnlocked?.call();
      }
    }
  }

  Future<bool> openManageSubscriptions() async {
    final gw = _gateway;
    if (gw == null) {
      _lastNotice = '请在「iOS 系统设置 → Apple 账户 → 订阅」管理自动续订';
      if (!_disposed) notifyListeners();
      return false;
    }
    final opened = await gw.manageSubscriptions();
    if (!opened && !_disposed) {
      _lastNotice = '未能调起系统订阅页，请在「系统设置 → Apple 账户 → 订阅」查看';
      notifyListeners();
    }
    return opened;
  }

  /// 清空本机数据时重置当月本地用量统计与调试覆盖，保留 StoreKit 权益状态。
  Future<void> resetLocalUsage() async {
    final wasExhausted = isLocalQuotaExhausted;
    _usedLocalTranscribeMs = 0;
    _monthlyCloudCreditsUsed = 0;
    _proSummariesUsed = 0;
    _proQaUsed = 0;
    _devQuotaOverrideMinutes = null;
    _backfilledForMonth = false;
    _lastNotice = null;
    _lastError = null;
    await _save();
    if (!_disposed) notifyListeners();
    if (wasExhausted && !isLocalQuotaExhausted) {
      onLocalQuotaUnlocked?.call();
    }
  }

  String settingRowSummary() {
    return switch (tier) {
      MembershipTier.free =>
        isLocalQuotaExhausted
            ? '免费版 · 本月已满'
            : '免费版 · 已用 $effectiveUsedMinutes/$freeMonthlyLimitMinutes 分',
      MembershipTier.localPro =>
        lifetimeLocalPro ? 'Local Pro · 永久版' : 'Local Pro · 无限转写',
      MembershipTier.cloudBasic => 'Cloud 基础版 · 剩 $cloudCreditsRemaining 积分',
      MembershipTier.cloudPro => 'Cloud 专业版 · Pro 剩 $cloudProSummariesRemaining 次',
    };
  }

  Future<void> _save() async {
    await _json.write(storageKey, <String, dynamic>{
      'ownedProductIds': _ownedProductIds.toList()..sort(),
      if (_subscriptionExpiresAtMs != null)
        'subscriptionExpiresAtMs': _subscriptionExpiresAtMs,
      'selectedCycle': _selectedCycle.name,
      'quotaMonthKey': _quotaMonthKey,
      'usedLocalTranscribeMs': _usedLocalTranscribeMs,
      'monthlyCloudCreditsUsed': _monthlyCloudCreditsUsed,
      'proSummariesUsed': _proSummariesUsed,
      'proQaUsed': _proQaUsed,
      if (_devQuotaOverrideMinutes != null)
        'devQuotaOverrideMinutes': _devQuotaOverrideMinutes,
      'backfilledForMonth': _backfilledForMonth,
      if (_bonusPacks.isNotEmpty)
        'bonusPacks': [for (final p in _bonusPacks) p.toJson()],
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_updatesSub?.cancel());
    super.dispose();
  }
}

class MembershipScope extends InheritedNotifier<MembershipStore> {
  const MembershipScope({
    super.key,
    required MembershipStore store,
    required super.child,
  }) : super(notifier: store);

  static MembershipStore? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MembershipScope>()
      ?.notifier;
}
