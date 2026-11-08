/// 全局错误兜底：接管框架异常与未捕获异步异常。
///
/// 做两件事：
/// 1. 统一用 `[crash]` 前缀打日志（release 下也能在 logcat / Console 里 grep 到）；
/// 2. 把**最近一条**错误落到本地（`rc.lastCrash`），供「关于录音卡」页展示，
///    让用户反馈问题时报出的信息可定位，而不是只有一句「它崩了」。
///
/// 只保留最近一条：崩溃信息是排查线索，不是日志系统，堆积反而占空间且无意义。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, debugPrint;

import '../storage/key_value_store.dart';

/// 本地键名（沿用项目 `rc.` 前缀习惯）。
const String lastCrashKey = 'rc.lastCrash';

/// 单条错误摘要上限：写太多既占空间，也让「关于」页排版难看。
const int _maxMessageChars = 600;
const int _maxStackLines = 12;

/// 最近一次错误的结构化记录。
class CrashRecord {
  const CrashRecord({
    required this.time,
    required this.kind,
    required this.message,
    this.stack,
  });

  /// 发生时间（本机时区）。
  final DateTime time;

  /// 错误来源：`FlutterError` / `UncaughtError`。
  final String kind;

  /// 错误摘要（已截断）。
  final String message;

  /// 调用栈前若干行（可为空）。
  final String? stack;

  /// 单行摘要，列表/复制用。
  String get summary => '$kind: $message';

  Map<String, Object?> toJson() => {
    't': time.toIso8601String(),
    'kind': kind,
    'message': message,
    if (stack != null && stack!.isNotEmpty) 'stack': stack,
  };

  /// 解析历史记录；格式不认识时返回 null（旧版本写过纯文本也算「不认识」）。
  static CrashRecord? fromJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final time = DateTime.tryParse('${decoded['t']}');
      final kind = decoded['kind'];
      final message = decoded['message'];
      if (time == null || kind is! String || message is! String) return null;
      final stack = decoded['stack'];
      return CrashRecord(
        time: time,
        kind: kind,
        message: message,
        stack: stack is String ? stack : null,
      );
    } catch (e) {
      debugPrint('[crash] 解析 lastCrash 失败，按无记录处理: $e');
      return null;
    }
  }
}

bool _installed = false;
KeyValueStore? _injectedStore;
KeyValueStore? _openedStore;

/// 安装全局错误处理器（在 `runApp` 之前调用一次，重复调用无副作用）。
///
/// [store] 仅用于测试注入内存实现；生产不传，内部懒加载 `PrefsStore`。
void installCrashHandlers({KeyValueStore? store}) {
  if (_installed) return;
  _installed = true;
  _injectedStore = store;

  FlutterError.onError = (FlutterErrorDetails details) {
    // 保留 Flutter 默认行为（debug 下红屏、release 下打印），再落一条本地记录
    FlutterError.presentError(details);
    _record('FlutterError', details.exceptionAsString(), details.stack);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _record('UncaughtError', error.toString(), stack);
    // 已成体系地记录过，就当作「已处理」，避免用户看到直接闪退
    return true;
  };
}

/// 读取最近一条错误；没有记录返回 null。
Future<CrashRecord?> readLastCrash({KeyValueStore? store}) async {
  final kv = await _resolveStore(store);
  if (kv == null) return null;
  final raw = await kv.getString(lastCrashKey);
  if (raw == null || raw.isEmpty) return null;
  return CrashRecord.fromJson(raw);
}

/// 清除最近一条错误（用户点了「已了解」或反馈已提交后调用）。
Future<void> clearLastCrash({KeyValueStore? store}) async {
  final kv = await _resolveStore(store);
  await kv?.remove(lastCrashKey);
}

/// 测试用：复位处理器与缓存（生产代码不调用）。
void resetCrashGuardForTest() {
  _installed = false;
  _injectedStore = null;
  _openedStore = null;
}

void _record(String kind, String message, StackTrace? stack) {
  final trimmedMessage = _truncate(message, _maxMessageChars);
  final trimmedStack = stack == null ? null : _truncateStack(stack.toString());

  debugPrint('[crash] $kind: $trimmedMessage');
  if (trimmedStack != null) {
    debugPrint('[crash] stack:\n$trimmedStack');
  }

  final record = CrashRecord(
    time: DateTime.now(),
    kind: kind,
    message: trimmedMessage,
    stack: trimmedStack,
  );
  // 错误处理路径里不能 await（也不能让写入失败再抛一次），fire-and-forget
  unawaited(_persist(record));
}

Future<void> _persist(CrashRecord record) async {
  try {
    final kv = await _resolveStore(null);
    if (kv == null) return;
    await kv.setString(lastCrashKey, jsonEncode(record.toJson()));
  } catch (e) {
    // 存储层自己出错时只打日志，绝不二次抛出
    debugPrint('[crash] 写入 lastCrash 失败: $e');
  }
}

Future<KeyValueStore?> _resolveStore(KeyValueStore? explicit) async {
  if (explicit != null) return explicit;
  if (_injectedStore != null) return _injectedStore;
  final opened = _openedStore;
  if (opened != null) return opened;
  try {
    final store = await PrefsStore.open();
    _openedStore = store;
    return store;
  } catch (e) {
    debugPrint('[crash] 打开本地存储失败，本次只打日志: $e');
    return null;
  }
}

String _truncate(String text, int maxChars) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= maxChars) return flat;
  return '${flat.substring(0, maxChars)}…';
}

String? _truncateStack(String stack) {
  final lines = stack
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.isNotEmpty)
      .take(_maxStackLines)
      .toList();
  if (lines.isEmpty) return null;
  return lines.join('\n');
}
