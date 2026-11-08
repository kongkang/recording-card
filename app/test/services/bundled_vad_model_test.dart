import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcription/bundled_vad_model.dart';

class TestVadBundle extends CachingAssetBundle {
  TestVadBundle(this.bytes);
  final Uint8List bytes;
  int loads = 0;
  @override
  Future<ByteData> load(String key) async {
    expect(key, BundledVadModel.assetPath);
    loads++;
    return ByteData.sublistView(bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'recording-card-vad-test-',
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'verified bundled MIT model installs once and retains managed cache',
    () async {
      final bytes = await File(BundledVadModel.assetPath).readAsBytes();
      final bundle = TestVadBundle(bytes);
      final path = await BundledVadModel.ensureReady(directory, bundle: bundle);
      expect(await File(path).length(), BundledVadModel.artifact.sizeBytes);
      expect(
        await BundledVadModel.ensureReady(directory, bundle: bundle),
        path,
      );
      expect(bundle.loads, 1);
    },
  );

  test(
    'corrupt asset refuses install without replacing an existing model',
    () async {
      final target = File(
        '${directory.path}/${BundledVadModel.artifact.fileName}',
      );
      await target.writeAsString('existing private file');
      await expectLater(
        BundledVadModel.ensureReady(
          directory,
          bundle: TestVadBundle(Uint8List(3)),
        ),
        throwsStateError,
      );
      expect(await target.readAsString(), 'existing private file');
    },
  );

  test(
    'failed install does not poison the serialized installer lane',
    () async {
      await expectLater(
        BundledVadModel.ensureReady(
          directory,
          bundle: TestVadBundle(Uint8List(0)),
        ),
        throwsStateError,
      );
      final bundle = TestVadBundle(
        await File(BundledVadModel.assetPath).readAsBytes(),
      );
      final path = await BundledVadModel.ensureReady(directory, bundle: bundle);
      expect(await File(path).length(), BundledVadModel.artifact.sizeBytes);
    },
  );
}
