/// 把口头问题拆成「日期窗口 + 时段过滤 + 全文检索串」，并提供跨引擎一致的中英文分词。
///
/// 日期词、时段词与口语追问壳只做结构化过滤或剥离，不拿去跟正文做关键词匹配，
/// 避免「前天下午聊了什么」因为搜不到字面「下午」或「什么」而漏召回。
library;

class MemoryTimeWindow {
  const MemoryTimeWindow(this.minOffset, this.maxOffset);

  final int minOffset;
  final int maxOffset;

  bool contains(int dayOffset) =>
      dayOffset >= minOffset && dayOffset <= maxOffset;
}

class MemoryHourRange {
  const MemoryHourRange(
    this.startMinutes,
    this.endMinutes, {
    this.name = '',
  });

  /// 距离当天 00:00 的起始分钟（含），如 `12:00` = `720`。
  final int startMinutes;

  /// 距离当天 00:00 的结束分钟（含），如 `18:30` = `1110`。
  final int endMinutes;

  final String name;

  int get startHour => startMinutes ~/ 60;
  int get endHour => endMinutes ~/ 60;

  static const MemoryHourRange morning = MemoryHourRange(
    5 * 60,
    9 * 60 + 59,
    name: 'morning',
  );
  static const MemoryHourRange forenoon = MemoryHourRange(
    8 * 60,
    12 * 60 + 30,
    name: 'forenoon',
  );
  static const MemoryHourRange noon = MemoryHourRange(
    11 * 60,
    14 * 60,
    name: 'noon',
  );
  static const MemoryHourRange afternoon = MemoryHourRange(
    12 * 60,
    18 * 60 + 30,
    name: 'afternoon',
  );
  static const MemoryHourRange evening = MemoryHourRange(
    18 * 60,
    23 * 60 + 59,
    name: 'evening',
  );

  static MemoryHourRange? fromCode(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    return switch (v) {
      'morning' || '早上' || '清晨' || '今早' || '早间' => morning,
      'forenoon' || '上午' => forenoon,
      'noon' || '中午' || '午间' => noon,
      'afternoon' || '下午' || '午后' => afternoon,
      'evening' || 'night' || '晚上' || '夜里' || '夜晚' || '昨晚' || '今晚' || '傍晚' =>
        evening,
      _ => null,
    };
  }

  bool matchesTimeLabel(String timeLabel) {
    final mins = parseClockMinutes(timeLabel);
    if (mins == null) return false;
    return mins >= startMinutes && mins <= endMinutes;
  }
}

/// 从 `'15:10'`、`'前天 15:10'`、`'09:05:12'` 等文本中提取当天分钟数（`0..1439`）。
int? parseClockMinutes(String raw) {
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(raw);
  if (m == null) return null;
  final h = int.tryParse(m.group(1)!) ?? -1;
  final min = int.tryParse(m.group(2)!) ?? -1;
  if (h < 0 || h > 23 || min < 0 || min > 59) return null;
  return h * 60 + min;
}

class ParsedMemoryQuery {
  const ParsedMemoryQuery(
    this.text,
    this.window, {
    this.hourRange,
  });

  final String text;
  final MemoryTimeWindow? window;
  final MemoryHourRange? hourRange;

  bool get hasFilter => window != null || hourRange != null;
}

