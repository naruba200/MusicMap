// ListenBrainz optional username layer (Phase 3, step 1).
//
// How it works, and what it deliberately does NOT do:
// - The user enters a ListenBrainz username in Settings (no key, no
//   OAuth: the recommendation endpoint serves public data). If no
//   username is set, the provider never constructs a call at all —
//   this layer is completely inactive, not just empty.
// - When a username IS set, one call per generation fetches that
//   user's recordings recommended with `artist_type=similar` — i.e.
//   tracks by artists similar to the user's own top artists. That is
//   the documented public recommendation endpoint
//   (GET /1/cf/recommendation/user/{user}/recording); it is the
//   user-facing form of ListenBrainz's similar-artist data.
// - The Labs similar-artists dataset endpoint was NOT used: MetaBrainz
//   describes it as semi-stable / proof-of-concept with limited
//   coverage, it is keyed by MusicBrainz artist MBID (which would
//   cost a MusicBrainz lookup per seed at 1 req/s), and its response
//   shape is not a stable public contract. The recommendation
//   endpoint gives the same kind of data in one capped call.
// - Results join the fallback pool at the standard 0.4 weight (see
//   the provider merge, mirroring the 1b/1c expansion merges) with
//   the honest reason "From ListenBrainz". Last.fm stays primary.
// - Failure tolerance, copied from Deezer/iTunes: any error returns
//   [] and never aborts a run. Plain Dio, no retry interceptor,
//   short timeouts. One call per generation, cached 7 days in Hive
//   (hits and misses alike), keyed by lowercased username.

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../enrichment/enrichment_cache.dart';
import '../lastfm/lastfm_client.dart';

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

List<Map<String, dynamic>> _asMapList(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }
  return const [];
}

String _nonEmpty(dynamic value) =>
    value is String ? value.trim() : '';

/// Recommended tracks from a ListenBrainz recommendation payload.
///
/// Accepts both shapes the API has served, so a field rename on one
/// shape does not silently empty the layer:
/// - recommendation shape: `payload.recordings[]` with
///   `artist_name` / `recording_name`;
/// - listen-shaped shape: items carrying `track_metadata` with
///   `artist_name` / `track_name`.
/// Empty artist/title pairs are dropped; order is source order and
/// the result is capped at [limit] (the caller also caps the request).
List<SimilarTrack> parseListenBrainzRecommendations(
  Map<String, dynamic> json, {
  int limit = 25,
}) {
  final payload = _asMap(json['payload']);
  var items = _asMapList(payload['recordings']);
  if (items.isEmpty) items = _asMapList(json['recordings']);
  final tracks = <SimilarTrack>[];
  final seen = <String>{};
  for (final item in items) {
    final meta = _asMap(item['track_metadata']);
    final artist = _nonEmpty(item['artist_name']).isNotEmpty
        ? _nonEmpty(item['artist_name'])
        : _nonEmpty(meta['artist_name']);
    final title = _nonEmpty(item['recording_name']).isNotEmpty
        ? _nonEmpty(item['recording_name'])
        : (_nonEmpty(meta['track_name']).isNotEmpty
            ? _nonEmpty(meta['track_name'])
            : _nonEmpty(item['track_name']));
    if (artist.isEmpty || title.isEmpty) continue;
    // Dedupe by lowercased pair; the first occurrence wins.
    if (!seen.add('${artist.toLowerCase()} - ${title.toLowerCase()}')) {
      continue;
    }
    tracks.add(SimilarTrack(artist: artist, title: title, match: 0));
    if (tracks.length >= limit) break;
  }
  return tracks;
}

/// Best-effort ListenBrainz client: [] on any failure, never throws.
class ListenBrainzClient {
  /// Mandatory meaningful User-Agent (same form as MusicBrainz).
  static const userAgent =
      'MusicMan/1.0.0 (https://github.com/naruba200/MusicMap)';

  /// One call per generation; 25 tracks is plenty for a 0.4-weight
  /// fallback pool, and the endpoint caps `count` at 100.
  static const maxRecommendations = 25;

  static const _base = 'https://api.listenbrainz.org/1';

  final Dio _dio;

  /// Plain Dio by default (no shared retry interceptor).
  ListenBrainzClient([Dio? dio]) : _dio = dio ?? Dio();

  /// Similar-artist-filtered recommendations for [username], or []
  /// when the username is blank, the user has no recommendations,
  /// or anything fails. An empty username makes no request at all.
  Future<List<SimilarTrack>> recommendedTracks(
    String username, {
    int count = maxRecommendations,
  }) async {
    final user = username.trim();
    if (user.isEmpty) return const [];
    final capped = count.clamp(1, 100);
    try {
      final res = await _dio.get(
        '$_base/cf/recommendation/user/${Uri.encodeComponent(user)}/recording',
        queryParameters: {'artist_type': 'similar', 'count': capped},
        options: Options(
          headers: {'User-Agent': userAgent},
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      return parseListenBrainzRecommendations(
        _asMap(res.data),
        limit: capped,
      );
    } catch (_) {
      return const [];
    }
  }
}

/// Hive cache for ListenBrainz recommendations (own box, 7-day TTL,
/// misses cached like the enrichment cache). Entries hold only the
/// artist/title pairs; scoring happens at runtime in the provider.
class ListenBrainzCache {
  static const boxName = 'listenbrainz_cache';
  static const ttl = Duration(days: 7);

  final Box _box;

  ListenBrainzCache(this._box);

  static Future<ListenBrainzCache> open() async {
    final box = await Hive.openBox(boxName);
    return ListenBrainzCache(box);
  }

  /// Cache key for a username (lowercased + trimmed, so "User" and
  /// "user " share one entry).
  static String keyFor(String username) =>
      'lb:recs:${username.trim().toLowerCase()}';

  Map<String, dynamic>? _entry(String username) {
    final value = _box.get(keyFor(username));
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  /// Fresh cached recommendations, or null (unknown, stale, or a
  /// cached miss — the caller checks [shouldRetry] to tell a fresh
  /// miss from a stale entry).
  List<SimilarTrack>? lookup(String username) {
    final entry = _entry(username);
    if (!isCacheEntryFresh(entry, DateTime.now(), ttl: ttl)) return null;
    final value = entry!['value'];
    if (value is! List) return null;
    final tracks = <SimilarTrack>[];
    for (final item in value) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final artist = _nonEmpty(map['artist']);
      final title = _nonEmpty(map['title']);
      if (artist.isEmpty || title.isEmpty) continue;
      tracks.add(SimilarTrack(artist: artist, title: title, match: 0));
    }
    return tracks;
  }

  /// Whether a lookup for [username] should be attempted at [now]:
  /// false when a fresh hit or a fresh miss is cached.
  bool shouldRetry(String username, DateTime now) =>
      !isCacheEntryFresh(_entry(username), now, ttl: ttl);

  void store(String username, List<SimilarTrack> tracks) =>
      _box.put(keyFor(username), {
        'cachedAt': DateTime.now().toIso8601String(),
        'value': [
          for (final t in tracks) {'artist': t.artist, 'title': t.title},
        ],
      });

  /// Record a miss so later runs skip this user until TTL expiry.
  void storeMiss(String username) => _box.put(keyFor(username), {
        'cachedAt': DateTime.now().toIso8601String(),
        'miss': true,
      });
}
