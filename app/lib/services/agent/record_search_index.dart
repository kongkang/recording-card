/// 后台 Isolate 内的记录与总结极速检索引擎（中文 bigram + 实义单字 + 英文数字词元 + IDF 摘要定位）。
///
/// 零 Flutter 依赖，纯内存执行，万级片段可在数毫秒内完成排序返回。
library;

import 'dart:math' as math;

import '../memory/memory_query.dart';
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

class _PreparedDoc {
  _PreparedDoc(this.doc)
    : titleLower = doc.title.toLowerCase(),
      spkLower = doc.speakers.toLowerCase(),
      spkNorm = RecordSearchIndex.normalizeSpeakerName(doc.speakers),
      sumLower = doc.summary.toLowerCase(),
      todosLower = doc.todos.join(' ').toLowerCase(),
      bodyLower = doc.body.toLowerCase() {
    combinedLower = '$titleLower\n$spkLower\n$sumLower\n$todosLower\n$bodyLower';
  }

  final AgentDocument doc;
  final String titleLower;
  final String spkLower;
  final String spkNorm;
  final String sumLower;
  final String todosLower;
  final String bodyLower;
  late final String combinedLower;
}

class RecordSearchIndex {
  List<AgentDocument> _docs = const [];
  List<_PreparedDoc> _prepared = const [];
  final Map<String, AgentDocument> _byId = {};
  final Map<String, int> _dfCache = {};

  int get length => _docs.length;

  void replaceCorpus(List<AgentDocument> docs) {
    _docs = List<AgentDocument>.unmodifiable(docs);
    _prepared = [for (final d in docs) _PreparedDoc(d)];
    _byId
      ..clear()
      ..addEntries([for (final d in docs) MapEntry(d.id, d)]);
    _dfCache.clear();
  }

  AgentDocument? getById(String id) => _byId[id];

  static String normalizeSpeakerName(String raw) {
    return raw
        .replaceAll(RegExp(r'[（(]\s*(?:机主本人|推测|本人)\s*[)）]'), '')
        .replaceAll(RegExp(r'^@+'), '')
        .trim()
        .toLowerCase();
  }

  double _tokenIdf(String tok) {
    if (_prepared.isEmpty) return 1.0;
    final df = _dfCache.putIfAbsent(tok, () {
      var count = 0;
      for (final p in _prepared) {
        if (p.combinedLower.contains(tok)) count += 1;
      }
      return count;
    });
    return math.log((_prepared.length + 1) / (df + 1)) + 1.0;
  }

