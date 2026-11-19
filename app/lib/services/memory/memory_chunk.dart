/// 本机记忆检索的一条可引用片段。
///
/// 只保存已经落在手机上的总结或转写文本，不包含音频和声纹向量。
library;

class MemoryChunk {
  const MemoryChunk({
    required this.id,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.body,
    required this.dayOffset,
    required this.timeLabel,
  });

  /// `summary:<id>` 或 `recording:<id>`。
  final String id;

  /// `summary` 或 `recording`。
  final String kind;
  final String sourceId;
  final String title;
  final String body;

  /// 相对今天的天数，0 = 今天。与 [RecordEvent.dayOffset] 一致。
  final int dayOffset;

  /// 记录上的钟点，如 `15:10`。
  final String timeLabel;
}

class MemoryHit {
  const MemoryHit({
    required this.chunkId,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.body,
    required this.snippet,
    required this.dayOffset,
    required this.timeLabel,
  });

  final String chunkId;
  final String kind;
  final String sourceId;
  final String title;
  final String body;
  final String snippet;
  final int dayOffset;
  final String timeLabel;

  String get dayLabel => memoryDayLabel(dayOffset);
}

String memoryDayLabel(int dayOffset) {
  if (dayOffset == 0) return '今天';
  if (dayOffset == 1) return '昨天';
  if (dayOffset == 2) return '前天';
  if (dayOffset > 2) return '$dayOffset天前';
  return '更早';
}
