import 'dart:typed_data';
import 'audio_decoder.dart';
import 'transcription_types.dart';

class PcmAudioSlice {
  final int sequence;
  final Duration start;
  final Duration end;
  final int sampleRate;
  final Uint8List pcm16;
  PcmAudioSlice({
    required this.sequence,
    required this.start,
    required this.end,
    required this.sampleRate,
    required Uint8List pcm16,
  }) : pcm16 = Uint8List.fromList(pcm16).asUnmodifiableView();
}

/// Feed B's continuous device ADPCM or PCM16 byte frames; persist returned
/// slices through C before invoking ASR. Frames and slice boundaries NEVER
/// reset the ADPCM predictor. A reconnect/new recording must create a new
/// slicer; do not silently join disconnected recordings.
class StreamingAudioSlicer {
  final int sampleRate;
  final Duration sliceDuration;
  final int maxFrameBytes;
  final CardAdpcmDecoder _adpcm = CardAdpcmDecoder();
  late final Uint8List _buffer;
  int _filled = 0;
  int _samplesEmitted = 0;
  int _sequence = 0;
  int? _danglingByte;
  bool _closed = false;
  AudioFileFormat? _format;

  StreamingAudioSlicer({
    this.sampleRate = 16000,
    this.sliceDuration = const Duration(seconds: 15),
    this.maxFrameBytes = 1024 * 1024,
  }) {
    if (!{8000, 16000}.contains(sampleRate) ||
        sliceDuration <= Duration.zero ||
        sliceDuration > const Duration(seconds: 30) ||
        maxFrameBytes < 1) {
      throw ArgumentError('音频流切片配置无效');
    }
    final samples = sliceDuration.inMicroseconds * sampleRate ~/ 1000000;
    if (samples < 1) {
      throw ArgumentError('切片不足一个音频样本');
    }
    _buffer = Uint8List(samples * 2);
  }

  List<PcmAudioSlice> addAdpcm(Uint8List frame) {
    _check(frame, AudioFileFormat.adpcm);
    final decoded = _adpcm.decode(frame);
    final bytes = Uint8List(decoded.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < decoded.length; i++) {
      data.setInt16(i * 2, decoded[i], Endian.little);
    }
    return _consume(bytes);
  }

  List<PcmAudioSlice> addPcm16(Uint8List frame) {
    _check(frame, AudioFileFormat.pcm16);
    return _consume(frame);
  }

  void _check(Uint8List frame, AudioFileFormat format) {
    if (_closed) {
      throw const TranscriptionException('closed', '流式切片器已结束');
    }
    if (frame.length > maxFrameBytes) {
      throw const TranscriptionException('audio_limit', '单帧音频超过缓冲限额');
    }
    if (_format != null && _format != format) {
      throw const TranscriptionException('audio_format', '不能在同一录音流混用ADPCM/PCM');
    }
    _format = format;
  }

  List<PcmAudioSlice> _consume(Uint8List bytes) {
    final slices = <PcmAudioSlice>[];
    var offset = 0;
    if (_danglingByte != null && bytes.isNotEmpty) {
      _buffer[_filled++] = _danglingByte!;
      _buffer[_filled++] = bytes[offset++];
      _danglingByte = null;
      if (_filled == _buffer.length) {
        slices.add(_emit());
      }
    }
    final alignedEnd = bytes.length - ((bytes.length - offset) % 2);
    while (offset < alignedEnd) {
      final available = alignedEnd - offset;
      final count = available < _buffer.length - _filled
          ? available
          : _buffer.length - _filled;
      _buffer.setRange(_filled, _filled + count, bytes, offset);
      _filled += count;
      offset += count;
      if (_filled == _buffer.length) {
        slices.add(_emit());
      }
    }
    if (offset < bytes.length) {
      _danglingByte = bytes[offset];
    }
    return List.unmodifiable(slices);
  }

  /// Finish a recording. Never fabricates a missing byte at truncation.
  PcmAudioSlice? flush() {
    if (_closed) {
      return null;
    }
    if (_danglingByte != null) {
      throw const TranscriptionException('audio_corrupt', 'PCM音频流截断半个样本');
    }
    _closed = true;
    return _filled == 0 ? null : _emit();
  }

  PcmAudioSlice _emit() {
    final samples = _filled ~/ 2;
    final start = Duration(
      microseconds: _samplesEmitted * 1000000 ~/ sampleRate,
    );
    _samplesEmitted += samples;
    final result = PcmAudioSlice(
      sequence: _sequence++,
      start: start,
      end: Duration(microseconds: _samplesEmitted * 1000000 ~/ sampleRate),
      sampleRate: sampleRate,
      pcm16: Uint8List.sublistView(_buffer, 0, _filled),
    );
    _filled = 0;
    return result;
  }
}
