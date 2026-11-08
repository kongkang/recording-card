/// 录音 / 转录设置 —— 与 prototype Setting 页 6 个开关一一对应。
///
/// 持久化到 KvStore（键 [storageKey]），重启后恢复；默认值即设计稿初始态。
library;
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/kv_store.dart';

class SettingsStore extends ChangeNotifier {
  SettingsStore({KvStore? storage}) : _storage = storage ?? MemoryKvStore() {
    _restore();
  }

  static const storageKey = 'rc-settings-v1';

  /// 与 SettingPage 展示顺序一致（UI 与测试都从这里取键）。
  static const defaults = <String, bool>{
    '持续录音': true,
    '标记重要对话': true,
    '自动转录': true,
    '自动清洗口语': true,
    '说话人推测归类': true,
    '仅 Wi-Fi 同步': false,
  };

  final KvStore _storage;
  final Map<String, bool> _values = {...defaults};

  List<String> get keys => defaults.keys.toList(growable: false);

  Map<String, bool> get values => Map.unmodifiable(_values);

  bool valueOf(String key) => _values[key] ?? false;

  void toggle(String key) {
    _values[key] = !valueOf(key);
    _persist();
    notifyListeners();
  }

  void _restore() {
    final raw = _storage.getString(storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      for (final key in defaults.keys) {
        final value = decoded[key];
        if (value is bool) _values[key] = value;
      }
    } catch (_) {
      // 损坏数据回落默认值，不阻塞启动
    }
  }

  void _persist() {
    unawaited(_storage.setString(storageKey, jsonEncode(_values)));
  }
}
