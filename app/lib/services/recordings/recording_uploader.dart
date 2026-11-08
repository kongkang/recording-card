import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'network_policy.dart';
import 'recording_models.dart';

class RecordingUploadConfigurationException implements Exception {
  final String message;
  const RecordingUploadConfigurationException(this.message);
  @override
  String toString() => 'RecordingUploadConfigurationException: $message';
}

class RecordingUploadException implements Exception {
  final String message;
  const RecordingUploadException(this.message);
  @override
  String toString() => 'RecordingUploadException: $message';
}

class RecordingUploadReceipt {
  final String cloudFileId;
  const RecordingUploadReceipt({required this.cloudFileId});
}

class RecordingUploadRequest {
  final RecordingIndexEntry entry;
  final Future<void> Function()? requireNetwork;
  const RecordingUploadRequest({required this.entry, this.requireNetwork});

  /// Same source/version must use the same key across restart and retries.
  String get idempotencyKey => '${entry.key}:${entry.contentHash}';
}

abstract interface class RecordingUploader {
  /// Throws before device/download side effects when upload is unavailable.
  void validateConfiguration();
  Future<RecordingUploadReceipt> upload(
    RecordingUploadRequest request, {
    RecordingProgress? onProgress,
  });
  Future<void> cancelActive();
}

/// Explicit raw-file HTTP contract: PUT (or configured POST), Content-Length,
/// X-Device-Id / X-Recording-Id (base64url UTF-8), X-Content-SHA256 and
/// Idempotency-Key. Requires a 200/201 JSON {accepted:true,fileId:"..."} receipt.
/// This is an opt-in adapter, NOT an assumption about an unconfigured backend.
/// For multipart/presigned/custom auth contracts inject another uploader.
class HttpRecordingUploader implements RecordingUploader {
  final Uri? endpoint;
  final Set<String> allowedHosts;
  final Future<Map<String, String>> Function()? authorizationHeaders;
  final String method;
  final Duration timeout;
  final HttpClient _client;
  final bool _ownsClient;
  HttpClientRequest? _active;
  bool _busy = false;
  HttpRecordingUploader({
    this.endpoint,
    Set<String> allowedHosts = const {},
    this.authorizationHeaders,
    this.method = 'PUT',
    this.timeout = const Duration(minutes: 5),
    HttpClient? client,
  }) : allowedHosts = Set.unmodifiable(
         allowedHosts.map((host) => host.toLowerCase()),
       ),
       _client = client ?? HttpClient(),
       _ownsClient = client == null;

  @override
  void validateConfiguration() {
    final uri = endpoint;
    if (uri == null) {
      throw const RecordingUploadConfigurationException(
        '同步上传端点未配置，不能仅下载后报告同步成功',
      );
    }
    if (allowedHosts.isEmpty ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !allowedHosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.toString().contains(RegExp(r'\s')) ||
        !(method == 'PUT' || method == 'POST')) {
      throw const RecordingUploadConfigurationException(
        '上传地址必须为获批白名单中的合法 HTTPS 端点',
      );
    }
    if (authorizationHeaders == null) {
      throw const RecordingUploadConfigurationException('上传认证/服务合约未配置');
    }
  }

  @override
  Future<RecordingUploadReceipt> upload(
    RecordingUploadRequest request, {
    RecordingProgress? onProgress,
  }) async {
    validateConfiguration();
    if (_busy) {
      throw const RecordingUploadException('An upload is already active');
    }
    _busy = true;
    HttpClientRequest? http;
    try {
      final entry = request.entry;
      final audio = File(entry.audioPath);
      if (!await audio.exists() ||
          await audio.length() != entry.sizeBytes ||
          (await sha256.bind(audio.openRead()).first).toString() !=
              entry.contentHash) {
        throw const RecordingUploadException('上传文件缺失或完整性校验失败');
      }
      await request.requireNetwork?.call();
      final headers = await authorizationHeaders!().timeout(timeout);
      http = await _client.openUrl(method, endpoint!).timeout(timeout);
      _active = http;
      http.followRedirects = false; // Never forward auth to a redirect host.
      for (final header in headers.entries) {
        final name = header.key.toLowerCase();
        if (const {
          'host',
          'content-length',
          'content-type',
          'transfer-encoding',
          'idempotency-key',
          'x-device-id',
          'x-recording-id',
          'x-content-sha256',
        }.contains(name)) {
          throw const RecordingUploadConfigurationException(
            'Authentication provider attempted to override a transport header',
          );
        }
        http.headers.set(header.key, header.value);
      }
      http.headers.contentType = ContentType.binary;
      http.contentLength = entry.sizeBytes;
      http.headers.set('Idempotency-Key', request.idempotencyKey);
      http.headers.set(
        'X-Device-Id',
        base64Url.encode(utf8.encode(entry.deviceId)),
      );
      http.headers.set(
        'X-Recording-Id',
        base64Url.encode(utf8.encode(entry.fileId)),
      );
      http.headers.set('X-Content-SHA256', entry.contentHash);
      var received = 0;
      final stream = audio.openRead().asyncMap((bytes) async {
        await request.requireNetwork?.call();
        received += bytes.length;
        onProgress?.call(received, entry.sizeBytes);
        return bytes;
      });
      await http.addStream(stream).timeout(timeout);
      if (received != entry.sizeBytes) {
        throw const RecordingUploadException('上传源文件在传输过程中改变');
      }
      final response = await http.close().timeout(timeout);
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw RecordingUploadException(
          '上传服务未接受文件（HTTP ${response.statusCode}）',
        );
      }
      final body = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (body.length + chunk.length > 65536) {
          throw const RecordingUploadException('上传回执过大');
        }
        body.addAll(chunk);
      }
      final receipt = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final id = receipt['fileId'];
      if (receipt['accepted'] != true ||
          id is! String ||
          id.trim().isEmpty ||
          id.length > 1024) {
        throw const RecordingUploadException('上传服务没有返回有效的接收确认和文件 ID');
      }
      return RecordingUploadReceipt(cloudFileId: id);
    } on RecordingUploadException {
      rethrow;
    } on RecordingNetworkPolicyException {
      rethrow;
    } on RecordingUploadConfigurationException {
      rethrow;
    } on TimeoutException {
      throw const RecordingUploadException('上传超时；保留本地文件，使用同一幂等键重试');
    } on FormatException {
      throw const RecordingUploadException('上传回执不是有效 JSON');
    } on TypeError {
      throw const RecordingUploadException('上传回执格式不符合服务合约');
    } catch (_) {
      // Do not leak bearer tokens, signed query URLs or response bodies.
      throw const RecordingUploadException('上传失败，请检查网络和服务合约后重试');
    } finally {
      http?.abort();
      _active = null;
      _busy = false;
    }
  }

  @override
  Future<void> cancelActive() async {
    _active?.abort();
  }

  void dispose() {
    if (_ownsClient) _client.close(force: true);
  }
}
