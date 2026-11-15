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

  final joined = keptTokens.join();
  if (_normalize(joined) != _normalize(text)) return null;

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
