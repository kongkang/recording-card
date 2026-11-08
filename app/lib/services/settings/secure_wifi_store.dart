import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Test substitutes are injected explicitly; production defaults to Keychain /
/// Android encrypted storage. No fallback to plaintext preferences.
abstract interface class SecureWifiStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureWifiStore implements SecureWifiStore {
  final FlutterSecureStorage storage;
  const FlutterSecureWifiStore({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  });
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}
