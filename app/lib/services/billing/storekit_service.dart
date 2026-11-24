/// Apple StoreKit 2 内购网关抽象与原生 MethodChannel 实现。
///
/// 通信通道：`com.reai.recordingcard/storekit`（iOS 侧由 `RCStoreKitBridge` 承载）。
/// 失败或当前平台无通道时如实返回 unavailable / 空列表，绝不伪造已购权益。
library;

import 'dart:async';

import 'package:flutter/services.dart';

class StoreProductInfo {
  const StoreProductInfo({
    required this.id,
    required this.displayName,
    required this.description,
    required this.displayPrice,
    required this.price,
    required this.currencyCode,
    required this.type,
  });

  final String id;
  final String displayName;
  final String description;
  final String displayPrice;
  final double price;
  final String currencyCode;
  final String type;

  factory StoreProductInfo.fromMap(Map<Object?, Object?> raw) =>
      StoreProductInfo(
        id: '${raw['id'] ?? ''}',
        displayName: '${raw['displayName'] ?? ''}',
        description: '${raw['description'] ?? ''}',
        displayPrice: '${raw['displayPrice'] ?? ''}',
        price: (raw['price'] as num?)?.toDouble() ?? 0.0,
        currencyCode: '${raw['currencyCode'] ?? ''}',
        type: '${raw['type'] ?? 'unknown'}',
      );
}

class StoreEntitlement {
  const StoreEntitlement({
    required this.productId,
    required this.transactionId,
    required this.originalTransactionId,
    this.expirationDateMs,
    this.isUpgraded = false,
  });

  final String productId;
  final String transactionId;
  final String originalTransactionId;
  final int? expirationDateMs;
  final bool isUpgraded;

  factory StoreEntitlement.fromMap(Map<Object?, Object?> raw) =>
      StoreEntitlement(
        productId: '${raw['productId'] ?? ''}',
        transactionId: '${raw['transactionId'] ?? ''}',
        originalTransactionId: '${raw['originalTransactionId'] ?? ''}',
        expirationDateMs: (raw['expirationDateMs'] as num?)?.toInt(),
        isUpgraded: raw['isUpgraded'] == true,
      );
}

class StoreCatalogResult {
  const StoreCatalogResult({
    this.products = const <StoreProductInfo>[],
    this.error,
  });

  final List<StoreProductInfo> products;
  final String? error;
}

enum StorePurchaseStatus {
  purchased,
  cancelled,
  pending,
  unverified,
  unavailable,
  error,
}

class StorePurchaseResult {
  const StorePurchaseResult({
    required this.status,
    this.productId,
    this.transactionId,
    this.originalTransactionId,
    this.expirationDateMs,
    this.message,
  });

  final StorePurchaseStatus status;
  final String? productId;
  final String? transactionId;
  final String? originalTransactionId;
  final int? expirationDateMs;
  final String? message;

  bool get isPurchased => status == StorePurchaseStatus.purchased;
}

class StoreRestoreResult {
  const StoreRestoreResult({
    required this.status,
    this.entitlements = const <StoreEntitlement>[],
    this.message,
  });

  final String status;
  final List<StoreEntitlement> entitlements;
  final String? message;

  bool get isSuccess => status == 'restored';
}

abstract class StoreKitGateway {
  /// 最近一次 [currentEntitlements] 调用是否真正拿到平台权威响应。
  /// 非 iOS 或未注册通道时返回 false，避免覆盖本机缓存的有效权益。
  bool get lastEntitlementCheckAuthoritative => true;

  Future<StoreCatalogResult> loadProducts(List<String> productIds);

  Future<List<StoreEntitlement>> currentEntitlements();

  Future<StorePurchaseResult> purchase(String productId);

  Future<StoreRestoreResult> restorePurchases();

  Future<bool> manageSubscriptions();

  Stream<void> get entitlementUpdates;

  void dispose() {}
}

class MethodChannelStoreKitGateway implements StoreKitGateway {
  MethodChannelStoreKitGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  static const String _channelName = 'com.reai.recordingcard/storekit';

  final MethodChannel _channel;
  final StreamController<void> _updates = StreamController<void>.broadcast();
  bool _lastAuthoritative = false;

  @override
  bool get lastEntitlementCheckAuthoritative => _lastAuthoritative;

  @override
  Stream<void> get entitlementUpdates => _updates.stream;

  Future<void> _onPlatformCall(MethodCall call) async {
    if (call.method == 'onEntitlementsUpdated' && !_updates.isClosed) {
      _updates.add(null);
    }
  }

