/// 健康与位置样本的本地 SQLite。
///
/// App 其余数据仍走 JsonStore / shared_preferences。这张库只给后续本机分析查询，
/// 不上传。测试可注入 [DatabaseFactory] 和路径，避免碰平台通道。
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'health_signal_models.dart';

class HealthSignalStore {
  HealthSignalStore({DatabaseFactory? factory, Future<String> Function()? path})
    : _factory = factory ?? databaseFactory,
      _path = path;

  final DatabaseFactory _factory;
  final Future<String> Function()? _path;

  Database? _db;
  Future<Database>? _opening;

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
      final path = await _resolvePath();
      final db = await _factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
CREATE TABLE health_samples (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  value_num REAL,
  value_text TEXT,
  unit TEXT,
  source_name TEXT,
  source_bundle TEXT,
  recording_id TEXT,
  aggregation TEXT,
  metadata_json TEXT,
  ingested_at_ms INTEGER NOT NULL
)''');
            await db.execute(
              'CREATE INDEX idx_health_start ON health_samples(start_ms)',
            );
            await db.execute(
              'CREATE INDEX idx_health_type_start ON health_samples(type, start_ms)',
            );
            await db.execute(
              'CREATE INDEX idx_health_recording ON health_samples(recording_id)',
            );
            await db.execute(
              'CREATE INDEX idx_health_source_name ON health_samples(source_name)',
            );
            await db.execute(
              'CREATE INDEX idx_health_source_bundle ON health_samples(source_bundle)',
            );
            await db.execute('''
CREATE TABLE health_sync_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
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
    return p.join(dir, 'health_signals.db');
  }

  Future<void> upsertAll(List<HealthSignalSample> samples) async {
    if (samples.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final sample in samples) {
        batch.insert(
          'health_samples',
          sample.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<HealthSignalSample>> query(HealthSignalQuery query) async {
    final db = await _open();
    final clause = _where(query);
    final rows = await db.query(
      'health_samples',
      where: clause.where,
      whereArgs: clause.args,
      orderBy: 'start_ms ${query.ascending ? 'ASC' : 'DESC'}, id ASC',
      limit: query.limit < 0 ? null : query.limit,
      offset: query.offset < 0 ? null : query.offset,
    );
    return [for (final row in rows) HealthSignalSample.fromRow(row)];
  }

  Future<int> count(HealthSignalQuery query) async {
    final db = await _open();
    final clause = _where(query);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM health_samples'
      '${clause.where == null ? '' : ' WHERE ${clause.where}'}',
      clause.args,
    );
    final value = rows.first['n'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  /// 按当前录音区间重写 [fromMs, toMs) 内样本的 recording_id。
  ///
  /// 不在任何录音里的样本会清空关联，避免录音删除后还挂着旧 id。
  Future<int> relink(
    List<RecordingSpan> spans, {
    int? fromMs,
    int? toMs,
  }) async {
    final db = await _open();
    final where = <String>[];
    final args = <Object?>[];
    if (fromMs != null) {
      where.add('end_ms >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.add('start_ms < ?');
      args.add(toMs);
    }
    var changed = 0;
    var offset = 0;
    const page = 500;
    while (true) {
      final rows = await db.query(
        'health_samples',
        columns: ['id', 'start_ms', 'end_ms', 'recording_id'],
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'id ASC',
        limit: page,
        offset: offset,
      );
      if (rows.isEmpty) break;
      final updates = <({Object? id, String? next})>[];
      for (final row in rows) {
        final start = _asInt(row['start_ms']);
        final end = _asInt(row['end_ms']);
        final next = linkRecordingId(start, end, spans);
        final current = row['recording_id'] as String?;
        if (next == current) continue;
        updates.add((id: row['id'], next: next));
      }
      if (updates.isNotEmpty) {
        changed += updates.length;
        await db.transaction((txn) async {
          final batch = txn.batch();
          for (final item in updates) {
            batch.update(
              'health_samples',
              {'recording_id': item.next},
              where: 'id = ?',
              whereArgs: [item.id],
            );
          }
          await batch.commit(noResult: true);
        });
      }
      if (rows.length < page) break;
      offset += rows.length;
    }
    return changed;
  }

  Future<Map<String, int>> readCursors() async {
    final db = await _open();
    final rows = await db.query(
      'health_sync_state',
      where: 'key LIKE ?',
      whereArgs: ['cursor:%'],
    );
    final out = <String, int>{};
    for (final row in rows) {
      final key = '${row['key'] ?? ''}';
      if (!key.startsWith('cursor:')) continue;
      out[key.substring('cursor:'.length)] =
          int.tryParse('${row['value']}') ?? 0;
    }
    return out;
  }

  Future<void> writeCursors(Map<String, int> cursors) async {
    if (cursors.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in cursors.entries) {
        batch.insert('health_sync_state', {
          'key': 'cursor:${entry.key}',
          'value': '${entry.value}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<bool> flag(String key) async {
    final db = await _open();
    final rows = await db.query(
      'health_sync_state',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['value'] == '1';
  }

  Future<void> setFlag(String key, bool value) async {
    final db = await _open();
    await db.insert('health_sync_state', {
      'key': key,
      'value': value ? '1' : '0',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearAll() async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete('health_samples');
      await txn.delete('health_sync_state');
    });
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    if (db != null) await db.close();
  }

  _Where _where(HealthSignalQuery query) {
    final where = <String>[];
    final args = <Object?>[];
    final type = query.type?.trim();
    final source = query.source?.trim();
    if (query.startMs != null) {
      where.add('end_ms >= ?');
      args.add(query.startMs);
    }
    if (query.endMs != null) {
      where.add('start_ms < ?');
      args.add(query.endMs);
    }
    if (type != null && type.isNotEmpty) {
      where.add('type = ?');
      args.add(type);
    }
    if (source != null && source.isNotEmpty) {
      where.add('(source_name = ? OR source_bundle = ?)');
      args
        ..add(source)
        ..add(source);
    }
    if (query.recordingId != null) {
      where.add('recording_id = ?');
      args.add(query.recordingId);
    }
    return _Where(
      where.isEmpty ? null : where.join(' AND '),
      args.isEmpty ? null : args,
    );
  }
}

class _Where {
  const _Where(this.where, this.args);
  final String? where;
  final List<Object?>? args;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}
