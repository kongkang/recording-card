/// 键值存储接缝 —— 生产走 SharedPreferences，测试走内存实现。
///
/// 只存 JSON 字符串，避免把平台插件类型泄漏进 store；后续换 Keychain /
/// 加密存储时只需替换实现，测试不受影响。
library;

abstract class KvStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// 测试/无插件环境实现：进程内 Map，写入立即可读。
class MemoryKvStore implements KvStore {
  MemoryKvStore([Map<String, String>? initial]) : _data = {...?initial};

  final Map<String, String> _data;

  @override
  String? getString(String key) => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}
