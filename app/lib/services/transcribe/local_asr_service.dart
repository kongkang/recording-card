/// 本地语音转写服务 —— sherpa-onnx + SenseVoice，跑在独立 worker isolate 里。
///
/// 为什么必须独立 isolate：一次 60~90 秒的解码是几十毫秒到几秒的同步 native
/// 调用，放主 isolate 会卡动画和手势。worker 里持有 recognizer，主 isolate 只
/// 发命令、收结果。
///
/// 失败语义：
/// - 模型没加载 → 明确抛 [AsrNotReadyException]，上层把切片留在「待转写」；
/// - 解码超时 → 杀掉 worker（native 调用无法取消），下次调用自动重建；
/// - 空文本是**正常结果**（静音/无法识别），不抛异常。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'sherpa_runtime.dart';
import 'slice_planner.dart';
import 'speech_engine.dart';

class AsrNotReadyException implements Exception {
  const AsrNotReadyException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AsrException implements Exception {
  const AsrException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一次解码的原始结果（保留模型给的 tokens / 时间 / 情绪 / 语种）。
class AsrResult {
  const AsrResult({
    required this.text,
    required this.tokens,
    required this.timestampsMs,
    required this.audioMs,
    this.lang,
    this.emotion,
    this.event,
  });

  final String text;
  final List<String> tokens;

  /// 与 [tokens] 对应的毫秒时间戳（模型不给时为空）。
  final List<int> timestampsMs;
  final int audioMs;
  final String? lang;
  final String? emotion;
  final String? event;

  bool get hasText => text.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'text': text,
    'tokens': tokens,
    'ts': timestampsMs,
    'audioMs': audioMs,
    if (lang != null) 'lang': lang,
    if (emotion != null) 'emotion': emotion,
    if (event != null) 'event': event,
  };
}

class LocalAsrService implements SpeechEngine {
  LocalAsrService({
    this.loadTimeout = const Duration(seconds: 90),
    this.transcribeTimeout = const Duration(seconds: 120),
  });

  final Duration loadTimeout;
  final Duration transcribeTimeout;

  Isolate? _isolate;
  SendPort? _command;
  ReceivePort? _responses;
  StreamSubscription<Object?>? _responseSub;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  bool _loaded = false;

  String? _modelPath;
  String? _tokensPath;
  String? _language;
  int _numThreads = 2;

  bool get isLoaded => _loaded;

  static const double defaultVadMinSilenceDuration = 0.45;
  static const double defaultVadMaxSpeechDuration = 28;

  static sherpa.SileroVadModelConfig buildSileroVadConfig(String vadPath) =>
      sherpa.SileroVadModelConfig(
        model: vadPath,
        threshold: 0.20,
        minSilenceDuration: defaultVadMinSilenceDuration,
        minSpeechDuration: 0.20,
        windowSize: 512,
        maxSpeechDuration: defaultVadMaxSpeechDuration,
      );

  bool _vadLoaded = false;
  String? _vadPath;

  bool _embeddingLoaded = false;
  String? _embeddingModelPath;
  int _embeddingDim = 0;

  int get embeddingDim => _embeddingDim;

  /// 加载声纹嵌入模型（Campplus）。与 pyannote 分割不同，这条路在 iOS 上
  /// 已被唤醒词功能验证过；分段直接用 VAD 语音段，不再单独跑分割模型。
  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {
    if (_embeddingLoaded && _embeddingModelPath == modelPath) return;
    await _ensureWorker();
    final response = await _call('loadEmbedding', {
      'modelPath': modelPath,
    }, const Duration(seconds: 60));
    if (response['ok'] != true) {
      throw AsrException('${response['error'] ?? '声纹模型加载失败'}');
    }
    _embeddingLoaded = true;
    _embeddingModelPath = modelPath;
    _embeddingDim = (response['dim'] as num?)?.toInt() ?? 0;
  }

