/// 带版本号的 JSON 读写层。
///
/// 解决三个具体问题：
/// 1. **版本化 key**：真实 key 形如 `rc_nav_stack_v1`，将来结构变更时升到 `_v2`，
///    旧数据自然失效而不用写迁移脚本；
/// 2. **损坏数据不致命**：手工改坏 / 写入中断导致的半截 JSON 一律当「空」处理，
///    并顺手删掉，不让一条坏记录卡死启动；
/// 3. **并发读改写不丢字段**：所有写操作经内部串行队列，`update()` 的
///    「读 → 改 → 写」整体不被其他写打断（否则两个并发 update 会互相覆盖）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'key_value_store.dart';

/// 版本化 JSON 存储。
///
/// 用法：
/// ```dart
/// final json = JsonStore(store: await PrefsStore.open());
/// await json.write('nav_stack', {'stack': []});
/// final data = await json.read('nav_stack');            // 损坏 → null
/// await json.update('settings', (cur) => {...cur, 'dark': true});
/// ```
class JsonStore {
  JsonStore({required KeyValueStore store, String namespace = 'rc'})
      : _store = store,
        _namespace = namespace;

  /// 当前 schema 版本；结构变更时改这里，旧 key 自动失效。
  static const int schemaVersion = 1;

  final KeyValueStore _store;
  final String _namespace;

  /// 串行队列尾巴：所有写操作挂在同一条 Future 链上，保证 FIFO。
  Future<void> _writeTail = Future<void>.value();

  /// 计算真实存储 key（`<namespace>_<name>_v1`）。
  String keyFor(String name) => '${_namespace}_${name}_v$schemaVersion';

  /// 读 JSON 对象。key 不存在 / JSON 损坏 / 顶层不是对象 → 返回 null。
  Future<Map<String, dynamic>?> read(String name) async {
    final raw = await _store.getString(keyFor(name));
    if (raw == null) return null;
    final decoded = _decode(raw, name);
    if (decoded == null) {
      // 损坏数据自我修复：删掉坏值，下次读就是干净的空。
      await _store.remove(keyFor(name));
      return null;
    }
    return decoded;
  }

  /// 读 JSON 数组；损坏同样按空处理。
  Future<List<Object?>?> readList(String name) async {
    final raw = await _store.getString(keyFor(name));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.cast<Object?>();
    } catch (e) {
      debugPrint('[JsonStore] 读取 $name 失败，按空处理: $e');
    }
    await _store.remove(keyFor(name));
    return null;
  }

  /// 整体覆盖写 JSON 对象（串行）。
  Future<void> write(String name, Map<String, dynamic> data) {
    return _serialize(() async {
      await _store.setString(keyFor(name), jsonEncode(data));
    });
  }

  /// 整体覆盖写 JSON 数组（串行）。
  Future<void> writeList(String name, List<Object?> data) {
    return _serialize(() async {
      await _store.setString(keyFor(name), jsonEncode(data));
    });
  }

  /// 读 → 改 → 写（原子语义：整个过程在串行队列内完成）。
  ///
  /// [mutate] 收到当前值（不存在时为空 Map，**调用方不要原地修改，返回新 Map**），
  /// 返回要写入的新值。抛异常则不写入任何东西，异常原样上抛。
  Future<Map<String, dynamic>> update(
    String name,
    FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> current)
        mutate,
  ) {
    return _serialize(() async {
      final current = await read(name) ?? <String, dynamic>{};
      final next = await mutate(current);
      await _store.setString(keyFor(name), jsonEncode(next));
      return next;
    });
  }

  /// 删除整个条目。
  Future<void> remove(String name) {
    return _serialize(() => _store.remove(keyFor(name)));
  }

  /// 把任意异步动作排进串行队列（供调用方把「读改写」以外的组合动作也排上队）。
  Future<T> serialize<T>(Future<T> Function() action) => _serialize(action);

  /// 串行队列实现：结果/异常通过 completer 透传给调用方，
  /// 队列本身吞掉异常继续跑（否则一个失败会让后续写全部挂掉）。
  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeTail = _writeTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, stack) {
        completer.completeError(e, stack);
      }
    });
    return completer.future;
  }

  Map<String, dynamic>? _decode(String raw, String name) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      debugPrint('[JsonStore] $name 顶层不是对象，按空处理');
    } catch (e) {
      debugPrint('[JsonStore] 解析 $name 失败，按空处理: $e');
    }
    return null;
  }
}
