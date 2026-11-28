/// 总结断点检查点持久化 —— 用于离开应用前缓存进度/已生成内容，回前台或冷重启后继续。
library;

import '../../core/storage/storage.dart';

class SummaryCheckpoint {
  const SummaryCheckpoint({
    required this.summaryId,
    required this.srcIds,
    required this.completedBatchDigests,
    required this.totalBatches,
    required this.streamedText,
    required this.progress,
    required this.step,
    required this.engineRoute,
    required this.pausedAtMs,
    this.pausedReason = 'background',
  });

  final String summaryId;
  final List<String> srcIds;
  final List<String> completedBatchDigests;
  final int totalBatches;
  final String streamedText;
  final double progress;
  final String step;
  final String engineRoute;
  final int pausedAtMs;
  final String pausedReason;

  SummaryCheckpoint copyWith({
    List<String>? completedBatchDigests,
    int? totalBatches,
    String? streamedText,
    double? progress,
    String? step,
    String? engineRoute,
    int? pausedAtMs,
    String? pausedReason,
  }) => SummaryCheckpoint(
    summaryId: summaryId,
    srcIds: srcIds,
    completedBatchDigests:
        completedBatchDigests ?? this.completedBatchDigests,
    totalBatches: totalBatches ?? this.totalBatches,
    streamedText: streamedText ?? this.streamedText,
    progress: progress ?? this.progress,
    step: step ?? this.step,
    engineRoute: engineRoute ?? this.engineRoute,
    pausedAtMs: pausedAtMs ?? this.pausedAtMs,
    pausedReason: pausedReason ?? this.pausedReason,
  );

  Map<String, dynamic> toJson() => {
    'summaryId': summaryId,
    'srcIds': srcIds,
    'completedBatchDigests': completedBatchDigests,
    'totalBatches': totalBatches,
    'streamedText': streamedText,
    'progress': progress,
    'step': step,
    'engineRoute': engineRoute,
    'pausedAtMs': pausedAtMs,
    'pausedReason': pausedReason,
  };

  factory SummaryCheckpoint.fromJson(Map<String, dynamic> j) =>
      SummaryCheckpoint(
        summaryId: '${j['summaryId'] ?? ''}',
        srcIds: [
          for (final id in (j['srcIds'] as List? ?? const [])) '$id',
        ],
        completedBatchDigests: [
          for (final d in (j['completedBatchDigests'] as List? ?? const []))
            '$d',
        ],
        totalBatches: (j['totalBatches'] as num?)?.toInt() ?? 0,
        streamedText: '${j['streamedText'] ?? ''}',
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        step: '${j['step'] ?? ''}',
        engineRoute: '${j['engineRoute'] ?? 'cloud'}',
        pausedAtMs: (j['pausedAtMs'] as num?)?.toInt() ?? 0,
        pausedReason: '${j['pausedReason'] ?? 'background'}',
      );
}

class SummaryCheckpointStore {
  SummaryCheckpointStore({JsonStore? jsonStore}) : _json = jsonStore;

  static const String storeKey = 'summary_checkpoints_v1';
  JsonStore? _json;
  Future<void> _serial = Future<void>.value();

  Future<JsonStore> _store() async {
    final existing = _json;
    if (existing != null) return existing;
    final created = JsonStore(store: await PrefsStore.open());
    _json = created;
    return created;
  }

  Future<Map<String, SummaryCheckpoint>> loadAll() async {
    final store = await _store();
    final raw = await store.read(storeKey);
    if (raw == null) return const {};
    final items = raw['items'];
    if (items is! Map) return const {};
    final out = <String, SummaryCheckpoint>{};
    for (final entry in items.entries) {
      if (entry.value is Map) {
        final cp = SummaryCheckpoint.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (cp.summaryId.isNotEmpty) {
          out[cp.summaryId] = cp;
        }
      }
    }
    return out;
  }

  Future<SummaryCheckpoint?> load(String summaryId) async {
    final all = await loadAll();
    return all[summaryId];
  }

  Future<void> save(SummaryCheckpoint checkpoint) {
    final next = _serial.then((_) async {
      final store = await _store();
      final all = Map<String, SummaryCheckpoint>.from(await loadAll());
      all[checkpoint.summaryId] = checkpoint;
      await store.write(storeKey, {
        'items': {
          for (final entry in all.entries) entry.key: entry.value.toJson(),
        },
      });
    });
    _serial = next.catchError((Object _) {});
    return next;
  }

  Future<void> remove(String summaryId) {
    final next = _serial.then((_) async {
      final store = await _store();
      final all = Map<String, SummaryCheckpoint>.from(await loadAll());
      if (all.remove(summaryId) == null) return;
      await store.write(storeKey, {
        'items': {
          for (final entry in all.entries) entry.key: entry.value.toJson(),
        },
      });
    });
    _serial = next.catchError((Object _) {});
    return next;
  }

  Future<void> clearAll() {
    final next = _serial.then((_) async {
      final store = await _store();
      await store.remove(storeKey);
    });
    _serial = next.catchError((Object _) {});
    return next;
  }
}
