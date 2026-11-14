// The user's Spotify web-player session: the sp_dc cookie plus the
// tokens minted from it.
//
// Secrets live here (secure storage) and in the client's in-memory cache
// only — never in the repo, never in logs, never in Hive. The sp_dc
// cookie is the long-lived session: it survives app restarts, and the
// client re-mints access tokens from it silently, so the user only ever
// signs in again when Spotify rejects the cookie itself.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key-value surface the Spotify session needs, so tests can
/// substitute an in-memory store without touching platform channels.
abstract class SpotifySecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production store: flutter_secure_storage.
class FlutterSecureStore implements SpotifySecureStore {
  final FlutterSecureStorage _storage;

  const FlutterSecureStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Persisted Spotify session keys (all namespaced `spotify_*`).
class SpotifySession {
  static const String spDcKey = 'spotify_sp_dc';
  static const String accessTokenKey = 'spotify_access_token';
  static const String accessTokenExpiresAtKey =
      'spotify_access_token_expires_at_ms';
  static const String clientTokenKey = 'spotify_client_token';
  static const String clientTokenExpiresAtKey =
      'spotify_client_token_expires_at_ms';

  final SpotifySecureStore _store;

  SpotifySession([SpotifySecureStore? store])
      : _store = store ?? const FlutterSecureStore();

  Future<String?> get spDc => _store.read(spDcKey);

  Future<void> saveSpDc(String value) => _store.write(spDcKey, value);

  Future<String?> get accessToken => _store.read(accessTokenKey);

  Future<int?> get accessTokenExpiresAtMs async {
    final raw = await _store.read(accessTokenExpiresAtKey);
    return raw == null ? null : int.tryParse(raw);
  }

  Future<void> saveAccessToken(String token, int expiresAtMs) async {
    await _store.write(accessTokenKey, token);
    await _store.write(
        accessTokenExpiresAtKey, expiresAtMs.toString());
  }

  Future<String?> get clientToken => _store.read(clientTokenKey);

  Future<int?> get clientTokenExpiresAtMs async {
    final raw = await _store.read(clientTokenExpiresAtKey);
    return raw == null ? null : int.tryParse(raw);
  }

  Future<void> saveClientToken(String token, int expiresAtMs) async {
    await _store.write(clientTokenKey, token);
    await _store.write(
        clientTokenExpiresAtKey, expiresAtMs.toString());
  }

  /// Clears every Spotify key (sign-out, or a session Spotify rejected).
  Future<void> clear() async {
    await _store.delete(spDcKey);
    await _store.delete(accessTokenKey);
    await _store.delete(accessTokenExpiresAtKey);
    await _store.delete(clientTokenKey);
    await _store.delete(clientTokenExpiresAtKey);
  }
}