  List<RecordSearchHit> search({
    String? query,
    String? speaker,
    int? dayOffset,
    int? minDayOffset,
    int? maxDayOffset,
    String? timeOfDay,
    String? kind,
    int limit = 6,
    DateTime? now,
  }) {
    if (_prepared.isEmpty) return const [];
    final rawQ = (query ?? '').trim();
    final parsed = rawQ.isEmpty ? null : parseMemoryQuery(rawQ, now: now);

    final effectiveMinDay = minDayOffset ??
        (dayOffset == null ? parsed?.window?.minOffset : null);
    final effectiveMaxDay = maxDayOffset ??
        (dayOffset == null ? parsed?.window?.maxOffset : null);
    final effectiveHourRange =
        MemoryHourRange.fromCode(timeOfDay) ?? parsed?.hourRange;

    final spkNorm = normalizeSpeakerName(speaker ?? '');
    final kindFilter = (kind ?? '').trim().toLowerCase();
    final q = (parsed?.text ?? rawQ).trim();
    final tokens = tokenize(q);

    final filtered = <_PreparedDoc>[];
    for (final p in _prepared) {
      final doc = p.doc;
      if (kindFilter.isNotEmpty && doc.kind.toLowerCase() != kindFilter) {
        continue;
      }
      if (dayOffset != null && doc.dayOffset != dayOffset) continue;
      if (effectiveMinDay != null && doc.dayOffset < effectiveMinDay) continue;
      if (effectiveMaxDay != null && doc.dayOffset > effectiveMaxDay) continue;
      if (effectiveHourRange != null &&
          !effectiveHourRange.matchesTimeLabel(doc.timeLabel)) {
        continue;
      }
      if (spkNorm.isNotEmpty &&
          !p.spkNorm.contains(spkNorm) &&
          !p.bodyLower.contains(spkNorm)) {
        continue;
      }
      filtered.add(p);
    }

    if (filtered.isEmpty) return const [];

    // 无关键词时按最新时间倒序返回最近记录，便于回答「今天聊了什么 / 前天下午聊了什么」
    if (tokens.isEmpty) {
      final sorted = [...filtered]
        ..sort((a, b) {
          final dayCmp = a.doc.dayOffset.compareTo(b.doc.dayOffset);
          if (dayCmp != 0) return dayCmp;
          return b.doc.timestampMs.compareTo(a.doc.timestampMs);
        });
      return [
        for (final p in sorted.take(limit))
          RecordSearchHit(
            doc: p.doc,
            score: 1.0,
            snippet: _buildSnippet(p.doc, const []),
          ),
      ];
    }

    final tokenWeights = <String, double>{};
    for (final tok in tokens) {
      final runeLen = tok.runes.length;
      final lenFactor = runeLen >= 3 ? 2.1 : (runeLen == 2 ? 1.55 : 0.72);
      tokenWeights[tok] = lenFactor * _tokenIdf(tok);
    }
    final rankedTokens = [...tokens]
      ..sort((a, b) => (tokenWeights[b] ?? 0).compareTo(tokenWeights[a] ?? 0));

    final hits = <RecordSearchHit>[];
    final qLower = q.toLowerCase();
    final checkFullQuery = qLower.isNotEmpty && !qLower.contains(' ');

    for (final p in filtered) {
      var score = 0.0;
      if (checkFullQuery) {
        if (p.titleLower.contains(qLower)) score += 8.0;
        if (p.sumLower.contains(qLower)) score += 5.0;
        if (p.todosLower.contains(qLower)) score += 5.0;
        if (p.bodyLower.contains(qLower)) score += 4.0;
      }

      for (final tok in rankedTokens) {
        final w = tokenWeights[tok] ?? 1.0;
        if (p.titleLower.contains(tok)) score += 3.2 * w;
        if (p.spkLower.contains(tok)) score += 2.6 * w;
        if (p.sumLower.contains(tok)) score += 2.0 * w;
        if (p.todosLower.contains(tok)) score += 2.2 * w;
        if (p.bodyLower.contains(tok)) score += 1.4 * w;
      }
      if (score <= 0) continue;

      // 轻微时间新近度加成，避免同分时旧记录压过今天记录
      final recency = 1.0 / (1.0 + math.max(0, p.doc.dayOffset) * 0.15);
      hits.add(
        RecordSearchHit(
          doc: p.doc,
          score: score + recency,
          snippet: _buildSnippet(
            p.doc,
            rankedTokens,
            exactQueryLower: checkFullQuery ? qLower : null,
          ),
        ),
      );
    }

    hits.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      final dayCmp = a.doc.dayOffset.compareTo(b.doc.dayOffset);
      if (dayCmp != 0) return dayCmp;
      return b.doc.timestampMs.compareTo(a.doc.timestampMs);
    });
    return hits.take(limit).toList(growable: false);
  }

  static List<String> tokenize(String raw) {
    final text = raw.toLowerCase().trim();
    if (text.isEmpty) return const [];
    final tokens = <String>{};

    // 复合英文/版本号词元（如 gpt-4、0.8.15）与单字符/多字符英文数字词元（如 a、b、3）
    for (final m in RegExp(r'[a-z0-9]+(?:[._-][a-z0-9]+)+').allMatches(text)) {
      tokens.add(m.group(0)!);
    }
    for (final m in RegExp(r'[a-z0-9]+').allMatches(text)) {
      final word = m.group(0)!;
      if (word.isNotEmpty) tokens.add(word);
    }

    // 按 Unicode 码点扫描 CJK（覆盖基本区、扩展 A 与扩展 B+ 0x20000..0x2ebef）
    final cjkRun = <int>[];
    void flushCjk() {
      if (cjkRun.isEmpty) return;
      final chars = [for (final r in cjkRun) String.fromCharCode(r)];
      if (cjkRun.length == 1) {
        if (!isCjkStopUnigramRune(cjkRun.single)) {
          tokens.add(chars.single);
        }
      } else {
        for (var i = 0; i + 1 < cjkRun.length; i++) {
          final r0 = cjkRun[i];
          final r1 = cjkRun[i + 1];
          if (isCjkParticleRune(r0) || isCjkParticleRune(r1)) continue;
          if (isCjkStopUnigramRune(r0) && isCjkStopUnigramRune(r1)) continue;
          tokens.add('${chars[i]}${chars[i + 1]}');
        }
        // 对不含结构助词的连续词组（<=6 字，如「黄金眼」「爆米花」）保留整词加权
        if (cjkRun.length >= 3 &&
            cjkRun.length <= 6 &&
            !cjkRun.any(isCjkParticleRune)) {
          tokens.add(chars.join());
        }
        for (var i = 0; i < cjkRun.length; i++) {
          if (!isCjkStopUnigramRune(cjkRun[i])) {
            tokens.add(chars[i]);
          }
        }
      }
      cjkRun.clear();
    }

    for (final rune in text.runes) {
      if (isCjkRune(rune)) {
        cjkRun.add(rune);
      } else {
        flushCjk();
      }
    }
    flushCjk();

    if (tokens.isEmpty) {
      for (final rune in text.runes) {
        if (isCjkRune(rune) && !isCjkParticleRune(rune)) {
          tokens.add(String.fromCharCode(rune));
        }
      }
    }
    return tokens.toList(growable: false);
  }

  static String _buildSnippet(
    AgentDocument doc,
    List<String> rankedTokens, {
    String? exactQueryLower,
  }) {
    final rawPool = [
      if (doc.summary.isNotEmpty) doc.summary,
      if (doc.todos.isNotEmpty) '待办：${doc.todos.join('；')}',
      if (doc.body.isNotEmpty) doc.body,
    ].join('\n');
    if (rawPool.isEmpty) return '';
    if (rawPool.length <= 280) return rawPool;
    if (rankedTokens.isEmpty && (exactQueryLower == null || exactQueryLower.isEmpty)) {
      return '${_safeSubstring(rawPool, 0, 280)}…';
    }

    final lower = rawPool.toLowerCase();
    var bestIdx = -1;
    if (exactQueryLower != null && exactQueryLower.isNotEmpty) {
      bestIdx = lower.indexOf(exactQueryLower);
    }
    if (bestIdx < 0) {
      // rankedTokens 已按最高 IDF × 词长降序排列，优先围绕最具区分度的稀有词定位摘要窗口
      for (final tok in rankedTokens) {
        final idx = lower.indexOf(tok);
        if (idx >= 0) {
          bestIdx = idx;
          break;
        }
      }
    }
    if (bestIdx < 0) return '${_safeSubstring(rawPool, 0, 280)}…';
    final start = _alignSurrogateStart(rawPool, math.max(0, bestIdx - 80));
    final end = _alignSurrogateEnd(
      rawPool,
      math.min(rawPool.length, start + 280),
    );
    final prefix = start > 0 ? '…' : '';
    final suffix = end < rawPool.length ? '…' : '';
    return '$prefix${rawPool.substring(start, end)}$suffix';
  }

  static String _safeSubstring(String s, int start, int end) {
    final a = _alignSurrogateStart(s, start.clamp(0, s.length));
    final b = _alignSurrogateEnd(s, end.clamp(a, s.length));
    return s.substring(a, b);
  }

  static int _alignSurrogateStart(String s, int index) {
    if (index <= 0 || index >= s.length) return index;
    final unit = s.codeUnitAt(index);
    if (unit >= 0xDC00 && unit <= 0xDFFF) return index + 1;
    return index;
  }

  static int _alignSurrogateEnd(String s, int index) {
    if (index <= 0 || index >= s.length) return index;
    final prev = s.codeUnitAt(index - 1);
    if (prev >= 0xD800 && prev <= 0xDBFF) return index - 1;
    return index;
  }

  static int safeAlignStart(String s, int index) =>
      _alignSurrogateStart(s, index);

  static int safeAlignEnd(String s, int index) => _alignSurrogateEnd(s, index);
}
