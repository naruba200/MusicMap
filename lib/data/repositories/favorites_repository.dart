// Favorite tracks, persisted in Hive (FR-12). Keyed by normalized
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
      'track': track.toJson(),
      'addedAt': DateTime.now().toIso8601String(),
    });
    return true;
  }

  List<Track> getAll() {
    final tracks = <Track>[];
    for (final value in _box.values) {
      if (value is Map) {
        final t = (value['track'] as Map?)?.cast<String, dynamic>();
        if (t != null) tracks.add(Track.fromJson(t));
      }
    }
    return tracks;
  }

  /// Distinct favorited artist names — seeds Daily picks (FR-12b, M3).
  List<String> favoritedArtists() =>
      getAll().map((t) => t.artist.trim()).toSet().toList();
}
