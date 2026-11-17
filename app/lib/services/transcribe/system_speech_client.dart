/// 系统内置语音识别客户端与引擎路由器 —— iOS 26+ 默认走纯端侧 SpeechAnalyzer，
/// 按需下载 SenseVoice 后可双引擎无缝切换。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'local_asr_service.dart';
import 'slice_planner.dart';
import 'speech_engine.dart';
import 'speech_models.dart';
import 'wav_io.dart';

enum LocalAsrEngineMode { system, sensevoice }

class SystemSpeechCapabilities {
  const SystemSpeechCapabilities({
    required this.platform,
    required this.osMajorVersion,
    required this.supportsModernSystemAsr,
    this.authStatus = 'notDetermined',
  });

  static const SystemSpeechCapabilities unsupported = SystemSpeechCapabilities(
    platform: 'other',
    osMajorVersion: 0,
    supportsModernSystemAsr: false,
  );

  final String platform;
  final int osMajorVersion;
  final bool supportsModernSystemAsr;
  final String authStatus;

  factory SystemSpeechCapabilities.fromMap(Map<Object?, Object?> map) =>
      SystemSpeechCapabilities(
        platform: '${map['platform'] ?? 'other'}',
        osMajorVersion: (map['osMajorVersion'] as num?)?.toInt() ?? 0,
        supportsModernSystemAsr: map['supportsModernSystemAsr'] == true,
        authStatus: '${map['authStatus'] ?? 'notDetermined'}',
      );
}

class SystemSpeechClient {
  SystemSpeechClient({
    MethodChannel? channel,
    Future<SystemSpeechCapabilities> Function()? capabilitiesOverride,
    Future<String> Function()? requestAuthOverride,
    Future<AsrResult> Function(
      Float32List samples,
      int sampleRate,
      String language,
    )?
    transcribeOverride,
  }) : _channel = channel,
       _capabilitiesOverride = capabilitiesOverride,
       _requestAuthOverride = requestAuthOverride,
       _transcribeOverride = transcribeOverride;

  static const MethodChannel _defaultChannel = MethodChannel(
    'com.reai.recordingcard/system_speech',
  );

  final MethodChannel? _channel;
  final Future<SystemSpeechCapabilities> Function()? _capabilitiesOverride;
  final Future<String> Function()? _requestAuthOverride;
  final Future<AsrResult> Function(
    Float32List samples,
    int sampleRate,
    String language,
  )?
  _transcribeOverride;

  int _seq = 0;

  Future<SystemSpeechCapabilities> capabilities() async {
    if (_capabilitiesOverride != null) {
      return _capabilitiesOverride();
    }
    if (_channel == null && !Platform.isIOS) {
      return SystemSpeechCapabilities(
        platform: Platform.isAndroid ? 'android' : 'other',
        osMajorVersion: 0,
        supportsModernSystemAsr: false,
      );
    }
    try {
      final raw = await (_channel ?? _defaultChannel)
          .invokeMapMethod<Object?, Object?>('capabilities');
      if (raw == null) return SystemSpeechCapabilities.unsupported;
      return SystemSpeechCapabilities.fromMap(raw);
    } on MissingPluginException {
      return SystemSpeechCapabilities.unsupported;
    } on PlatformException {
      return SystemSpeechCapabilities.unsupported;
    }
  }

  Future<String> requestAuthorization() async {
    if (_requestAuthOverride != null) {
      return _requestAuthOverride();
    }
    if (_channel == null && !Platform.isIOS) {
      return 'denied';
    }
    try {
      final res = await (_channel ?? _defaultChannel).invokeMethod<Object?>(
        'requestAuthorization',
      );
      return '${res ?? 'denied'}';
    } on MissingPluginException {
      return 'denied';
    } on PlatformException {
      return 'denied';
    }
  }