  /// 计算一段语音的声纹向量。音频太短（模型未 ready）时返回空列表，不抛异常。
  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (!_embeddingLoaded) {
      throw const AsrNotReadyException('声纹模型未加载');
    }
    if (samples.isEmpty) return const [];
    final response = await _call('embed', {
      'samples': samples,
      'sampleRate': sampleRate,
    }, const Duration(seconds: 60));
    if (response['ok'] != true) {
      throw AsrException('${response['error'] ?? '声纹计算失败'}');
    }
    return [
      for (final v in (response['embedding'] as List? ?? const []))
        if (v is num) v.toDouble(),
    ];
  }

  /// 加载 VAD 模型（与 ASR 独立，可只做切片不做转写）。
  @override
  Future<void> loadVad(String vadPath) async {
    if (_vadLoaded && _vadPath == vadPath) return;
    await _ensureWorker();
    final response = await _call('loadVad', {
      'vadPath': vadPath,
    }, const Duration(seconds: 30));
    if (response['ok'] != true) {
      throw AsrException('${response['error'] ?? 'VAD 加载失败'}');
    }
    _vadLoaded = true;
    _vadPath = vadPath;
  }

  /// 检测语音段（采样点区间）。没有语音时返回空列表。
  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (!_vadLoaded) {
      throw const AsrNotReadyException('VAD 模型未加载');
    }
    if (samples.isEmpty) return const [];
    final response = await _call('detectSpeech', {
      'samples': samples,
      'sampleRate': sampleRate,
    }, const Duration(minutes: 2));
    if (response['ok'] != true) {
      throw AsrException('${response['error'] ?? 'VAD 检测失败'}');
    }
    final spans = <SpeechSpan>[];
    for (final raw in (response['spans'] as List? ?? const [])) {
      if (raw is List && raw.length >= 2) {
        spans.add(
          SpeechSpan(
            (raw[0] as num).toInt(),
            (raw[1] as num).toInt(),
          ),
        );
      }
    }
    return spans;
  }

  /// 加载/切换模型。相同路径重复调用直接返回。
  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
    String? nativeLibraryPath,
  }) async {
    if (_loaded &&
        _modelPath == modelPath &&
        _tokensPath == tokensPath &&
        _language == language &&
        _numThreads == numThreads) {
      return;
    }
    await _ensureWorker();
    final response = await _call('load', {
      'modelPath': modelPath,
      'tokensPath': tokensPath,
      'language': language,
      'numThreads': numThreads,
      'nativeLibraryPath': ?nativeLibraryPath,
    }, loadTimeout);
    if (response['ok'] != true) {
      throw AsrException('${response['error'] ?? '模型加载失败'}');
    }
    _modelPath = modelPath;
    _tokensPath = tokensPath;
    _language = language;
    _numThreads = numThreads;
    _loaded = true;
  }

  /// 转写一段 16 kHz 单声道 PCM。空文本正常返回。
  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    if (!_loaded) {
      throw const AsrNotReadyException('本地转写模型未加载');
    }
    if (samples.isEmpty) {
      return const AsrResult(
        text: '',
        tokens: [],
        timestampsMs: [],
        audioMs: 0,
      );
    }
    final response = await _call('transcribe', {
      'samples': samples,
      'sampleRate': sampleRate,
    }, transcribeTimeout);
    if (response['ok'] != true) {
      throw AsrException('${response['error'] ?? '转写失败'}');
    }
    final timestamps = <int>[
      for (final t in (response['timestamps'] as List? ?? const []))
        if (t is num) (t * 1000).round(),
    ];
    return AsrResult(
      text: '${response['text'] ?? ''}',
      tokens: [
        for (final t in (response['tokens'] as List? ?? const [])) '$t',
      ],
      timestampsMs: timestamps,
      audioMs: (response['audioMs'] as num?)?.toInt() ?? 0,
      lang: _cleanTag(response['lang'] as String?),
      emotion: _cleanTag(response['emotion'] as String?),
      event: _cleanTag(response['event'] as String?),
    );
  }

  /// 释放模型（保留 worker 可复用；下次 load 重建）。
  Future<void> unload() async {
    if (!_loaded) return;
    try {
      await _call('unload', const {}, const Duration(seconds: 10));
    } on Object {
      // 卸载失败也要把本地状态复位：调用方只需要知道"现在不能用"
    }
    _loaded = false;
  }

  @override
  Future<void> dispose() async {
    try {
      if (_command != null) {
        await _call('dispose', const {}, const Duration(seconds: 5));
      }
    } on Object {
      // 忽略
    }
    await _killWorker();
  }

  /// SenseVoice 的语种/情绪/事件是 `<|zh|>` 形式，存库前去掉包装。
  static String? _cleanTag(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return null;
    final match = RegExp(r'^<\|(.*)\|>$').firstMatch(v);
    final inner = match?.group(1)?.trim();
    return (inner == null || inner.isEmpty) ? v : inner;
  }

  Future<void> _ensureWorker() async {
    if (_command != null) return;
    final responsePort = ReceivePort();
    final ready = Completer<SendPort>();
    _responses = responsePort;
    _responseSub = responsePort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List && message.length >= 2) {
        // Isolate.spawn(onError:) 的错误格式：[error, stackTrace]
        final reason = '${message[0]}';
        if (!ready.isCompleted) ready.completeError(AsrException(reason));
        _failAll(AsrException('转写进程异常退出：$reason'));
        return;
      }
      if (message is Map) {
        final map = message.cast<String, dynamic>();
        final id = (map['id'] as num?)?.toInt();
        if (id == null) return;
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(map);
        }
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _asrWorkerMain,
        responsePort.sendPort,
        debugName: 'rc-asr',
        onError: responsePort.sendPort,
      );
      _command = await ready.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const AsrException('转写进程启动超时'),
      );
    } on Object {
      await _killWorker();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _call(
    String cmd,
    Map<String, Object?> payload,
    Duration timeout,
  ) async {
    final command = _command;
    if (command == null) {
      throw const AsrNotReadyException('转写进程未启动');
    }
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    command.send({'id': id, 'cmd': cmd, ...payload});
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      // native 解码无法取消：杀进程，下次调用重建
      _loaded = false;
      await _killWorker();
      throw AsrException('转写超时（${timeout.inSeconds}s），已重置转写进程');
    }
  }

  void _failAll(Object error) {
    final pending = Map<int, Completer<Map<String, dynamic>>>.from(_pending);
    _pending.clear();
    _loaded = false;
    for (final c in pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  Future<void> _killWorker() async {
    final isolate = _isolate;
    _isolate = null;
    _command = null;
    _loaded = false;
    _vadLoaded = false;
    _embeddingLoaded = false;
    isolate?.kill(priority: Isolate.immediate);
    await _responseSub?.cancel();
    _responseSub = null;
    _responses?.close();
    _responses = null;
    _failAll(const AsrException('转写进程已停止'));
  }
}

// ============ Worker Isolate ============

void _asrWorkerMain(SendPort mainPort) {
  final commandPort = ReceivePort();
  mainPort.send(commandPort.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  sherpa.SpeakerEmbeddingExtractor? embedding;

  void reply(int id, Map<String, Object?> payload) {
    mainPort.send({'id': id, ...payload});
  }

  commandPort.listen((message) {
    final msg = (message as Map).cast<String, dynamic>();
    final id = (msg['id'] as num).toInt();
    try {
      switch (msg['cmd']) {
        case 'load':
          recognizer?.free();
          recognizer = null;
          initSherpaBindings(msg['nativeLibraryPath'] as String?);
          recognizer = sherpa.OfflineRecognizer(
            sherpa.OfflineRecognizerConfig(
              model: sherpa.OfflineModelConfig(
                senseVoice: sherpa.OfflineSenseVoiceModelConfig(
                  model: msg['modelPath'] as String,
                  language: (msg['language'] as String?) ?? 'auto',
                  useInverseTextNormalization: true,
                ),
                tokens: msg['tokensPath'] as String,
                numThreads: (msg['numThreads'] as num?)?.toInt() ?? 2,
                debug: false,
              ),
            ),
          );
          reply(id, {'ok': true});

        case 'transcribe':
          final active = recognizer;
          if (active == null) {
            reply(id, {'ok': false, 'error': '模型未加载'});
            break;
          }
          final samples = msg['samples'] as Float32List;
          final sampleRate = (msg['sampleRate'] as num?)?.toInt() ?? 16000;
          final stream = active.createStream();
          try {
            stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
            active.decode(stream);
            final result = active.getResult(stream);
            reply(id, {
              'ok': true,
              'text': result.text,
              'tokens': result.tokens,
              'timestamps': result.timestamps,
              'lang': result.lang,
              'emotion': result.emotion,
              'event': result.event,
              'audioMs': samples.length * 1000 ~/ sampleRate,
            });
          } finally {
            stream.free();
          }

        case 'loadVad':
          vad?.free();
          vad = null;
          initSherpaBindings(msg['nativeLibraryPath'] as String?);
          vad = sherpa.VoiceActivityDetector(
            config: sherpa.VadModelConfig(
              sileroVad: LocalAsrService.buildSileroVadConfig(
                msg['vadPath'] as String,
              ),
              sampleRate: 16000,
              numThreads: 1,
              debug: false,
            ),
            bufferSizeInSeconds: 120,
          );
          reply(id, {'ok': true});

        case 'detectSpeech':
          final detector = vad;
          if (detector == null) {
            reply(id, {'ok': false, 'error': 'VAD 未加载'});
            break;
          }
          final samples = msg['samples'] as Float32List;
          // Silero VAD 按 512 采样窗口喂，并边喂边排空已检出的语音段，防止长音频溢出环形缓冲。
          const window = 512;
          final spans = <List<int>>[];
          for (var i = 0; i < samples.length; i += window) {
            final end = i + window < samples.length
                ? i + window
                : samples.length;
            detector.acceptWaveform(Float32List.sublistView(samples, i, end));
            while (!detector.isEmpty()) {
              final segment = detector.front();
              spans.add([segment.start, segment.start + segment.samples.length]);
              detector.pop();
            }
          }
          detector.flush();
          while (!detector.isEmpty()) {
            final segment = detector.front();
            spans.add([segment.start, segment.start + segment.samples.length]);
            detector.pop();
          }
          detector.reset();
          reply(id, {'ok': true, 'spans': spans});

        case 'loadEmbedding':
          embedding?.free();
          embedding = null;
          initSherpaBindings(msg['nativeLibraryPath'] as String?);
          embedding = sherpa.SpeakerEmbeddingExtractor(
            config: sherpa.SpeakerEmbeddingExtractorConfig(
              model: msg['modelPath'] as String,
              numThreads: 1,
              debug: false,
            ),
          );
          reply(id, {'ok': true, 'dim': embedding!.dim});

        case 'embed':
          final extractor = embedding;
          if (extractor == null) {
            reply(id, {'ok': false, 'error': '声纹模型未加载'});
            break;
          }
          final embedSamples = msg['samples'] as Float32List;
          final embedRate = (msg['sampleRate'] as num?)?.toInt() ?? 16000;
          final embedStream = extractor.createStream();
          try {
            embedStream.acceptWaveform(
              samples: embedSamples,
              sampleRate: embedRate,
            );
            if (!extractor.isReady(embedStream)) {
              reply(id, {'ok': true, 'embedding': const <double>[]});
            } else {
              final vector = extractor.compute(embedStream);
              reply(id, {'ok': true, 'embedding': vector.toList()});
            }
          } finally {
            embedStream.free();
          }

        case 'unload':
          recognizer?.free();
          recognizer = null;
          reply(id, {'ok': true});

        case 'dispose':
          recognizer?.free();
          recognizer = null;
          vad?.free();
          vad = null;
          embedding?.free();
          embedding = null;
          reply(id, {'ok': true});

        default:
          reply(id, {'ok': false, 'error': '未知命令 ${msg['cmd']}'});
      }
    } on Object catch (e) {
      reply(id, {'ok': false, 'error': '$e'});
    }
  });
}
