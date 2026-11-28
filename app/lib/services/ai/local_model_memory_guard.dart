/// 端侧重模型单槽位内存互斥守卫。
///
/// 移动端（尤其 4GB 内存 iPhone 13 mini / 6~8GB 机型）不能同时常驻多个百兆/千兆级权重：
/// - ASR（SenseVoice / CAM++）
/// - 小型端侧 LLM（如 Qwen3.5-0.8B）
/// - 大型端侧 LLM（如 Qwen3.5-2B）
///
/// 本守卫保证任意时刻内存中最多只有 1 个重模型槽位处于激活状态；
/// 切换新槽位前先串行释放其他已占用槽位并触发系统内存回收。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 端侧重模型互斥槽位。
enum LocalHeavyModelSlot {
  none('none'),
  asr('asr'),
  smallLlm('small_llm'),
  largeLlm('large_llm');

  const LocalHeavyModelSlot(this.code);
  final String code;
}

class LocalModelMemoryGuard extends ChangeNotifier {
  LocalModelMemoryGuard({
    Future<void> Function()? onTrimNativeMemory,
  }) : _onTrimNativeMemory = onTrimNativeMemory;

  final Future<void> Function()? _onTrimNativeMemory;
  final Map<LocalHeavyModelSlot, Future<void> Function()> _releasers = {};
  final List<String> _recentEvents = [];

  LocalHeavyModelSlot _activeSlot = LocalHeavyModelSlot.none;
  Future<void> _serial = Future<void>.value();
  int _evictionCount = 0;

  LocalHeavyModelSlot get activeSlot => _activeSlot;
  int get evictionCount => _evictionCount;
  List<String> get recentEvents => List.unmodifiable(_recentEvents);

  void registerReleaser(
    LocalHeavyModelSlot slot,
    Future<void> Function() releaser,
  ) {
    if (slot == LocalHeavyModelSlot.none) return;
    _releasers[slot] = releaser;
  }

  /// 申请占用 [target] 槽位；若当前已有其他重模型常驻，先释放并回收原生堆内存。
  Future<void> acquire(
    LocalHeavyModelSlot target, {
    String reason = 'switch',
  }) {
    final completer = Completer<void>();
    _serial = _serial.then((_) async {
      try {
        await _acquireLocked(target, reason: reason);
        completer.complete();
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 释放指定槽位。
  Future<void> release(
    LocalHeavyModelSlot slot, {
    String reason = 'explicit',
  }) {
    final completer = Completer<void>();
    _serial = _serial.then((_) async {
      try {
        await _releaseLocked(slot, reason: reason);
        completer.complete();
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 退后台或收到系统内存警告时释放所有已激活重模型。
  Future<void> releaseAll({String reason = 'background'}) {
    final completer = Completer<void>();
    _serial = _serial.then((_) async {
      try {
        final slots = _releasers.keys.toList(growable: false);
        var releasedAny = false;
        for (final slot in slots) {
          if (_activeSlot == slot || reason == 'memory_pressure') {
            await _releaseSlotUnsafe(slot);
            releasedAny = true;
          }
        }
        if (_activeSlot != LocalHeavyModelSlot.none) {
          _activeSlot = LocalHeavyModelSlot.none;
          releasedAny = true;
        }
        if (releasedAny) {
          await _trimNativeUnsafe();
          _log('releaseAll:$reason');
          notifyListeners();
        }
        completer.complete();
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _acquireLocked(
    LocalHeavyModelSlot target, {
    required String reason,
  }) async {
    if (target == LocalHeavyModelSlot.none) {
      await _releaseSlotUnsafe(_activeSlot);
      _activeSlot = LocalHeavyModelSlot.none;
      notifyListeners();
      return;
    }
    if (_activeSlot == target) return;

    if (_activeSlot != LocalHeavyModelSlot.none) {
      final prev = _activeSlot;
      await _releaseSlotUnsafe(prev);
      _evictionCount++;
      await _trimNativeUnsafe();
      _log('evict:${prev.code}->${target.code}($reason)');
    } else {
      _log('acquire:${target.code}($reason)');
    }
    _activeSlot = target;
    notifyListeners();
  }

  Future<void> _releaseLocked(
    LocalHeavyModelSlot slot, {
    required String reason,
  }) async {
    if (slot == LocalHeavyModelSlot.none) return;
    await _releaseSlotUnsafe(slot);
    if (_activeSlot == slot) {
      _activeSlot = LocalHeavyModelSlot.none;
      await _trimNativeUnsafe();
      _log('release:${slot.code}($reason)');
      notifyListeners();
    }
  }

  Future<void> _releaseSlotUnsafe(LocalHeavyModelSlot slot) async {
    if (slot == LocalHeavyModelSlot.none) return;
    final releaser = _releasers[slot];
    if (releaser == null) return;
    try {
      await releaser();
    } on Object catch (e) {
      debugPrint('[memory-guard] 释放 ${slot.code} 失败：$e');
    }
  }

  Future<void> _trimNativeUnsafe() async {
    final trim = _onTrimNativeMemory;
    if (trim == null) return;
    try {
      await trim();
    } on Object catch (e) {
      debugPrint('[memory-guard] 原生内存清理失败：$e');
    }
  }

  void _log(String event) {
    _recentEvents.add(event);
    if (_recentEvents.length > 24) {
      _recentEvents.removeAt(0);
    }
  }
}
