/// 开发者回放：清掉上一轮 AI 整理，保留原始录音、本地 ASR 和音频文件，
/// 再按模拟切片窗口把已有转写重新送进清洗与分段。
///
/// 不重新解码音频，也不重跑本地 ASR。窗口只决定「到这个时刻为止，哪些已有切片/转写可见」，
/// 用来接近以后边录边洗的节奏。
library;

import '../../core/models/recording.dart';
import '../recordings/recording_store.dart';
import '../segment/fast_topic_segment_agent.dart';
import '../transcribe/utterance_builder.dart';

typedef ReplayWindowClean =
    Future<int> Function(
      List<RecordingFile> visible,
      int simulatedNowMs,
      bool sessionEnded,
    );

class CleaningReplayResult {
  const CleaningReplayResult({
    required this.files,
    required this.utterancesKept,
    required this.windowsRun,
    required this.cleanBatches,
    required this.audioPaths,
    this.note,
  });

  final int files;
  final int utterancesKept;
  final int windowsRun;
  final int cleanBatches;
  final List<String> audioPaths;
  final String? note;

  String get summary {
    final extra = note == null || note!.isEmpty ? '' : ' $note';
    if (windowsRun == 0) {
      return '已清掉上一轮 AI 整理，保留 $utterancesKept 条本地转写。没有可回放的语音。$extra'.trim();
    }
    return '已按窗口回放 $windowsRun 步，保留 $utterancesKept 条本地转写和 ${audioPaths.length} 个音频路径，'
            '云端实际清洗 $cleanBatches 批。旧的 AI 整理已丢弃。$extra'
        .trim();
  }
}

class CleaningReplayService {
  Future<CleaningReplayResult> run({
    required RecordingStore store,
    required TopicSegmentationStore topicStore,
    required int windowMinutes,
    ReplayWindowClean? cleanWindow,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('正在清掉上一轮 AI 整理…');
    await clearAiOrganization(store: store, topicStore: topicStore);
    final files = await store.loadAll(refresh: true);
    final audioPaths = <String>[
      for (final file in files) ..._audioPathsOf(file),
    ];
    final utterancesKept = files.fold<int>(
      0,
      (sum, file) => sum + file.utterances.length,
    );
    final windows = _windowEnds(files, windowMinutes);
    if (windows.isEmpty || cleanWindow == null) {
      onProgress?.call('AI 整理已清除');
      return CleaningReplayResult(
        files: files.length,
        utterancesKept: utterancesKept,
        windowsRun: 0,
        cleanBatches: 0,
        audioPaths: audioPaths,
        note: cleanWindow == null && windows.isNotEmpty ? '未挂清洗回调' : null,
      );
    }
    var batches = 0;
    for (var i = 0; i < windows.length; i++) {
      final simNow = windows[i];
      final isLast = i == windows.length - 1;
      onProgress?.call('回放 ${i + 1}/${windows.length} · 模拟到已有转写的这个时刻');
      final visible = [for (final file in files) maskRecording(file, simNow)];
      batches += await cleanWindow(visible, simNow, isLast);
    }
    onProgress?.call('回放完成，正在刷新时间轴');
    return CleaningReplayResult(
      files: files.length,
      utterancesKept: utterancesKept,
      windowsRun: windows.length,
      cleanBatches: batches,
      audioPaths: audioPaths,
    );
  }

  /// 删话题/滚动分段、云端润色 turn 和云端标题摘要。不删音频，不改本地 ASR 文本。
  Future<void> clearAiOrganization({
    required RecordingStore store,
    required TopicSegmentationStore topicStore,
  }) async {
    await topicStore.clear();
    final files = await store.loadAll(refresh: true);
    for (final file in files) {
      file.turns = const [];
      file.polishedThroughSlice = -1;
      file.polishStale = false;
      file.segments = [
        for (final segment in file.segments) _resetSegment(file, segment),
      ];
      await store.save(file);
    }
  }

  List<int> _windowEnds(List<RecordingFile> files, int windowMinutes) {
    int? earliest;
    int? latest;
    for (final file in files) {
      for (final utterance in file.utterances) {
        final start = file.startAtMs + utterance.startMs;
        final end = file.startAtMs + utterance.endMs;
        earliest = earliest == null || start < earliest ? start : earliest;
        latest = latest == null || end > latest ? end : latest;
      }
    }
    if (earliest == null || latest == null || latest <= earliest) {
      return const [];
    }
    final windowMs = (windowMinutes < 1 ? 1 : windowMinutes) * 60 * 1000;
    final ends = <int>[];
    var cursor = earliest;
    while (cursor < latest) {
      final next = cursor + windowMs;
      final sim = next > latest ? latest : next;
      if (sim <= cursor) break;
      ends.add(sim);
      cursor = sim;
    }
    return ends;
  }

  List<String> _audioPathsOf(RecordingFile file) => [
    if (file.wavPath != null && file.wavPath!.isNotEmpty) file.wavPath!,
    if (file.apmPath.isNotEmpty) file.apmPath,
    for (final slice in file.slices)
      if (slice.wavPath.isNotEmpty) slice.wavPath,
  ];
}

RecordingFile maskRecording(RecordingFile file, int simulatedNowMs) {
  final slices = [
    for (final slice in file.slices)
      if (file.startAtMs + slice.startMs < simulatedNowMs) slice,
  ];
  final sliceIds = {for (final slice in slices) slice.id};
  final utterances = [
    for (final utterance in file.utterances)
      if (file.startAtMs + utterance.startMs < simulatedNowMs &&
          (utterance.sliceId.isEmpty ||
              sliceIds.isEmpty ||
              sliceIds.contains(utterance.sliceId)))
        utterance,
  ];
  return RecordingFile(
    deviceName: file.deviceName,
    session: file.session,
    seq: file.seq,
    startAtMs: file.startAtMs,
    apmPath: file.apmPath,
    createdAtMs: file.createdAtMs,
    wavPath: file.wavPath,
    durationMs: file.durationMs,
    timeSynced: file.timeSynced,
    stage: file.stage,
    slices: slices,
    utterances: utterances,
    turns: const [],
    segments: file.segments,
    polishedThroughSlice: -1,
    error: file.error,
  );
}

SegmentRecord _resetSegment(RecordingFile file, SegmentRecord segment) {
  final startRel = segment.startAtMs - file.startAtMs;
  final rawEnd = segment.endAtMs ?? segment.startAtMs;
  final endRel = rawEnd - file.startAtMs;
  final limit = endRel <= startRel ? startRel + 1 : endRel;
  final text = [
    for (final utterance in file.utterances)
      if (utterance.endMs > startRel &&
          utterance.startMs < limit &&
          isMeaningfulSpeechText(utterance.text))
        utterance.text.trim(),
  ].join(' ');
  final silent = text.isEmpty;
  final title = silent ? '未识别到语音' : buildReadableFallbackTitle(text);
  final brief = silent
      ? '本段未检测到有效人声，原始录音已保存在本机。'
      : (text.length <= 68 ? text : '${text.substring(0, 68)}…');
  return SegmentRecord(
    id: segment.id,
    sessionId: segment.sessionId,
    index: segment.index,
    startAtMs: segment.startAtMs,
    endAtMs: segment.endAtMs,
    title: title,
    brief: brief,
    longText: silent ? brief : text,
    speakerLabels: segment.speakerLabels,
    speakerCount: segment.speakerCount,
    tags: segment.tags,
    status: segment.status,
    sliceIds: segment.sliceIds,
    turnIds: const [],
    mark: segment.mark,
    legacy: segment.legacy,
    polishStale: false,
    fallback: !silent,
  );
}
