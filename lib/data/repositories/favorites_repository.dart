// Favorite tracks and albums, persisted in Hive (FR-12). Keyed by normalized
// artist+title so the same song from different runs dedupes.

import 'package:hive_flutter/hive_flutter.dart';

import '../engine/recommendation_engine.dart';
import '../models/music_models.dart';

class FavoritesRepository {
  static const boxName = 'favorites';

  final Box _box;

  FavoritesRepository(this._box);

  static Future<FavoritesRepository> open() async {
    final box = await Hive.openBox(boxName);
    return FavoritesRepository(box);
  }

  static String keyOf(String artist, String title) =>
      RecommendationEngine.normalizeKey(artist, title);

  static bool _isAlbumEntry(dynamic value) =>
      value is Map && value['kind'] == 'album';

  bool isFavorite(String artist, String title) =>
      _box.containsKey(keyOf(artist, title));

  /// Toggles the favorite state; returns the new state (true = favorited).
  bool toggle(Track track) {
    final key = keyOf(track.artist, track.title);
    if (_box.containsKey(key)) {
      _box.delete(key);
      return false;
    }
    _box.put(key, {
      'kind': 'track',
      'track': track.toJson(),
      'addedAt': DateTime.now().toIso8601String(),
    });
    return true;
  }

  /// Remove a favorite by artist+title (used by multi-select, FR-12c).
  void remove(String artist, String title) =>
      _box.delete(keyOf(artist, title));

  /// Remove a favorite by its storage key.
  void removeByKey(String key) => _box.delete(key);

  List<Track> getAll() {
    final tracks = <Track>[];
    for (final value in _box.values) {
      if (value is Map && !_isAlbumEntry(value)) {
        final t = (value['track'] as Map?)?.cast<String, dynamic>();
        if (t != null) tracks.add(Track.fromJson(t));
      }
    }
    return tracks;
  }

  // -- Albums ---------------------------------------------------------------

  bool isAlbumFavorite(String artist, String name) =>
      _box.containsKey(keyOf(artist, name));

  /// Toggles an album favorite; returns the new state (true = favorited).
  bool toggleAlbum(AlbumRec album) {
    final key = keyOf(album.artist, album.name);
    if (_box.containsKey(key)) {
      _box.delete(key);
      return false;
    }
    _box.put(key, {
      'kind': 'album',
      'album': album.toJson(),
      'addedAt': DateTime.now().toIso8601String(),
    });
    return true;
  }

  List<AlbumRec> getAlbums() {
    final albums = <AlbumRec>[];
    for (final value in _box.values) {
      if (_isAlbumEntry(value)) {
        final a = (value['album'] as Map?)?.cast<String, dynamic>();
        if (a != null) {
          try {
            albums.add(AlbumRec.fromJson(a));
          } catch (_) {
            // ignore malformed legacy entries
          }
        }
      }
    }
    return albums;
  }

  /// Distinct favorited artist names — seeds Daily picks (FR-12b, M3).
  List<String> favoritedArtists() {
    final artists = <String>{};
    for (final t in getAll()) {
      final a = t.artist.trim();
      if (a.isNotEmpty) artists.add(a);
    }
    for (final a in getAlbums()) {
      final ar = a.artist.trim();
      if (ar.isNotEmpty) artists.add(ar);
    }
    return artists.toList();
  }

  /// Full export payload for FR-14b.
  List<Map<String, dynamic>> exportJson() => [
        for (final key in _box.keys)
          {'key': key.toString(), 'value': _box.get(key)},
      ];
}
