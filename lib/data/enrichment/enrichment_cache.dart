// Hive cache for Phase 2 enrichment (MusicBrainz, Discogs,
// TheAudioDB). One box, keys prefixed per source. Follows the
// youtube_video_ids pattern: hits store JSON + timestamp, misses
// store a timestamp only and retry only after the TTL (30 days).

import 'package:hive_flutter/hive_flutter.dart';

import 'enrichment_models.dart';

/// A cached entry is fresh when its timestamp is within [ttl].
bool isCacheEntryFresh(
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

class EnrichmentCache {
  static const boxName = 'enrichment_cache';
  static const ttl = Duration(days: 30);

  final Box _box;

  EnrichmentCache(this._box);

  static Future<EnrichmentCache> open() async {
    final box = await Hive.openBox(boxName);
    return EnrichmentCache(box);
  }

  /// Cache key for a MusicBrainz track lookup (normalized key).
  static String musicBrainzTrackKey(String normalizedKey) =>
      'mb:track:$normalizedKey';

  Map<String, dynamic>? _entry(String key) {
    final value = _box.get(key);
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  /// Fresh track enrichment, or null (unknown, stale, cached miss).
  TrackEnrichment? lookupTrack(String normalizedKey) {
    final entry = _entry(musicBrainzTrackKey(normalizedKey));
    if (!isCacheEntryFresh(entry, DateTime.now(), ttl: ttl)) return null;
    final value = entry!['value'];
    if (value is Map) {
      try {
        return TrackEnrichment.fromJson(value.cast<String, dynamic>());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Whether a lookup for [normalizedKey] should be attempted at
  /// [now]: false when a fresh hit or a fresh miss is cached.
  bool shouldRetryTrack(String normalizedKey, DateTime now) =>
      !isCacheEntryFresh(
          _entry(musicBrainzTrackKey(normalizedKey)), now,
          ttl: ttl);

  void storeTrack(String normalizedKey, TrackEnrichment enrichment) =>
      _box.put(musicBrainzTrackKey(normalizedKey), {
        'cachedAt': DateTime.now().toIso8601String(),
        'value': enrichment.toJson(),
      });

  /// Record a miss so later runs skip this track until TTL expiry.
  void storeTrackMiss(String normalizedKey) =>
      _box.put(musicBrainzTrackKey(normalizedKey), {
        'cachedAt': DateTime.now().toIso8601String(),
        'miss': true,
      });
}
