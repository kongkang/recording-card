/// 总结卡片模型。成功必须来自真实模型结果；旧构造/完成态 JSON 兼容。
library;

enum SummaryState { pending, generating, done, failed, cancelled }

enum SummaryStage {
  queued,
  preparing,
  generating,
  validating,
  completed,
  failed,
  cancelled,
}

class SourceRef {
  final String eventId;
  final String label;
  final String range;
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
  String time;
  double progress;
  List<String> srcIds = const [];
  SummaryStage stage;
  String? errorCode;
  String? errorMessage;
  bool retryable;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? modelId;
  List<String> uncertainties = const [];

  String? title;
  String? subDesc;
  String? overview;
  List<MapBranch> structure = const [];
  List<InfoPoint> points = const [];
  List<String> todos = const [];

  /// Same index as todos; sources are validated by AnalysisService.
  List<List<SourceRef>> todoSources = const [];

  /// Union of references actually used by points and todos.
  List<SourceRef> sources = const [];
  String? srcDesc;
  String? markdown;

  SummaryCard({
    required this.id,
    required this.time,
    this.state = SummaryState.pending,
    this.stage = SummaryStage.queued,
    this.progress = 0,
    this.errorCode,
    this.errorMessage,
    this.retryable = false,
    this.startedAt,
    this.finishedAt,
    this.modelId,
  });

  static List<String> _strings(dynamic v) =>
      v is List ? v.whereType<String>().toList() : <String>[];
  static List<dynamic> _refs(List<SourceRef> refs) => [
    for (final s in refs) [s.eventId, s.label, s.range],
  ];
  static List<SourceRef> _readRefs(dynamic value) => [
    for (final s in value is List ? value : const [])
      if (s is List && s.length == 3 && s.every((x) => x is String))
        SourceRef(s[0] as String, s[1] as String, s[2] as String),
  ];

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time,
    'state': state.name,
    'stage': stage.name,
    'progress': progress,
    'srcIds': srcIds,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
    'retryable': retryable,
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'modelId': modelId,
    'uncertainties': uncertainties,
    'title': title,
    'subDesc': subDesc,
    'overview': overview,
    'structure': [
      for (final b in structure) {'name': b.name, 'leaves': b.leaves},
    ],
    'points': [
      for (final p in points)
        {'t': p.title, 'd': p.detail, 'src': _refs(p.sources)},
    ],
    'todos': todos,
    'todoSources': [for (final refs in todoSources) _refs(refs)],
    'sources': _refs(sources),
    'srcDesc': srcDesc,
    'md': markdown,
  };

  static SummaryCard fromJson(Map<String, dynamic> j) {
    // Legacy persisted cards did not contain a state and represented done cards.
    final state =
        SummaryState.values.where((s) => s.name == j['state']).firstOrNull ??
        (j.containsKey('title') ? SummaryState.done : SummaryState.pending);
    final c = SummaryCard(
      id: j['id'] as String,
      time: j['time'] as String,
      state: state,
      stage:
          SummaryStage.values.where((s) => s.name == j['stage']).firstOrNull ??
          (state == SummaryState.done
              ? SummaryStage.completed
              : SummaryStage.queued),
      progress:
          (j['progress'] as num?)?.toDouble() ??
          (state == SummaryState.done ? 100 : 0),
      errorCode: j['errorCode'] as String?,
      errorMessage: j['errorMessage'] as String?,
      retryable: j['retryable'] == true,
      startedAt: DateTime.tryParse(j['startedAt'] as String? ?? ''),
      finishedAt: DateTime.tryParse(j['finishedAt'] as String? ?? ''),
      modelId: j['modelId'] as String?,
    );
    c.srcIds = _strings(j['srcIds']);
    c.uncertainties = _strings(j['uncertainties']);
    c.title = j['title'] as String?;
    c.subDesc = j['subDesc'] as String?;
    c.overview = j['overview'] as String?;
    c.structure = [
      for (final b in (j['structure'] as List? ?? []))
        MapBranch(b['name'] as String, _strings(b['leaves'])),
    ];
    c.points = [
      for (final p in (j['points'] as List? ?? []))
        InfoPoint(p['t'] as String, p['d'] as String, _readRefs(p['src'])),
    ];
    c.todos = _strings(j['todos']);
    c.todoSources = [
      for (final refs in (j['todoSources'] as List? ?? [])) _readRefs(refs),
    ];
    c.sources = _readRefs(j['sources']);
    if (!j.containsKey('sources')) {
      c.sources = [for (final p in c.points) ...p.sources];
    }
    c.srcDesc = j['srcDesc'] as String?;
    c.markdown = j['md'] as String?;
    return c;
  }
}
