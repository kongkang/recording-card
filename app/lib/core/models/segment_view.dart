/// 分段详情视图 —— 一份数据三处展示的中间层：
/// Timeline 用 [SegmentRecord] 的摘要，详情页用同一份 turns/utterances/slices。
library;

import 'recording.dart';

class SegmentView {
  const SegmentView({
    required this.segment,
    required this.file,
    required this.turns,
    required this.utterances,
    required this.slices,
  });

  final SegmentRecord segment;
  final RecordingFile file;

  /// 润色后的对话（可能为空：未配置云端 / 润色失败时用 utterances 兜底）。
  final List<PolishedTurn> turns;

  /// 本地原始句（含时间、情绪、声纹簇）。
  final List<RawUtterance> utterances;

  /// 归属本段的切片（原始数据页按片分组）。
  final List<AudioSlice> slices;
}
