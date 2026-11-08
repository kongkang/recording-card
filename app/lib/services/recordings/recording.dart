/// 录音实体 —— 一条录音对应一次事件/话题，保留原始转写、清洗文本与说话人分段。
library;

class SpeakerTurn {
  const SpeakerTurn({
    required this.speaker,
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String speaker;
  final String text;
  final int startMs;
  final int endMs;

  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
      };

  factory SpeakerTurn.fromJson(Map<String, dynamic> json) => SpeakerTurn(
        speaker: json['speaker'] as String? ?? '未知',
        text: json['text'] as String? ?? '',
        startMs: (json['startMs'] as num?)?.toInt() ?? 0,
        endMs: (json['endMs'] as num?)?.toInt() ?? 0,
      );
}

class Recording {
  const Recording({
    required this.id,
    required this.title,
    required this.recordedAt,
    required this.durationMs,
    this.rawTranscript,
    this.cleanTranscript,
    this.mark,
    this.remoteFileId,
    this.turns = const [],
  });

  final String id;
  final String title;
  final DateTime recordedAt;
  final int durationMs;
  final String? rawTranscript;
  final String? cleanTranscript;
  final String? mark;
  final String? remoteFileId;
  final List<SpeakerTurn> turns;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'recordedAt': recordedAt.toIso8601String(),
        'durationMs': durationMs,
        'rawTranscript': rawTranscript,
        'cleanTranscript': cleanTranscript,
        'mark': mark,
        'remoteFileId': remoteFileId,
        'turns': [for (final t in turns) t.toJson()],
      };

  /// 容错解析：缺字段给默认值，损坏字段忽略而不是整条丢弃。
  factory Recording.fromJson(Map<String, dynamic> json) {
    final recordedAt =
        DateTime.tryParse(json['recordedAt'] as String? ?? '') ?? DateTime.now();
    final turns = <SpeakerTurn>[];
    final rawTurns = json['turns'];
    if (rawTurns is List) {
      for (final item in rawTurns) {
        if (item is Map<String, dynamic>) {
          turns.add(SpeakerTurn.fromJson(item));
        }
      }
    }
    return Recording(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      recordedAt: recordedAt,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      rawTranscript: json['rawTranscript'] as String?,
      cleanTranscript: json['cleanTranscript'] as String?,
      mark: json['mark'] as String?,
      remoteFileId: json['remoteFileId'] as String?,
      turns: turns,
    );
  }
}
