/// 音频切片仓库 —— 元数据索引持久化到 KvStore，音频本体交给 [AudioBlobStore]。
///
/// 设计要点：
/// - KV 里只放元数据 + 长度 + 内容 hash，避免大音频撑爆 SharedPreferences；
/// - 音频本体由可替换的 blob store 保存（生产可换文件 / SQLite / 加密目录）；
/// - 去重同时看 id 与 sessionId+seq，防止录音卡重传造成重复切片。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/storage/kv_store.dart';
import 'audio_slice.dart';

/// 音频本体存储接缝。写入按 [sliceId] 幂等，覆盖即替换。
abstract class AudioBlobStore {
  Future<void> write(String sliceId, Uint8List bytes);

  Future<Uint8List?> read(String sliceId);

  Future<void> delete(String sliceId);
}

/// 测试 / 开发期实现：进程内 Map，读写都做拷贝，避免外部缓冲串改。
class MemoryAudioBlobStore implements AudioBlobStore {
  final Map<String, Uint8List> _data = {};

  @override
  Future<void> write(String sliceId, Uint8List bytes) async {
    _data[sliceId] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> read(String sliceId) async {
    final stored = _data[sliceId];
    return stored == null ? null : Uint8List.fromList(stored);
  }

  @override
  Future<void> delete(String sliceId) async {
    _data.remove(sliceId);
  }
}

class AudioSliceRepository {
  AudioSliceRepository({
    required KvStore index,
    required AudioBlobStore blobs,
  })  : _index = index,
        _blobs = blobs {
    _load();
  }

  static const storageKey = 'rc-audio-slices-v1';

  final KvStore _index;
  final AudioBlobStore _blobs;
  final Map<String, _IndexedSlice> _entries = {};
  final Set<(String, int)> _sessionSeq = {};

  /// 全部切片，按 [AudioSlice.startMs] 升序（同起点按 seq / id 稳定排序）。
  List<AudioSlice> all() {
    final list = [for (final entry in _entries.values) entry.slice]
      ..sort(_compare);
    return List.unmodifiable(list);
  }

  /// 增量拉取游标：当前最后一条切片的 id；空仓库为 null。
  String? get cursor {
    final list = all();
    return list.isEmpty ? null : list.last.id;
  }

  /// 写入切片：先落 blob 再写索引；重复（id 或 sessionId+seq）返回 false。
  Future<bool> add(AudioSlice slice) async {
    if (slice.id.isEmpty) return false;
    final sessionSeq = (slice.sessionId, slice.seq);
    if (_entries.containsKey(slice.id) || _sessionSeq.contains(sessionSeq)) {
      return false;
    }
    await _blobs.write(slice.id, slice.bytes);
    _entries[slice.id] = _IndexedSlice(
      slice: slice,
      byteLength: slice.bytes.length,
      hash: sha256.convert(slice.bytes).toString(),
    );
    _sessionSeq.add(sessionSeq);
    await _persist();
    return true;
  }

  /// 清空索引与全部音频本体，供「删除全部录音」/ 测试隔离使用。
  Future<void> clear() async {
    final ids = _entries.keys.toList(growable: false);
    _entries.clear();
    _sessionSeq.clear();
    for (final id in ids) {
      await _blobs.delete(id);
    }
    await _index.remove(storageKey);
  }

  void _load() {
    final raw = _index.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final slice = AudioSlice.fromJson(item);
        if (slice.id.isEmpty || _entries.containsKey(slice.id)) continue;
        final rawLength = item['byteLength'];
        final rawHash = item['hash'];
        _entries[slice.id] = _IndexedSlice(
          slice: slice,
          byteLength:
              rawLength is num ? rawLength.toInt() : slice.bytes.length,
          hash: rawHash is String ? rawHash : '',
        );
        _sessionSeq.add((slice.sessionId, slice.seq));
      }
    } catch (_) {
      // 损坏索引回落空仓库，不阻塞启动
      _entries.clear();
      _sessionSeq.clear();
    }
  }

  Future<void> _persist() {
    final ordered = all();
    return _index.setString(
      storageKey,
      jsonEncode([
        for (final slice in ordered) _entries[slice.id]!.toJson(),
      ]),
    );
  }

  static int _compare(AudioSlice a, AudioSlice b) {
    final byStart = a.startMs.compareTo(b.startMs);
    if (byStart != 0) return byStart;
    final bySeq = a.seq.compareTo(b.seq);
    if (bySeq != 0) return bySeq;
    return a.id.compareTo(b.id);
  }
}

/// 索引条目：切片元数据 + 仅索引需要的长度 / hash。
///
/// 恢复后的 [slice] 不含音频字节，长度与 hash 仍从索引原样保留。
class _IndexedSlice {
  const _IndexedSlice({
    required this.slice,
    required this.byteLength,
    required this.hash,
  });

  final AudioSlice slice;
  final int byteLength;
  final String hash;

  Map<String, dynamic> toJson() {
    final json = slice.toJson()..remove('bytes');
    json['byteLength'] = byteLength;
    json['hash'] = hash;
    return json;
  }
}
