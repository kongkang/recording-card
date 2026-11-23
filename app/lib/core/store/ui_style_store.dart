/// 可选界面风格状态机 —— 当前风格持久化、模板包安装列表、Apple-Hosted 资源包按需拉取及未来会员门控。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/transcribe/apple_asset_pack_client.dart';
import '../storage/storage.dart';
import '../theme/ui_style.dart';

/// 管理「默认 + 5 套可选模板」的安装与激活状态。
///
/// 现阶段全部模板为 [UIStyleTier.free]，支持随时获取与切换；后续上线会员档位时，
/// 只需在 [UIStyleDescriptor.catalog] 中将目标模板设为 [UIStyleTier.pro]，
/// 并由订阅状态同步 [hasProEntitlement] 即可平滑接入鉴权门槛。
class UIStyleStore extends ChangeNotifier {
  UIStyleStore({
    required KeyValueStore store,
    AppleAssetPackClient? appleAssets,
    Future<String> Function()? styleRootResolver,
    bool hasProEntitlement = false,
  }) : _store = store,
       _appleAssets = appleAssets ?? AppleAssetPackClient(),
       _styleRootResolver = styleRootResolver ?? _defaultStyleRoot,
       _hasProEntitlement = hasProEntitlement;

  static const String activeKey = 'rc.ui.style.active';
  static const String installedKey = 'rc.ui.style.installed';

  final KeyValueStore _store;
  final AppleAssetPackClient _appleAssets;
  final Future<String> Function() _styleRootResolver;

  RCUIStyleId _activeStyleId = RCUIStyleId.warmPaper;
  final Set<RCUIStyleId> _installed = <RCUIStyleId>{RCUIStyleId.warmPaper};
  RCUIStyleId? _installingStyleId;
  double _installProgress = 0;
  String? _installStatusText;
  String? _lastError;
  bool _appleHostingAvailable = false;
  bool _hasProEntitlement;
  bool _loaded = false;
  bool _disposed = false;

  RCUIStyleId get activeStyleId => _activeStyleId;
  UIStyleDescriptor get activeDescriptor =>
      UIStyleDescriptor.byId(_activeStyleId);
  Set<RCUIStyleId> get installedStyles => Set<RCUIStyleId>.unmodifiable(_installed);
  RCUIStyleId? get installingStyleId => _installingStyleId;
  double get installProgress => _installProgress;
  String? get installStatusText => _installStatusText;
  String? get lastError => _lastError;
  bool get appleHostingAvailable => _appleHostingAvailable;
  bool get hasProEntitlement => _hasProEntitlement;
  bool get loaded => _loaded;
  bool get isBusy => _installingStyleId != null;

  bool isInstalled(RCUIStyleId id) =>
      UIStyleDescriptor.byId(id).builtin || _installed.contains(id);

  bool isUnlocked(RCUIStyleId id) {
    final desc = UIStyleDescriptor.byId(id);
    return desc.tier == UIStyleTier.free || _hasProEntitlement;
  }

  void setProEntitlement(bool value) {
    if (_hasProEntitlement == value) return;
    _hasProEntitlement = value;
    _notifySafely();
  }

