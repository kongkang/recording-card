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
    this.mergedChildren = const [],
  });

  final SegmentRecord segment;
  final RecordingFile file;

  /// 润色后的对话（可能为空：未配置云端 / 润色失败时用 utterances 兜底）。
  final List<PolishedTurn> turns;

  /// 本地原始句（含时间、情绪、声纹簇）。
  final List<RawUtterance> utterances;

  /// 归属本段的切片（原始数据页按片分组）。
  final List<AudioSlice> slices;

  /// 若当前视图由连续多段无语音切片或 `< 30s` 停顿连续发言切片在投影层折叠合并而成，
  /// 保存按时间正序排列的全部原始子视图（供逐片原始 WAV 回听）；普通单段视图为空。
  final List<SegmentView> mergedChildren;

  /// 是否为多片聚合视图（无语音或 `< 30s` 连续语音）。
  bool get isMerged => mergedChildren.length > 1;

  /// 是否为连续无语音切片合并后的聚合视图（`N >= 2`）。
  bool get isMergedSilent =>
      isMerged && turns.isEmpty && utterances.isEmpty;

  /// 是否为 `< 30s` 停顿连续语音切片合并后的聚合视图（`N >= 2`）。
  bool get isMergedSpeech => isMerged && !isMergedSilent;

  /// 合并包含的底层分片数量（单段为 1）。
  int get mergedSliceCount => isMerged ? mergedChildren.length : 1;

  /// 本视图包含的全部底层分段 ID（单段为 `[segment.id]`，合并段为全部子分段 ID）。
  List<String> get constituentSegmentIds => isMerged
      ? [for (final c in mergedChildren) c.segment.id]
      : [segment.id];
}
