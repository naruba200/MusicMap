// Thin wrapper around flutter_secure_storage for OAuth tokens.
// Keys are namespaced per platform: "<platformId>_access_token", etc.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStore {
  final FlutterSecureStorage _storage;

  TokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  String _key(String platformId, String name) => '${platformId}_$name';

  Future<void> saveTokens(
    String platformId, {
    required String accessToken,
    String? refreshToken,
    int? expiresInSeconds,
  }) async {
    await _storage.write(
        key: _key(platformId, 'access_token'), value: accessToken);
    if (refreshToken != null) {
      await _storage.write(
          key: _key(platformId, 'refresh_token'), value: refreshToken);
    }
    if (expiresInSeconds != null) {
      final expiry =
          DateTime.now().add(Duration(seconds: expiresInSeconds - 60));
      await _storage.write(
          key: _key(platformId, 'expires_at'),
          value: expiry.toIso8601String());
    }
  }

  Future<String?> accessToken(String platformId) =>
      _storage.read(key: _key(platformId, 'access_token'));

  Future<String?> refreshToken(String platformId) =>
      _storage.read(key: _key(platformId, 'refresh_token'));

  /// True when a non-expired access token exists.
  Future<bool> hasValidToken(String platformId) async {
    final token = await accessToken(platformId);
    if (token == null || token.isEmpty) return false;
    final expiresAt = await _storage.read(key: _key(platformId, 'expires_at'));
    if (expiresAt == null) return true; // no expiry info: assume valid
    final expiry = DateTime.tryParse(expiresAt);
    return expiry == null || expiry.isAfter(DateTime.now());
  }

  Future<void> clear(String platformId) async {
    await _storage.delete(key: _key(platformId, 'access_token'));
    await _storage.delete(key: _key(platformId, 'refresh_token'));
    await _storage.delete(key: _key(platformId, 'expires_at'));
  }
}
