/// 加密存储层（OAuth token 专用）。
///
/// 与 [KeyValueStore] 的分工：明文偏好数据（设置开关、导航栈）走 shared_preferences，
/// 凭据类数据（access/refresh token）必须走系统密钥库——
/// iOS Keychain / Android Keystore 加密的 SharedPreferences。
///
/// 提供两个实现：
/// - [KeychainSecureStore]：真实实现，包装 flutter_secure_storage；
/// - [InMemorySecureStore]：测试实现，不需要平台通道。
///
/// 设计约束：**按 key 读写，不做 deleteAll**。清空只针对自己登记过的 key 列表，
/// 避免误删其他模块（未来可能接入的推送 token 等）的凭据。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 加密键值存储抽象接口。
abstract interface class SecureStore {
  /// 读明文（不存在返回 null）。
  Future<String?> read(String key);

  /// 写明文（覆盖）。
  Future<void> write(String key, String value);

  /// 删除（不存在时静默成功）。
  Future<void> delete(String key);

  /// 读 JSON 对象：不存在 → null；损坏 → null（并删除坏值，不致命）。
  Future<Map<String, dynamic>?> readJson(String key);

  /// 写 JSON 对象（一次性写入，避免多 key 轮换错配）。
  Future<void> writeJson(String key, Map<String, dynamic> value);
}

/// flutter_secure_storage 实现。
///
/// - iOS：`first_unlock` 可访问性（设备重启后首次解锁前不可读，重启后后台任务
///   不会因读不到 token 而崩）；
/// - Android：库默认的 AES-GCM + Keystore 密钥包装。
///
/// 平台通道异常（如纯 Dart 测试环境无插件）由调用方决定如何降级：本类不吞异常。
class KeychainSecureStore implements SecureStore {
  KeychainSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, dynamic>?> readJson(String key) async {
    final raw = await read(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[SecureStore] $key 解析失败，按空处理: $e');
    }
    // 损坏数据直接清掉：留着永远读不出来，还会让上层每次都要判断。
    await delete(key);
    return null;
  }

  @override
  Future<void> writeJson(String key, Map<String, dynamic> value) =>
      write(key, jsonEncode(value));
}

/// 纯内存实现（测试 / 无平台通道环境）。进程退出即丢。
class InMemorySecureStore implements SecureStore {
  InMemorySecureStore([Map<String, String>? initial])
      : _values = {...?initial};

  final Map<String, String> _values;

  /// 当前内容快照（测试断言用）。
  Map<String, String> get snapshot => Map.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<Map<String, dynamic>?> readJson(String key) async {
    final raw = _values[key];
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[InMemorySecureStore] $key 解析失败，按空处理: $e');
    }
    _values.remove(key);
    return null;
  }

  @override
  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    _values[key] = jsonEncode(value);
  }
}
