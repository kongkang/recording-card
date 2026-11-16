/// 本地声纹样本采集与特征提取 —— 供 Setting › 声纹管理「录制我的声音 / 录新样本」使用。
///
/// 流程：检查/请求本机麦克风权限 → 录制约 3 秒 16kHz 单声道 PCM → 落盘 WAV 供回放 →
/// 经端侧 CAM++ 提取声纹向量（绝不上传音频，模型缺失或授权被拒时如实返回错误，不编造向量）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../transcribe/asr_models.dart';
import '../transcribe/local_asr_service.dart';
import '../transcribe/speech_engine.dart';
import '../transcribe/wav_io.dart';
import 'phone_mic_service.dart';

class VoiceSampleCaptureResult {
  const VoiceSampleCaptureResult({
    required this.ok,
    this.embedding = const [],
    this.durationMs = 0,
    this.audioPath,
    this.error,
  });

  final bool ok;
  final List<double> embedding;
  final int durationMs;

  /// 本机可回放的 WAV 绝对路径。
  final String? audioPath;
  final String? error;
}

typedef VoiceSampleOverride =
    Future<VoiceSampleCaptureResult> Function({
      required String targetName,
      required String deviceLabel,
      required String sceneLabel,
    });

class VoiceSampleCaptureDriver {
  VoiceSampleCaptureDriver({
    PhoneMicBackend? micBackend,
    ModelInstaller? installer,
    SpeechEngine Function()? engineFactory,
    VoiceSampleOverride? overrideCapture,
    this.captureDuration = const Duration(milliseconds: 2800),
    this.onTick,
  }) : _micBackend = micBackend,
       _installer = installer,
       _engineFactory = engineFactory ?? LocalAsrService.new,
       _override = overrideCapture;

  /// 测试注入覆盖回调（若为空则走真实本机麦克风 + 端侧 CAM++ 提取）。
  static VoiceSampleOverride? debugOverrideCapture;

  final PhoneMicBackend? _micBackend;
  final ModelInstaller? _installer;
  final SpeechEngine Function() _engineFactory;
  final VoiceSampleOverride? _override;
  final Duration captureDuration;

  /// 倒计时剩余整秒回调（含起始秒，例如 3→2→1）。
  final void Function(int remainSec)? onTick;

  Future<VoiceSampleCaptureResult> captureAndEmbed({
    required String targetName,
    String deviceLabel = '本机麦克风',
    String sceneLabel = '近场本人录入',
  }) async {
    final override = _override ?? debugOverrideCapture;
    if (override != null) {
      // 测试路径也走一遍倒计时 tick，方便 UI 联调；时长压到极短。
      await _emitCountdown(const Duration(milliseconds: 120));
      return override(
        targetName: targetName,
        deviceLabel: deviceLabel,
        sceneLabel: sceneLabel,
      );
    }

    final installer = _installer ?? ModelInstaller();
    final embeddingPath = await installer.resolve(
      campplusEmbeddingSpec,
      campplusEmbeddingSpec.files.first.relPath,
    );
    if (embeddingPath == null || embeddingPath.isEmpty) {
      return const VoiceSampleCaptureResult(
        ok: false,
        error: '端侧声纹模型尚未就绪，请先点击上方「下载」后再录制声纹',
      );
    }

    final mic = _micBackend ?? PlatformPhoneMicBackend();
    var perm = await mic.checkPermission();
    if (perm != PhoneMicPermission.granted) {
      perm = await mic.requestPermission();
    }
    if (perm != PhoneMicPermission.granted) {
      return const VoiceSampleCaptureResult(
        ok: false,
        error: '需要麦克风权限才能录入本机声纹样本',
      );
    }

    final pcmChunks = <int>[];
    String? micError;
    try {
      await mic.startCapture(
        (chunk) {
          pcmChunks.addAll(chunk);
        },
        onError: (err) {
          micError ??= err;
        },
      );
      await _emitCountdown(captureDuration);
    } on Object catch (e) {
      return VoiceSampleCaptureResult(
        ok: false,
        error: '麦克风启动失败：$e',
      );
    } finally {
      try {
        await mic.stopCapture();
      } on Object {
        // 停止清理失败不覆盖前序捕获结果
      }
    }

    if (micError != null && pcmChunks.isEmpty) {
      return VoiceSampleCaptureResult(ok: false, error: micError);
    }

    final byteCount = pcmChunks.length - (pcmChunks.length % 2);
    final sampleCount = byteCount ~/ 2;
    final durationMs = (sampleCount * 1000) ~/ 16000;
    if (sampleCount < 16000 * 6 ~/ 10) {
      return VoiceSampleCaptureResult(
        ok: false,
        durationMs: durationMs,
        error: '录音时长不足 0.6 秒（当前 ${durationMs}ms），请靠近麦克风清晰朗读一句话后再试',
      );
    }

    final bytes = Uint8List.fromList(pcmChunks.sublist(0, byteCount));
    final bd = ByteData.sublistView(bytes);
    final floats = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      floats[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }

    String? audioPath;
    try {
      final dir = await getApplicationSupportDirectory();
      final vpDir = Directory('${dir.path}/voiceprints');
      if (!vpDir.existsSync()) {
        await vpDir.create(recursive: true);
      }
      final safeName = targetName.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]+'), '_');
      final file = File(
        '${vpDir.path}/vs_${safeName}_${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      await file.writeAsBytes(encodeWav(floats), flush: true);
      audioPath = file.path;
    } on Object {
      // 落盘失败不阻塞声纹向量入库，只是无法回放
      audioPath = null;
    }

    final engine = _engineFactory();
    try {
      await engine.loadSpeakerEmbedding(embeddingPath);
      final vector = await engine.embedSpeaker(floats, sampleRate: 16000);
      if (vector.isEmpty) {
        return VoiceSampleCaptureResult(
          ok: false,
          durationMs: durationMs,
          audioPath: audioPath,
          error: '未能提取到有效声纹特征，请在安静环境再试一次',
        );
      }
      return VoiceSampleCaptureResult(
        ok: true,
        embedding: vector,
        durationMs: durationMs,
        audioPath: audioPath,
      );
    } on Object catch (e) {
      return VoiceSampleCaptureResult(
        ok: false,
        durationMs: durationMs,
        audioPath: audioPath,
        error: '声纹特征提取失败：$e',
      );
    } finally {
      await engine.dispose();
    }
  }

  Future<void> _emitCountdown(Duration total) async {
    final totalSec = total.inMilliseconds <= 0
        ? 1
        : (total.inMilliseconds / 1000).ceil().clamp(1, 9);
    final tickMs = total.inMilliseconds <= 0
        ? 1
        : (total.inMilliseconds / totalSec).round().clamp(1, total.inMilliseconds);
    for (var remain = totalSec; remain >= 1; remain--) {
      onTick?.call(remain);
      await Future<void>.delayed(Duration(milliseconds: tickMs));
    }
    onTick?.call(0);
  }
}
