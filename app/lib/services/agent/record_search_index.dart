/// 后台 Isolate 内的记录与总结极速检索引擎（中文 bigram + 英文词元 + 时间新近度）。
///
/// 零 Flutter 依赖，纯内存执行，万级片段可在数毫秒内完成排序返回。
library;

import 'dart:math' as math;

import 'agent_models.dart';

class RecordSearchHit {
  const RecordSearchHit({
    required this.doc,
    required this.score,
    required this.snippet,
  });

  final AgentDocument doc;
  final double score;
  final String snippet;
}

class RecordSearchIndex {
  List<AgentDocument> _docs = const [];
  final Map<String, AgentDocument> _byId = {};

  int get length => _docs.length;

  void replaceCorpus(List<AgentDocument> docs) {
    _docs = List<AgentDocument>.unmodifiable(docs);
    _byId
      ..clear()
      ..addEntries([for (final d in docs) MapEntry(d.id, d)]);
  }

  AgentDocument? getById(String id) => _byId[id];

  List<RecordSearchHit> search({
    String? query,
    String? speaker,
    int? dayOffset,
    String? kind,
    int limit = 6,
  }) {
    if (_docs.isEmpty) return const [];
    final q = (query ?? '').trim();
    final spkFilter = (speaker ?? '').trim().toLowerCase();
    final kindFilter = (kind ?? '').trim().toLowerCase();
    final tokens = tokenize(q);

    final filtered = <AgentDocument>[];
    for (final doc in _docs) {
      if (kindFilter.isNotEmpty && doc.kind.toLowerCase() != kindFilter) {
        continue;
      }
      if (dayOffset != null && doc.dayOffset != dayOffset) continue;
      if (spkFilter.isNotEmpty &&
          !doc.speakers.toLowerCase().contains(spkFilter) &&
          !doc.body.toLowerCase().contains(spkFilter)) {
        continue;
      }
      filtered.add(doc);
    }

    if (filtered.isEmpty) return const [];

    // 无关键词时按最新时间倒序返回最近记录，便于回答「今天聊了什么 / 最近待办」
    if (tokens.isEmpty) {
      final sorted = [...filtered]
        ..sort((a, b) {
          final dayCmp = a.dayOffset.compareTo(b.dayOffset);
          if (dayCmp != 0) return dayCmp;
          return b.timestampMs.compareTo(a.timestampMs);
        });
      return [
        for (final doc in sorted.take(limit))
          RecordSearchHit(
            doc: doc,
            score: 1.0,
            snippet: _buildSnippet(doc, tokens),
          ),
      ];
    }

    final hits = <RecordSearchHit>[];
    final qLower = q.toLowerCase();
    for (final doc in filtered) {
      final titleLower = doc.title.toLowerCase();
      final spkLower = doc.speakers.toLowerCase();
      final sumLower = doc.summary.toLowerCase();
      final todosLower = doc.todos.join(' ').toLowerCase();
      final bodyLower = doc.body.toLowerCase();

      var score = 0.0;
      if (titleLower.contains(qLower)) score += 8.0;
      if (sumLower.contains(qLower)) score += 5.0;
      if (todosLower.contains(qLower)) score += 5.0;
      if (bodyLower.contains(qLower)) score += 4.0;

      for (final tok in tokens) {
        final w = tok.length >= 2 ? 1.5 : 0.6;
        if (titleLower.contains(tok)) score += 3.2 * w;
        if (spkLower.contains(tok)) score += 2.6 * w;
        if (sumLower.contains(tok)) score += 2.0 * w;
        if (todosLower.contains(tok)) score += 2.2 * w;
        if (bodyLower.contains(tok)) score += 1.4 * w;
      }
      if (score <= 0) continue;

      // 轻微时间新近度加成，避免同分时旧记录压过今天记录
      final recency = 1.0 / (1.0 + math.max(0, doc.dayOffset) * 0.15);
      hits.add(
        RecordSearchHit(
          doc: doc,
          score: score + recency,
          snippet: _buildSnippet(doc, tokens),
        ),
      );
    }

    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList(growable: false);
  }

  static List<String> tokenize(String raw) {
    final text = raw.toLowerCase().trim();
    if (text.isEmpty) return const [];
    final tokens = <String>{};

    // 英文/数字词元
    for (final m in RegExp(r'[a-z0-9_.-]{2,}').allMatches(text)) {
      tokens.add(m.group(0)!);
    }

    // 中文连续片段做 bigram 切分，覆盖「黄金眼」「爆米花」「导出方案」等子串匹配
    for (final m in RegExp(r'[\u4e00-\u9fff]+').allMatches(text)) {
      final seg = m.group(0)!;
      if (seg.length == 1) {
        tokens.add(seg);
        continue;
      }
      for (var i = 0; i < seg.length - 1; i++) {
        tokens.add(seg.substring(i, i + 2));
      }
      if (seg.length <= 6) {
        tokens.add(seg);
      }
    }
    return tokens.toList(growable: false);
  }

  static String _buildSnippet(AgentDocument doc, List<String> tokens) {
    final rawPool = [
      if (doc.summary.isNotEmpty) doc.summary,
      if (doc.todos.isNotEmpty) '待办：${doc.todos.join('；')}',
      if (doc.body.isNotEmpty) doc.body,
    ].join('\n');
    if (rawPool.isEmpty) return '';
    if (tokens.isEmpty || rawPool.length <= 280) {
      return rawPool.length <= 280
          ? rawPool
          : '${rawPool.substring(0, 280)}…';
    }
    final lower = rawPool.toLowerCase();
    var bestIdx = -1;
    for (final tok in tokens) {
      final idx = lower.indexOf(tok);
      if (idx >= 0) {
        bestIdx = idx;
        break;
      }
    }
    if (bestIdx < 0) return '${rawPool.substring(0, 280)}…';
    final start = math.max(0, bestIdx - 80);
    final end = math.min(rawPool.length, start + 280);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < rawPool.length ? '…' : '';
    return '$prefix${rawPool.substring(start, end)}$suffix';
  }
}