ParsedMemoryQuery parseMemoryQuery(String raw, {DateTime? now}) {
  var text = raw.trim();
  if (text.isEmpty) return const ParsedMemoryQuery('', null);

  final ref = now ?? DateTime.now();
  MemoryTimeWindow? window;
  MemoryHourRange? hourRange;

  bool takeLiteral(
    String token, {
    MemoryTimeWindow? win,
    MemoryHourRange? hours,
  }) {
    final at = text.indexOf(token);
    if (at < 0) return false;
    if (win != null) window = win;
    if (hours != null) hourRange = hours;
    text = '${text.substring(0, at)} ${text.substring(at + token.length)}';
    return true;
  }

  // 1) 最长优先：复合「日期 + 时段」表达
  const compoundRules = <(String, int, int, MemoryHourRange)>[
    ('大前天晚上', 3, 3, MemoryHourRange.evening),
    ('大前天夜里', 3, 3, MemoryHourRange.evening),
    ('前天晚上', 2, 2, MemoryHourRange.evening),
    ('前天夜里', 2, 2, MemoryHourRange.evening),
    ('昨天晚上', 1, 1, MemoryHourRange.evening),
    ('昨天夜里', 1, 1, MemoryHourRange.evening),
    ('今天早上', 0, 0, MemoryHourRange.morning),
    ('今天清晨', 0, 0, MemoryHourRange.morning),
    ('今天晚上', 0, 0, MemoryHourRange.evening),
    ('今天夜里', 0, 0, MemoryHourRange.evening),
    ('昨晚', 1, 1, MemoryHourRange.evening),
    ('今早', 0, 0, MemoryHourRange.morning),
    ('今晨', 0, 0, MemoryHourRange.morning),
    ('今晚', 0, 0, MemoryHourRange.evening),
  ];
  for (final r in compoundRules) {
    if (takeLiteral(
      r.$1,
      win: MemoryTimeWindow(r.$2, r.$3),
      hours: r.$4,
    )) {
      break;
    }
  }

  // 2) 相对天数 / 自然周 / 星期X（仅在尚未命中日期窗口时提取）
  if (window == null) {
    final recentN = RegExp(
      r'(?:最近|过去|近)\s*([0-9]+|[一二两三四五六七八九十]+)\s*[天日]',
    ).firstMatch(text);
    final nDaysAgo = RegExp(
      r'([0-9]+|[一二两三四五六七八九十]+)\s*[天日]前',
    ).firstMatch(text);
    final lastWeekday = RegExp(
      r'(?:上个星期|上星期|上个礼拜|上礼拜|上周)([一二三四五六日天])',
    ).firstMatch(text);
    final thisWeekday = RegExp(
      r'(?:这个星期|这星期|本星期|这个礼拜|这礼拜|本礼拜|这周|本周)([一二三四五六日天])',
    ).firstMatch(text);

    if (recentN != null) {
      final n = _parseCnInt(recentN.group(1)!);
      if (n != null && n >= 0) {
        window = MemoryTimeWindow(0, n);
        text = text.replaceRange(recentN.start, recentN.end, ' ');
      }
    } else if (nDaysAgo != null) {
      final n = _parseCnInt(nDaysAgo.group(1)!);
      if (n != null && n >= 0) {
        window = MemoryTimeWindow(n, n);
        text = text.replaceRange(nDaysAgo.start, nDaysAgo.end, ' ');
      }
    } else if (lastWeekday != null) {
      final w = _parseWeekdayChar(lastWeekday.group(1)!);
      final d = ref.weekday + 7 - w;
      window = MemoryTimeWindow(d, d);
      text = text.replaceRange(lastWeekday.start, lastWeekday.end, ' ');
    } else if (thisWeekday != null) {
      final w = _parseWeekdayChar(thisWeekday.group(1)!);
      final d = w <= ref.weekday ? (ref.weekday - w) : (ref.weekday + 7 - w);
      window = MemoryTimeWindow(d, d);
      text = text.replaceRange(thisWeekday.start, thisWeekday.end, ' ');
    } else if (_takeFirstLiteral(
      text,
      const ['上周末', '上个周末'],
      (rest) => text = rest,
    )) {
      window = MemoryTimeWindow(ref.weekday, ref.weekday + 1);
    } else if (_takeFirstLiteral(
      text,
      const ['上个星期', '上星期', '上个礼拜', '上礼拜', '上周'],
      (rest) => text = rest,
    )) {
      window = MemoryTimeWindow(ref.weekday, ref.weekday + 6);
    } else if (_takeFirstLiteral(
      text,
      const ['这个星期', '这星期', '本星期', '这个礼拜', '这礼拜', '本礼拜', '这周', '本周'],
      (rest) => text = rest,
    )) {
      window = MemoryTimeWindow(0, ref.weekday - 1);
    } else {
      final bareWeekday = RegExp(r'(?:星期|礼拜|周)([一二三四五六日天])').firstMatch(text);
      if (bareWeekday != null) {
        final w = _parseWeekdayChar(bareWeekday.group(1)!);
        final d = w <= ref.weekday ? (ref.weekday - w) : (ref.weekday + 7 - w);
        window = MemoryTimeWindow(d, d);
        text = text.replaceRange(bareWeekday.start, bareWeekday.end, ' ');
      } else {
        // 最长词优先：大前天 必须在 前天 之前匹配！
        const fixedRules = <(String, int, int)>[
          ('大前天', 3, 3),
          ('前几天', 0, 7),
          ('这几天', 0, 7),
          ('最近', 0, 7),
          ('近期', 0, 7),
          ('前天', 2, 2),
          ('昨天', 1, 1),
          ('昨日', 1, 1),
          ('今天', 0, 0),
          ('今日', 0, 0),
        ];
        for (final rule in fixedRules) {
          if (takeLiteral(
            rule.$1,
            win: MemoryTimeWindow(rule.$2, rule.$3),
          )) {
            break;
          }
        }
      }
    }
  }

  // 3) 时段词提取并从正文检索串剥离
  const todRules = <(String, MemoryHourRange)>[
    ('早上', MemoryHourRange.morning),
    ('清晨', MemoryHourRange.morning),
    ('早间', MemoryHourRange.morning),
    ('上午', MemoryHourRange.forenoon),
    ('中午', MemoryHourRange.noon),
    ('午间', MemoryHourRange.noon),
    ('下午', MemoryHourRange.afternoon),
    ('午后', MemoryHourRange.afternoon),
    ('晚上', MemoryHourRange.evening),
    ('夜里', MemoryHourRange.evening),
    ('夜晚', MemoryHourRange.evening),
    ('傍晚', MemoryHourRange.evening),
    ('深夜', MemoryHourRange.evening),
  ];
  for (final r in todRules) {
    final at = text.indexOf(r.$1);
    if (at < 0) continue;
    hourRange ??= r.$2;
    text = '${text.substring(0, at)} ${text.substring(at + r.$1.length)}';
    break;
  }

  // 4) 剥离口语追问壳与连接助词
  text = stripConversationalFillers(
    text,
    hadTemporalFilter: window != null || hourRange != null,
  );

  return ParsedMemoryQuery(text, window, hourRange: hourRange);
}

