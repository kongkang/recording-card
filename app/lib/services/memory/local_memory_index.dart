/// 本机 SQLite FTS5 记忆索引。
///
/// 测试可注入 [DatabaseFactory] 和路径。真机落在应用数据库目录，不上传。
library;

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

  Future<void> replaceAll(List<MemoryChunk> chunks) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete('memory_fts');
      for (final chunk in chunks) {
        await txn.insert('memory_fts', {
          'chunk_id': chunk.id,
          'kind': chunk.kind,
          'source_id': chunk.sourceId,
          'day_offset': '${chunk.dayOffset}',
          'time_label': chunk.timeLabel,
          'title': chunk.title,
          'body': chunk.body,
          'search_text': indexedText('${chunk.title}\n${chunk.body}'),
        });
      }
    });
  }

  Future<List<MemoryHit>> search({
    String? match,
    int? minDay,
    int? maxDay,
    int limit = 8,
  }) async {
    if ((match == null || match.trim().isEmpty) &&
        minDay == null &&
        maxDay == null) {
      return const [];
    }
    final db = await _open();
    try {
      final where = <String>[];
      final args = <Object?>[];
      if (match != null && match.trim().isNotEmpty) {
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
      args.add(limit);
      final rows = await db.rawQuery('''
SELECT chunk_id, kind, source_id, day_offset, time_label, title, body,
       snippet(memory_fts, 6, '', '', '…', 24) AS snip
FROM memory_fts
WHERE ${where.join(' AND ')}
ORDER BY ${match == null ? 'CAST(day_offset AS INTEGER) ASC, time_label ASC' : 'bm25(memory_fts)'}
LIMIT ?
''', args);
      return [for (final row in rows) _hit(row)];
    } on DatabaseException {
      return const [];
    }
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    if (db != null) await db.close();
  }

  MemoryHit _hit(Map<String, Object?> row) {
    final body = '${row['body'] ?? ''}';
    final snippet = '${row['snip'] ?? ''}'.trim();
    return MemoryHit(
      chunkId: '${row['chunk_id'] ?? ''}',
      kind: '${row['kind'] ?? ''}',
      sourceId: '${row['source_id'] ?? ''}',
      title: '${row['title'] ?? ''}',
      body: body,
      snippet: snippet.isEmpty ? _preview(body) : snippet,
      dayOffset: int.tryParse('${row['day_offset'] ?? ''}') ?? 0,
      timeLabel: '${row['time_label'] ?? ''}',
    );
  }

  String _preview(String body) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
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

  Future<Database> _openNew() async {
    try {
      final db = await _factory.openDatabase(
        await _resolvePath(),
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
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
  tokenize = 'unicode61'
)''');
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
