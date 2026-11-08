/// SharedPreferences 实现 —— 仅 main.dart 注入，测试不触发平台通道。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'kv_store.dart';

class SharedPreferencesKvStore implements KvStore {
  const SharedPreferencesKvStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}
