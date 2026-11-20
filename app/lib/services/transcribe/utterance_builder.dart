/// 把一次切片解码的整段文本拆成"句级原始 utterance"，并给出相对录音起点的时间。
///
/// 优先用 SenseVoice 的 token 级时间戳：它的 tokens 是中文字符，`tokens.join()`
/// 与 `text` 完全一致（已实测），所以可以按"停顿 ≥500ms / 句末标点"把字符分组，
/// 得到真正的句级对齐。
///
/// 模型不给 token 时间戳时退回：
/// - 用切片起止时间作为语音范围；
/// - 句与句之间按字符数比例分配。
/// 这是近似，不声称字级精确。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/models/recording.dart';

/// 句末标点（中英文）。
final RegExp _sentenceEnd = RegExp(r'[。！？!?；;\n]+');

/// 超长句再按逗号切开，避免一句话占满整片、详情页无法阅读。
final RegExp _clauseEnd = RegExp(r'[，,、]+');

/// 模型特殊标记（`<|zh|>`、`<|NEUTRAL|>`、`<blank>` 等）。
final RegExp _specialToken = RegExp(r'^<.*>$');
final RegExp _inlineSpecialTag = RegExp(r'<[^>]*>');
final RegExp _meaningfulChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

const int _maxCharsPerUtterance = 80;

/// 判断一段 ASR 文本是否包含真实语音文字（过滤掉静音触发的孤立 `"。"`、`"."`、`"，。"` 等纯标点幻觉）。
bool isMeaningfulSpeechText(String text) {
  final cleaned = text.replaceAll(_inlineSpecialTag, '').trim();
  if (cleaned.isEmpty) return false;
  return _meaningfulChar.hasMatch(cleaned);
}

/// 从有效语音中提取干净可读的短标题（彻底杜绝纯标点与「实时切片 #N」）。
String buildReadableFallbackTitle(
  String text, {
  String fallback = '语音对话',
}) {
  final stripped = text.replaceAll(_inlineSpecialTag, '').trim();
  if (!isMeaningfulSpeechText(stripped)) return fallback;
  final clauses = stripped
      .split(RegExp(r'[\n。！？!?，,；;]+'))
      .map((s) => s.trim())
      .where(isMeaningfulSpeechText);
  final first = clauses.isEmpty ? stripped : clauses.first;
  return first.length <= 18 ? first : '${first.substring(0, 18)}…';
}

/// 优先使用 token 时间戳；不可用时按标点 + 比例兜底。
List<RawUtterance> buildUtterancesFromAsr({
  required String sliceId,
  required int sliceStartMs,
  required int sliceEndMs,
  required String text,
  List<String> tokens = const [],
  List<int> tokenTimestampsMs = const [],
  String? lang,
  String? emotion,
  int pauseMs = 500,
}) {
  final tokensText = tokens
      .where((t) => t.trim().isNotEmpty && !_specialToken.hasMatch(t.trim()))
      .join();
  if (!isMeaningfulSpeechText(text) && !isMeaningfulSpeechText(tokensText)) {
    return const [];
  }
  final aligned = _buildFromTokens(
    sliceId: sliceId,
    sliceStartMs: sliceStartMs,
    sliceEndMs: sliceEndMs,
    text: text,
    tokens: tokens,
    timestampsMs: tokenTimestampsMs,
    lang: lang,
    emotion: emotion,
    pauseMs: pauseMs,
  );
  if (aligned != null) return aligned;
  return buildUtterances(
    sliceId: sliceId,
    sliceStartMs: sliceStartMs,
    sliceEndMs: sliceEndMs,
    text: text,
    tokenTimestampsMs: tokenTimestampsMs,
    lang: lang,
    emotion: emotion,
  );
}

/// 标点 + 比例兜底路径。
List<RawUtterance> buildUtterances({
  required String sliceId,
  required int sliceStartMs,
  required int sliceEndMs,
  required String text,
  List<int> tokenTimestampsMs = const [],
  String? lang,
  String? emotion,
}) {
  final sentences = splitSentences(text);
  if (sentences.isEmpty) return const [];

  var rangeStart = sliceStartMs;
  var rangeEnd = sliceEndMs;
  if (tokenTimestampsMs.isNotEmpty) {
    final first = tokenTimestampsMs.first;
    final last = tokenTimestampsMs.last;
    if (last > first) {
      // token 时间相对切片开头；换算成录音内绝对时间
      rangeStart = sliceStartMs + first;
      rangeEnd = sliceStartMs + last;
    }
  }
  if (rangeEnd <= rangeStart) {
    rangeEnd = rangeStart + 1;
  }

  final times = allocateTimes(
    sentences: sentences,
    startMs: rangeStart,
    endMs: rangeEnd,
  );

  final out = <RawUtterance>[];
  for (var i = 0; i < sentences.length; i++) {
    out.add(
      RawUtterance(
        id: '${sliceId}u$i',
        sliceId: sliceId,
        startMs: times[i].$1,
        endMs: times[i].$2,
        text: sentences[i],
        lang: lang,
        emotion: emotion,
      ),
    );
  }
  return out;
}

