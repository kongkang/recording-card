/// 设置页开关状态 —— 6 个开关的分组定义 + 本地持久化。
///
/// 为什么单独成 store：开关状态原来写死在页面 State 里，切 Tab 重建就复位。
/// 这里把「开关清单（顺序/文案）」「当前值」「落盘」集中到一处：
/// - 页面只按 [SettingsStore.groups] 渲染，顺序与文案改这里；
/// - 值走 [KeyValueStore]（生产 = shared_preferences，测试 = [InMemoryStore]）；
/// - 页面重建后 `load()` 从盘里读回，状态不再丢。
///
/// 传输层：`KeyValueStore` 由构造注入，页面在拿到 `PrefsStore.open()` 的
/// Future 后 await 再注入；测试直接注入 [InMemoryStore]，不碰平台通道。
library;

import 'package:flutter/foundation.dart';

import '../storage/storage.dart';

/// 单个开关定义。
@immutable
class SettingsSwitchItem {
  const SettingsSwitchItem({
    required this.key,
    required this.label,
    required this.defaultValue,
    required this.semanticLabel,
  });

  /// 持久化键（带 `rc.set.` 前缀，避免与导航栈/总结快照等其它 key 撞车）。
  final String key;

  /// 行文案（严格对齐 prototype/index.html `#p-setting`）。
  final String label;

  /// 首次启动（盘里没有该 key）时的取值。
  final bool defaultValue;

  /// 读屏标签（对齐原型 `aria-label`，例如「仅 Wi-Fi 同步开关」）。
  final String semanticLabel;
}

/// 开关分组（组标题 + 若干开关）。
@immutable
class SettingsGroup {
  const SettingsGroup({required this.title, required this.items});

  final String title;
  final List<SettingsSwitchItem> items;
}

/// 设置开关状态机。
class SettingsStore extends ChangeNotifier {
  SettingsStore({required KeyValueStore store}) : _store = store;

  final KeyValueStore _store;
  final Map<String, bool> _values = <String, bool>{};
  final Set<String> _touched = <String>{};
  bool _loaded = false;
  bool _disposed = false;

  /// 分组与顺序（UI 渲染、测试锚点 `sw-<索引>` 都以它为准）。
  ///
  /// 默认值：自动转录/清洗/说话人开，「仅使用 Wi-Fi 同步」关。
  static const List<SettingsGroup> groups = <SettingsGroup>[
    SettingsGroup(
      title: '转录与清洗',
      items: <SettingsSwitchItem>[
        SettingsSwitchItem(
          key: 'rc.set.trans.auto',
          label: '自动转录',
          defaultValue: true,
          semanticLabel: '自动转录开关',
        ),
        SettingsSwitchItem(
          key: 'rc.set.trans.clean',
          label: '自动清洗口语',
          defaultValue: true,
          semanticLabel: '自动清洗口语开关',
        ),
        SettingsSwitchItem(
          key: 'rc.set.trans.speaker',
          label: '说话人推测归类',
          defaultValue: true,
          semanticLabel: '说话人推测归类开关',
        ),
      ],
    ),
    SettingsGroup(
      title: '同步',
      items: <SettingsSwitchItem>[
        SettingsSwitchItem(
          key: 'rc.set.sync.wifiOnly',
          label: '仅使用 Wi-Fi 同步',
          defaultValue: false,
          semanticLabel: '仅 Wi-Fi 同步开关',
        ),
      ],
    ),
  ];

  /// 全部开关按 UI 顺序扁平化（索引 0..3 = 测试锚点 `sw-0`…`sw-3`）。
  static List<SettingsSwitchItem> get items => <SettingsSwitchItem>[
    for (final g in groups) ...g.items,
  ];

  /// 是否已从存储读过一次。
  bool get loaded => _loaded;

  /// 本次运行内被 [setValue] 改过的键（页面从内存 store 切到持久化 store 时用来搬运）。
  Set<String> get touchedKeys => Set<String>.unmodifiable(_touched);

  /// 读一次盘：盘里没有的键取原型默认值。
  ///
  /// 幂等：重复调用只是再读一次盘；读失败（平台通道不可用）按默认值处理，
  /// 不抛异常——设置页不该因为存储不可用而白屏。
  Future<void> load() async {
    final next = <String, bool>{};
    for (final item in items) {
      bool? stored;
      try {
        stored = await _store.getBool(item.key);
      } catch (e) {
        debugPrint('[settings] 读取 ${item.key} 失败，用默认值: $e');
      }
      next[item.key] = stored ?? item.defaultValue;
    }
    // 本次运行内用户已改过的键不让盘里的旧值覆盖（避免异步 load 回来时
    // 把用户刚点的开关弹回去）
    for (final key in _touched) {
      final v = _values[key];
      if (v != null) next[key] = v;
    }
    if (_disposed) return;
    _values
      ..clear()
      ..addAll(next);
    _loaded = true;
    notifyListeners();
  }

  /// 当前值；未读过盘或未知键时回落到原型默认值（首帧就能渲染正确状态）。
  bool value(String key) => _values[key] ?? defaultValueOf(key);

  /// 定义里的默认值；未知键返回 false 并打日志（调用方写错 key 时可查）。
  static bool defaultValueOf(String key) {
    for (final item in items) {
      if (item.key == key) return item.defaultValue;
    }
    debugPrint('[settings] 未知设置键: $key');
    return false;
  }

  /// 写入并持久化（先更新内存 + 通知 UI，再落盘；落盘失败只记日志）。
  Future<void> setValue(String key, bool v) async {
    if (value(key) == v) return;
    _values[key] = v;
    _touched.add(key);
    if (!_disposed) notifyListeners();
    try {
      await _store.setBool(key, v);
    } catch (e) {
      debugPrint('[settings] 保存 $key 失败: $e');
    }
  }

  /// 取反（点整行/开关都走这里）。
  Future<void> toggle(String key) => setValue(key, !value(key));

  /// 清空本机数据或重置本机偏好时清空全部已保存开关项并恢复默认。
  Future<void> resetAll() async {
    _values.clear();
    _touched.clear();
    for (final item in items) {
      try {
        await _store.remove(item.key);
      } catch (_) {
        // 忽略重置单个键异常
      }
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
