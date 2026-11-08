import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';

void main() {
  group('ModelInstaller', () {
    late Directory root;
    late HttpServer server;
    late Map<String, List<int>> files;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rc-model-test-');
      files = {};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path.replaceFirst('/', '');
        final bytes = files[path];
        if (bytes == null) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final range = request.headers.value('range');
        if (range != null && range.startsWith('bytes=')) {
          final start = int.parse(
            range.substring(6).split('-').first,
          );
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes $start-${bytes.length - 1}/${bytes.length}',
          );
          request.response.add(bytes.sublist(start));
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    ModelSpec specFor(List<int> bytes, {String? sha}) => ModelSpec(
      id: 'sensevoice-small-int8',
      displayName: '测试模型',
      version: 'v-test',
      kind: LocalModelKind.asr,
      files: [
        ModelFileSpec(
          relPath: 'tokens.txt',
          sizeBytes: bytes.length,
          sha256: sha ?? sha256.convert(bytes).toString(),
        ),
      ],
    );

    test('下载 → 校验 → 原子落盘 → status 已安装', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      files['sensevoice-small-int8/tokens.txt'] = bytes;
      final spec = specFor(bytes);
      final installer = ModelInstaller(root: root);

      await installer.installFrom(
        spec,
        baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
      );

      final path = await installer.filePath(spec, spec.files.first);
      expect(await File(path).readAsBytes(), bytes);
      expect(await File('$path.part').exists(), isFalse);
      final status = await installer.status(spec);
      expect(status.installed, isTrue);
      expect(status.missing, isEmpty);
    });

    test('已有 .part 时用 Range 续传，不重复下载前半段', () async {
      final bytes = List<int>.generate(8192, (i) => (i * 7) % 256);
      files['sensevoice-small-int8/tokens.txt'] = bytes;
      final spec = specFor(bytes);
      final installer = ModelInstaller(root: root);
      final path = await installer.filePath(spec, spec.files.first);
      await File(path).parent.create(recursive: true);
      await File('$path.part').writeAsBytes(bytes.sublist(0, 3000));

      await installer.installFrom(
        spec,
        baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
      );

      expect(await File(path).readAsBytes(), bytes);
    });

    test('SHA 不匹配：删除产物并报错', () async {
      final bytes = List<int>.filled(100, 1);
      files['sensevoice-small-int8/tokens.txt'] = bytes;
      final spec = specFor(bytes, sha: '0' * 64);
      final installer = ModelInstaller(root: root);

      await expectLater(
        installer.installFrom(
          spec,
          baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
        ),
        throwsA(isA<ModelInstallException>()),
      );
      final path = await installer.filePath(spec, spec.files.first);
      expect(await File(path).exists(), isFalse);
    });

    test('大小不符：保留 .part 供续传，报错', () async {
      final bytes = List<int>.filled(100, 1);
      files['sensevoice-small-int8/tokens.txt'] = bytes;
      final spec = ModelSpec(
        id: 'sensevoice-small-int8',
        displayName: '测试模型',
        version: 'v-test',
        kind: LocalModelKind.asr,
        files: const [
          ModelFileSpec(relPath: 'tokens.txt', sizeBytes: 200),
        ],
      );
      final installer = ModelInstaller(root: root);

      await expectLater(
        installer.installFrom(
          spec,
          baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
          verify: false,
        ),
        throwsA(isA<ModelInstallException>()),
      );
    });
  });
}