/// token 对齐路径：无法对齐时返回 null，交给兜底。
List<RawUtterance>? _buildFromTokens({
  required String sliceId,
  required int sliceStartMs,
  required int sliceEndMs,
  required String text,
  required List<String> tokens,
  required List<int> timestampsMs,
  required String? lang,
  required String? emotion,
  required int pauseMs,
}) {
  if (tokens.isEmpty || tokens.length != timestampsMs.length) return null;

  final keptTokens = <String>[];
  final keptTimes = <int>[];
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.trim().isEmpty || _specialToken.hasMatch(token.trim())) continue;
    keptTokens.add(token);
    keptTimes.add(timestampsMs[i]);
  }
  if (keptTokens.isEmpty) return null;

  final joined = keptTokens.join().replaceAll('▁', ' ');
  if (_normalize(joined) != _normalize(text)) {
    return _buildResilientAlignedFromTokens(
      sliceId: sliceId,
      sliceStartMs: sliceStartMs,
      sliceEndMs: sliceEndMs,
      text: text,
      keptTokens: keptTokens,
      keptTimes: keptTimes,
      lang: lang,
      emotion: emotion,
      pauseMs: pauseMs,
    );
  }

  // 分组：停顿足够长，或上一个字符是句末标点
  final groups = <List<int>>[];
  var current = <int>[0];
  for (var i = 1; i < keptTokens.length; i++) {
    final gap = keptTimes[i] - keptTimes[i - 1];
    final prev = keptTokens[i - 1];
    final breakHere =
        gap >= pauseMs || RegExp(r'[。！？!?；;\n]$').hasMatch(prev);
    if (breakHere) {
      groups.add(current);
      current = <int>[i];
    } else {
      current.add(i);
    }
  }
  groups.add(current);

  // 太短的分组（1 个字符）尽量并入下一组，避免"嗯"单独成句
  final merged = <List<int>>[];
  for (final g in groups) {
    final chars = g.map((i) => keptTokens[i]).join().trim();
    if (chars.length < 2 && merged.isNotEmpty) {
      merged.last.addAll(g);
    } else {
      merged.add([...g]);
    }
  }

  final out = <RawUtterance>[];
  for (var gi = 0; gi < merged.length; gi++) {
    final g = merged[gi];
    final groupText = g.map((i) => keptTokens[i]).join().trim();
    if (!isMeaningfulSpeechText(groupText)) continue;
    final start = sliceStartMs + keptTimes[g.first];
    final nextStart = gi + 1 < merged.length
        ? sliceStartMs + keptTimes[merged[gi + 1].first]
        : sliceEndMs;
    var end = gi + 1 < merged.length
        ? sliceStartMs + keptTimes[g.last] + 300
        : sliceEndMs;
    if (end <= start) end = start + 200;
    if (end > nextStart) end = nextStart;
    if (end <= start) end = start + 1;
    out.add(
      RawUtterance(
        id: '${sliceId}u${out.length}',
        sliceId: sliceId,
        startMs: start,
        endMs: end,
        text: groupText,
        lang: lang,
        emotion: emotion,
      ),
    );
  }
  return out;
}

