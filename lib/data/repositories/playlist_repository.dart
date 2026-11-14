// Saved (imported) playlists, persisted in Hive as JSON (FR-15, US-15).

import 'package:hive_flutter/hive_flutter.dart';

import '../engine/recommendation_engine.dart';
import '../models/music_models.dart';

class PlaylistRepository {
  static const String boxName = 'saved_playlists';
  final Box _box;

  PlaylistRepository(this._box);

  static Future<PlaylistRepository> open() async {
    final box = await Hive.openBox(boxName);
    return PlaylistRepository(box);
  }

  String _key(String platformId, String playlistId) =>
      '$platformId::$playlistId';

  List<SavedPlaylist> getAll() {
    final out = <SavedPlaylist>[];
    for (final value in _box.values) {
      try {
        out.add(SavedPlaylist.fromJson(
            Map<String, dynamic>.from(value as Map)));
      } catch (_) {
        // Skip corrupt entries rather than crashing the list.
      }
    }
    out.sort((a, b) => b.lastScannedAt.compareTo(a.lastScannedAt));
    return out;
  }

  SavedPlaylist? get(String platformId, String playlistId) {
    final raw = _box.get(_key(platformId, playlistId));
    if (raw == null) return null;
    return SavedPlaylist.fromJson(Map<String, dynamic>.from(raw as Map));
  }

  Future<void> save(SavedPlaylist playlist) =>
      _box.put(_key(playlist.info.platformId, playlist.info.id),
          playlist.toJson());

  /// Full export payload for FR-14b.
  List<Map<String, dynamic>> exportJson() =>
      [for (final p in getAll()) p.toJson()];

  Future<void> remove(String platformId, String playlistId) =>
      _box.delete(_key(platformId, playlistId));

  /// Appends [track] to the saved playlist (the mini-player's
  /// add-to-playlist). A track with the same normalized artist+title
  /// is never added twice. Returns true when the track was added,
  /// false when it was already there or the playlist does not exist.
  Future<bool> addTrack(
      String platformId, String playlistId, Track track) async {
    final existing = get(platformId, playlistId);
    if (existing == null) return false;
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    final alreadyThere = existing.tracks.any((t) =>
        RecommendationEngine.normalizeKey(t.artist, t.title) == key);
    if (alreadyThere) return false;
    await save(SavedPlaylist(
      info: existing.info,
      tracks: [...existing.tracks, track],
      settings: existing.settings,
      importedAt: existing.importedAt,
      lastScannedAt: existing.lastScannedAt,
    ));
    return true;
  }

  Future<void> updateSettings(
      String platformId, String playlistId, DiscoverySettings settings) async {
    final existing = get(platformId, playlistId);
    if (existing == null) return;
    await save(SavedPlaylist(
      info: existing.info,
      tracks: existing.tracks,
      settings: settings,
      importedAt: existing.importedAt,
      lastScannedAt: existing.lastScannedAt,
    ));
  }
}