String stripConversationalFillers(
  String raw, {
  bool hadTemporalFilter = false,
}) {
  var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return '';

  const trimPunct = r'^[，,。！？!?、：:；;\s]+|[，,。！？!?、：:；;\s]+$';
  s = s.replaceAll(RegExp(trimPunct), '').trim();

  const prefixes = <String>[
    '请问一下',
    '请问',
    '麻烦帮我',
    '麻烦',
    '能不能帮我',
    '能不能',
    '可以帮我',
    '帮我查一下',
    '帮我查查',
    '帮我找一下',
    '帮我找找',
    '帮我看看',
    '帮我搜一下',
    '帮我回忆一下',
    '帮我回顾一下',
    '帮我梳理一下',
    '帮我总结一下',
    '帮我',
    '查一下',
    '查查',
    '找一下',
    '找找',
    '搜一下',
    '搜搜',
    '看一下',
    '看看',
    '回忆一下',
    '回顾一下',
    '梳理一下',
    '我想知道',
    '我想问一下',
    '我想查一下',
    '我想问',
    '想问一下',
    '问一下',
    '关于',
    '有关',
  ];

  var changed = true;
  while (changed && s.isNotEmpty) {
    changed = false;
    s = s.replaceAll(RegExp(trimPunct), '').trim();
    for (final p in prefixes) {
      if (s.startsWith(p)) {
        s = s.substring(p.length).trim();
        changed = true;
        break;
      }
    }
    if (hadTemporalFilter) {
      final next = s
          .replaceFirst(
            RegExp(r'^(?:那场|那次|那段|那个|在|里|我跟|我和|我们|都|主要|大概)+'),
            '',
          )
          .trim();
      if (next != s) {
        s = next;
        changed = true;
      }
    }
    final afterHasWhat = s.replaceFirst(
      RegExp(r'^(?:有哪些|有些什么|有什么|有啥)'),
      '',
    );
    if (afterHasWhat != s && afterHasWhat.trim().isNotEmpty) {
      s = afterHasWhat.trim();
      changed = true;
    }
    final afterVerbDe = s.replaceFirst(
      RegExp(r'^(?:看的|听的|录的|记的|写的|买的|吃的|喝的|聊的|说的|讲的)'),
      '',
    );
    if (afterVerbDe != s && afterVerbDe.trim().isNotEmpty) {
      s = afterVerbDe.trim();
      changed = true;
    }
    final afterDe = s.replaceFirst(RegExp(r'^[的了]+'), '').trim();
    if (afterDe != s) {
      s = afterDe;
      changed = true;
    }
  }

  const suffixes = <String>[
    '聊了些什么内容',
    '聊了什么内容',
    '聊了些什么',
    '聊了什么',
    '聊了啥',
    '说了些什么内容',
    '说了什么内容',
    '说了些什么',
    '说了什么',
    '说了啥',
    '讲了些什么内容',
    '讲了什么内容',
    '讲了些什么',
    '讲了什么',
    '讲了啥',
    '讨论了些什么',
    '讨论了什么内容',
    '讨论了什么',
    '讨论了啥',
    '提到了些什么',
    '提到了什么',
    '提到什么',
    '记了些什么',
    '记了什么',
    '录了什么',
    '做了什么',
    '干了什么',
    '发生了什么',
    '有哪些内容',
    '有什么内容',
    '有哪些',
    '有什么',
    '是什么名字',
    '叫什么名字',
    '什么名字',
    '叫什么',
    '叫啥',
    '是什么内容',
    '是什么事情',
    '是什么事',
    '是什么',
    '是啥',
    '是怎么说的',
    '怎么说的',
    '怎么说',
    '怎么样',
    '的事儿',
    '的事情',
    '的内容',
    '吗',
    '呢',
    '吧',
    '呀',
    '啊',
  ];

  changed = true;
  while (changed && s.isNotEmpty) {
    changed = false;
    s = s.replaceAll(RegExp(trimPunct), '').trim();
    for (final sfx in suffixes) {
      if (s.endsWith(sfx)) {
        s = s.substring(0, s.length - sfx.length).trim();
        changed = true;
        break;
      }
    }
  }

  s = s.replaceAll(RegExp(trimPunct), '').replaceFirst(RegExp(r'^[的了]+'), '').trim();
  return s;
}

