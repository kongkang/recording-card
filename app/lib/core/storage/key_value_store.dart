/// 键值存储抽象层。
///
/// 目的：把「具体存储介质」从业务代码里隔离出来——
/// - 生产实现 [PrefsStore] 走 shared_preferences（iOS NSUserDefaults / Android
///   SharedPreferences，明文，只放非敏感数据）；
/// - 测试实现 [InMemoryStore] 纯内存，无需平台通道，widget/unit 测试可直接用。
///
/// 敏感数据（OAuth token）**不要**走这里，走 `secure_store.dart`。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 键值存储抽象接口（字符串 + 布尔，够覆盖设置开关、导航栈、列表快照等场景）。
///
/// 约定：
/// - 所有方法返回 Future，调用方必须 `await`；
/// - 读取不存在的 key 返回 null（布尔返回 null 而不是 false，便于区分「未设置」）；
/// - 实现不得抛「key 不存在」类异常。
abstract interface class KeyValueStore {
  /// 读字符串；不存在返回 null。
  Future<String?> getString(String key);

  /// 写字符串（覆盖）。
  Future<void> setString(String key, String value);

  /// 读布尔；不存在返回 null。
  Future<bool?> getBool(String key);

  /// 写布尔。
  Future<void> setBool(String key, bool value);

  /// 删除单个 key（不存在时静默成功）。
  Future<void> remove(String key);

  /// key 是否存在。
  Future<bool> containsKey(String key);
}

/// shared_preferences 实现。
///
/// 用法：`final store = await PrefsStore.open();`
///
/// 注意：`SharedPreferences.getInstance()` 把整个偏好表读进内存，只需拿一次实例，
/// 不要在每个读写点重复 `open()`。
class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);

  /// 打开底层 SharedPreferences 并包装。
  static Future<PrefsStore> open() async {
    return PrefsStore(await SharedPreferences.getInstance());
  }

  final SharedPreferences _prefs;

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<bool?> getBool(String key) async => _prefs.getBool(key);

  @override
  Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _prefs.containsKey(key);
}

/// 纯内存实现（测试 / 预览用）。进程退出即丢，不做任何持久化。
class InMemoryStore implements KeyValueStore {
  InMemoryStore([Map<String, String>? initial])
      : _values = {...?initial};

  final Map<String, String> _values;

  /// 当前全部内容（只读快照，测试断言用）。
  Map<String, String> get snapshot => Map.unmodifiable(_values);

  /// 布尔值以 'true' / 'false' 字符串存放，与字符串 key 共用一张表，
  /// 键名冲突时类型以最后一次写入为准（测试里不要混用同名 key）。
  static const _truePrefix = '@bool:';

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<bool?> getBool(String key) async {
    final raw = _values['$_truePrefix$key'];
    if (raw == null) return null;
    return raw == 'true';
  }

  @override
  Future<void> setBool(String key, bool value) async {
    _values['$_truePrefix$key'] = value.toString();
  }

  @override
  Future<void> remove(String key) async {
    _values
      ..remove(key)
      ..remove('$_truePrefix$key');
  }

  @override
  Future<bool> containsKey(String key) async =>
      _values.containsKey(key) || _values.containsKey('$_truePrefix$key');
}
