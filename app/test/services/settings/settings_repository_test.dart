import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

class FakeSecureWifiStore implements SecureWifiStore {
  final Map<String, String> values = {};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('test secure write unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late Directory temp;
  late FakeSecureWifiStore secrets;
  late SettingsRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('settings-repo-test-');
    secrets = FakeSecureWifiStore();
    repository = SettingsRepository(directory: temp, secureStore: secrets);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'six existing defaults and every switch persist across restart',
    () async {
      final initial = (await repository.load()).settings;
      expect(initial.switchesByLabel.values.toList(), [
        true,
        true,
        true,
        true,
        true,
        false,
      ]);
      for (var i = 0; i < AppSettings.switchKeys.length; i++) {
        await repository.setSwitch(
          AppSettings.switchLabels[i],
          !initial.toJson()[AppSettings.switchKeys[i]],
        );
      }
      final settings = (await SettingsRepository(
        directory: temp,
        secureStore: secrets,
      ).load()).settings;
      expect(settings.toJson().values.toList(), [
        false,
        false,
        false,
        false,
        false,
        true,
      ]);
      await expectLater(
        repository.setSwitch('unknown', true),
        throwsArgumentError,
      );
      await repository.setSwitch('autoTranscribe', true);
      expect((await repository.load()).settings.autoTranscribe, true);
    },
  );

  test('concurrent switch changes use latest snapshot rather than dropping another change', () async {
    await Future.wait([
      repository.setSwitch('continuousRecording', false),
      repository.setSwitch('markImportant', false),
    ]);
    final settings = (await repository.load()).settings;
    expect(settings.continuousRecording, false);
    expect(settings.markImportant, false);
  });

  test('Wi-Fi passwords only in secure store; same SSID replaces instead of duplicates', () async {
    final saved = await repository.saveWifiNetwork(
      ssid: 'test-wifi-2.4G',
      password: 'secret-key-1',
    );
    await repository.saveWifiNetwork(
      ssid: 'test-wifi-2.4G',
      password: 'secret-key-2',
    );
    final restarted = SettingsRepository(directory: temp, secureStore: secrets);
    expect((await restarted.load()).networks, hasLength(1));
    final credential = await restarted.readWifiCredential(saved.id);
    expect(credential.ssid, saved.ssid);
    expect(credential.password, 'secret-key-2');
    expect(credential.toString(), isNot(contains('secret-key')));
    final files = await temp
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    for (final file in files) {
      final text = await file.readAsString();
      expect(text, isNot(contains('secret-key-1')));
      expect(text, isNot(contains('secret-key-2')));
    }
    await restarted.removeWifiNetwork(saved.id);
    expect((await restarted.load()).networks, isEmpty);
    expect(secrets.values, isEmpty);
    await expectLater(
      restarted.readWifiCredential(saved.id),
      throwsA(isA<RecordingStorageException>()),
    );
  });

  test(
    'secure failure does not fall back to plaintext or register a network',
    () async {
      secrets.failWrites = true;
      await expectLater(
        repository.saveWifiNetwork(ssid: 'network', password: 'secret-key'),
        throwsStateError,
      );
      expect((await repository.load()).networks, isEmpty);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'missing or corrupted keychain entry requires explicit credential re-entry',
    () async {
      final saved = await repository.saveWifiNetwork(
        ssid: 'network',
        password: 'secret-key',
      );
      secrets.values.clear();
      await expectLater(
        repository.readWifiCredential(saved.id),
        throwsA(isA<RecordingStorageException>()),
      );
      secrets.values['recording_card.wifi.v1.${saved.id}'] = '{bad';
      await expectLater(
        repository.readWifiCredential(saved.id),
        throwsA(isA<RecordingStorageException>()),
      );
    },
  );

  test(
    'bad settings recover last backup; both bad generations fail closed',
    () async {
      await repository.save(const AppSettings(autoTranscribe: false));
      await repository.save(const AppSettings(autoClean: false));
      await File('${temp.path}/settings.json').writeAsString('{bad');
      final recovered = SettingsRepository(
        directory: temp,
        secureStore: secrets,
      );
      expect((await recovered.load()).settings.autoTranscribe, false);
      expect(recovered.diagnostics, isNotEmpty);
      await File('${temp.path}/settings.json').writeAsString('{bad');
      await File('${temp.path}/settings.json.bak').writeAsString('{bad');
      await expectLater(
        SettingsRepository(directory: temp, secureStore: secrets).load(),
        throwsA(isA<RepositoryCorruptionException>()),
      );
    },
  );

  test(
    'Wi-Fi input validation preserves open networks and rejects invalid keys',
    () async {
      final open = await repository.saveWifiNetwork(
        ssid: 'open-network',
        password: '',
      );
      expect((await repository.readWifiCredential(open.id)).password, '');
      await expectLater(
        repository.saveWifiNetwork(ssid: '', password: 'secret-key'),
        throwsArgumentError,
      );
      await expectLater(
        repository.saveWifiNetwork(ssid: 'network', password: 'short'),
        throwsArgumentError,
      );
    },
  );
}