  Future<AsrResult> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    String language = 'auto',
  }) async {
    if (samples.isEmpty) {
      return const AsrResult(
        text: '',
        tokens: [],
        timestampsMs: [],
        audioMs: 0,
      );
    }
    if (_transcribeOverride != null) {
      return _transcribeOverride(samples, sampleRate, language);
    }
    if (_channel == null && !Platform.isIOS) {
      throw const AsrException('当前平台不支持 iOS 系统语音识别');
    }

    final audioMs = samples.length * 1000 ~/ sampleRate;
    final wavBytes = encodeWav(samples, sampleRate: sampleRate);
    final tmpFile = File(
      '${Directory.systemTemp.path}/rc_sys_asr_${DateTime.now().microsecondsSinceEpoch}_${_seq++}.wav',
    );
    await tmpFile.writeAsBytes(wavBytes, flush: true);

    try {
      final raw = await (_channel ?? _defaultChannel)
          .invokeMapMethod<Object?, Object?>('transcribeWav', {
            'wavPath': tmpFile.path,
            'language': language,
          });
      if (raw == null) {
        return AsrResult(
          text: '',
          tokens: const [],
          timestampsMs: const [],
          audioMs: audioMs,
        );
      }
      final text = '${raw['text'] ?? ''}';
      final tokens = [
        for (final t in (raw['tokens'] as List? ?? const [])) '$t',
      ];
      final timestampsMs = [
        for (final ts in (raw['timestampsMs'] as List? ?? const []))
          if (ts is num) ts.toInt(),
      ];
      final langRaw = raw['lang'] as String?;
      return AsrResult(
        text: text,
        tokens: tokens,
        timestampsMs: timestampsMs,
        audioMs: audioMs,
        lang: (langRaw == null || langRaw.trim().isEmpty)
            ? null
            : langRaw.trim(),
      );
    } on PlatformException catch (e) {
      throw AsrException(e.message ?? '系统语音识别失败');
    } on MissingPluginException {
      throw const AsrException('系统语音识别通道未就绪');
    } finally {
      try {
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
      } on Object {
        // 清理临时 WAV 失败不阻塞主流程
      }
    }
  }
}

/// 根据 `modelPath` 是否为系统哨兵值，在 iOS 原生引擎与 SenseVoice 之间路由转写。
/// VAD 与声纹嵌入仍统一走本地 sherpa-onnx 引擎，保证切片与声纹完全一致。
class RoutingSpeechEngine implements SpeechEngine {
  RoutingSpeechEngine({
    required this.localEngine,
    required this.systemSpeech,
  });

  final SpeechEngine localEngine;
  final SystemSpeechClient systemSpeech;

  bool _activeIsSystem = false;
  String _language = 'auto';

  bool get activeIsSystem => _activeIsSystem;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {
    _language = language;
    if (modelPath == kSystemSpeechSentinelModelPath) {
      final auth = await systemSpeech.requestAuthorization();
      if (auth == 'denied' || auth == 'restricted') {
        throw const AsrException(
          '未开启系统语音识别权限，请在系统设置中开启或切换 SenseVoice 增强模型',
        );
      }
      _activeIsSystem = true;
      final local = localEngine;
      if (local is LocalAsrService && local.isLoaded) {
        await local.unload();
      }
      return;
    }

    _activeIsSystem = false;
    await localEngine.load(
      modelPath: modelPath,
      tokensPath: tokensPath,
      language: language,
      numThreads: numThreads,
    );
  }

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (_activeIsSystem) {
      return systemSpeech.transcribeSamples(
        samples,
        sampleRate: sampleRate,
        language: _language,
      );
    }
    return localEngine.transcribe(samples, sampleRate: sampleRate);
  }

  @override
  Future<void> loadVad(String vadPath) => localEngine.loadVad(vadPath);

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) => localEngine.detectSpeech(samples, sampleRate: sampleRate);

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) =>
      localEngine.loadSpeakerEmbedding(modelPath);

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) => localEngine.embedSpeaker(samples, sampleRate: sampleRate);

  @override
  Future<void> dispose() => localEngine.dispose();
}