  @override
  Future<StoreCatalogResult> loadProducts(List<String> productIds) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'loadProducts',
        <String, Object?>{'productIds': productIds},
      );
      if (raw == null) {
        return const StoreCatalogResult(error: 'StoreKit 通道未返回商品目录');
      }
      final rawList = raw['products'] as List<Object?>? ?? const <Object?>[];
      final products = <StoreProductInfo>[
        for (final item in rawList)
          if (item is Map<Object?, Object?>) StoreProductInfo.fromMap(item),
      ];
      final err = raw['error'] as String?;
      return StoreCatalogResult(products: products, error: err);
    } on MissingPluginException {
      return const StoreCatalogResult(error: '当前平台不支持 Apple StoreKit 内购');
    } on PlatformException catch (e) {
      return StoreCatalogResult(error: e.message ?? e.code);
    } on Object catch (e) {
      return StoreCatalogResult(error: '$e');
    }
  }

  @override
  Future<List<StoreEntitlement>> currentEntitlements() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'currentEntitlements',
      );
      if (raw == null) {
        _lastAuthoritative = false;
        return const <StoreEntitlement>[];
      }
      _lastAuthoritative = true;
      final list = raw['entitlements'] as List<Object?>? ?? const <Object?>[];
      return <StoreEntitlement>[
        for (final item in list)
          if (item is Map<Object?, Object?>) StoreEntitlement.fromMap(item),
      ];
    } on MissingPluginException {
      _lastAuthoritative = false;
      return const <StoreEntitlement>[];
    } on PlatformException {
      _lastAuthoritative = false;
      return const <StoreEntitlement>[];
    } on Object {
      _lastAuthoritative = false;
      return const <StoreEntitlement>[];
    }
  }

  @override
  Future<StorePurchaseResult> purchase(String productId) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'purchase',
        <String, Object?>{'productId': productId},
      );
      if (raw == null) {
        return const StorePurchaseResult(
          status: StorePurchaseStatus.unavailable,
          message: 'StoreKit 购买通道暂不可用',
        );
      }
      final statusStr = '${raw['status'] ?? 'error'}';
      final status = switch (statusStr) {
        'purchased' => StorePurchaseStatus.purchased,
        'cancelled' => StorePurchaseStatus.cancelled,
        'pending' => StorePurchaseStatus.pending,
        'unverified' => StorePurchaseStatus.unverified,
        'unavailable' => StorePurchaseStatus.unavailable,
        _ => StorePurchaseStatus.error,
      };
      return StorePurchaseResult(
        status: status,
        productId: raw['productId'] as String?,
        transactionId: raw['transactionId'] as String?,
        originalTransactionId: raw['originalTransactionId'] as String?,
        expirationDateMs: (raw['expirationDateMs'] as num?)?.toInt(),
        message: raw['message'] as String?,
      );
    } on MissingPluginException {
      return const StorePurchaseResult(
        status: StorePurchaseStatus.unavailable,
        message: '当前平台暂不支持 Apple StoreKit 内购',
      );
    } on PlatformException catch (e) {
      return StorePurchaseResult(
        status: StorePurchaseStatus.error,
        message: e.message ?? e.code,
      );
    } on Object catch (e) {
      return StorePurchaseResult(
        status: StorePurchaseStatus.error,
        message: '$e',
      );
    }
  }

  @override
  Future<StoreRestoreResult> restorePurchases() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'restorePurchases',
      );
      if (raw == null) {
        return const StoreRestoreResult(
          status: 'unavailable',
          message: 'StoreKit 恢复购买通道暂不可用',
        );
      }
      final list = raw['entitlements'] as List<Object?>? ?? const <Object?>[];
      return StoreRestoreResult(
        status: '${raw['status'] ?? 'error'}',
        entitlements: <StoreEntitlement>[
          for (final item in list)
            if (item is Map<Object?, Object?>) StoreEntitlement.fromMap(item),
        ],
        message: raw['message'] as String?,
      );
    } on MissingPluginException {
      return const StoreRestoreResult(
        status: 'unavailable',
        message: '当前平台暂不支持 Apple StoreKit 内购',
      );
    } on PlatformException catch (e) {
      return StoreRestoreResult(
        status: 'error',
        message: e.message ?? e.code,
      );
    } on Object catch (e) {
      return StoreRestoreResult(status: 'error', message: '$e');
    }
  }

  @override
  Future<bool> manageSubscriptions() async {
    try {
      final ok = await _channel.invokeMethod<bool>('manageSubscriptions');
      return ok ?? false;
    } on Object {
      return false;
    }
  }

  @override
  void dispose() {
    unawaited(_updates.close());
  }
}
