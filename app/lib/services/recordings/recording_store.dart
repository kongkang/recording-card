/// 录音 v2 存储 —— 一条设备录音一份 `meta.json`（切片/原始句/润色/分段全在里面），
/// 音频文件放同目录；不再把所有记录塞进一个 shared_preferences 值。
///
/// 设计要点：
/// - **原子写**：先写 `meta.json.tmp` 再 rename，进程被杀不会留下半截 JSON；
/// - **坏数据不致命**：单条解析失败跳过，不影响其它录音；
/// - **v1 迁移**：旧清单（整文件一条 transcript）转成 `legacy` 分段，不丢内容；
/// - **音频可清理**：文本永久保留，音频按保留期删除（`pruneAudio`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../../core/models/recording.dart';
import '../../core/storage/storage.dart';
import 'recordings_manifest.dart';

class _CachedMeta {
  const _CachedMeta({
    required this.modified,
    required this.size,
    required this.startAtMs,
    required this.json,
  });

  final DateTime modified;
  final int size;
  final int startAtMs;
  final Map<String, dynamic> json;
}

class _PendingMeta {
  const _PendingMeta({
    required this.dirName,
    required this.entityDirPath,
    required this.metaPath,
    required this.modified,
    required this.size,
  });

  final String dirName;
  final String entityDirPath;
  final String metaPath;
  final DateTime modified;
  final int size;
}

class _ParsedMeta {
  const _ParsedMeta({required this.dirName, required this.cached});

  final String dirName;
  final _CachedMeta cached;
}

class RecordingStore {
  RecordingStore({Directory? root, JsonStore? jsonStore})
    : _rootOverride = root,
      _json = jsonStore;

  static const int _isolateParseThreshold = 24;

  final Directory? _rootOverride;
  JsonStore? _json;
  Directory? _resolvedRoot;
  Map<String, _CachedMeta>? _cacheByDir;
  List<_CachedMeta>? _sortedCache;
  int _mutationEpoch = 0;

  /// 清空内存索引缓存，降低后台常驻内存；下次读取按需从磁盘重载。
  void clearMemoryCache() {
    _cacheByDir = null;
    _sortedCache = null;
    _mutationEpoch++;
  }

