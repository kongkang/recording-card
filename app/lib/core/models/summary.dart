/// 总结卡片（Action Card）模型 —— 状态机 pending → generating → done。
library;

import 'record.dart';

enum SummaryState { pending, generating, done, failed }

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
String cleanSpokenFillers(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
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
  return s.isEmpty ? raw.trim() : s;
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
  final ordered = sortEventsChronological(events);
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
  final String range; // "14:20—14:27"
  const SourceRef(this.eventId, this.label, this.range);
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
  String? srcDesc;
  String? markdown;
  String fullText = '';

  /// 生成失败时的可展示原因（failed 态使用；不编造成功内容）。
  String? error;

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
    c.srcDesc = j['srcDesc'] as String?;
    c.markdown = j['md'] as String?;
    c.fullText = (j['ft'] as String?) ?? '';
    return c;
  }
}
