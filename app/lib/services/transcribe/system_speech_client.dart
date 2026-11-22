/// 系统内置语音识别客户端与引擎路由器 ——
/// - iOS 26+ 默认走纯端侧 `SpeechAnalyzer`；
/// - Android 13+ 已识别到标准端侧识别服务（非三星 Bixby/SMT 误开麦实现）时默认启用系统内置引擎；
/// - 其余系统（iOS < 26、无端侧服务的国行 Android / HarmonyOS 等）仅提供按需 SenseVoice，不跨平台错误推荐；
/// - 按需下载 SenseVoice 后可双引擎无缝切换。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
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
    this.sdkInt = 0,
    this.brandId = '',
    this.deviceSummary = '',
    this.engineName = '',
    this.onDeviceServicePackage = '',
    this.offlinePackInstalled = true,
    this.canDownloadOfflinePack = false,
    this.unsupportedReason = '',
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
  final int sdkInt;
  final String brandId;
  final String deviceSummary;
  final String engineName;
  final String onDeviceServicePackage;
  final bool offlinePackInstalled;
  final bool canDownloadOfflinePack;
  final String unsupportedReason;

  bool get isAndroid => platform == 'android';
  bool get isIOS => platform == 'ios';

  String get effectiveEngineTitle {
    final clean = engineName.trim();
    if (clean.isNotEmpty) return clean;
    if (isAndroid) return 'Android 系统端侧语音引擎';
    return 'iOS 系统内置模型（SpeechAnalyzer）';
  }

  String get effectiveDeviceLabel {
    final clean = deviceSummary.trim();
    if (clean.isNotEmpty) return clean;
    if (isAndroid) {
      return sdkInt > 0 ? 'Android (API $sdkInt)' : 'Android 设备';
    }
    if (isIOS) {
      return osMajorVersion > 0 ? 'iPhone · iOS $osMajorVersion' : 'iPhone';
    }
    return '当前设备';
  }

  String get effectiveUnsupportedReason {
    final clean = unsupportedReason.trim();
    if (clean.isNotEmpty) return clean;
    if (isAndroid) {
      return '当前 Android 设备未提供可用的端侧音频文件转写服务，音频不上传云端，请下载纯端侧 SenseVoice 增强模型。';
    }
    if (isIOS) {
      return '当前系统低于 iOS 26，不支持新一代纯端侧内置引擎，请下载 SenseVoice 增强模型。';
    }
    return '当前运行环境未提供系统端侧离线语音引擎，请下载 SenseVoice 增强模型。';
  }

  factory SystemSpeechCapabilities.fromMap(Map<Object?, Object?> map) =>
      SystemSpeechCapabilities(
        platform: '${map['platform'] ?? 'other'}',
        osMajorVersion: (map['osMajorVersion'] as num?)?.toInt() ?? 0,
        supportsModernSystemAsr: map['supportsModernSystemAsr'] == true,
        authStatus: '${map['authStatus'] ?? 'notDetermined'}',
        sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
        brandId: '${map['brandId'] ?? ''}',
        deviceSummary: '${map['deviceSummary'] ?? ''}',
        engineName: '${map['engineName'] ?? ''}',
        onDeviceServicePackage: '${map['onDeviceServicePackage'] ?? ''}',
        offlinePackInstalled: map['offlinePackInstalled'] != false,
        canDownloadOfflinePack: map['canDownloadOfflinePack'] == true,
        unsupportedReason: '${map['unsupportedReason'] ?? ''}',
      );
}

class SystemSpeechClient {
  SystemSpeechClient({
    MethodChannel? channel,
    Future<SystemSpeechCapabilities> Function()? capabilitiesOverride,
    Future<String> Function()? requestAuthOverride,
    Future<bool> Function(String language)? downloadModelOverride,
    Future<AsrResult> Function(
      Float32List samples,
      int sampleRate,
      String language,
    )?
    transcribeOverride,
    bool? debugForceNativePlatform,
  }) : _channel = channel,
       _capabilitiesOverride = capabilitiesOverride,
       _requestAuthOverride = requestAuthOverride,
       _downloadModelOverride = downloadModelOverride,
       _transcribeOverride = transcribeOverride,
       _debugForceNativePlatform = debugForceNativePlatform;

  static const MethodChannel _defaultChannel = MethodChannel(
    'com.reai.recordingcard/system_speech',
  );

  final MethodChannel? _channel;
  final bool? _debugForceNativePlatform;
  final Future<SystemSpeechCapabilities> Function()? _capabilitiesOverride;
  final Future<String> Function()? _requestAuthOverride;
  final Future<bool> Function(String language)? _downloadModelOverride;
  final Future<AsrResult> Function(
    Float32List samples,
    int sampleRate,
    String language,
  )?
  _transcribeOverride;

  int _seq = 0;

  bool get _hasNativePlatform =>
      _debugForceNativePlatform ??
      (_channel != null || (!kIsWeb && (Platform.isIOS || Platform.isAndroid)));

  Future<SystemSpeechCapabilities> capabilities() async {
    if (_capabilitiesOverride != null) {
      return _capabilitiesOverride();
    }
    if (!_hasNativePlatform) {
      return const SystemSpeechCapabilities(
        platform: 'other',
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
    if (!_hasNativePlatform) {
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

  /// Android 13+ 触发系统端侧中文离线语言包下载；其余平台或不支持时返回 false。
  Future<bool> triggerSystemModelDownload({String language = 'zh'}) async {
    if (_downloadModelOverride != null) {
      return _downloadModelOverride(language);
    }
    if (!_hasNativePlatform) return false;
    try {
      final ok = await (_channel ?? _defaultChannel).invokeMethod<bool>(
        'downloadSystemModel',
        {'language': language},
      );
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
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
    if (!_hasNativePlatform) {
      throw const AsrException('当前平台不支持系统内置离线语音识别');
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

/// 根据 `modelPath` 是否为系统哨兵值，在系统内置引擎与 SenseVoice 之间路由转写。
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

  /// 退后台或内存紧张时释放底层端侧 Isolate 与模型内存。
  Future<void> releaseMemory() async {
    final local = localEngine;
    if (local is LocalAsrService) {
      await local.releaseMemory();
    }
  }
}
