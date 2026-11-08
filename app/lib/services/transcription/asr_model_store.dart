import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'transcription_types.dart';

class ModelArtifact {
  final String fileName;
  final int sizeBytes;
  final String sha256Digest;
  final Uri? downloadUri;
  const ModelArtifact({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256Digest,
    this.downloadUri,
  });
  void validateSpec() {
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(fileName) ||
        fileName == '.' ||
        fileName == '..' ||
        sizeBytes <= 0 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256Digest)) {
      throw ArgumentError('模型清单必须包含安全文件名、精确大小和SHA256');
    }
  }
}

/// Values audited from ReAI mobile model_registry.dart at 7f9d13a.
/// No download or license acceptance is implicit. Remote mirrors must deliver
/// exactly these artifacts; callers can configure other verified artifacts.
const senseVoiceInt8Artifact = ModelArtifact(
  fileName: 'model.int8.onnx',
  sizeBytes: 239233841,
  sha256Digest:
      'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
);
const senseVoiceTokensArtifact = ModelArtifact(
  fileName: 'tokens.txt',
  sizeBytes: 315894,
  sha256Digest:
      'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
);

class AsrModelStore {
  final Directory directory;
  final ModelArtifact model;
  final ModelArtifact tokens;
  final ModelArtifact? vad;
  final Set<String> allowedDownloadHosts;
  final String? nativeLibraryPath;
  final bool licenseAccepted;
  final Duration downloadTimeout;
  Future<void> _tail = Future.value();

  AsrModelStore({
    required this.directory,
    this.model = senseVoiceInt8Artifact,
    this.tokens = senseVoiceTokensArtifact,
    this.vad,
    Set<String> allowedDownloadHosts = const {},
    this.nativeLibraryPath,
    this.licenseAccepted = false,
    this.downloadTimeout = const Duration(minutes: 15),
  }) : allowedDownloadHosts = Set.unmodifiable(
         allowedDownloadHosts.map((h) => h.toLowerCase()),
       ) {
    model.validateSpec();
    tokens.validateSpec();
    vad?.validateSpec();
    if ({
          model.fileName,
          tokens.fileName,
          if (vad != null) vad!.fileName,
        }.length !=
        (vad == null ? 2 : 3)) {
      throw ArgumentError('模型文件名不能重复');
    }
    if (downloadTimeout <= Duration.zero) {
      throw ArgumentError('下载超时必须为正');
    }
  }

  Future<AsrModelPaths> ensureReady({
    bool allowDownload = false,
    CancellationToken? cancellation,
    void Function(String fileName, int received, int total)? onDownloadProgress,
  }) {
    final result = _tail.then((_) async {
      final token = cancellation ?? CancellationToken();
      token.throwIfCancelled();
      if (!licenseAccepted) {
        throw const TranscriptionException(
          'model_license',
          '必须先确认SenseVoice权重许可与使用场景',
        );
      }
      for (final artifact in [model, tokens, ?vad]) {
        token.throwIfCancelled();
        final file = File('${directory.path}/${artifact.fileName}');
        if (await _verified(file, artifact)) {
          continue;
        }
        if (!allowDownload) {
          throw TranscriptionException(
            await file.exists() ? 'model_corrupt' : 'model_missing',
            '${artifact.fileName}未安装或校验失败，请配置模型路径/显式下载',
          );
        }
        if (artifact.downloadUri == null) {
          throw const TranscriptionException('model_source', '未配置受信任模型下载来源');
        }
        await directory.create(recursive: true);
        await _download(file, artifact, token, onDownloadProgress);
      }
      token.throwIfCancelled();
      return AsrModelPaths(
        modelPath: '${directory.path}/${model.fileName}',
        tokensPath: '${directory.path}/${tokens.fileName}',
        vadPath: vad == null ? null : '${directory.path}/${vad!.fileName}',
        nativeLibraryPath: nativeLibraryPath,
      );
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> _verified(File file, ModelArtifact artifact) async {
    if (!await file.exists() || await file.length() != artifact.sizeBytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == artifact.sha256Digest.toLowerCase();
  }

  void _checkUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        !allowedDownloadHosts.contains(uri.host.toLowerCase()) ||
        (uri.hasPort && uri.port != 443)) {
      throw const TranscriptionException(
        'model_source',
        '模型下载只允许显式白名单HTTPS来源（含重定向）',
      );
    }
  }

  Future<void> _download(
    File target,
    ModelArtifact artifact,
    CancellationToken token,
    void Function(String, int, int)? progress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final partial = File(
      '${target.path}.part.${DateTime.now().microsecondsSinceEpoch}',
    );
    IOSink? sink;
    var timedOut = false;
    final timer = Timer(downloadTimeout, () {
      timedOut = true;
      client.close(force: true);
    });
    void abort() {
      client.close(force: true);
    }

    token.addListener(abort);
    try {
      var uri = artifact.downloadUri!;
      HttpClientResponse? response;
      for (var redirects = 0; redirects <= 5; redirects++) {
        token.throwIfCancelled();
        _checkUri(uri);
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        response = await request.close();
        if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
          break;
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirects == 5) {
          throw const TranscriptionException('model_download', '模型重定向无效/次数超限');
        }
        uri = uri.resolve(location);
      }
      if (response == null || response.statusCode != 200) {
        throw const TranscriptionException('model_download', '模型下载服务未返回完整文件');
      }
      if (response.contentLength >= 0 &&
          response.contentLength != artifact.sizeBytes) {
        throw const TranscriptionException('model_corrupt', '模型下载长度与清单不符');
      }
      sink = partial.openWrite();
      var received = 0;
      await for (final bytes in response) {
        token.throwIfCancelled();
        received += bytes.length;
        if (received > artifact.sizeBytes) {
          throw const TranscriptionException('model_corrupt', '模型下载超出清单大小');
        }
        sink.add(bytes);
        progress?.call(artifact.fileName, received, artifact.sizeBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      token.throwIfCancelled();
      if (!await _verified(partial, artifact)) {
        throw const TranscriptionException('model_corrupt', '模型大小/SHA256校验失败');
      }
      // Only replace this managed artifact after complete verification.
      await partial.rename(target.path);
    } catch (error) {
      token.throwIfCancelled();
      if (timedOut) {
        throw const TranscriptionException('model_download_timeout', '模型下载超时');
      }
      if (error is TranscriptionException) {
        rethrow;
      }
      throw const TranscriptionException(
        'model_download',
        '模型下载/写入失败，请检查网络和存储空间',
      );
    } finally {
      timer.cancel();
      token.removeListener(abort);
      client.close(force: true);
      await sink?.close();
      if (await partial.exists()) {
        await partial.delete();
      }
    }
  }
}
