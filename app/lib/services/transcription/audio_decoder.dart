import 'dart:io';
import 'dart:typed_data';
import 'transcription_types.dart';

/// ReAI card firmware uses raw IMA ADPCM, low nibble first, predictor/index=0.
/// Not Microsoft WAV ADPCM: compressed WAV headers are explicitly rejected.
class CardAdpcmDecoder {
  int _predictor = 0;
  int _index = 0;
  static const _indexTable = [-1, -1, -1, -1, 2, 4, 6, 8];
  static const _steps = [
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    16,
    17,
    19,
    21,
    23,
    25,
    28,
    31,
    34,
    37,
    41,
    45,
    50,
    55,
    60,
    66,
    73,
    80,
    88,
    97,
    107,
    118,
    130,
    143,
    157,
    173,
    190,
    209,
    230,
    253,
    279,
    307,
    337,
    371,
    408,
    449,
    494,
    544,
    598,
    658,
    724,
    796,
    876,
    963,
    1060,
    1166,
    1282,
    1411,
    1552,
    1707,
    1878,
    2066,
    2272,
    2499,
    2749,
    3024,
    3327,
    3660,
    4026,
    4428,
    4871,
    5358,
    5894,
    6484,
    7132,
    7845,
    8630,
    9493,
    10442,
    11487,
    12635,
    13899,
    15289,
    16818,
    18500,
    20350,
    22385,
    24623,
    27086,
    29794,
    32767,
  ];
  void reset() {
    _predictor = 0;
    _index = 0;
  }

  Int16List decode(List<int> bytes) {
    final result = Int16List(bytes.length * 2);
    var offset = 0;
    for (final byte in bytes) {
      result[offset++] = _code(byte & 15);
      result[offset++] = _code((byte >> 4) & 15);
    }
    return result;
  }

  int _code(int code) {
    final step = _steps[_index];
    var difference = step >> 3;
    if ((code & 1) != 0) difference += step >> 2;
    if ((code & 2) != 0) difference += step >> 1;
    if ((code & 4) != 0) difference += step;
    _predictor = (_predictor + ((code & 8) != 0 ? -difference : difference))
        .clamp(-32768, 32767);
    _index = (_index + _indexTable[code & 7]).clamp(0, 88);
    return _predictor;
  }
}

class DecodedAudio {
  final Float32List samples;
  final int sampleRate;
  const DecodedAudio(this.samples, this.sampleRate);
  Duration get duration =>
      Duration(microseconds: samples.length * 1000000 ~/ sampleRate);
}

class AudioDecoder {
  static DecodedAudio readFile(
    AudioFileInput input,
    TranscriptionOptions options,
  ) {
    options.validate();
    final file = File(input.path);
    if (!file.existsSync()) {
      throw const TranscriptionException('audio_missing', '本地录音文件不存在');
    }
    final size = file.lengthSync();
    if (size <= 0) {
      throw const TranscriptionException('audio_empty', '录音文件为空');
    }
    if (size > options.maxFileBytes) {
      throw const TranscriptionException('audio_limit', '录音文件超过大小限额');
    }
    // Raw streams have predictable decoded duration; reject before allocation.
    if (input.format != AudioFileFormat.wav) {
      _checkRate(input.sampleRate);
      final count = input.format == AudioFileFormat.adpcm
          ? size * 2
          : size ~/ 2;
      _checkLength(count, input.sampleRate, options);
    }
    return decode(
      file.readAsBytesSync(),
      input.format,
      sampleRate: input.sampleRate,
      options: options,
    );
  }

