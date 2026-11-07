/// 总结卡片（Action Card）模型 —— 状态机 pending → generating → done。
library;

enum SummaryState { pending, generating, done }

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

  SummaryCard({required this.id, required this.time, this.state = SummaryState.pending});

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
    return c;
  }
}