  Future<Directory> root() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final base =
        _rootOverride ??
        Directory('${(await getApplicationSupportDirectory()).path}/recordings');
    if (!await base.exists()) await base.create(recursive: true);
    _resolvedRoot = base;
    return base;
  }

  Future<JsonStore> _store() async {
    final existing = _json;
    if (existing != null) return existing;
    final created = JsonStore(store: await PrefsStore.open());
    _json = created;
    return created;
  }

  /// 设备文件名 → 目录名（保留可读性，去掉路径分隔符等危险字符）。
  static String dirNameFor(String deviceName) {
    final cleaned = deviceName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'^\.+'), '_');
    return cleaned.isEmpty ? '_recording' : cleaned;
  }

  Future<Directory> dirFor(String deviceName) async {
    final base = await root();
    return Directory('${base.path}/${dirNameFor(deviceName)}');
  }

  Future<String> metaPath(String deviceName) async =>
      '${(await dirFor(deviceName)).path}/meta.json';

  static String _dirBasename(String path) {
    final slash = path.lastIndexOf('/');
    final bSlash = path.lastIndexOf('\\');
    final idx = slash > bSlash ? slash : bSlash;
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  /// 读取全部录音（按 startAtMs 倒序）。带按目录增量内存缓存；
  /// 每次返回独立实例副本，防止调用方就地改写字段破坏缓存或产生对象别名。
  Future<List<RecordingFile>> loadAll({bool refresh = false}) async {
    final sorted = _sortedCache;
    if (!refresh && sorted != null) {
      return List.unmodifiable([
        for (final c in sorted) RecordingFile.fromJson(c.json),
      ]);
    }

    final epochAtStart = _mutationEpoch;
    final base = await root();
    final appSupportPath = _inferAppSupportPath(base.path);
    final prevByDir = _cacheByDir;
    final nextByDir = <String, _CachedMeta>{};
    final pending = <_PendingMeta>[];

    await for (final entity in base.list()) {
      if (entity is! Directory) continue;
      final dirName = _dirBasename(entity.path);
      final metaPath = '${entity.path}/meta.json';
      final stat = await File(metaPath).stat();
      if (stat.type != FileSystemEntityType.file) continue;
      final cached = prevByDir?[dirName];
      if (cached != null &&
          cached.modified == stat.modified &&
          cached.size == stat.size) {
        nextByDir[dirName] = cached;
        continue;
      }
      pending.add(
        _PendingMeta(
          dirName: dirName,
          entityDirPath: entity.path,
          metaPath: metaPath,
          modified: stat.modified,
          size: stat.size,
        ),
      );
    }

    if (pending.isNotEmpty) {
      final parsed = pending.length >= _isolateParseThreshold
          ? await Isolate.run(() => _parseMetaBatchSync(pending, appSupportPath))
          : await _parseMetaBatchAsync(pending, appSupportPath);
      for (final entry in parsed) {
        nextByDir[entry.dirName] = entry.cached;
      }
    }

    final sortedMetas = nextByDir.values.toList()
      ..sort((a, b) => b.startAtMs.compareTo(a.startAtMs));
    if (_mutationEpoch == epochAtStart) {
      _cacheByDir = nextByDir;
      _sortedCache = sortedMetas;
    }
    return List.unmodifiable([
      for (final c in sortedMetas) RecordingFile.fromJson(c.json),
    ]);
  }

  /// iOS 每次覆盖安装/升级 App 都会轮换沙盒容器 UUID
  /// （`/var/mobile/Containers/Data/Application/<UUID>/Library/Application Support/...`）。
  /// `meta.json` 里若存了旧容器的绝对路径，读取时统一迁回当前容器目录，避免把已有音频误判为丢失。
  static String rebaseAppSupportPath(
    String rawPath, {
    String? appSupportPath,
    String? entityDirPath,
  }) {
    if (rawPath.isEmpty) return rawPath;
    const marker = '/Library/Application Support/';
    if (appSupportPath != null && appSupportPath.isNotEmpty) {
      final idx = rawPath.indexOf(marker);
      if (idx >= 0) {
        final rel = rawPath.substring(idx + marker.length);
        return '$appSupportPath/$rel';
      }
    }
    if (entityDirPath != null && !File(rawPath).existsSync()) {
      final slash = rawPath.lastIndexOf('/');
      final baseName = slash >= 0 ? rawPath.substring(slash + 1) : rawPath;
      if (baseName.isNotEmpty) {
        final candidate = '$entityDirPath/$baseName';
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return rawPath;
  }

  static String? _inferAppSupportPath(String recordingsRootPath) {
    const suffix = '/recordings';
    if (recordingsRootPath.endsWith(suffix)) {
      return recordingsRootPath.substring(
        0,
        recordingsRootPath.length - suffix.length,
      );
    }
    const marker = '/Library/Application Support';
    final idx = recordingsRootPath.indexOf(marker);
    if (idx >= 0) {
      return recordingsRootPath.substring(0, idx + marker.length);
    }
    return null;
  }

  static void _rebaseRecordingPaths(
    RecordingFile file, {
    required String entityDirPath,
    required String? appSupportPath,
  }) {
    file.apmPath = rebaseAppSupportPath(
      file.apmPath,
      appSupportPath: appSupportPath,
      entityDirPath: entityDirPath,
    );
    if (file.wavPath != null && file.wavPath!.isNotEmpty) {
      file.wavPath = rebaseAppSupportPath(
        file.wavPath!,
        appSupportPath: appSupportPath,
        entityDirPath: entityDirPath,
      );
    }
    if (file.slices.isNotEmpty) {
      final sliceDir = '$entityDirPath/slices';
      file.slices = [
        for (final s in file.slices)
          AudioSlice(
            id: s.id,
            index: s.index,
            startMs: s.startMs,
            endMs: s.endMs,
            wavPath: rebaseAppSupportPath(
              s.wavPath,
              appSupportPath: appSupportPath,
              entityDirPath: sliceDir,
            ),
            silenceAfterMs: s.silenceAfterMs,
            stage: s.stage,
            error: s.error,
          ),
      ];
    }
  }

  /// 清理既无本地音频/转写内容、又不在当前录音卡文件列表里的历史残骸（如半截中断且卡上已删的空壳）。
  Future<int> pruneMissingGhosts(Set<String> deviceFileNames) async {
    final all = await loadAll(refresh: true);
    var removed = 0;
    for (final file in all) {
      if (file.stage == RecordingStage.ready) continue;
      if (deviceFileNames.contains(file.deviceName)) continue;
      if (file.utterances.isNotEmpty ||
          file.turns.isNotEmpty ||
          file.segments.isNotEmpty) {
        continue;
      }
      final hasApm =
          file.apmPath.isNotEmpty && await File(file.apmPath).exists();
      final hasWav = file.wavPath != null &&
          file.wavPath!.isNotEmpty &&
          await File(file.wavPath!).exists();
      if (hasApm || hasWav) continue;
      await remove(file.deviceName);
      removed++;
    }
    return removed;
  }

  Future<RecordingFile?> load(String deviceName) async {
    final cachedByDir = _cacheByDir;
    if (cachedByDir != null && _sortedCache != null) {
      final hit = cachedByDir[dirNameFor(deviceName)];
      return hit == null ? null : RecordingFile.fromJson(hit.json);
    }
    final all = await loadAll();
    for (final file in all) {
      if (file.deviceName == deviceName) return file;
    }
    return null;
  }

  Future<void> save(RecordingFile file) async {
    final dir = await dirFor(file.deviceName);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}/meta.json');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(file.toJson()), flush: true);
    await tmp.rename(target.path);
    _mutationEpoch++;
    _cacheByDir?.remove(dirNameFor(file.deviceName));
    _sortedCache = null;
  }

  Future<void> remove(String deviceName) async {
    final dir = await dirFor(deviceName);
    if (await dir.exists()) await dir.delete(recursive: true);
    _mutationEpoch++;
    _cacheByDir?.remove(dirNameFor(deviceName));
    _sortedCache = null;
  }

  /// 删除过期音频文件（WAV/APM），保留 meta 与文本。
  ///
  /// 返回删除的字节数；[keep] 之前的录音才会被清理。
  Future<int> pruneAudio({Duration keep = const Duration(days: 7)}) async {
    final cutoff = DateTime.now().subtract(keep).millisecondsSinceEpoch;
    var freed = 0;
    final all = await loadAll(refresh: true);
    for (final file in all) {
      if (file.startAtMs > cutoff) continue;
      if (file.stage != RecordingStage.ready) continue; // 未处理完的不动
      final paths = <String>[
        if (file.wavPath != null) file.wavPath!,
        for (final slice in file.slices) slice.wavPath,
        file.apmPath,
      ];
      for (final path in paths) {
        final f = File(path);
        if (!await f.exists()) continue;
        try {
          freed += await f.length();
          await f.delete();
        } on FileSystemException {
          // 文件被占用：下次再清
        }
      }
    }
    return freed;
  }

  // ── v1 → v2 迁移 ────────────────────────────────────────
  /// 旧清单里的整文件 transcript → 一个 `legacy` 分段。
  ///
  /// 只迁移还没有 v2 meta 的文件；可重复调用（幂等）。
  Future<int> migrateFromV1(RecordingsManifest manifest) async {
    final json = await _store();
    final flag = await json.read('migration');
    if (flag?['v1_to_v2'] == true) return 0;

    final items = await manifest.load();
    var migrated = 0;
    for (final item in items) {
      final existing = await load(item.deviceName);
      if (existing != null) continue;
      final startAtMs = item.recordedAt.millisecondsSinceEpoch;
      final durationMs = (item.durationSecs * 1000).round();
      final text = item.transcript.trim();
      final segments = <SegmentRecord>[];
      if (text.isNotEmpty) {
        segments.add(
          SegmentRecord(
            id: 'legacy-${RecordingStore.dirNameFor(item.deviceName)}',
            sessionId: item.deviceName,
            index: 0,
            startAtMs: startAtMs,
            endAtMs: startAtMs + durationMs,
            title: _legacyTitle(text),
            brief: _legacyBrief(text),
            longText: text,
            status: SegmentStatus.closed,
            legacy: true,
            turnIds: const ['legacy-turn-0'],
          ),
        );
      }
      final turns = text.isEmpty
          ? const <PolishedTurn>[]
          : <PolishedTurn>[
              PolishedTurn(
                id: 'legacy-turn-0',
                startMs: 0,
                endMs: durationMs <= 0 ? 1000 : durationMs,
                speakerLabel: '未区分',
                text: text,
                srcUtteranceIds: const ['legacy-raw-0'],
              ),
            ];
      final raws = text.isEmpty
          ? const <RawUtterance>[]
          : <RawUtterance>[
              RawUtterance(
                id: 'legacy-raw-0',
                sliceId: 'legacy-slice-0',
                startMs: 0,
                endMs: durationMs <= 0 ? 1000 : durationMs,
                text: text,
              ),
            ];
      await save(
        RecordingFile(
          deviceName: item.deviceName,
          session: item.deviceName,
          seq: 1,
          startAtMs: startAtMs,
          apmPath: item.apmPath,
          wavPath: item.wavPath,
          durationMs: durationMs,
          stage: text.isEmpty
              ? RecordingStage.transcoding
              : RecordingStage.ready,
          turns: turns,
          utterances: raws,
          segments: segments,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      migrated++;
    }
    await json.write('migration', {'v1_to_v2': true, 'at': DateTime.now().toIso8601String()});
    return migrated;
  }

  static String _legacyTitle(String text) {
    final first = text.split(RegExp(r'[\n。！？!?]')).first.trim();
    if (first.isEmpty) return '旧版记录';
    return first.length <= 18 ? first : '${first.substring(0, 18)}…';
  }

  static String _legacyBrief(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '尚未转写';
    return flat.length <= 48 ? flat : '${flat.substring(0, 48)}…';
  }
}

_ParsedMeta? _decodeMetaFile(
  String rawJson,
  _PendingMeta item,
  String? appSupportPath,
) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return null;
    final file = RecordingFile.fromJson(decoded);
    if (file.deviceName.isEmpty) return null;
    RecordingStore._rebaseRecordingPaths(
      file,
      entityDirPath: item.entityDirPath,
      appSupportPath: appSupportPath,
    );
    return _ParsedMeta(
      dirName: item.dirName,
      cached: _CachedMeta(
        modified: item.modified,
        size: item.size,
        startAtMs: file.startAtMs,
        json: file.toJson(),
      ),
    );
  } on Object {
    // 单条损坏：跳过，不影响其它录音
    return null;
  }
}

List<_ParsedMeta> _parseMetaBatchSync(
  List<_PendingMeta> pending,
  String? appSupportPath,
) {
  final out = <_ParsedMeta>[];
  for (final item in pending) {
    try {
      final parsed = _decodeMetaFile(
        File(item.metaPath).readAsStringSync(),
        item,
        appSupportPath,
      );
      if (parsed != null) out.add(parsed);
    } on Object {
      // 单条读取失败：跳过
    }
  }
  return out;
}

Future<List<_ParsedMeta>> _parseMetaBatchAsync(
  List<_PendingMeta> pending,
  String? appSupportPath,
) async {
  final out = <_ParsedMeta>[];
  for (final item in pending) {
    try {
      final parsed = _decodeMetaFile(
        await File(item.metaPath).readAsString(),
        item,
        appSupportPath,
      );
      if (parsed != null) out.add(parsed);
    } on Object {
      // 单条读取失败：跳过
    }
  }
  return out;
}
