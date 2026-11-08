/// 最小 WAV 读写 —— 只处理录音卡转码后的格式：16 kHz / 16-bit / 单声道 PCM。
///
/// 为什么不用第三方库：这里只需要三件事——读头、按帧切、写头。自己实现可以
/// 保证切片是**字节级无损**的（直接在原始 PCM 字节上切，不重采样、不量化）。
library;

import 'dart:io';
import 'dart:typed_data';

/// 解析后的 WAV：保留原始字节，方便零拷贝切片。
class WavPcm {
  WavPcm({
    required this.bytes,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  final Uint8List bytes;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// `data` 块第一个采样字节的偏移。
  final int dataOffset;

  /// `data` 块的字节数。
  final int dataLength;

  int get bytesPerFrame => (bitsPerSample ~/ 8) * channels;

  int get frames => dataLength ~/ bytesPerFrame;

  int get durationMs => frames * 1000 ~/ sampleRate;

  bool get isMono16 => channels == 1 && bitsPerSample == 16;

  /// 转成 sherpa 需要的 [-1, 1] 浮点采样。
  Float32List toFloat32() {
    final count = frames;
    final out = Float32List(count);
    final data = ByteData.sublistView(bytes, dataOffset, dataOffset + dataLength);
    for (var i = 0; i < count; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// 按帧区间切出一个新的 WAV（含 44 字节头）。
  Uint8List sliceWav(int startFrame, int endFrame) {
    final total = frames;
    final start = startFrame.clamp(0, total);
    final end = endFrame.clamp(start, total);
    final byteStart = dataOffset + start * bytesPerFrame;
    final byteEnd = dataOffset + end * bytesPerFrame;
    return _buildWav(
      bytes.sublist(byteStart, byteEnd),
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
    );
  }
}

/// 解析 WAV 字节；格式不支持时抛 [FormatException]（带可读原因）。
WavPcm parseWav(Uint8List bytes) {
  if (bytes.length < 44) {
    throw const FormatException('WAV 文件过短，缺少头部');
  }
  final header = String.fromCharCodes(bytes.sublist(0, 4));
  final format = String.fromCharCodes(bytes.sublist(8, 12));
  if (header != 'RIFF' || format != 'WAVE') {
    throw const FormatException('不是 RIFF/WAVE 文件');
  }

  int? sampleRate;
  int? channels;
  int? bits;
  int? audioFormat;
  int? dataOffset;
  int? dataLength;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = ByteData.sublistView(
      bytes,
      offset + 4,
      offset + 8,
    ).getUint32(0, Endian.little);
    final body = offset + 8;
    if (body + size > bytes.length) {
      // 截断文件：按实际长度处理（录音传输中断时很常见），但只接受 data 块
      if (id != 'data') break;
    }
    final safeSize = (body + size <= bytes.length)
        ? size
        : (bytes.length - body).clamp(0, size);

    if (id == 'fmt ') {
      if (safeSize < 16) throw const FormatException('fmt 块过短');
      final view = ByteData.sublistView(bytes, body, body + 16);
      audioFormat = view.getUint16(0, Endian.little);
      channels = view.getUint16(2, Endian.little);
      sampleRate = view.getUint32(4, Endian.little);
      bits = view.getUint16(14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = safeSize;
    }

    // 块长度为奇数时有一个填充字节
    offset = body + safeSize + (safeSize.isOdd ? 1 : 0);
  }

  if (sampleRate == null || channels == null || bits == null) {
    throw const FormatException('WAV 缺少 fmt 块');
  }
  if (audioFormat != 1) {
    throw FormatException('只支持 PCM WAV（当前格式 $audioFormat）');
  }
  if (channels != 1 || bits != 16) {
    throw FormatException('只支持 16-bit 单声道（当前 $channels 声道 / $bits bit）');
  }
  if (dataOffset == null || dataLength == null) {
    throw const FormatException('WAV 缺少 data 块');
  }
  if (sampleRate != 16000) {
    // 模型只接受 16k；明确拒绝而不是悄悄重采样（重采样需要额外依赖）
    throw FormatException('采样率必须是 16000（当前 $sampleRate）');
  }

  return WavPcm(
    bytes: bytes,
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bits,
    dataOffset: dataOffset,
    dataLength: dataLength,
  );
}

/// 16-bit 单声道 PCM 浮点采样 → WAV 字节。
Uint8List encodeWav(Float32List samples, {int sampleRate = 16000}) {
  final pcm = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
    view.setInt16(i * 2, v, Endian.little);
  }
  return _buildWav(
    pcm,
    sampleRate: sampleRate,
    channels: 1,
    bitsPerSample: 16,
  );
}

/// 从文件读 WAV（同步 IO 只在后台 isolate 或小文件路径使用）。
WavPcm readWavFile(String path) => parseWav(File(path).readAsBytesSync());

Uint8List _buildWav(
  List<int> pcm, {
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
}) {
  const headerSize = 44;
  final out = Uint8List(headerSize + pcm.length);
  final view = ByteData.sublistView(out);
  final blockAlign = channels * bitsPerSample ~/ 8;
  final byteRate = sampleRate * blockAlign;

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      out[offset + i] = value.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, pcm.length, Endian.little);
  out.setAll(headerSize, pcm);
  return out;
}
