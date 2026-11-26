/// 自建 / 私有云 OpenAI Whisper 兼容 ASR 客户端（BYO-ASR）。
///
/// 支持局域网 `http://` 与私有 `https://` 端点：直接以 multipart/form-data
/// 上传 16kHz 单声道 WAV 到用户配置的私有端点（可选 Bearer Key，可注入热词 `prompt`），
/// 完全绕过外脑官方网关。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'local_asr_service.dart';
import 'wav_io.dart';

/// 启用自建私有云 ASR 时的哨兵模型路径。
const String kByoCloudSentinelModelPath = '__byo_cloud_asr__';

class ByoAsrClient {
  ByoAsrClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// 把用户输入的 Base URL 或完整端点规整为 `/audio/transcriptions` URI。
  static Uri resolveTranscriptionsUri(String rawUrl) {
    final trimmed = rawUrl.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.trim().isEmpty) {
      throw const AsrException('请输入有效服务地址');
    }
    var path = parsed.path;
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('/audio/transcriptions')) {
      return parsed.replace(path: path);
    }
    if (path.isEmpty || path == '/') {
      return parsed.replace(path: '/v1/audio/transcriptions');
    }
    return parsed.replace(path: '$path/audio/transcriptions');
  }

  Future<void> testConnection({
    required String baseUrl,
    required String model,
    String apiKey = '',
  }) async {
    // 发送 200ms 静音 WAV 验证端点与鉴权连通性。
    final silence = Float32List(3200);
    await transcribeSamples(
      silence,
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey,
      sampleRate: 16000,
      language: 'zh',
      timeout: const Duration(seconds: 10),
    );
  }

  Future<AsrResult> transcribeSamples(
    Float32List samples, {
    required String baseUrl,
    required String model,
    String apiKey = '',
    List<String> hotwords = const [],
    int sampleRate = 16000,
    String language = 'auto',
    String? wavPath,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final uri = resolveTranscriptionsUri(baseUrl);
    final trimmedPath = wavPath?.trim() ?? '';
    final existingFile = trimmedPath.isNotEmpty ? File(trimmedPath) : null;
    final canUseDirectWav =
        existingFile != null && await existingFile.exists();

    if (samples.isEmpty && !canUseDirectWav) {
      return const AsrResult(
        text: '',
        tokens: [],
        timestampsMs: [],
        audioMs: 0,
      );
    }

    final Uint8List wavBytes;
    final int audioMs;
    if (canUseDirectWav) {
      wavBytes = await existingFile.readAsBytes();
      audioMs = readWavDurationMsSync(existingFile.path) ?? 0;
    } else {
      wavBytes = encodeWav(samples, sampleRate: sampleRate);
      audioMs = samples.length * 1000 ~/ sampleRate;
    }

    final req = http.MultipartRequest('POST', uri);
    final cleanKey = apiKey.trim();
    if (cleanKey.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $cleanKey';
    }
    final cleanModel = model.trim().isEmpty ? 'whisper-1' : model.trim();
    req.fields['model'] = cleanModel;
    req.fields['response_format'] = 'json';
    final cleanLang = language.trim();
    if (cleanLang.isNotEmpty && cleanLang != 'auto') {
      req.fields['language'] = cleanLang;
    }
    final cleanHotwords = [
      for (final w in hotwords)
        if (w.trim().isNotEmpty) w.trim(),
    ];
    if (cleanHotwords.isNotEmpty) {
      req.fields['prompt'] = cleanHotwords.join(', ');
    }
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        wavBytes,
        filename: 'audio.wav',
      ),
    );

    final http.Response response;
    try {
      final streamed = await _http.send(req).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on Object catch (e) {
      throw AsrException('自建转写请求失败：$e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AsrException('自建转写返回 HTTP ${response.statusCode}');
    }

    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      body = decoded;
    } catch (e) {
      throw AsrException('自建转写结果解析失败：$e');
    }

    final rawText = body['text'];
    final text = rawText is String ? rawText.trim() : '';
    final rawLang = body['language'] as String?;
    return AsrResult(
      text: text,
      tokens: const [],
      timestampsMs: const [],
      audioMs: audioMs,
      lang: (rawLang == null || rawLang.trim().isEmpty) ? null : rawLang.trim(),
    );
  }
}