  static Future<String> _defaultStyleRoot() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/ui_styles';
  }

  /// 读取持久化状态，并探测 Apple-Hosted Background Assets 是否就绪。
  Future<void> load() async {
    var nextActive = RCUIStyleId.warmPaper;
    final nextInstalled = <RCUIStyleId>{RCUIStyleId.warmPaper};

    try {
      final rawInstalled = await _store.getString(installedKey);
      if (rawInstalled != null && rawInstalled.trim().isNotEmpty) {
        final decoded = jsonDecode(rawInstalled);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is String && item.trim().isNotEmpty) {
              nextInstalled.add(RCUIStyleId.fromWireId(item));
            }
          }
        }
      }
      final rawActive = await _store.getString(activeKey);
      if (rawActive != null && rawActive.trim().isNotEmpty) {
        nextActive = RCUIStyleId.fromWireId(rawActive);
        nextInstalled.add(nextActive);
      }
    } catch (e) {
      debugPrint('[ui_style] 读取风格设置失败，使用默认风格: $e');
    }

    var hostingAvailable = false;
    try {
      hostingAvailable = await _appleAssets.isAvailable();
    } catch (_) {
      hostingAvailable = false;
    }

    if (_disposed) return;
    _activeStyleId = nextActive;
    _installed
      ..clear()
      ..addAll(nextInstalled);
    _appleHostingAvailable = hostingAvailable;
    _loaded = true;
    _notifySafely();
  }

  /// 切换风格：若已安装则立即激活，否则走下载/启用流程。
  Future<void> selectStyle(RCUIStyleId id) async {
    if (isInstalled(id)) {
      if (!isUnlocked(id)) {
        _lastError = '该风格模板需会员解锁';
        _notifySafely();
        return;
      }
      _lastError = null;
      _activeStyleId = id;
      await _persist();
      _notifySafely();
      return;
    }
    await installAndSelect(id);
  }

  /// 安装（或启用）并激活指定风格模板。
  ///
  /// - 宿主处于 iOS 26+ Apple-Hosted 托管环境且云端已上架对应 AssetPack 时，
  ///   优先从 Apple CDN 拉取真实资源清单并汇报下载进度；
  /// - 开发签名包 / Android / 测试环境或远端资源包尚未发布时，
  ///   平滑回退使用应用内置的可编程样式表完成安装，不虚构假进度、不阻塞切换。
  Future<bool> installAndSelect(RCUIStyleId id) async {
    if (_installingStyleId != null) return false;
    final desc = UIStyleDescriptor.byId(id);
    if (!isUnlocked(id)) {
      _lastError = '${desc.name}模板将于后续会员档位开放';
      _notifySafely();
      return false;
    }

    if (desc.builtin || _installed.contains(id)) {
      _lastError = null;
      _activeStyleId = id;
      await _persist();
      _notifySafely();
      return true;
    }

    _installingStyleId = id;
    _installProgress = 0.0;
    _installStatusText = '正在获取「${desc.name}」模板…';
    _lastError = null;
    _notifySafely();

    try {
      await _tryFetchAppleAssetPack(desc);
      if (_disposed) return false;
      _installed.add(id);
      _activeStyleId = id;
      await _persist();
      return true;
    } catch (e) {
      if (_disposed) return false;
      _lastError = e.toString();
      return false;
    } finally {
      _installingStyleId = null;
      _installProgress = 0.0;
      _installStatusText = null;
      _notifySafely();
    }
  }

  Future<void> _tryFetchAppleAssetPack(UIStyleDescriptor desc) async {
    var available = false;
    try {
      available = await _appleAssets.isAvailable();
      _appleHostingAvailable = available;
    } catch (_) {
      available = false;
    }
    if (!available) {
      return;
    }

    final packIds = await _appleAssets.availablePackIds();
    if (packIds != null && !packIds.contains(desc.assetPackId)) {
      // Apple CDN 尚未上架该风格资源包时平滑回落至客户端内置模板参数
      return;
    }

    final root = await _styleRootResolver();
    final destManifest = '$root/${desc.id.wireId}/manifest.json';
    try {
      await _appleAssets.installAssetPack(
        packId: desc.assetPackId,
        displayName: desc.name,
        files: <AppleAssetPackFile>[
          AppleAssetPackFile(
            assetPath: '${desc.id.wireId}/manifest.json',
            destPath: destManifest,
          ),
        ],
        onProgress: (p, text) {
          if (_disposed) return;
          _installProgress = p;
          _installStatusText = text;
          _notifySafely();
        },
      );
    } on AppleAssetPackException catch (e) {
      if (e.isNotFound || e.code == 'NOT_CONFIGURED' || e.code == 'MISSING_PLUGIN') {
        return;
      }
      rethrow;
    }
  }

  /// 卸载已安装的非默认风格模板（若正在使用则自动切回默认「静纸声录」）。
  Future<void> removeStyle(RCUIStyleId id) async {
    final desc = UIStyleDescriptor.byId(id);
    if (desc.builtin || !_installed.contains(id)) return;

    await _appleAssets.removeAssetPack(desc.assetPackId);
    try {
      final root = await _styleRootResolver();
      final dir = Directory('$root/${desc.id.wireId}');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 本地目录清理失败不影响状态移除
    }

    _installed.remove(id);
    if (_activeStyleId == id) {
      _activeStyleId = RCUIStyleId.warmPaper;
    }
    _lastError = null;
    await _persist();
    _notifySafely();
  }

  Future<void> _persist() async {
    try {
      await _store.setString(activeKey, _activeStyleId.wireId);
      final encoded = jsonEncode(<String>[
        for (final id in _installed) id.wireId,
      ]);
      await _store.setString(installedKey, encoded);
    } catch (e) {
      debugPrint('[ui_style] 保存风格配置失败: $e');
    }
  }

  void _notifySafely() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 将 [UIStyleStore] 向下透传给设置页与子页，无需在每层构造函数显式必传。
class UIStyleScope extends InheritedNotifier<UIStyleStore> {
  const UIStyleScope({
    super.key,
    required UIStyleStore store,
    required super.child,
  }) : super(notifier: store);

  static UIStyleStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UIStyleScope>()?.notifier;

  static UIStyleStore of(BuildContext context) {
    final store = maybeOf(context);
    assert(store != null, 'No UIStyleScope found in context');
    return store!;
  }
}