  static DecodedAudio decode(
    Uint8List bytes,
    AudioFileFormat format, {
    int sampleRate = 16000,
    TranscriptionOptions options = const TranscriptionOptions(),
  }) {
    options.validate();
    if (bytes.isEmpty) {
      throw const TranscriptionException('audio_empty', '录音文件为空');
    }
    if (bytes.length > options.maxFileBytes) {
      throw const TranscriptionException('audio_limit', '录音文件超过大小限额');
    }
    if (format == AudioFileFormat.wav) {
      return _wav(bytes, options);
    }
    _checkRate(sampleRate);
    if (format == AudioFileFormat.adpcm) {
      _checkLength(bytes.length * 2, sampleRate, options);
      final pcm = CardAdpcmDecoder().decode(bytes);
      final samples = Float32List(pcm.length);
      for (var i = 0; i < pcm.length; i++) {
        samples[i] = pcm[i] / 32768.0;
      }
      return DecodedAudio(samples, sampleRate);
    }
    return _pcm(bytes, sampleRate, 1, options);
  }

  static DecodedAudio _pcm(
    Uint8List bytes,
    int rate,
    int channels,
    TranscriptionOptions options,
  ) {
    if (bytes.length % (2 * channels) != 0) {
      throw const TranscriptionException('audio_corrupt', 'PCM16长度未对齐');
    }
    final count = bytes.length ~/ (2 * channels);
    _checkLength(count, rate, options);
    final samples = Float32List(count);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < count; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += data.getInt16((i * channels + c) * 2, Endian.little);
      }
      samples[i] = sum / (32768.0 * channels);
    }
    return DecodedAudio(samples, rate);
  }

  static DecodedAudio _wav(Uint8List bytes, TranscriptionOptions options) {
    String tag(int offset) =>
        String.fromCharCodes(bytes.sublist(offset, offset + 4));
    void corrupt() =>
        throw const TranscriptionException('audio_corrupt', 'WAV头或数据损坏/截断');
    if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      corrupt();
    }
    final data = ByteData.sublistView(bytes);
    final limit = data.getUint32(4, Endian.little) + 8;
    if (limit > bytes.length || limit < 12) {
      corrupt();
    }
    int? rate, channels, dataStart, dataSize;
    var offset = 12;
    while (offset + 8 <= limit) {
      final size = data.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      if (start + size > limit) {
        corrupt();
      }
      if (tag(offset) == 'fmt ') {
        if (size < 16) {
          corrupt();
        }
        if (data.getUint16(start, Endian.little) != 1 ||
            data.getUint16(start + 14, Endian.little) != 16) {
          throw const TranscriptionException(
            'audio_format',
            '仅支持PCM16 WAV，压缩/浮点WAV请先转换',
          );
        }
        channels = data.getUint16(start + 2, Endian.little);
        rate = data.getUint32(start + 4, Endian.little);
        if (channels < 1 || channels > 2) {
          throw const TranscriptionException('audio_format', '仅支持单声道/双声道WAV');
        }
        if (data.getUint16(start + 12, Endian.little) != channels * 2 ||
            data.getUint32(start + 8, Endian.little) != rate * channels * 2) {
          corrupt();
        }
      } else if (tag(offset) == 'data') {
        if (dataStart != null) {
          corrupt();
        }
        dataStart = start;
        dataSize = size;
      }
      offset = start + size + (size.isOdd ? 1 : 0);
    }
    if (rate == null ||
        channels == null ||
        dataStart == null ||
        dataSize == null) {
      corrupt();
    }
    final actualRate = rate!;
    _checkRate(actualRate);
    return _pcm(
      Uint8List.sublistView(bytes, dataStart!, dataStart + dataSize!),
      actualRate,
      channels!,
      options,
    );
  }

  static void _checkRate(int rate) {
    if (rate != 8000 && rate != 16000) {
      throw const TranscriptionException(
        'audio_rate',
        '本地ASR支持8kHz/16kHz音频，请先重采样',
      );
    }
  }

  static void _checkLength(int count, int rate, TranscriptionOptions options) {
    if (count <= 0) {
      throw const TranscriptionException('audio_empty', '录音无PCM样本');
    }
    if (count * 1000000 ~/ rate > options.maxDuration.inMicroseconds) {
      throw const TranscriptionException('audio_limit', '录音超过本地ASR时长限额，请分段处理');
    }
  }
}
