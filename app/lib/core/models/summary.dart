/// 总结卡片（Action Card）模型 —— 状态机 pending → generating → done。
library;

import 'dart:math' as math;

import '../../services/transcribe/utterance_builder.dart';
import 'record.dart';

enum SummaryState { pending, generating, done, failed }

/// 判断一条记录是否为纯静音占位卡片（无有效对话与原始转写，且标记为无语音/未识别到语音）。
bool isSilentPlaceholderEvent(RecordEvent e) {
  if (e.dialog.isNotEmpty || e.raw.isNotEmpty) return false;
  final spk = e.speakers.trim();
  final title = e.title.trim();
  return spk == '无语音' || title == '未识别到语音';
}

final RegExp _substantiveChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 去掉标点和模型标记后的实质字数。
int substantiveCharCount(String text) {
  final cleaned = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return _substantiveChar.allMatches(cleaned).length;
}

/// 时间轴不展示的记录：纯静音占位，或正文只有几个字、没有独立事实。
///
/// 有完整话题的短句（如「询问深圳晚间天气」）字数超过 4，会保留。
bool isFragmentRecord(RecordEvent e) {
  if (e.live) return false;
  if (e.id.startsWith('getnote-')) return false;
  if (isSilentPlaceholderEvent(e)) return true;
  final speech = <String>[
    for (final t in e.dialog) t.text,
    for (final t in e.raw) t.text,
  ].where((s) => s.trim().isNotEmpty).join();
  if (speech.isEmpty) {
    final fallback = '${e.title}\n${e.brief}\n${e.longText}';
    if (fallback.contains('没有识别到人声') || fallback.contains('未识别到语音')) {
      return true;
    }
    return substantiveCharCount(fallback) <= 4;
  }
  return substantiveCharCount(speech) <= 4;
}

/// 解析形如 `14:20—14:35`、`14:20—14:35 · 15m`、`14:20 · 18分40秒`、`14:20 · 15m` 的起止日内秒数区间。
(int, int)? parseSourceClockWindow(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  int clockToSec(RegExpMatch m, {required bool end}) {
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    final sec = m.group(3) != null
        ? (int.tryParse(m.group(3)!) ?? 0)
        : (end ? 59 : 0);
    return h * 3600 + min * 60 + sec;
  }

  // 1) 显式起止时钟区间（如 "14:20—14:35"、"14:20—14:35 · 15m"、"来源 14:20—14:38"）
  final rangeMatch = RegExp(
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(?:[—–\-~]|至|to)\s*(\d{1,2}):(\d{2})(?::(\d{2}))?',
    caseSensitive: false,
  ).firstMatch(text);
  if (rangeMatch != null) {
    final h1 = int.tryParse(rangeMatch.group(1)!) ?? 0;
    final m1 = int.tryParse(rangeMatch.group(2)!) ?? 0;
    final s1 = int.tryParse(rangeMatch.group(3) ?? '0') ?? 0;
    final h2 = int.tryParse(rangeMatch.group(4)!) ?? 0;
    final m2 = int.tryParse(rangeMatch.group(5)!) ?? 0;
    final s2 = rangeMatch.group(6) != null
        ? (int.tryParse(rangeMatch.group(6)!) ?? 0)
        : 59;
    final startSec = h1 * 3600 + m1 * 60 + s1;
    var endSec = h2 * 3600 + m2 * 60 + s2;
    if (endSec < startSec) endSec += 86400;
    return (startSec, endSec);
  }

  // 2) 兼容两个独立时钟串的情况
  final clocks = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').allMatches(text).toList();
  if (clocks.isEmpty) return null;
  if (clocks.length >= 2) {
    final startSec = clockToSec(clocks[0], end: false);
    var endSec = clockToSec(clocks[1], end: true);
    if (endSec < startSec) endSec += 86400;
    return (startSec, endSec);
  }

  // 3) 起始时钟 + 时长描述（如 "14:20 · 18分40秒"、"14:20 · 15m"、"14:20 · 1小时5分"）
  final firstClock = clocks.first;
  final startSec = clockToSec(firstClock, end: false);
  final hasStartSec = firstClock.group(3) != null;
  final tail = text.substring(firstClock.end);
  final durSec = parseDurationSeconds(tail);
  if (durSec == null || durSec <= 0) return null;

  final rawEnd = startSec + durSec;
  // 若起始时间仅精确到分钟（HH:mm），将该结束分钟末尾（:59）纳入容差，防秒级截断漏图
  final endSec = hasStartSec
      ? rawEnd
      : math.max(rawEnd, (rawEnd ~/ 60) * 60 + 59);
  return (startSec, endSec);
}

/// 判断日内时钟秒数 [sec]（`0..86399`）是否落在 [window] 内；兼容跨零点窗口（`window.$2 >= 86400`）。
bool isClockSecondInWindow(int sec, (int, int) window) {
  if (sec >= window.$1 && sec <= window.$2) return true;
  if (window.$2 >= 86400) {
    final shifted = sec + 86400;
    if (shifted >= window.$1 && shifted <= window.$2) return true;
  }
  return false;
}

