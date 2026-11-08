import 'dart:convert';

import 'sliding_window_service.dart';
import 'analysis_gateway.dart';

class TranscriptStage {
  final String id;
  final String recordId;
  final List<RawTranscriptChunk> chunks;
  final Duration start;
  final Duration end;
  final String reason;
  TranscriptStage({
    required this.id,
    required this.recordId,
    required List<RawTranscriptChunk> chunks,
    required this.start,
    required this.end,
    required this.reason,
  }) : chunks = List.unmodifiable(chunks);
  Map<String, dynamic> toJson() => {
    'id': id,
    'recordId': recordId,
    'chunkIds': chunks.map((c) => c.id).toList(),
    'startUs': start.inMicroseconds,
    'endUs': end.inMicroseconds,
    'reason': reason,
  };
}

/// The producer supplies actual VAD/recording-clock offsets, not wall-clock
/// timers. observeSilence is only valid after producer has confirmed no speech
/// through that offset. No audio-energy guess is made by this segmenter.
class StageSegmenter {
  final String recordId;
  final Duration silenceThreshold;
  final bool sealSourceGaps;
  final List<RawTranscriptChunk> _pending = [];
  final Map<String, String> _seen = {};
  final List<TranscriptStage> _stages = [];
  RawTranscriptChunk? _last;
  Duration _observedThrough = Duration.zero;
  StageSegmenter({
    required this.recordId,
    this.silenceThreshold = const Duration(seconds: 30),
    this.sealSourceGaps = true,
  }) {
    if (recordId.isEmpty || silenceThreshold <= Duration.zero) {
      throw ArgumentError('阶段配置无效');
    }
  }
  List<TranscriptStage> get stages => List.unmodifiable(_stages);

  Map<String, dynamic> toJson() => {
    'recordId': recordId,
    'seen': _seen,
    'pending': [for (final c in _pending) c.toJson()],
    'stages': [
      for (final s in _stages)
        {
          ...s.toJson(),
          'chunks': [for (final c in s.chunks) c.toJson()],
        },
    ],
    'last': _last?.toJson(),
    'observedThroughUs': _observedThrough.inMicroseconds,
  };

  void restoreSnapshot(Map<String, dynamic> json) {
    if (_seen.isNotEmpty || json['recordId'] != recordId) {
      throw const AnalysisException('stage_record', '阶段快照只能恢复到同录音的空服务');
    }
    RawTranscriptChunk chunk(dynamic j) =>
        RawTranscriptChunk.fromJson((j as Map).cast<String, dynamic>());
    final pending = [for (final j in json['pending'] as List) chunk(j)];
    final stages = [
      for (final j in json['stages'] as List)
        TranscriptStage(
          id: j['id'] as String,
          recordId: j['recordId'] as String,
          chunks: [for (final c in j['chunks'] as List) chunk(c)],
          start: Duration(microseconds: j['startUs'] as int),
          end: Duration(microseconds: j['endUs'] as int),
          reason: j['reason'] as String,
        ),
    ];
    if ([
      ...pending,
      for (final s in stages) ...s.chunks,
    ].any((c) => c.recordId != recordId)) {
      throw const AnalysisException('stage_record', '阶段快照包含跨录音来源');
    }
    _seen.addAll((json['seen'] as Map).cast<String, String>());
    _pending.addAll(pending);
    _stages.addAll(stages);
    _last = json['last'] == null ? null : chunk(json['last']);
    _observedThrough = Duration(microseconds: json['observedThroughUs'] as int);
  }

  /// Returns a stage sealed by a long gap before this new speech chunk, or null.
  TranscriptStage? addChunk(RawTranscriptChunk chunk) {
    if (chunk.recordId != recordId) {
      throw const AnalysisException('stage_record', '阶段不能混入其他录音');
    }
    if (_seen.containsKey(chunk.id)) {
      if (_seen[chunk.id] != jsonEncode(chunk.toJson())) {
        throw const AnalysisException('raw_immutable', '阶段片段ID不可改写原文');
      }
      return null;
    }
    if (chunk.start < _observedThrough ||
        (_last != null &&
            (chunk.start < _last!.end ||
                chunk.ordinal != _last!.ordinal + 1))) {
      throw const AnalysisException('chunk_order', '阶段片段时序无效或与已确认静音重叠');
    }
    TranscriptStage? sealed;
    if (sealSourceGaps &&
        _pending.isNotEmpty &&
        chunk.start - _pending.last.end >= silenceThreshold) {
      sealed = _seal('long_silence');
    }
    _seen[chunk.id] = jsonEncode(chunk.toJson());
    _pending.add(chunk);
    _last = chunk;
    return sealed;
  }

  TranscriptStage? observeSilence(Duration through) {
    if (through < _observedThrough ||
        through.isNegative ||
        (_last != null && through < _last!.end)) {
      throw const AnalysisException('silence_order', '静音观测时间不能倒退或早于已有语音');
    }
    _observedThrough = through;
    if (_pending.isNotEmpty &&
        through - _pending.last.end >= silenceThreshold) {
      return _seal('long_silence');
    }
    return null;
  }

  TranscriptStage? flush() =>
      _pending.isEmpty ? null : _seal('recording_stopped');

  TranscriptStage _seal(String reason) {
    final stage = TranscriptStage(
      id: '$recordId:stage:${_stages.length}',
      recordId: recordId,
      chunks: List.of(_pending),
      start: _pending.first.start,
      end: _pending.last.end,
      reason: reason,
    );
    _pending.clear();
    _stages.add(stage);
    return stage;
  }
}
