// Hive cache for Last.fm album tracklists (album.getInfo).
// Follows the lyrics cache pattern: hits store JSON + timestamp,
// misses store a timestamp only and are retried only after the TTL
// (30 days, like the other metadata caches).

import 'package:hive_flutter/hive_flutter.dart';

import '../enrichment/album_enrichment.dart';
import '../enrichment/enrichment_cache.dart';
import 'lastfm_client.dart';

class AlbumTracklistCache {
  static const boxName = 'album_tracklists';
  static const ttl = Duration(days: 30);

  final Box _box;

  AlbumTracklistCache(this._box);

  static Future<AlbumTracklistCache> open() async {
    final box = await Hive.openBox(boxName);
    return AlbumTracklistCache(box);
  }

  /// Cache key for an album lookup. Same artist|album shape the
  /// enrichment layer already uses.
  static String keyFor(String artist, String album) =>
      'album:${albumEnrichmentKey(artist, album)}';

  Map<String, dynamic>? _entry(String key) {
    final value = _box.get(key);
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  /// Fresh cached tracklist, or null (unknown, stale, cached miss).
  /// An empty list is never stored as a hit: empty results are
  /// recorded with [storeMiss] instead.
  List<AlbumTrack>? lookup(String artist, String album) {
    final entry = _entry(keyFor(artist, album));
    if (!isCacheEntryFresh(entry, DateTime.now(), ttl: ttl)) return null;
    final value = entry!['value'];
    if (value is Map) {
      final raw = value['tracks'];
      if (raw is List) {
        try {
          return raw
              .whereType<Map>()
              .map((m) => AlbumTrack.fromJson(m.cast<String, dynamic>()))
              .toList();
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  /// Whether a lookup for this album should be attempted at [now]:
  /// false when a fresh hit or a fresh miss is cached.
  bool shouldRetry(String artist, String album, DateTime now) =>
      !isCacheEntryFresh(_entry(keyFor(artist, album)), now, ttl: ttl);

  void store(String artist, String album, List<AlbumTrack> tracks) =>
      _box.put(keyFor(artist, album), {
        'cachedAt': DateTime.now().toIso8601String(),
        'value': {
          'tracks': [for (final t in tracks) t.toJson()],
        },
      });

  /// Record that Last.fm has no tracklist for this album, so later
  /// opens skip the fetch until TTL expiry.
  void storeMiss(String artist, String album) =>
      _box.put(keyFor(artist, album), {
        'cachedAt': DateTime.now().toIso8601String(),
        'miss': true,
      });
}
