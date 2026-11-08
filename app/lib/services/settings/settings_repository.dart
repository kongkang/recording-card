import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../recordings/atomic_json_file.dart';
import 'app_settings.dart';
import 'secure_wifi_store.dart';

export 'app_settings.dart';
export 'secure_wifi_store.dart';

class SettingsRepository {
  final Directory directory;
  final SecureWifiStore secureStore;
  late final AtomicJsonFile _file = AtomicJsonFile(
    File('${directory.path}/settings.json'),
  );
  SettingsSnapshot? _snapshot;
  Future<void> _tail = Future<void>.value();
  final List<String> _diagnostics = [];
  List<String> get diagnostics => List.unmodifiable(_diagnostics);

  SettingsRepository({
    required Directory directory,
    SecureWifiStore? secureStore,
  }) : directory = directory.absolute,
       secureStore = secureStore ?? const FlutterSecureWifiStore();

  static Future<SettingsRepository> openDefault({
    SecureWifiStore? secureStore,
  }) async {
    final support = await getApplicationSupportDirectory();
    return SettingsRepository(
      directory: Directory('${support.path}/recording_card/v1'),
      secureStore: secureStore,
    );
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<SettingsSnapshot> _load() async {
    if (_snapshot != null) return _snapshot!;
    final value = await _file.read(
      validate: (json) {
        SettingsSnapshot.fromJson(json);
      },
    );
    final snapshot = value == null
        ? SettingsSnapshot()
        : SettingsSnapshot.fromJson(value);
    if (_file.recoveredBackup) {
      _diagnostics.add('Settings recovered from previous committed generation');
      await _file.write(snapshot.toJson());
    }
    _snapshot = snapshot;
    return snapshot;
  }

  Future<SettingsSnapshot> load() => _serial(_load);

  Future<void> save(AppSettings settings) => _serial(() async {
    final old = await _load();
    final next = SettingsSnapshot(settings: settings, networks: old.networks);
    await _file.write(next.toJson());
    _snapshot = next;
  });

  Future<AppSettings> setSwitch(String keyOrLabel, bool enabled) => _serial(
    () async {
      final old = await _load();
      final settings = old.settings.withSwitch(keyOrLabel, enabled);
      final next = SettingsSnapshot(settings: settings, networks: old.networks);
      await _file.write(next.toJson());
      _snapshot = next;
      return settings;
    },
  );

  Future<SavedWifiNetwork> saveWifiNetwork({
    required String ssid,
    required String password,
  }) => _serial(() async {
    final nameBytes = utf8.encode(ssid).length;
    if (nameBytes == 0 || nameBytes > 32 || ssid.contains('\u0000')) {
      throw ArgumentError('SSID must be 1–32 UTF-8 bytes without NUL');
    }
    final passwordBytes = utf8.encode(password).length;
    if (password.isNotEmpty &&
        !(passwordBytes >= 8 && passwordBytes <= 63) &&
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(password)) {
      throw ArgumentError(
        'Wi-Fi key must be empty (open network), 8–63 bytes, or 64 hex digits',
      );
    }
    final old = await _load();
    final id = sha256.convert(utf8.encode(ssid)).toString();
    // Secure write must succeed before the non-secret metadata becomes visible.
    await secureStore.write(
      _key(id),
      jsonEncode({'ssid': ssid, 'password': password}),
    );
    final network = SavedWifiNetwork(
      id: id,
      ssid: ssid,
      updatedAt: DateTime.now(),
    );
    final next = SettingsSnapshot(
      settings: old.settings,
      networks: [network, ...old.networks.where((item) => item.id != id)],
    );
    await _file.write(next.toJson());
    _snapshot = next;
    return network;
  });

  Future<WifiCredential> readWifiCredential(String id) => _serial(() async {
    final old = await _load();
    final networks = old.networks.where((network) => network.id == id);
    if (networks.isEmpty) {
      throw const RecordingStorageException(
        'Saved Wi-Fi network does not exist',
      );
    }
    final text = await secureStore.read(_key(id));
    if (text == null) {
      throw const RecordingStorageException(
        'Secure Wi-Fi credential is unavailable; re-enter it',
      );
    }
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['ssid'] != networks.first.ssid) {
        throw const FormatException('Credential mismatch');
      }
      return WifiCredential(
        ssid: json['ssid'] as String,
        password: json['password'] as String,
      );
    } on FormatException {
      throw const RecordingStorageException(
        'Secure Wi-Fi credential is invalid; re-enter it',
      );
    } on TypeError {
      throw const RecordingStorageException(
        'Secure Wi-Fi credential is invalid; re-enter it',
      );
    }
  });

  Future<void> removeWifiNetwork(String id) => _serial(() async {
    final old = await _load();
    await secureStore.delete(_key(id));
    final next = SettingsSnapshot(
      settings: old.settings,
      networks: old.networks.where((network) => network.id != id).toList(),
    );
    await _file.write(next.toJson());
    _snapshot = next;
  });

  String _key(String id) => 'recording_card.wifi.v1.$id';
}