bool _takeFirstLiteral(
  String source,
  List<String> candidates,
  void Function(String updated) apply,
) {
  for (final c in candidates) {
    final at = source.indexOf(c);
    if (at >= 0) {
      apply('${source.substring(0, at)} ${source.substring(at + c.length)}');
      return true;
    }
  }
  return false;
}

int _parseWeekdayChar(String ch) => switch (ch) {
  '一' => 1,
  '二' => 2,
  '三' => 3,
  '四' => 4,
  '五' => 5,
  '六' => 6,
  '日' || '天' => 7,
  _ => 1,
};

int? _parseCnInt(String raw) {
  final asDigits = int.tryParse(raw);
  if (asDigits != null) return asDigits;
  const digits = <String, int>{
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (digits.containsKey(raw)) return digits[raw];
  if (raw == '十') return 10;
  if (raw.startsWith('十') && raw.length == 2) {
    final tail = digits[raw.substring(1)];
    if (tail != null) return 10 + tail;
  }
  if (raw.endsWith('十') && raw.length == 2) {
    final head = digits[raw.substring(0, 1)];
    if (head != null) return head * 10;
  }
  if (raw.length == 3 && raw[1] == '十') {
    final head = digits[raw[0]];
    final tail = digits[raw[2]];
    if (head != null && tail != null) return head * 10 + tail;
  }
  return null;
}

/// 把正文变成 FTS 可稳定匹配的词串。
///
/// 每个汉字（含扩展区 Ext A / Ext B+）编成 `u` + 16 进制码点，
/// 单字符英文与数字也独立入词（覆盖 `A组`、`B方案`、`3楼`）。
String indexedText(String text) {
  final parts = <String>[];
  final word = StringBuffer();
  void flushWord() {
    if (word.isEmpty) return;
    parts.add(word.toString());
    word.clear();
  }

  for (final rune in text.runes) {
    if (isCjkRune(rune)) {
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

/// 整句短语。中文按字相邻匹配，适合「黄金眼」「B方案」这种连续说法。
String? ftsPhraseExpression(String text) {
  final indexed = indexedText(text);
  if (indexed.isEmpty) return null;
  return 'search_text : "$indexed"';
}

/// 短语落空时的宽松召回：同时组合 CJK 二字组 + 实义汉字单字（过滤虚词停用字）
/// + 英文/数字词元（含 1 字符如 A/B/3）+ CJK Ext B+，用 OR 交给 BM25 叠加排序。
///
/// 「陈总说的茶」因此能召回「老陈推荐喝茶」，且不会误召回仅有「说的」的无关对话。
String? ftsRelaxedExpression(String text) {
  final tokens = <String>{};
  final cjkRun = <int>[];
  final asciiRun = StringBuffer();

  void flushCjk() {
    if (cjkRun.isEmpty) return;
    if (cjkRun.length == 1) {
      final r = cjkRun.single;
      if (!isCjkStopUnigramRune(r)) {
        tokens.add('u${r.toRadixString(16)}');
      }
    } else {
      for (var i = 0; i + 1 < cjkRun.length; i++) {
        final r0 = cjkRun[i];
        final r1 = cjkRun[i + 1];
        if (isCjkParticleRune(r0) || isCjkParticleRune(r1)) continue;
        if (isCjkStopUnigramRune(r0) && isCjkStopUnigramRune(r1)) continue;
        tokens.add('u${r0.toRadixString(16)} u${r1.toRadixString(16)}');
      }
      for (final r in cjkRun) {
        if (!isCjkStopUnigramRune(r)) {
          tokens.add('u${r.toRadixString(16)}');
        }
      }
    }
    cjkRun.clear();
  }

  void flushAscii() {
    if (asciiRun.isEmpty) return;
    tokens.add(asciiRun.toString());
    asciiRun.clear();
  }

  for (final rune in text.runes) {
    if (isCjkRune(rune)) {
      flushAscii();
      cjkRun.add(rune);
    } else if (_isWordChar(rune)) {
      flushCjk();
      asciiRun.write(String.fromCharCode(rune).toLowerCase());
    } else {
      flushCjk();
      flushAscii();
    }
  }
  flushCjk();
  flushAscii();

  // 若整句全是极短高频字（如单搜一个字），兜底保留非标点码点避免完全无表达式
  if (tokens.isEmpty) {
    for (final rune in text.runes) {
      if (isCjkRune(rune) && !isCjkParticleRune(rune)) {
        tokens.add('u${rune.toRadixString(16)}');
      }
    }
  }

  if (tokens.isEmpty) return null;
  return tokens.map((token) => 'search_text : "$token"').join(' OR ');
}

/// 纯语法结构助词/语气词：会打断词语边界，不参与跨词 bigram 拼接（如「说的」「看的」）。
final Set<int> _cjkParticleRunes = {
  for (final r in '的了着过吗呢吧啊呀哦嗯呃哈嘛呗啦哇噢唉喂'.runes) r,
};

/// 单字检索停用字：过滤虚词、代词、高频口语汇报动词与疑问字，保留「陈」「茶」「酒」等实义单字。
final Set<int> _cjkStopUnigramRunes = {
  ..._cjkParticleRunes,
  for (final r
      in '是在有我你他她它咱们这那哪谁什怎么与及和或但而就都也还又再很太更最把被让给向往从到对跟同得地之个些说聊讲问看听查找做干去来要会能想可没不'
          .runes)
    r,
};

bool isCjkParticleRune(int rune) => _cjkParticleRunes.contains(rune);

bool isCjkStopUnigramRune(int rune) => _cjkStopUnigramRunes.contains(rune);

bool isCjkRune(int rune) =>
    (rune >= 0x3400 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x2ebef);

bool _isWordChar(int rune) =>
    (rune >= 0x30 && rune <= 0x39) ||
    (rune >= 0x41 && rune <= 0x5a) ||
    (rune >= 0x61 && rune <= 0x7a);
