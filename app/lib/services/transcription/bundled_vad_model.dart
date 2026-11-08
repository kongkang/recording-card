import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'asr_model_store.dart';

/// Small MIT-licensed Silero model reused from the authorized reference app.
/// Installation does not download a model or read/upload any recording.
class BundledVadModel {
  BundledVadModel._();

  static const assetPath = 'assets/models/silero_vad.onnx';
  static const artifact = ModelArtifact(
    fileName: 'silero_vad.onnx',
    sizeBytes: 643854,
    sha256Digest:
        '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
  );
  static Future<void> _tail = Future.value();

  static Future<String> ensureReady(
    Directory directory, {
    AssetBundle? bundle,
  }) {
    final result = _tail.then((_) async {
      await directory.create(recursive: true);
      final target = File('${directory.path}/${artifact.fileName}');
      if (await target.exists() &&
          await target.length() == artifact.sizeBytes) {
        final digest = await sha256.bind(target.openRead()).first;
        if (digest.toString() == artifact.sha256Digest) return target.path;
      }
      final data = await (bundle ?? rootBundle).load(assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.length != artifact.sizeBytes ||
          sha256.convert(bytes).toString() != artifact.sha256Digest) {
        throw StateError('内置静音模型校验失败，不能伪造静音结果');
      }
      final temporary = File(
        '${target.path}.part.${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return target.path;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
