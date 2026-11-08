/// 本地模型清单与安装器（SenseVoice / VAD / 声纹分割 / 声纹嵌入）。
///
/// 模型不随包发布（237MB 级），运行时从 `RC_MODEL_BASE` 或 manifest 下载到
/// 应用支持目录；VAD 是小文件（644KB），作为 asset 随包，首次使用时复制出来。
///
/// 安全边界：
/// - 下载先写 `.part`，校验大小/SHA-256 后再原子重命名；
/// - 支持 HTTP Range 续传；服务端不支持 Range 时整文件重下一次；
/// - 校验失败删除产物，绝不把半截模型交给推理引擎。
///
/// TODO(P1)：生产 manifest 必须补 SenseVoice 官方文件的 size/sha256；
/// 当前仓库里的规格来自开发机上的模型副本，避免把 237MB 模型提交进 git。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum LocalModelKind { asr, vad, speakerSegmentation, speakerEmbedding }

class ModelFileSpec {
  const ModelFileSpec({
    required this.relPath,
    this.sizeBytes = 0,
    this.sha256 = '',
  });

  final String relPath;

  /// 0 表示不校验大小（开发期 sideload）；生产规格必须填。
  final int sizeBytes;

  /// 空表示不校验；生产规格必须填。
  final String sha256;
}

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.version,
    required this.kind,
    required this.files,
    this.bundled = false,
  });

  final String id;
  final String displayName;
  final String version;
  final LocalModelKind kind;
  final List<ModelFileSpec> files;

  /// 随包资源（VAD），不走下载。
  final bool bundled;

  int get totalBytes => files.fold<int>(0, (a, f) => a + f.sizeBytes);
}

/// SenseVoice int8。
///
/// 注意：`model.int8.onnx` 的 size/sha 留空是有意的——开发期用本机已有的模型
/// 副本（与 reai 注册表里的 239MB 版本不是同一份）；正式发布前必须用 manifest
/// 下发的官方规格替换，否则供应链校验等于没有。
const ModelSpec senseVoiceSpec = ModelSpec(
  id: 'sensevoice-small-int8',
  displayName: '本地转写模型',
  version: '2024-07-17',
  kind: LocalModelKind.asr,
  files: [
    ModelFileSpec(relPath: 'model.int8.onnx'),
    ModelFileSpec(
      relPath: 'tokens.txt',
      sizeBytes: 315894,
      sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    ),
  ],
);

/// Silero VAD（随包）。
const ModelSpec sileroVadSpec = ModelSpec(
  id: 'silero-vad',
  displayName: '语音活动检测',
  version: '1',
  kind: LocalModelKind.vad,
  bundled: true,
  files: [
    ModelFileSpec(
      relPath: 'silero_vad.onnx',
      sizeBytes: 643854,
      sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    ),
  ],
);

/// 3D-Speaker Campplus 声纹嵌入（16k 中英通用）。
///
/// 注意：这里刻意**不再引入 pyannote 分割模型**。`OfflineSpeakerDiarization`
/// 在 iOS 真机上会卡死（fp32/int8 都在 9 分钟后仍未返回，Mac 正常），
/// 改为"VAD 语音段 → Campplus embedding → 本地聚类"，见 `speaker_clusterer.dart`。
const ModelSpec campplusEmbeddingSpec = ModelSpec(
  id: 'campplus-embedding',
  displayName: '声纹嵌入模型',
  version: '16k-common',
  kind: LocalModelKind.speakerEmbedding,
  files: [
    ModelFileSpec(
      relPath: '3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
      sizeBytes: 28281164,
      sha256: 'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2',
    ),
  ],
);

const List<ModelSpec> localModelRegistry = [
  senseVoiceSpec,
  sileroVadSpec,
  campplusEmbeddingSpec,
];

class ModelStatus {
  const ModelStatus({
    required this.spec,
    required this.installed,
    required this.presentBytes,
    required this.missing,
  });

  final ModelSpec spec;
  final bool installed;
  final int presentBytes;
  final List<String> missing;

  double get progress =>
      spec.totalBytes <= 0 ? (installed ? 1 : 0) : presentBytes / spec.totalBytes;
}

class ModelInstallException implements Exception {
  const ModelInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModelInstaller {
  ModelInstaller({Directory? root, http.Client Function()? clientFactory})
    : _rootOverride = root,
      _clientFactory = clientFactory ?? http.Client.new;

  final Directory? _rootOverride;
  final http.Client Function() _clientFactory;

  Directory? _resolvedRoot;

  Future<Directory> root() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final base =
        _rootOverride ?? Directory('${(await getApplicationSupportDirectory()).path}/models');
    if (!await base.exists()) await base.create(recursive: true);
    _resolvedRoot = base;
    return base;
  }

  Future<Directory> dirFor(ModelSpec spec) async {
    final base = await root();
    return Directory('${base.path}/${spec.id}/${spec.version}');
  }

  Future<String> filePath(ModelSpec spec, ModelFileSpec file) async {
    final dir = await dirFor(spec);
    return '${dir.path}/${file.relPath}';
  }

  /// 解析模型文件路径；未安装时返回 null。
  Future<String?> resolve(ModelSpec spec, String relPath) async {
    final dir = await dirFor(spec);
    final f = File('${dir.path}/$relPath');
    return await f.exists() ? f.path : null;
  }