String _normalize(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').trim();

const Map<String, String> _chineseDigitMap = {
  '零': '0',
  '〇': '0',
  '一': '1',
  '壹': '1',
  '二': '2',
  '两': '2',
  '贰': '2',
  '三': '3',
  '叁': '3',
  '四': '4',
  '肆': '4',
  '五': '5',
  '伍': '5',
  '六': '6',
  '陆': '6',
  '七': '7',
  '柒': '7',
  '八': '8',
  '捌': '8',
  '九': '9',
  '玖': '9',
};

String _canonicalChar(String ch) {
  final lower = ch.toLowerCase();
  return _chineseDigitMap[lower] ?? lower;
}

final RegExp _singleSentenceEndChar = RegExp(r'^[。！？!?；;\n]$');
final RegExp _closingOrSentenceEndChar = RegExp(
  r'''^[。！？!?；;\n”’）》」】"'\)]$''',
);
final RegExp _singleClauseChar = RegExp(r'^[，,、]$');

/// 当 SenseVoice 开启 ITN（数字规范化、自动标点、子词空格）导致 `tokens.join() != text` 时，
/// 通过字符级最长公共子序列（LCS）把 `text` 中的有效字符对齐回 `tokens` 时间戳，避免丢弃全部真实时间！
List<RawUtterance>? _buildResilientAlignedFromTokens({
  required String sliceId,
  required int sliceStartMs,
  required int sliceEndMs,
  required String text,
  required List<String> keptTokens,
  required List<int> keptTimes,
  required String? lang,
  required String? emotion,
  required int pauseMs,
}) {
  final cleanedText = text.replaceAll(_inlineSpecialTag, '').trim();
  if (!isMeaningfulSpeechText(cleanedText)) return null;

  final tokenAnchors = <({String ch, int timeMs})>[];
  for (var i = 0; i < keptTokens.length; i++) {
    final tok = keptTokens[i].replaceAll(_inlineSpecialTag, '').replaceAll('▁', '');
    for (final rune in tok.runes) {
      final s = String.fromCharCode(rune);
      if (_meaningfulChar.hasMatch(s)) {
        tokenAnchors.add((ch: _canonicalChar(s), timeMs: keptTimes[i]));
      }
    }
  }
  if (tokenAnchors.isEmpty) return null;

  final textRunes = cleanedText.runes.toList();
  final textAnchors = <({String ch, int runeIdx})>[];
  for (var ri = 0; ri < textRunes.length; ri++) {
    final s = String.fromCharCode(textRunes[ri]);
    if (_meaningfulChar.hasMatch(s)) {
      textAnchors.add((ch: _canonicalChar(s), runeIdx: ri));
    }
  }
  if (textAnchors.isEmpty) return null;

  final n = textAnchors.length;
  final m = tokenAnchors.length;
  final matchedTimes = List<int?>.filled(n, null);
  var matchedCount = 0;

  if (n * m <= 200000) {
    final cols = m + 1;
    final dp = Uint16List((n + 1) * cols);
    for (var i = n - 1; i >= 0; i--) {
      final row = i * cols;
      final nextRow = (i + 1) * cols;
      final tch = textAnchors[i].ch;
      for (var j = m - 1; j >= 0; j--) {
        if (tch == tokenAnchors[j].ch) {
          dp[row + j] = dp[nextRow + j + 1] + 1;
        } else {
          final down = dp[nextRow + j];
          final right = dp[row + j + 1];
          dp[row + j] = down >= right ? down : right;
        }
      }
    }
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (textAnchors[i].ch == tokenAnchors[j].ch) {
        matchedTimes[i] = tokenAnchors[j].timeMs;
        matchedCount++;
        i++;
        j++;
      } else if (dp[(i + 1) * cols + j] >= dp[i * cols + j + 1]) {
        i++;
      } else {
        j++;
      }
    }
  } else {
    var j = 0;
    for (var i = 0; i < n && j < m; i++) {
      final limit = math.min(m, j + 12);
      for (var k = j; k < limit; k++) {
        if (textAnchors[i].ch == tokenAnchors[k].ch) {
          matchedTimes[i] = tokenAnchors[k].timeMs;
          matchedCount++;
          j = k + 1;
          break;
        }
      }
    }
  }

  final minLen = math.min(n, m);
  final maxLen = math.max(n, m);
  if (matchedCount < (minLen * 0.55).ceil() ||
      matchedCount < (maxLen * 0.40).ceil()) {
    return null;
  }

  // 对 ITN 改写而未直接命中的少量字符做前后锚点线性插值
  final anchorTimes = List<int>.filled(n, 0);
  int? firstMatchedIdx;
  int? lastMatchedIdx;
  for (var i = 0; i < n; i++) {
    if (matchedTimes[i] != null) {
      firstMatchedIdx ??= i;
      lastMatchedIdx = i;
      anchorTimes[i] = matchedTimes[i]!;
    }
  }
  if (firstMatchedIdx == null || lastMatchedIdx == null) return null;
  for (var i = 0; i < firstMatchedIdx; i++) {
    anchorTimes[i] = anchorTimes[firstMatchedIdx];
  }
  for (var i = lastMatchedIdx + 1; i < n; i++) {
    anchorTimes[i] = anchorTimes[lastMatchedIdx];
  }
  var left = firstMatchedIdx;
  while (left < lastMatchedIdx) {
    var right = left + 1;
    while (right <= lastMatchedIdx && matchedTimes[right] == null) {
      right++;
    }
    if (right > left + 1) {
      final t0 = anchorTimes[left];
      final t1 = anchorTimes[right];
      final span = right - left;
      for (var k = left + 1; k < right; k++) {
        anchorTimes[k] = t0 + ((t1 - t0) * (k - left) / span).round();
      }
    }
    left = right;
  }

  final runeTimes = List<int>.filled(textRunes.length, anchorTimes.first);
  var ai = 0;
  for (var ri = 0; ri < textRunes.length; ri++) {
    if (ai < n && textAnchors[ai].runeIdx == ri) {
      runeTimes[ri] = anchorTimes[ai];
      ai++;
    } else if (ri > 0) {
      runeTimes[ri] = runeTimes[ri - 1];
    }
  }

  // 按句末标点或 token 真实长停顿切分
  final groups = <(int, int)>[];
  var groupStart = 0;
  for (var ri = 1; ri < textRunes.length; ri++) {
    final prev = String.fromCharCode(textRunes[ri - 1]);
    final curr = String.fromCharCode(textRunes[ri]);
    final gap = runeTimes[ri] - runeTimes[ri - 1];
    final punctBreak =
        _singleSentenceEndChar.hasMatch(prev) &&
        !_closingOrSentenceEndChar.hasMatch(curr);
    final clauseOverflow =
        (ri - groupStart) >= _maxCharsPerUtterance &&
        _singleClauseChar.hasMatch(prev);
    if (punctBreak || gap >= pauseMs || clauseOverflow) {
      groups.add((groupStart, ri));
      groupStart = ri;
    }
  }
  groups.add((groupStart, textRunes.length));

  final merged = <(int, int)>[];
  for (final g in groups) {
    final segStr = String.fromCharCodes(textRunes.sublist(g.$1, g.$2)).trim();
    final contentLen = _meaningfulChar.allMatches(segStr).length;
    if (contentLen < 2 && merged.isNotEmpty) {
      final prev = merged.last;
      merged[merged.length - 1] = (prev.$1, g.$2);
    } else {
      merged.add(g);
    }
  }

  final out = <RawUtterance>[];
  for (var gi = 0; gi < merged.length; gi++) {
    final g = merged[gi];
    final groupText = String.fromCharCodes(textRunes.sublist(g.$1, g.$2)).trim();
    if (!isMeaningfulSpeechText(groupText)) continue;
    final start = sliceStartMs + runeTimes[g.$1];
    final nextStart = gi + 1 < merged.length
        ? sliceStartMs + runeTimes[merged[gi + 1].$1]
        : sliceEndMs;
    var end = gi + 1 < merged.length
        ? sliceStartMs + runeTimes[g.$2 - 1] + 300
        : sliceEndMs;
    if (end <= start) end = start + 200;
    if (end > nextStart) end = nextStart;
    if (end <= start) end = start + 1;
    out.add(
      RawUtterance(
        id: '${sliceId}u${out.length}',
        sliceId: sliceId,
        startMs: start,
        endMs: end,
        text: groupText,
        lang: lang,
        emotion: emotion,
      ),
    );
  }
  return out.isEmpty ? null : out;
}

