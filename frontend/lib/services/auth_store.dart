import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class AuthStore {
  Future<String?> readRefreshToken();
  Future<bool> readGuestMode();
  Future<void> saveRefreshToken(String value);
  Future<void> saveGuestMode(bool value);
  Future<void> clear();
}

final class SecureAuthStore implements AuthStore {
  SecureAuthStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _refreshKey = 'finguard_refresh_token';
  static const String _guestKey = 'finguard_guest_mode';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  @override
  Future<bool> readGuestMode() async =>
      await _storage.read(key: _guestKey) == 'true';

  @override
  Future<void> saveRefreshToken(String value) async {
    await _storage.write(key: _refreshKey, value: value);
    await _storage.delete(key: _guestKey);
  }

  @override
  Future<void> saveGuestMode(bool value) async {
    if (value) {
      await _storage.write(key: _guestKey, value: 'true');
      await _storage.delete(key: _refreshKey);
    } else {
      await _storage.delete(key: _guestKey);
    }
  }

  @override
  Future<void> clear() => _storage.deleteAll();
}
