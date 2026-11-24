/// 本机 SQLite FTS5 记忆索引（v2：content_hash 脏哈希增量同步，零全表清空开销）。
///
/// 测试可注入 [DatabaseFactory] 和路径。真机落在应用数据库目录，不上传。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'memory_chunk.dart';
import 'memory_query.dart';

class LocalMemoryIndex {
  LocalMemoryIndex({DatabaseFactory? factory, Future<String> Function()? path})
    : _factory = factory ?? databaseFactory,
      _path = path;

  final DatabaseFactory _factory;
  final Future<String> Function()? _path;

  Database? _db;
  Future<Database>? _opening;

  String? _lastCorpusDigest;
  Map<String, String>? _knownHashes;

  /// 供测试观测实际写库事务次数与增删行数。
  int debugSyncTransactions = 0;
  int debugInsertedRows = 0;
  int debugDeletedRows = 0;

  Future<void> replaceAll(List<MemoryChunk> chunks) async {
    final db = await _open();

    // 去重：若传入相同 chunk_id，以最后一条为准
    final byId = <String, MemoryChunk>{
      for (final chunk in chunks) chunk.id: chunk,
    };
    final incomingHashes = <String, String>{};
    final digestBuf = StringBuffer('${byId.length}|');
    for (final entry in byId.entries) {
      final h = _hashChunk(entry.value);
      incomingHashes[entry.key] = h;
      digestBuf
        ..write(entry.key)
        ..write(':')
        ..write(h)
        ..write(';');
    }
    final corpusDigest = sha1
        .convert(utf8.encode(digestBuf.toString()))
        .toString();

    if (_knownHashes != null && corpusDigest == _lastCorpusDigest) {
      return;
    }

    final known = await _loadKnownHashes(db);
    final staleIds = <String>[];
    for (final existingId in known.keys) {
      final nextHash = incomingHashes[existingId];
      final prevHash = known[existingId];
      if (nextHash == null || prevHash == null || prevHash.isEmpty || nextHash != prevHash) {
        staleIds.add(existingId);
      }
    }

    final toInsert = <MemoryChunk>[];
    for (final entry in byId.entries) {
      final id = entry.key;
      final nextHash = incomingHashes[id]!;
      final prevHash = known[id];
      if (prevHash == null || prevHash.isEmpty || prevHash != nextHash) {
        toInsert.add(entry.value);
      }
    }

    if (staleIds.isEmpty && toInsert.isEmpty) {
      _knownHashes = incomingHashes;
      _lastCorpusDigest = corpusDigest;
      return;
    }

    await db.transaction((txn) async {
      debugSyncTransactions += 1;
      const batchSize = 150;
      for (var i = 0; i < staleIds.length; i += batchSize) {
        final slice = staleIds.sublist(
          i,
          math.min(staleIds.length, i + batchSize),
        );
        final placeholders = List.filled(slice.length, '?').join(', ');
        final deleted = await txn.rawDelete(
          'DELETE FROM memory_fts WHERE chunk_id IN ($placeholders)',
          slice,
        );
        debugDeletedRows += deleted;
      }

      for (final chunk in toInsert) {
        await txn.insert('memory_fts', {
          'chunk_id': chunk.id,
          'kind': chunk.kind,
          'source_id': chunk.sourceId,
          'day_offset': '${chunk.dayOffset}',
          'time_label': chunk.timeLabel,
          'title': chunk.title,
          'body': chunk.body,
          'search_text': indexedText('${chunk.title}\n${chunk.body}'),
          'content_hash': incomingHashes[chunk.id]!,
        });
        debugInsertedRows += 1;
      }
    });

    _knownHashes = incomingHashes;
    _lastCorpusDigest = corpusDigest;
  }

  Future<Map<String, String>> _loadKnownHashes(Database db) async {
    final cached = _knownHashes;
    if (cached != null) return cached;

    final rows = await db.rawQuery(
      'SELECT chunk_id, content_hash FROM memory_fts',
    );
    final loaded = <String, String>{};
    for (final row in rows) {
      final id = '${row['chunk_id'] ?? ''}';
      if (id.isEmpty) continue;
      final hash = '${row['content_hash'] ?? ''}';
      if (loaded.containsKey(id)) {
        // 若发现重复 chunk_id，置空强制走增量清理重建该键
        loaded[id] = '';
      } else {
        loaded[id] = hash;
      }
    }
    _knownHashes = loaded;
    return loaded;
  }

  static String _hashChunk(MemoryChunk chunk) {
    final payload =
        '${chunk.id}\x00${chunk.kind}\x00${chunk.sourceId}\x00'
        '${chunk.dayOffset}\x00${chunk.timeLabel}\x00'
        '${chunk.title}\x00${chunk.body}';
    return sha1.convert(utf8.encode(payload)).toString();
  }

