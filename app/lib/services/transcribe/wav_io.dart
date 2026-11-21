/// 最小 WAV 读写 —— 只处理录音卡转码后的格式：16 kHz / 16-bit / 单声道 PCM。
///
/// 为什么不用第三方库：这里只需要三件事——读头、按帧切、写头。自己实现可以
/// 保证切片是**字节级无损**的（直接在原始 PCM 字节上切，不重采样、不量化）。
library;

import 'dart:io';
import 'dart:math' as math;
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

  /// 面向 VAD / ASR / 声纹推理的预处理浮点采样：
  /// 1. 一阶高通去直流偏置（消除蓝牙实时 ADPCM 解码器预测器漂移导致的 +10000 级直流台阶）；
  /// 2. 基于 50ms 帧 95 分位 RMS 的噪声门控增益归一化（把远场低幅人声抬到模型工作区间，纯静音不放大）。
  Float32List toSpeechFloat32() =>
      conditionSpeechSamples(toFloat32(), sampleRate: sampleRate);

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

/// 仅读取 WAV 头部（最多 512 字节）以获取真实时长（毫秒），不把整段 PCM 读入内存。
int? readWavDurationMsSync(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    final length = file.lengthSync();
    if (length < 44) return null;
    final raf = file.openSync();
    try {
      final headLen = math.min(length, 512);
      final head = raf.readSync(headLen);
      if (head.length < 44) return null;
      if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') {
        return null;
      }
      int? byteRate;
      int? dataBytes;
      var offset = 12;
      while (offset + 8 <= head.length) {
        final id = String.fromCharCodes(head.sublist(offset, offset + 4));
        final size = ByteData.sublistView(
          head,
          offset + 4,
          offset + 8,
        ).getUint32(0, Endian.little);
        final body = offset + 8;
        if (id == 'fmt ' && body + 16 <= head.length) {
          final view = ByteData.sublistView(head, body, body + 16);
          byteRate = view.getUint32(8, Endian.little);
        } else if (id == 'data') {
          final available = (length - body).clamp(0, length);
          dataBytes = size <= available ? size : available;
          break;
        }
        offset = body + size + (size.isOdd ? 1 : 0);
      }
      if (byteRate == null || byteRate <= 0) return null;
      final pcmBytes = dataBytes ?? (length - 44).clamp(0, length);
      return (pcmBytes * 1000) ~/ byteRate;
    } finally {
      raf.closeSync();
    }
  } on Object {
    return null;
  }
}

/// 异步封装，语义同 [readWavDurationMsSync]。
Future<int?> readWavDurationMs(String path) async => readWavDurationMsSync(path);

final Expando<bool> _conditionedTag = Expando<bool>('rcConditionedSpeech');

/// 判断一段采样是否需要高通去直流或音量抬升（若无需改动，系统内置引擎可直接消费原切片 WAV 路径）。
bool needsSignalConditioning(
  Float32List raw, {
  int sampleRate = 16000,
}) {
  if (raw.isEmpty || _conditionedTag[raw] == true) return false;
  var sum = 0.0;
  for (var i = 0; i < raw.length; i++) {
    sum += raw[i];
  }
  final dcMean = sum / raw.length;
  if (dcMean.abs() >= 0.005) return true;

  final p95Rms = _percentile95FrameRms(raw, sampleRate: sampleRate);
  const speechGateRms = 0.00085;
  if (p95Rms < speechGateRms) return false;
  const targetP95Rms = 0.065;
  final gain = (targetP95Rms / p95Rms).clamp(1.0, 10.0);
  return gain > 1.02;
}

