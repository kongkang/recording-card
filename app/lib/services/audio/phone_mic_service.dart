/// 手机本机麦克风采集与实时 1 分钟 WAV 切片封口服务。
///
/// 两个核心场景：
/// 1. 未绑定/未连接录音卡时，直接在手机端独立开启「本机录音」；
/// 2. 硬件正在录音时确认升级固件，自动停掉硬件录音并无缝切到手机本机录音，
///    升级重连成功后再自动关掉本机录音，避免升级重启窗口期丢失录音内容。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'live_audio_recorder.dart';
import 'pcm_ring_buffer.dart';

enum PhoneMicPermission { granted, denied, notDetermined }

abstract interface class PhoneMicBackend {
  Future<PhoneMicPermission> checkPermission();
  Future<PhoneMicPermission> requestPermission();
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  });
  Future<void> stopCapture();
}

/// iOS 原生麦克风采集通道（`AVAudioEngine` → 16kHz 16-bit 单声道 PCM）。
class PlatformPhoneMicBackend implements PhoneMicBackend {
  PlatformPhoneMicBackend({
    MethodChannel channel = const MethodChannel(
      'com.reai.recordingcard/phone_mic',
    ),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handleIncoming);
  }

  final MethodChannel _channel;
  void Function(Uint8List)? _onPcm;
  void Function(String)? _onError;

  static PhoneMicPermission _parsePermission(String? raw) => switch (raw) {
    'granted' => PhoneMicPermission.granted,
    'notDetermined' => PhoneMicPermission.notDetermined,
    _ => PhoneMicPermission.denied,
  };

  Future<void> _handleIncoming(MethodCall call) async {
    switch (call.method) {
      case 'pcm':
        final args = call.arguments;
        if (args is Uint8List && args.isNotEmpty) {
          _onPcm?.call(args);
        }
      case 'error':
        final msg = '${call.arguments ?? '本机录音采集异常'}';
        _onError?.call(msg);
    }
  }

  @override
  Future<PhoneMicPermission> checkPermission() async {
    try {
      final raw = await _channel.invokeMethod<String>('status');
      return _parsePermission(raw);
    } on MissingPluginException {
      return PhoneMicPermission.denied;
    } on PlatformException {
      return PhoneMicPermission.denied;
    }
  }

  @override
  Future<PhoneMicPermission> requestPermission() async {
    try {
      final raw = await _channel.invokeMethod<String>('request');
      return _parsePermission(raw);
    } on MissingPluginException {
      return PhoneMicPermission.denied;
    } on PlatformException {
      return PhoneMicPermission.denied;
    }
  }

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    _onPcm = onPcm;
    _onError = onError;
    await _channel.invokeMethod<void>('start');
  }

  @override
  Future<void> stopCapture() async {
    _onPcm = null;
    _onError = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // ignore in test environments
    } on PlatformException {
      // best-effort stop
    }
  }
}

/// 将本机麦克风 16kHz 16-bit mono PCM 实时切为可配置窗口（默认 1 分钟）的标准 `.WAV` 切片。
class PhoneMicRecorder {
  PhoneMicRecorder({
    Duration sliceDuration = const Duration(minutes: 1),
    Future<Directory> Function()? sliceRootDir,
    DateTime Function()? clock,
  }) : _sliceDuration = sliceDuration >= const Duration(seconds: 1)
           ? sliceDuration
           : const Duration(seconds: 1),
       _sliceRootDir = sliceRootDir,
       _clock = clock ?? DateTime.now;

  static const int sampleRate = 16000;
  static const int bytesPerSample = 2;
  static const int bytesPerSecond = sampleRate * bytesPerSample;

  /// 手动下拉刷新最小切分阈值：至少累积 0.5 秒（16000 字节）才封口一片。
  static const int minManualFlushBytes = bytesPerSecond ~/ 2;

  Duration _sliceDuration;
  Duration get sliceDuration => _sliceDuration;

  /// 动态调整本机录音切片窗口（最小 1 秒）；若缩小时已超阈值则立即切分已满片段。
  void setSliceDuration(Duration next) {
    final normalized = next >= const Duration(seconds: 1)
        ? next
        : const Duration(seconds: 1);
    if (_sliceDuration == normalized) return;
    _sliceDuration = normalized;
    if (_running && !_disposed) {
      _slicer.flushIfExceeds(
        sliceDuration: _sliceDuration,
        sampleRate: sampleRate,
        onSliceFlush: (chunk) => _scheduleFlush(chunk, isFinal: false),
      );
    }
  }

  final Future<Directory> Function()? _sliceRootDir;
  final DateTime Function() _clock;

  /// 最近 120 秒本机麦实时音频内存环形缓冲，供侧边按钮按 `[startMs, endMs]` 截取。
  final PcmRingBuffer ringBuffer = PcmRingBuffer();

  final StreamController<LiveAudioSlice> _slices =
      StreamController<LiveAudioSlice>.broadcast();
  Stream<LiveAudioSlice> get slices => _slices.stream;

  bool _running = false;
  bool get isRunning => _running;

  String? _sessionId;
  int _sessionStartedAtMs = 0;
  int _sliceIndex = 0;
  int _sliceStartSamples = 0;
  final SoftBoundaryPcmSlicer _slicer = SoftBoundaryPcmSlicer();
  final List<int> _sliceMarksMs = <int>[];
  bool _disposed = false;
  Future<void> _writeChain = Future<void>.value();

  /// 等待当前已封口切片的异步落盘与广播流投递完成（仅供测试做确定性断言，不中断录音）。
  @visibleForTesting
  Future<void> get pendingSliceWrites async {
    await _writeChain;
    await Future<void>.microtask(() {});
  }

