/// 把口头问题拆成「日期窗口 + 全文检索串」。
///
/// 日期词只做过滤，不拿去跟正文做关键词匹配，避免「前天」本身把不相关的句子召回来。
library;

class MemoryTimeWindow {
  const MemoryTimeWindow(this.minOffset, this.maxOffset);

  final int minOffset;
  final int maxOffset;

  bool contains(int dayOffset) =>
      dayOffset >= minOffset && dayOffset <= maxOffset;
}

class ParsedMemoryQuery {
  const ParsedMemoryQuery(this.text, this.window);

  final String text;
  final MemoryTimeWindow? window;
}

ParsedMemoryQuery parseMemoryQuery(String raw) {
  var text = raw.trim();
  MemoryTimeWindow? window;
  const rules = <(String, int, int)>[
    ('前几天', 1, 7),
    ('上周', 7, 14),
    ('前天', 2, 2),
    ('昨天', 1, 1),
    ('今天', 0, 0),
  ];
  for (final rule in rules) {
    final at = text.indexOf(rule.$1);
    if (at < 0) continue;
    window = MemoryTimeWindow(rule.$2, rule.$3);
    text = '${text.substring(0, at)}${text.substring(at + rule.$1.length)}'
        .trim();
    break;
  }
  text = text.replaceFirst(RegExp(r'^[的了看]+'), '').trim();
  return ParsedMemoryQuery(text, window);
}

/// 把正文变成 FTS 可稳定匹配的词串。
///
/// 每个汉字编成 `u` + 码点，避免各平台 SQLite 对中文分词不一致。
/// 「黄金眼」会变成相邻的 `u9ec4 u91d1 u773c`。
String indexedText(String text) {
  final parts = <String>[];
  final word = StringBuffer();
  void flushWord() {
    if (word.isEmpty) return;
    parts.add(word.toString());
    word.clear();
  }

  for (final rune in text.runes) {
    if (_isCjk(rune)) {
      flushWord();
      parts.add('u${rune.toRadixString(16)}');
    } else if (_isWordChar(rune)) {
      word.write(String.fromCharCode(rune).toLowerCase());
    } else {
      flushWord();
    }
  }
  flushWord();
  return parts.join(' ');
}

/// 整句短语。中文按字相邻匹配，适合「黄金眼」这种连续说法。
String? ftsPhraseExpression(String text) {
  final indexed = indexedText(text);
  if (indexed.isEmpty) return null;
  return 'search_text : "$indexed"';
}

/// 短语落空时的宽松召回：中文二字片段与英文数字词，用 OR 拼起来。
///
/// 「看电影」因此仍能命中「看了电影」。
String? ftsRelaxedExpression(String text) {
  final tokens = <String>[];
  for (final match in RegExp(r'[\u3400-\u9fff]+').allMatches(text)) {
    final codes = [
      for (final rune in match.group(0)!.runes) 'u${rune.toRadixString(16)}',
    ];
    if (codes.length == 1) tokens.add(codes.single);
    for (var i = 0; i + 1 < codes.length; i++) {
      tokens.add('${codes[i]} ${codes[i + 1]}');
    }
  }
  for (final match in RegExp(r'[A-Za-z0-9]+').allMatches(text)) {
    final word = match.group(0)!.toLowerCase();
    if (word.isNotEmpty) tokens.add(word);
  }
  if (tokens.isEmpty) return null;
  return tokens.map((token) => 'search_text : "$token"').join(' OR ');
}

bool _isCjk(int rune) =>
    (rune >= 0x3400 && rune <= 0x9fff) || (rune >= 0xf900 && rune <= 0xfaff);

bool _isWordChar(int rune) =>
    (rune >= 0x30 && rune <= 0x39) ||
    (rune >= 0x41 && rune <= 0x5a) ||
    (rune >= 0x61 && rune <= 0x7a);