/// 解析中文或英文简写时长字符串为秒数（如 `18分40秒`、`15m`、`1小时05分`、`45s`）。
int? parseDurationSeconds(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  var total = 0;
  var matched = false;

  final hourMatch = RegExp(
    r'(\d+)\s*(?:小时|时|hours?|hrs?|h(?![a-z]))',
    caseSensitive: false,
  ).firstMatch(s);
  if (hourMatch != null) {
    total += (int.tryParse(hourMatch.group(1)!) ?? 0) * 3600;
    matched = true;
  }

  final minMatch = RegExp(
    r'(\d+)\s*(?:分钟|分|minutes?|mins?|m(?![a-z]))',
    caseSensitive: false,
  ).firstMatch(s);
  if (minMatch != null) {
    total += (int.tryParse(minMatch.group(1)!) ?? 0) * 60;
    matched = true;
  }

  final secMatch = RegExp(
    r'(\d+)\s*(?:秒钟?|seconds?|secs?|s(?![a-z]))',
    caseSensitive: false,
  ).firstMatch(s);
  if (secMatch != null) {
    total += int.tryParse(secMatch.group(1)!) ?? 0;
    matched = true;
  }

  return matched && total > 0 ? total : null;
}

/// 将记录按时间从早到晚排序（天数偏移大→小、同日时刻小→大）。
List<RecordEvent> sortEventsChronological(Iterable<RecordEvent> events) {
  final list = events.toList();
  int minutesOf(String hhmm) {
    final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(hhmm);
    if (m == null) return 0;
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    return h * 60 + min;
  }

  list.sort((a, b) {
    final dayCmp = b.dayOffset.compareTo(a.dayOffset);
    if (dayCmp != 0) return dayCmp;
    final minCmp = minutesOf(a.time).compareTo(minutesOf(b.time));
    if (minCmp != 0) return minCmp;
    return a.id.compareTo(b.id);
  });
  return list;
}

/// 清理句首及停顿中的常见口水词（仅作保真润色，不删改实义内容）。
///
/// 对仅有标点/标记而无实际语言内容（如孤立的 `"。"`）的片段返回空串，
/// 避免静音幻觉标点在润色后保留下来。
String cleanSpokenFillers(String raw) {
  var s = raw.trim();
  if (s.isEmpty || !isMeaningfulSpeechText(s)) return '';
  s = s.replaceAll(RegExp(r'[（(]\s*(?:静音|停顿)[^)）]*[)）]\s*'), '');
  s = s.replaceAll(
    RegExp(r'^(?:(?:嗯+|啊+|呃+|唉+|哦+|那个+|就是说|就是|然后呢)[，,、。\s]+)+'),
    '',
  );
  s = s.replaceAll(
    RegExp(r'(?<=[，,。！？\s])(?:嗯+|啊+|呃+|那个|就是说)[，,、\s]+'),
    '',
  );
  s = s.replaceAll(RegExp(r'[，,]{2,}'), '，').trim();
  s = s.replaceFirst(RegExp(r'^[，,、\s]+'), '').trim();
  if (!isMeaningfulSpeechText(s)) return '';
  return s;
}

String joinPolishedUtterances(String prev, String next) {
  if (prev.isEmpty) return next;
  if (next.isEmpty) return prev;
  final tail = prev[prev.length - 1];
  if ('。！？!?…；;'.contains(tail)) return '$prev$next';
  if ('，,、：:'.contains(tail)) return '$prev$next';
  final isAsciiTail = RegExp(r'[A-Za-z0-9]$').hasMatch(prev);
  final isAsciiHead = RegExp(r'^[A-Za-z0-9]').hasMatch(next);
  if (isAsciiTail || isAsciiHead) return '$prev $next';
  return '$prev，$next';
}

/// 按时间顺序拼接散落记录的润色全文（AI 返回缺失或回退渲染时复用）。
String stitchPolishedFullText(
  Iterable<RecordEvent> events, {
  String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
  String Function(RecordEvent event, int turnIndex, String rawSpeaker)?
  turnSpeakerResolver,
}) {
  final ordered = sortEventsChronological(
    events.where((e) => !isSilentPlaceholderEvent(e)),
  );
  if (ordered.isEmpty) return '';
  final blocks = <String>[];
  for (final e in ordered) {
    final turns = e.dialog.isNotEmpty ? e.dialog : e.raw;
    final paragraphs = <String>[];
    if (ordered.length > 1) {
      paragraphs.add('【${e.time} · ${e.title}】');
    }
    if (turns.isNotEmpty) {
      String? currentSpeaker;
      var currentText = '';
      void flush() {
        if (currentSpeaker == null || currentText.trim().isEmpty) return;
        paragraphs.add('$currentSpeaker：$currentText');
      }

      for (var ti = 0; ti < turns.length; ti++) {
        final t = turns[ti];
        final cleaned = cleanSpokenFillers(t.text);
        if (cleaned.isEmpty) continue;
        final resolvedSpk =
            (turnSpeakerResolver?.call(e, ti, t.spk) ??
                    speakerResolver?.call(e, t.spk) ??
                    t.spk)
                .trim();
        final spk = resolvedSpk.isEmpty ? '未区分' : resolvedSpk;
        if (spk == currentSpeaker) {
          currentText = joinPolishedUtterances(currentText, cleaned);
        } else {
          flush();
          currentSpeaker = spk;
          currentText = cleaned;
        }
      }
      flush();
    } else {
      final fallback = (e.longText.trim().isNotEmpty ? e.longText : e.brief)
          .trim();
      if (fallback.isNotEmpty) {
        paragraphs.add(fallback);
      }
    }
    if (paragraphs.length > (ordered.length > 1 ? 1 : 0)) {
      blocks.add(paragraphs.join('\n'));
    }
  }
  return blocks.join('\n\n').trim();
}