  Future<Directory> _resolveDir() async {
    if (_sliceRootDir != null) {
      final dir = await _sliceRootDir();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/recordings/live_phone_slices');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> start({DateTime? startedAt}) async {
    if (_disposed || _running) return;
    final now = startedAt ?? _clock();
    _sessionStartedAtMs = now.millisecondsSinceEpoch;
    _sessionId = 'phone-$_sessionStartedAtMs';
    _sliceIndex = 0;
    _sliceStartSamples = 0;
    _slicer.clear();
    _sliceMarksMs.clear();
    ringBuffer.clear();
    _running = true;
  }

  /// 记录一次当前本机录音切片内的物理/界面重点打点。
  void recordMark({int? timestampMs}) {
    if (!_running || _disposed) return;
    if (timestampMs != null) {
      _sliceMarksMs.add(timestampMs);
      return;
    }
    final relSamples = (_slicer.totalAlignedSamples - _sliceStartSamples).clamp(
      0,
      1 << 30,
    );
    _sliceMarksMs.add(relSamples * 1000 ~/ sampleRate);
  }

  void ingestPcm(Uint8List pcmBytes) {
    if (!_running || _disposed || pcmBytes.isEmpty) return;
    final aligned = _slicer.append(
      pcmBytes,
      sliceDuration: sliceDuration,
      sampleRate: sampleRate,
      onSliceFlush: (chunk) => _scheduleFlush(chunk, isFinal: false),
    );
    if (aligned.isNotEmpty) {
      ringBuffer.append(
        aligned,
        endTimestampMs: _clock().millisecondsSinceEpoch,
      );
    }
  }

  /// Timeline 下拉刷新触发：在**不停止**麦克风与灵动岛录音的前提下，
  /// 将当前已缓冲的尾部 PCM（`>= 0.5s`）立即封口为一片正式 `.WAV` 并投递转写。
  Future<bool> flushActiveSlice() async {
    if (!_running || _disposed) return false;
    if (_slicer.bufferedBytes < minManualFlushBytes) {
      await _writeChain;
      return false;
    }
    final chunk = _slicer.takeRemainingBytes(clearOddByte: false);
    if (chunk.length < minManualFlushBytes) {
      await _writeChain;
      return false;
    }
    _scheduleFlush(chunk, isFinal: false);
    await _writeChain;
    await Future<void>.microtask(() {});
    return true;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    final tail = _slicer.takeRemainingBytes(clearOddByte: true);
    if (tail.isNotEmpty) {
      _scheduleFlush(tail, isFinal: true);
    }
    await _writeChain;
    if (tail.isNotEmpty) {
      await Future<void>.microtask(() {});
    }
  }

  void _scheduleFlush(Uint8List pcm, {required bool isFinal}) {
    final sid = _sessionId ?? 'phone-${DateTime.now().millisecondsSinceEpoch}';
    final index = _sliceIndex++;
    final marks = _sliceMarksMs.isEmpty
        ? const <int>[]
        : List<int>.unmodifiable(_sliceMarksMs);
    _sliceMarksMs.clear();
    final samples = pcm.length ~/ bytesPerSample;
    final startAtMs =
        _sessionStartedAtMs + (_sliceStartSamples * 1000 ~/ sampleRate);
    _sliceStartSamples += samples;
    final nextStartAtMs =
        _sessionStartedAtMs + (_sliceStartSamples * 1000 ~/ sampleRate);
    final durationMs = (nextStartAtMs - startAtMs).clamp(
      1,
      sliceDuration.inMilliseconds * 2,
    );

    _writeChain = _writeChain.then((_) async {
      if (_disposed || pcm.isEmpty) return;
      final dir = await _resolveDir();
      final tag = sid.replaceFirst('phone-', '');
      final seq = (index + 1).toString().padLeft(4, '0');
      final sliceKey = 'LIVE_PHONE_${tag}_$seq.WAV';
      final partFile = File('${dir.path}/$sliceKey.part');
      final finalFile = File('${dir.path}/$sliceKey');
      final wavBytes = _encodeWav(pcm);
      await partFile.writeAsBytes(wavBytes, flush: true);
      await partFile.rename(finalFile.path);
      if (_disposed) return;
      _slices.add(
        LiveAudioSlice(
          sessionId: sid,
          sliceIndex: index,
          startAtMs: startAtMs,
          durationMs: durationMs,
          wavPath: finalFile.path,
          isFinal: isFinal,
          sliceKeyOverride: sliceKey,
          marksMs: marks,
        ),
      );
    }).catchError((Object e, StackTrace st) {
      debugPrint('[PhoneMicRecorder] flush slice failed: $e');
    });
  }

  static Uint8List _encodeWav(Uint8List pcm) {
    final dataLen = pcm.length;
    final totalLen = 44 + dataLen;
    final out = Uint8List(totalLen);
    final bd = ByteData.sublistView(out);
    out.setAll(0, const [0x52, 0x49, 0x46, 0x46]); // RIFF
    bd.setUint32(4, 36 + dataLen, Endian.little);
    out.setAll(8, const [0x57, 0x41, 0x56, 0x45]); // WAVE
    out.setAll(12, const [0x66, 0x6D, 0x74, 0x20]); // fmt
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, bytesPerSecond, Endian.little);
    bd.setUint16(32, bytesPerSample, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    out.setAll(36, const [0x64, 0x61, 0x74, 0x61]); // data
    bd.setUint32(40, dataLen, Endian.little);
    out.setRange(44, totalLen, pcm);
    return out;
  }

  void dispose() {
    _disposed = true;
    _running = false;
    unawaited(_slices.close());
  }
}
