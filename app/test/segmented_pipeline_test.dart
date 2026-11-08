// 分段转写管线验收（TDD）—— WAV 切片 → 逐片 ASR → 滑动窗口润色 →
// 阶段总结；自动转录关闭不调用 ASR；单片失败不拖垮整段。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/services/analysis/incremental_refine.dart';
import 'package:recording_card/services/analysis/live_analysis_pipeline.dart';
import 'package:recording_card/services/analysis/staged_summary.dart';
import 'package:recording_card/services/audio/wav_splitter.dart';
import 'package:recording_card/services/transcription/segmented_transcription_pipeline.dart';
import 'package:recording_card/services/transcription/transcription.dart';
import 'package:recording_card/services/transcription/transcription_pipeline.dart';

Uint8List _wav(int samples) {
  const rate = 16000;
  const blockAlign = 2;
  final dataLen = samples * blockAlign;
  final bytes = Uint8List(44 + dataLen);
  final bd = ByteData.sublistView(bytes);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[off + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, rate, Endian.little);
  bd.setUint32(28, rate * blockAlign, Endian.little);
  bd.setUint16(32, blockAlign, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, dataLen, Endian.little);
  return bytes;
}

class _PerCallAsr implements TranscriptionService {
  _PerCallAsr({this.failAt});

  final int? failAt;
  int calls = 0;

  @override
  Future<TranscriptResult> transcribe(Uint8List audio, {String? language}) async {
    calls++;
    if (failAt == calls) throw const TranscriptionUnavailable('ASR 超时');
    final n = calls;
    return TranscriptResult(
      rawText: '原始 $n',
      cleanText: '清洗 $n',
      language: language,
    );
  }
}

class _Refiner implements SegmentRefiner {
  @override
  Future<List<RefinedSegment>> refine(List<RefineSegmentInput> window) async => [
        for (final s in window)
          RefinedSegment(
            id: s.id,
            cleanText: '润色:${s.rawText}',
            speaker: s.speaker,
          ),
      ];
}

class _Summarizer implements EventSummarizer {
  @override
  Future<EventSummary> summarize(
    List<SummarySegmentInput> segments, {
    EventSummary? previousEvent,
  }) async =>
      EventSummary(
        id: 'event-${segments.first.id}',
        startMs: segments.first.startMs,
        endMs: segments.last.endMs,
        title: '事件',
        overview: segments.map((s) => s.cleanText).join(' / '),
        segmentIds: [for (final s in segments) s.id],
      );
}

SegmentedTranscriptionPipeline _pipeline(
  TranscriptionService asr,
  SettingsStore settings,
) =>
    SegmentedTranscriptionPipeline(
      splitter: const WavSplitter(),
      transcription:
          TranscriptionPipeline(service: asr, settings: settings),
      analysis: LiveAnalysisPipeline(
        refine: IncrementalRefineCoordinator(refiner: _Refiner()),
        summary: StagedSummaryCoordinator(
          summarizer: _Summarizer(),
          silenceGap: const Duration(seconds: 3),
        ),
      ),
      segment: const Duration(milliseconds: 400),
    );

void main() {
  test('三段音频 → 三段转写 → 润色 → 一个事件', () async {
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    final asr = _PerCallAsr();
    final result = await _pipeline(asr, settings)
        .process(_wav(16000), recordingId: 'r1');

    expect(asr.calls, 3);
    expect(result.segments, hasLength(3));
    expect(result.segments.map((s) => s.rawText), ['原始 1', '原始 2', '原始 3']);
    expect(result.segments.map((s) => s.cleanText),
        ['润色:原始 1', '润色:原始 2', '润色:原始 3']);
    expect(result.events.single.segmentIds, ['r1-0', 'r1-1', 'r1-2']);
    expect(result.error, isNull);
  });

  test('自动转录关闭：不调用 ASR，返回空结果', () async {
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    await settings.setValue('rc.set.trans.auto', false);
    final asr = _PerCallAsr();
    final result = await _pipeline(asr, settings)
        .process(_wav(16000), recordingId: 'r1');

    expect(asr.calls, 0);
    expect(result.segments, isEmpty);
    expect(result.events, isEmpty);
    expect(result.skipped, isTrue);
  });

  test('单片 ASR 失败：记录错误但继续其他片', () async {
    final settings = SettingsStore(store: InMemoryStore());
    addTearDown(settings.dispose);
    final asr = _PerCallAsr(failAt: 2);
    final result = await _pipeline(asr, settings)
        .process(_wav(16000), recordingId: 'r1');

    expect(asr.calls, 3);
    expect(result.segments, hasLength(2));
    expect(result.errors, hasLength(1));
    expect(result.errors.single, contains('ASR 超时'));
    expect(result.segments.map((s) => s.id), ['r1-0', 'r1-2']);
  });
}
