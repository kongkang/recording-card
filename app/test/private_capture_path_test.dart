import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/runtime/private_capture_path.dart';

void main() {
  late Directory temp, capture;
  late File manifest, audio;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rc-private-rebase-');
    capture = Directory(
      '${temp.path}/Library/Application Support/recording_card/v1/capture',
    );
    await capture.create(recursive: true);
    manifest = await File('${capture.path}/session-000001.json')
        .writeAsString('{}');
    audio = await File('${capture.path}/session-000001.wav')
        .writeAsBytes([1, 2, 3]);
  });
  tearDown(() async => temp.delete(recursive: true));
  const old =
      '/var/mobile/Containers/Data/Application/7441D036-B57A-4298-ABAC-5421FC0F2FAD/Library/Application Support/recording_card/v1/capture/session-000001.wav';
  test('same private sibling survives iOS container UUID replacement without changing sidecar', () async {
    expect(
      (await resolvePrivateCaptureAudio(capture, manifest, old)).path,
      audio.path,
    );
    expect(await manifest.readAsString(), '{}');
  });
  test('private var alias in historic iOS path is equivalent', () async {
    expect(
      (await resolvePrivateCaptureAudio(
        capture,
        manifest,
        '/private$old',
      )).path,
      audio.path,
    );
  });
  test('regular current private path is unchanged', () async {
    expect(
      (await resolvePrivateCaptureAudio(capture, manifest, audio.path)).path,
      audio.path,
    );
  });
  test('external path and incorrect filename remain rejected', () async {
    for (final path in [
      '/tmp/session-000001.wav',
      old.replaceFirst('session-000001', 'other-000001'),
      old.replaceFirst('capture/', 'capture/../capture/'),
    ]) {
      await expectLater(
        resolvePrivateCaptureAudio(capture, manifest, path),
        throwsFormatException,
      );
    }
  });
  test('a real sibling must exist; no fabricated recovery', () async {
    await audio.delete();
    await expectLater(
      resolvePrivateCaptureAudio(capture, manifest, old),
      throwsFormatException,
    );
  });
  test('a paired symlink cannot escape capture ownership', () async {
    await audio.delete();
    final outside = await File('${temp.path}/outside.wav').writeAsBytes([4]);
    await Link(audio.path).create(outside.path);
    await expectLater(
      resolvePrivateCaptureAudio(capture, manifest, old),
      throwsFormatException,
    );
  });
  test('manifest symlink cannot escape the private directory', () async {
    await manifest.delete();
    final outside = await File('${temp.path}/outside.json').writeAsString('{}');
    await Link(manifest.path).create(outside.path);
    await expectLater(
      resolvePrivateCaptureAudio(capture, manifest, old),
      throwsFormatException,
    );
  });
}
