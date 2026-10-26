// Hive cache for LRCLIB lyrics (Phase 5, push 1). Follows the
// youtube_video_ids pattern: hits store JSON + timestamp, misses
// store a timestamp only and are retried only after the TTL.
// TTL is 30 days (plan §0: enrichment metadata).

import 'package:hive_flutter/hive_flutter.dart';

import '../engine/recommendation_engine.dart';
import 'lrclib_client.dart';

/// A cached lyrics entry is fresh when its timestamp is within [ttl].
bool isLyricsCacheEntryFresh(
  Map<String, dynamic>? entry,
  DateTime now, {
  Duration ttl = const Duration(days: 30),
}) {
  if (entry == null) return false;
  final raw = entry['cachedAt'];
  final cachedAt = raw is String ? DateTime.tryParse(raw) : null;
  if (cachedAt == null) return false;
  return now.difference(cachedAt) < ttl;
}

class LyricsCache {
  static const boxName = 'lyrics_cache';
  static const ttl = Duration(days: 30);

  final Box _box;

  LyricsCache(this._box);

  static Future<LyricsCache> open() async {
    final box = await Hive.openBox(boxName);
    return LyricsCache(box);
  }

  /// Cache key for a track lookup (normalized artist+title key, the
  /// same function generation uses everywhere else).
  static String keyFor(String artist, String title) =>
      'lrclib:${RecommendationEngine.normalizeKey(artist, title)}';

  Map<String, dynamic>? _entry(String key) {
    final value = _box.get(key);
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  /// Fresh cached lyrics, or null (unknown, stale, cached miss).
  LrclibLyrics? lookup(String artist, String title) {
    final entry = _entry(keyFor(artist, title));
    if (!isLyricsCacheEntryFresh(entry, DateTime.now(), ttl: ttl)) {
      return null;
    }
    final value = entry!['value'];
    if (value is Map) {
      try {
        return LrclibLyrics.fromJson(value.cast<String, dynamic>());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Whether a lookup for this track should be attempted at [now]:
  /// false when a fresh hit or a fresh miss is cached.
  bool shouldRetry(String artist, String title, DateTime now) =>
      !isLyricsCacheEntryFresh(_entry(keyFor(artist, title)), now,
          ttl: ttl);

  void store(String artist, String title, LrclibLyrics lyrics) =>
      _box.put(keyFor(artist, title), {
        'cachedAt': DateTime.now().toIso8601String(),
        'value': lyrics.toJson(),
      });

  /// Record a miss so later views skip this track until TTL expiry.
  void storeMiss(String artist, String title) =>
      _box.put(keyFor(artist, title), {
        'cachedAt': DateTime.now().toIso8601String(),
        'miss': true,
      });
}
