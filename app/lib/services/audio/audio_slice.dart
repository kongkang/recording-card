/// 音频切片实体与来源接缝。
///
/// 录音卡按顺序上传小片段（ADPCM / PCM16 / WAV），每片带会话内序号与相对
/// 时间；仓库只持久化元数据，[bytes] 在写入时交给 blob store。
library;

import 'dart:convert';
import 'dart:typed_data';

enum AudioSliceFormat { adpcm, pcm16, wav }

/// 一段录音切片。字段只读，[bytes] 构造时防御性拷贝并加不可变视图，
/// 防止调用方在入仓后改动音频。
class AudioSlice {
  AudioSlice({
    required this.id,
    required this.sessionId,
    required this.seq,
    required this.startMs,
    required this.endMs,
    required Uint8List bytes,
    this.format = AudioSliceFormat.adpcm,
    this.sampleRate,
    this.mark,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final String id;

  /// 一次连续录音（会话）的标识；重启录音卡后可能变化。
  final String sessionId;

  /// 会话内序号，从 0 开始递增，用于去重与排序兜底。
  final int seq;

  /// 相对会话起点的毫秒偏移。
  final int startMs;
  final int endMs;

  /// 音频本体；恢复自索引的切片为空，需经 AudioBlobStore 读取。
  final Uint8List bytes;

  final AudioSliceFormat format;

  /// 采样率（Hz），未知为 null。
  final int? sampleRate;

  /// 用户标记（如「重点」），无标记为 null。
  final String? mark;

  int get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'seq': seq,
        'startMs': startMs,
        'endMs': endMs,
        'bytes': base64Encode(bytes),
        'format': format.name,
        'sampleRate': sampleRate,
        'mark': mark,
      };

  /// 容错解析：缺字段 / 坏类型 / 损坏 base64 均回落到安全默认值，
  /// 不因单个切片异常拖垮整批拉取。
  factory AudioSlice.fromJson(Map<String, dynamic> json) {
    final rawBytes = json['bytes'];
    var bytes = Uint8List(0);
    if (rawBytes is String && rawBytes.isNotEmpty) {
      try {
        bytes = base64Decode(rawBytes);
      } catch (_) {
        // 损坏的 base64 按空音频处理
      }
    }
    return AudioSlice(
      id: _stringOf(json['id']),
      sessionId: _stringOf(json['sessionId']),
      seq: _intOf(json['seq']),
      startMs: _intOf(json['startMs']),
      endMs: _intOf(json['endMs']),
      bytes: bytes,
      format: _formatOf(json['format']),
      sampleRate: _nullableIntOf(json['sampleRate']),
      mark: _nullableStringOf(json['mark']),
    );
  }
}

/// 切片来源接缝 —— 真实实现后续接 card_bridge 做增量拉取。
abstract class AudioSliceSource {
  /// 拉取一批切片；[cursor] 为上一批最后一条 id，null 表示从头开始。
  Future<List<AudioSlice>> pull({String? cursor});
}

String _stringOf(Object? value) => value is String ? value : '';

int _intOf(Object? value) => value is num ? value.toInt() : 0;

int? _nullableIntOf(Object? value) => value is num ? value.toInt() : null;

String? _nullableStringOf(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

AudioSliceFormat _formatOf(Object? value) {
  if (value is AudioSliceFormat) return value;
  if (value is String) {
    final name = value.toLowerCase();
    for (final format in AudioSliceFormat.values) {
      if (format.name == name) return format;
    }
  }
  return AudioSliceFormat.adpcm;
}