/// 一阶高通去直流（截止频率约 12.7 Hz @ 16kHz）+ 噪声门控语音增益归一化。
///
/// 解决真机实测发现的两类硬件实时流信号问题：
/// - IMA-ADPCM 实时流预测器漂移后会产生约 +10000（+0.305）的恒定直流偏置，
///   扬声器交流耦合回听正常，但 Silero VAD 在大幅直流偏置下完全失明；
/// - 佩戴距离较远时有效交流峰值仅 500~950（约 -32 dBFS），而底噪仅 10~12（约 -69 dBFS），
///   按 50ms 帧 95 分位 RMS 抬升增益可避免单样本脉冲干扰，同时对极低能量微弱环境摩擦音限制最大增益，
///   彻底杜绝底噪放大 24x 引发 SenseVoice 幻觉。
Float32List conditionSpeechSamples(
  Float32List raw, {
  int sampleRate = 16000,
}) {
  final n = raw.length;
  if (n == 0 || _conditionedTag[raw] == true) return raw;

  final hp = Float32List(n);
  var prevX = raw[0].toDouble();
  var y = 0.0;
  for (var i = 0; i < n; i++) {
    final x = raw[i].toDouble();
    y = (x - prevX) + 0.995 * y;
    prevX = x;
    hp[i] = y.clamp(-1.0, 1.0);
  }

  final p95Rms = _percentile95FrameRms(hp, sampleRate: sampleRate);
  // 蓝牙流纯静音底噪 p95Rms ≈ 0.00035~0.00045；低于门限视为静音，不施加放大避免幻觉
  const speechGateRms = 0.00085;
  if (p95Rms < speechGateRms) {
    _conditionedTag[hp] = true;
    return hp;
  }

  // 对极微弱环境响动（衣服摩擦/空调底噪，0.00085..0.005）采用渐进软膝盖上限（2x..10x），
  // 防止把 -56 dBFS 的环境微弱沙沙声暴力放大 24x 触发 SenseVoice 幻觉；真实远场语音上限 10x。
  const targetP95Rms = 0.065;
  final ramp = ((p95Rms - speechGateRms) / (0.005 - speechGateRms)).clamp(
    0.0,
    1.0,
  );
  final maxAllowedGain = 2.0 + 8.0 * ramp; // 2.0x .. 10.0x
  final gain = (targetP95Rms / p95Rms).clamp(1.0, maxAllowedGain);
  if (gain <= 1.02) {
    _conditionedTag[hp] = true;
    return hp;
  }

  for (var i = 0; i < n; i++) {
    final v = hp[i] * gain;
    // 超过 ±0.80 进入平滑软限幅，防止偶发 ADPCM 台阶尖峰硬削顶爆音
    if (v > 0.80) {
      final excess = v - 0.80;
      hp[i] = (0.80 + 0.18 * (excess / (0.18 + excess))).clamp(-0.98, 0.98);
    } else if (v < -0.80) {
      final excess = -v - 0.80;
      hp[i] = -(0.80 + 0.18 * (excess / (0.18 + excess))).clamp(-0.98, 0.98);
    } else {
      hp[i] = v;
    }
  }
  _conditionedTag[hp] = true;
  return hp;
}

/// 判断一段采样在去直流后是否包含明显高于硬件底噪的声学活动（用于 VAD 漏检兜底）。
bool hasAcousticSpeechCandidate(
  Float32List raw, {
  int sampleRate = 16000,
}) {
  final n = raw.length;
  if (n < sampleRate ~/ 4) return false;
  final hp = Float32List(n);
  var rawSum = 0.0;
  var prevX = raw[0].toDouble();
  var y = 0.0;
  for (var i = 0; i < n; i++) {
    final x = raw[i].toDouble();
    rawSum += x;
    y = (x - prevX) + 0.995 * y;
    prevX = x;
    hp[i] = y;
  }
  final dcMean = (rawSum / n).abs();
  final window = math.max(160, sampleRate ~/ 20); // 50ms
  var activeFrames = 0;
  final rmsList = <double>[];
  for (var start = 0; start < n; start += window) {
    final end = math.min(n, start + window);
    final len = end - start;
    if (len <= 0) continue;
    var sumSq = 0.0;
    for (var i = start; i < end; i++) {
      final s = hp[i];
      sumSq += s * s;
    }
    final rms = math.sqrt(sumSq / len);
    rmsList.add(rms);
    if (rms >= 0.00085) activeFrames++;
  }
  if (rmsList.isEmpty || activeFrames < 3) return false;
  rmsList.sort();
  final p10 = rmsList[((rmsList.length - 1) * 0.10).floor()];
  final p95 = rmsList[((rmsList.length - 1) * 0.95).floor()];
  if (p95 < 0.00085) return false;
  // 排除无直流偏置且 100% 恒幅无包络起伏的低幅稳态底噪/测试载波（p95 < 0.010 且无调制）
  if (dcMean < 0.02 && p95 < 0.010 && p95 <= p10 * 1.08) {
    return false;
  }
  return true;
}

double _percentile95FrameRms(Float32List samples, {required int sampleRate}) {
  final n = samples.length;
  if (n == 0) return 0;
  final window = math.max(160, sampleRate ~/ 20); // 50ms
  final rmsList = <double>[];
  for (var start = 0; start < n; start += window) {
    final end = math.min(n, start + window);
    final len = end - start;
    if (len <= 0) continue;
    var sumSq = 0.0;
    for (var i = start; i < end; i++) {
      final s = samples[i];
      sumSq += s * s;
    }
    rmsList.add(math.sqrt(sumSq / len));
  }
  if (rmsList.isEmpty) return 0;
  rmsList.sort();
  final idx = ((rmsList.length - 1) * 0.95).floor();
  return rmsList[idx];
}

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