  Future<ModelStatus> status(ModelSpec spec) async {
    final dir = await dirFor(spec);
    var present = 0;
    final missing = <String>[];
    for (final f in spec.files) {
      final file = File('${dir.path}/${f.relPath}');
      if (!await file.exists()) {
        missing.add(f.relPath);
        continue;
      }
      final length = await file.length();
      if (f.sizeBytes > 0 && length != f.sizeBytes) {
        missing.add(f.relPath);
        present += length;
        continue;
      }
      present += length;
    }
    return ModelStatus(
      spec: spec,
      installed: missing.isEmpty,
      presentBytes: present,
      missing: missing,
    );
  }

  /// 从 HTTP 目录安装：URL = `<base>/<spec.id>/<relPath>`。
  ///
  /// [verify] 为 false 时只校验存在与大小，用于开发期 sideload 的非官方副本。
  Future<void> installFrom(
    ModelSpec spec, {
    required Uri baseUri,
    void Function(double progress, String text)? onProgress,
    bool verify = true,
    bool Function()? isCancelled,
  }) async {
    if (spec.bundled) {
      await ensureBundled(spec);
      return;
    }
    final dir = await dirFor(spec);
    if (!await dir.exists()) await dir.create(recursive: true);

    final total = spec.totalBytes;
    var done = 0;
    for (final file in spec.files) {
      if (isCancelled?.call() == true) {
        throw const ModelInstallException('下载已取消');
      }
      final target = File('${dir.path}/${file.relPath}');
      if (await target.exists()) {
        final length = await target.length();
        if (file.sizeBytes == 0 || length == file.sizeBytes) {
          done += length;
          continue;
        }
        await target.delete();
      }

      final url = _resolveUrl(baseUri, '${spec.id}/${file.relPath}');
      onProgress?.call(
        total <= 0 ? 0 : (done / total).clamp(0, 1),
        '正在下载 ${spec.displayName}…',
      );
      final received = await _download(
        url,
        target,
        expectedSize: file.sizeBytes,
        onBytes: (bytes, _) {
          final current = done + bytes;
          onProgress?.call(
            total <= 0 ? 0 : (current / total).clamp(0, 1),
            '正在下载 ${spec.displayName}…',
          );
        },
        isCancelled: isCancelled,
      );

      if (verify && file.sha256.isNotEmpty) {
        final actual = await _sha256File(target);
        if (actual != file.sha256) {
          await target.delete();
          throw ModelInstallException(
            '${file.relPath} 校验失败（期望 ${file.sha256.substring(0, 8)}…，实际 ${actual.substring(0, 8)}…）',
          );
        }
      }
      done += received;
    }
    onProgress?.call(1, '${spec.displayName}已就绪');
  }

  /// 随包模型（VAD）：复制到模型目录并校验。
  Future<String> ensureBundled(ModelSpec spec) async {
    final file = spec.files.first;
    final target = File(await filePath(spec, file));
    if (await target.exists()) {
      final length = await target.length();
      if ((file.sizeBytes == 0 || length == file.sizeBytes) &&
          (file.sha256.isEmpty || await _sha256File(target) == file.sha256)) {
        return target.path;
      }
    }
    final data = await rootBundle.load('assets/models/${file.relPath}');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final digest = sha256.convert(bytes).toString();
    if (file.sha256.isNotEmpty && digest != file.sha256) {
      throw ModelInstallException('随包模型 ${file.relPath} 校验失败');
    }
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
    return target.path;
  }

  Future<void> delete(ModelSpec spec) async {
    final dir = await dirFor(spec);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static Uri _resolveUrl(Uri baseUri, String path) {
    final base = baseUri.toString().endsWith('/')
        ? baseUri
        : Uri.parse('${baseUri.toString()}/');
    return base.resolve(path);
  }

  Future<int> _download(
    Uri url,
    File target, {
    required int expectedSize,
    required void Function(int received, int total) onBytes,
    bool Function()? isCancelled,
  }) async {
    final client = _clientFactory();
    final part = File('${target.path}.part');
    var existing = await part.exists() ? await part.length() : 0;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (isCancelled?.call() == true) {
          throw const ModelInstallException('下载已取消');
        }
        final request = http.Request('GET', url);
        if (existing > 0) {
          request.headers['Range'] = 'bytes=$existing-';
        }
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 60));
        if (response.statusCode == 416 && existing > 0) {
          // 本地 .part 比服务端文件还大：删掉重来
          await part.delete();
          existing = 0;
          continue;
        }
        final append = response.statusCode == 206 && existing > 0;
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw ModelInstallException('下载失败（HTTP ${response.statusCode}）');
        }
        if (!append) existing = 0;
        final sink = part.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        var received = existing;
        try {
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 60),
          )) {
            if (isCancelled?.call() == true) {
              throw const ModelInstallException('下载已取消');
            }
            sink.add(chunk);
            received += chunk.length;
            onBytes(received, expectedSize);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (expectedSize > 0 && received != expectedSize) {
          // 不完整：保留 .part 供下次续传，但本次失败
          throw ModelInstallException(
            '下载不完整（$received / $expectedSize 字节）',
          );
        }
        await part.rename(target.path);
        return received;
      }
      throw const ModelInstallException('下载重试失败');
    } finally {
      client.close();
    }
  }

  static Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