class SourceRef {
  final String eventId;
  final String label; // 记录标题
  final String range; // "14:20—14:27" 或 "14:20 · 18分40秒"
  const SourceRef(this.eventId, this.label, this.range);

  /// 解析当前溯源范围对应的日内秒数时间窗。
  (int, int)? get clockWindow => parseSourceClockWindow(range);
}

class InfoPoint {
  final String title;
  final String detail;
  final List<SourceRef> sources;
  const InfoPoint(this.title, this.detail, this.sources);
}

class MapBranch {
  final String name;
  final List<String> leaves;
  const MapBranch(this.name, this.leaves);
}

class SummaryCard {
  final String id;
  SummaryState state;
  String time; // 发起时刻 h:mm
  double progress = 0; // 0-100
  List<String> srcIds = const [];

  // done 后填充：
  String? title;
  String? subDesc; // 统计行
  String? overview;
  List<MapBranch> structure = const [];
  List<InfoPoint> points = const [];
  List<String> todos = const [];
  Set<int> checkedTodos = <int>{};
  String? srcDesc;
  String? markdown;
  String fullText = '';

  /// 生成失败时的可展示原因（failed 态使用；不编造成功内容）。
  String? error;

  /// 用户是否已主动取消生成中的任务。
  bool cancelled = false;

  SummaryCard({required this.id, required this.time, this.state = SummaryState.pending});

  /// 解析可用于展示/导出的全文：优先使用润色拼接全文并联动说话人标记；若为空则按时间顺序拼接来源记录。
  String resolvedFullText(
    List<RecordEvent> sourceEvents, {
    String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
    String Function(RecordEvent event, int turnIndex, String rawSpeaker)?
    turnSpeakerResolver,
    bool preferResolvedTurns = false,
    String Function(String text, List<RecordEvent> events)? aliasTextTransformer,
  }) {
    final stored = fullText.trim();
    if (stored.isNotEmpty && !preferResolvedTurns) {
      return aliasTextTransformer?.call(stored, sourceEvents) ?? stored;
    }
    return stitchPolishedFullText(
      sourceEvents,
      speakerResolver: speakerResolver,
      turnSpeakerResolver: turnSpeakerResolver,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time,
        'srcIds': srcIds,
        if (state == SummaryState.done) ...{
          'title': title,
          'subDesc': subDesc,
          'overview': overview,
          'structure': [
            for (final b in structure) {'name': b.name, 'leaves': b.leaves}
          ],
          'points': [
            for (final p in points)
              {
                't': p.title,
                'd': p.detail,
                'src': [
                  for (final s in p.sources) [s.eventId, s.label, s.range]
                ],
              }
          ],
          'todos': todos,
          if (checkedTodos.isNotEmpty)
            'doneTodos': (checkedTodos.toList()..sort()),
          'srcDesc': srcDesc,
          'md': markdown,
          if (fullText.trim().isNotEmpty) 'ft': fullText,
        }
      };

  static SummaryCard fromJson(Map<String, dynamic> j) {
    final c = SummaryCard(id: j['id'] as String, time: j['time'] as String)
      ..srcIds = (j['srcIds'] as List).cast<String>()
      ..state = SummaryState.done;
    c.title = j['title'] as String?;
    c.subDesc = j['subDesc'] as String?;
    c.overview = j['overview'] as String?;
    c.structure = [
      for (final b in (j['structure'] as List? ?? []))
        MapBranch(b['name'] as String, (b['leaves'] as List).cast<String>())
    ];
    c.points = [
      for (final p in (j['points'] as List? ?? []))
        InfoPoint(
          p['t'] as String,
          p['d'] as String,
          [
            for (final s in (p['src'] as List))
              SourceRef(s[0] as String, s[1] as String, s[2] as String)
          ],
        )
    ];
    c.todos = (j['todos'] as List? ?? []).cast<String>();
    c.checkedTodos = {
      for (final idx in (j['doneTodos'] as List? ?? const []))
        if (idx is num) idx.toInt(),
    };
    c.srcDesc = j['srcDesc'] as String?;
    c.markdown = j['md'] as String?;
    c.fullText = (j['ft'] as String?) ?? '';
    return c;
  }
}
