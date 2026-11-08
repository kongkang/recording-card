/// 录音仓库 —— 元数据持久化在 KvStore，音频本体由文件存储层管理（后续接）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/kv_store.dart';
import 'recording.dart';

class RecordingRepository extends ChangeNotifier {
  RecordingRepository(this._storage) {
    _load();
  }

  static const storageKey = 'rc-recordings-v1';

  final KvStore _storage;
  final Map<String, Recording> _records = {};

  List<Recording> all() {
    final list = _records.values.toList()
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    return List.unmodifiable(list);
  }

  Recording? byId(String id) => _records[id];

  bool containsRemote(String remoteFileId) =>
      _records.values.any((r) => r.remoteFileId == remoteFileId);

  Future<void> upsert(Recording recording) async {
    _records[recording.id] = recording;
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    _records.remove(id);
    notifyListeners();
    await _persist();
  }

  Future<void> replaceAll(List<Recording> recordings) async {
    _records
      ..clear()
      ..addEntries(recordings.map((r) => MapEntry(r.id, r)));
    notifyListeners();
    await _persist();
  }

  void _load() {
    final raw = _storage.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final recording = Recording.fromJson(item);
        if (recording.id.isNotEmpty) _records[recording.id] = recording;
      }
    } catch (_) {
      // 损坏数据回落空仓库，不阻塞启动
      _records.clear();
    }
  }

  Future<void> _persist() => _storage.setString(
        storageKey,
        jsonEncode([for (final r in _records.values) r.toJson()]),
      );
}
