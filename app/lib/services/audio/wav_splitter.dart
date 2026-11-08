/// WAV 切片 —— 把录音卡转码出的 16k/mono PCM WAV 按时间窗口切成合法子 WAV，
/// 供逐片 ASR → 滑动窗口润色 → 阶段总结。
///
/// 只支持 PCM（audioFormat=1）；非 PCM/损坏/缺 chunk 一律抛
/// [WavFormatException]，不猜测格式。
library;

import 'dart:typed_data';

class WavFormatException implements Exception {
  const WavFormatException(this.message);

  final String message;

  @override
  String toString() => 'WavFormatException: $message';
}

class WavSegment {
  const WavSegment({
    required this.startMs,
    required this.endMs,
    required this.bytes,
  });

  final int startMs;
  final int endMs;
  final Uint8List bytes;
}

class WavSplitter {
  const WavSplitter();

  List<WavSegment> split(
    Uint8List wav, {
    Duration segment = const Duration(seconds: 30),
  }) {
    if (segment <= Duration.zero) {
      throw ArgumentError.value(segment, 'segment', '必须为正时长');
    }
    if (wav.length < 44) {
      throw const WavFormatException('文件过短');
    }
    final bd = ByteData.sublistView(wav);
    String tag(int offset) =>
        String.fromCharCodes(wav.sublist(offset, offset + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const WavFormatException('不是 RIFF/WAVE');
    }

    int? fmtOffset;
    int? fmtSize;
    int? dataOffset;
    int? dataSize;
    var offset = 12;
    while (offset + 8 <= wav.length) {
      final id = tag(offset);
      final size = bd.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (body + size > wav.length) {
        throw const WavFormatException('chunk 越界');
      }
      if (id == 'fmt ') {
        fmtOffset = body;
        fmtSize = size;
      } else if (id == 'data') {
        dataOffset = body;
        dataSize = size;
        break;
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    if (fmtOffset == null || fmtSize == null || fmtSize < 16) {
      throw const WavFormatException('缺少 fmt chunk');
    }
    if (dataOffset == null || dataSize == null) {
      throw const WavFormatException('缺少 data chunk');
    }

    final format = bd.getUint16(fmtOffset, Endian.little);
    final channels = bd.getUint16(fmtOffset + 2, Endian.little);
    final sampleRate = bd.getUint32(fmtOffset + 4, Endian.little);
    final byteRate = bd.getUint32(fmtOffset + 8, Endian.little);
    final blockAlign = bd.getUint16(fmtOffset + 12, Endian.little);
    final bits = bd.getUint16(fmtOffset + 14, Endian.little);
    if (format != 1 ||
        channels < 1 ||
        sampleRate <= 0 ||
        byteRate <= 0 ||
        blockAlign <= 0 ||
        bits <= 0) {
      throw const WavFormatException('仅支持有效 PCM 格式');
    }

    final available = dataSize.clamp(0, wav.length - dataOffset);
    if (available == 0) return const [];

    final maxBytes = segment.inMilliseconds * byteRate ~/ 1000;
    final segmentBytes = (maxBytes ~/ blockAlign) * blockAlign;
    if (segmentBytes <= 0) {
      throw WavFormatException('切片窗口小于一帧：${segment.inMilliseconds}ms');
    }

    final pieces = <WavSegment>[];
    var cursor = 0;
    while (cursor < available) {
      var length = segmentBytes;
      if (cursor + length > available) length = available - cursor;
      length = (length ~/ blockAlign) * blockAlign;
      if (length <= 0) break;
      final startMs = cursor * 1000 ~/ byteRate;
      final endMs = (cursor + length) * 1000 ~/ byteRate;
      pieces.add(WavSegment(
        startMs: startMs,
        endMs: endMs,
        bytes: _buildWav(
          wav,
          dataOffset + cursor,
          length,
          format: format,
          channels: channels,
          sampleRate: sampleRate,
          byteRate: byteRate,
          blockAlign: blockAlign,
          bits: bits,
        ),
      ));
      cursor += length;
    }
    return pieces;
  }

  Uint8List _buildWav(
    Uint8List source,
    int dataStart,
    int dataLength, {
    required int format,
    required int channels,
    required int sampleRate,
    required int byteRate,
    required int blockAlign,
    required int bits,
  }) {
    final out = Uint8List(44 + dataLength);
    final bd = ByteData.sublistView(out);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    bd.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, format, Endian.little);
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bits, Endian.little);
    ascii(36, 'data');
    bd.setUint32(40, dataLength, Endian.little);
    out.setRange(44, 44 + dataLength, source, dataStart);
    return out;
  }
}