  Future<List<MemoryHit>> search({
    String? match,
    int? minDay,
    int? maxDay,
    MemoryHourRange? hourRange,
    String? queryHint,
    int limit = 8,
  }) async {
    final hasMatch = match != null && match.trim().isNotEmpty;
    if (!hasMatch && minDay == null && maxDay == null && hourRange == null) {
      return const [];
    }
    final db = await _open();
    try {
      final where = <String>[];
      final args = <Object?>[];
      if (hasMatch) {
        where.add('memory_fts MATCH ?');
        args.add(match);
      }
      if (minDay != null) {
        where.add('CAST(day_offset AS INTEGER) >= ?');
        args.add(minDay);
      }
      if (maxDay != null) {
        where.add('CAST(day_offset AS INTEGER) <= ?');
        args.add(maxDay);
      }

      // 若带时段过滤或无关键词时间浏览，多取候选在 Dart 层做精确分钟过滤与时钟排序
      final sqlLimit = hourRange != null
          ? math.max(limit * 12, 96)
          : math.max(limit, 1);
      final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
      args.add(sqlLimit);

      final rows = await db.rawQuery('''
SELECT chunk_id, kind, source_id, day_offset, time_label, title, body,
       snippet(memory_fts, 6, '', '', '…', 24) AS snip
FROM memory_fts
$whereClause
ORDER BY ${!hasMatch ? 'CAST(day_offset AS INTEGER) ASC, time_label ASC' : 'bm25(memory_fts)'}
LIMIT ?
''', args);

      var hits = <MemoryHit>[
        for (final row in rows) _hit(row, queryHint: queryHint),
      ];
      if (hourRange != null) {
        hits = [
          for (final h in hits)
            if (hourRange.matchesTimeLabel(h.timeLabel)) h,
        ];
      }
      if (!hasMatch) {
        hits.sort((a, b) {
          final dayCmp = a.dayOffset.compareTo(b.dayOffset);
          if (dayCmp != 0) return dayCmp;
          final ma = parseClockMinutes(a.timeLabel) ?? 0;
          final mb = parseClockMinutes(b.timeLabel) ?? 0;
          return ma.compareTo(mb);
        });
      }
      if (hits.length > limit) {
        return hits.sublist(0, limit);
      }
      return hits;
    } on DatabaseException {
      return const [];
    }
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    _lastCorpusDigest = null;
    _knownHashes = null;
    if (db != null) await db.close();
  }

  MemoryHit _hit(Map<String, Object?> row, {String? queryHint}) {
    final body = '${row['body'] ?? ''}';
    final ftsSnip = '${row['snip'] ?? ''}'.trim();
    final centered = _centeredSnippet(body, queryHint, fallback: ftsSnip);
    return MemoryHit(
      chunkId: '${row['chunk_id'] ?? ''}',
      kind: '${row['kind'] ?? ''}',
      sourceId: '${row['source_id'] ?? ''}',
      title: '${row['title'] ?? ''}',
      body: body,
      snippet: centered,
      dayOffset: int.tryParse('${row['day_offset'] ?? ''}') ?? 0,
      timeLabel: '${row['time_label'] ?? ''}',
    );
  }

  String _centeredSnippet(String body, String? queryHint, {required String fallback}) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return fallback;
    final hint = (queryHint ?? '').trim();
    if (hint.isNotEmpty) {
      final lowerBody = compact.toLowerCase();
      final lowerHint = hint.toLowerCase();
      var idx = lowerBody.indexOf(lowerHint);
      if (idx < 0) {
        for (final r in hint.runes) {
          if (isCjkRune(r) && !isCjkStopUnigramRune(r)) {
            idx = lowerBody.indexOf(String.fromCharCode(r));
            if (idx >= 0) break;
          }
        }
      }
      if (idx >= 0) {
        if (compact.length <= 72) return compact;
        final start = math.max(0, idx - 20);
        final end = math.min(compact.length, start + 72);
        final prefix = start > 0 ? '…' : '';
        final suffix = end < compact.length ? '…' : '';
        return '$prefix${compact.substring(start, end)}$suffix';
      }
    }
    if (fallback.isNotEmpty) return fallback;
    if (compact.length <= 48) return compact;
    return '${compact.substring(0, 48)}…';
  }

  Future<Database> _open() {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    final pending = _opening;
    if (pending != null) return pending;
    final next = _openNew();
    _opening = next;
    return next;
  }

  static Future<void> _createFtsTable(Database db) async {
    await db.execute('''
CREATE VIRTUAL TABLE memory_fts USING fts5(
  chunk_id UNINDEXED,
  kind UNINDEXED,
  source_id UNINDEXED,
  day_offset UNINDEXED,
  time_label UNINDEXED,
  title,
  body,
  search_text,
  content_hash UNINDEXED,
  tokenize = 'unicode61'
)''');
  }

  Future<Database> _openNew() async {
    try {
      final db = await _factory.openDatabase(
        await _resolvePath(),
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await _createFtsTable(db);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            await db.execute('DROP TABLE IF EXISTS memory_fts');
            await _createFtsTable(db);
          },
        ),
      );
      _db = db;
      return db;
    } on Object {
      _opening = null;
      rethrow;
    }
  }

  Future<String> _resolvePath() async {
    final custom = _path;
    if (custom != null) return custom();
    final dir = await getDatabasesPath();
    return p.join(dir, 'memory_index.db');
  }
}