/// 按句末标点切句；过长的句子再按逗号切。
List<String> splitSentences(String text) {
  final trimmed = text.trim();
  if (!isMeaningfulSpeechText(trimmed)) return const [];
  final out = <String>[];
  for (final part in trimmed.split(_sentenceEnd)) {
    final s = part.trim();
    if (!isMeaningfulSpeechText(s)) continue;
    if (s.length <= _maxCharsPerUtterance) {
      out.add(s);
      continue;
    }
    final buffer = StringBuffer();
    for (final clause in s.split(_clauseEnd)) {
      final c = clause.trim();
      if (!isMeaningfulSpeechText(c)) continue;
      if (buffer.isNotEmpty && buffer.length + c.length > _maxCharsPerUtterance) {
        out.add(buffer.toString());
        buffer.clear();
      }
      if (buffer.isNotEmpty) buffer.write('，');
      buffer.write(c);
    }
    if (isMeaningfulSpeechText(buffer.toString())) out.add(buffer.toString());
  }
  return out;
}

/// 按字符数比例分配时间；保证每句至少 200ms 且严格递增。
List<(int, int)> allocateTimes({
  required List<String> sentences,
  required int startMs,
  required int endMs,
}) {
  final weights = [
    for (final s in sentences) _weight(s),
  ];
  final total = weights.fold<int>(0, (a, b) => a + b);
  final span = (endMs - startMs).clamp(sentences.length * 200, 1 << 31);

  final out = <(int, int)>[];
  var cursor = startMs;
  for (var i = 0; i < sentences.length; i++) {
    final isLast = i == sentences.length - 1;
    var duration = total == 0
        ? span ~/ sentences.length
        : (span * weights[i] / total).round();
    if (duration < 200) duration = 200;
    var end = isLast ? startMs + span : cursor + duration;
    if (end <= cursor) end = cursor + 1;
    out.add((cursor, end));
    cursor = end;
  }
  return out;
}

int _weight(String text) {
  // 纯标点/空白按 1 计，避免除零；中文按 rune 数
  final n = text.runes.where((r) => r > 32).length;
  return n == 0 ? 1 : n;
}
