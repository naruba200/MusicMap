// Discogs enrichment (Phase 2, step 2). Album cards only, top
// results only, after scoring — never a candidate pool. Adds
// release year, style, community rating. Auth split per Discogs:
// known-release fetch works unauthenticated (~25/min, descriptive
// User-Agent required); database search needs a token. Without a
// token, release ids resolve token-free via MusicBrainz
// url-relations; with a token, via search. Token is a nullable
// constructor parameter (null by default, never commit a real
// one). Failures skip the album, never abort. Plain Dio.

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../engine/recommendation_engine.dart';
import 'album_enrichment.dart';
import 'enrichment_cache.dart';
import 'enrichment_models.dart';
import 'musicbrainz_client.dart';
import 'rate_limiter.dart';

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

List<String> _asStringList(dynamic value) {
  if (value is List) {
    return value
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return const [];
}

/// A parsed Discogs release: the fields album cards show.
class DiscogsRelease {
  final int id;
  final int? year;
  final List<String> styles;
  final List<String> genres;
  final double? communityRating;
  final int? ratingCount;

  const DiscogsRelease({
    required this.id,
    this.year,
    this.styles = const [],
    this.genres = const [],
    this.communityRating,
    this.ratingCount,
  });

  AlbumEnrichment toAlbumEnrichment() => AlbumEnrichment(
        year: year,
        styles: styles,
        genres: genres,
        communityRating: communityRating,
        ratingCount: ratingCount,
        discogsReleaseId: id,
        sources: const ['Discogs'],
      );
}

/// Parses a /releases/{id} response, or null when it has no id.
DiscogsRelease? parseDiscogsRelease(Map<String, dynamic> json) {
  final id = (json['id'] as num?)?.toInt();
  if (id == null) return null;
  final rating = _asMap(_asMap(json['community'])['rating']);
  return DiscogsRelease(
    id: id,
    year: (json['year'] as num?)?.toInt(),
    styles: _asStringList(json['styles']),
    genres: _asStringList(json['genres']),
    communityRating: (rating['average'] as num?)?.toDouble(),
    ratingCount: (rating['count'] as num?)?.toInt(),
  );
}

/// First release-type id from a /database/search response, or
/// null. Non-release results are ignored, never fetched as if
/// they were releases.
int? parseDiscogsSearchReleaseId(Map<String, dynamic> json) {
  final results = json['results'];
  if (results is List) {
    for (final r in results) {
      if (r is Map && r['type'] == 'release') {
        final id = (r['id'] as num?)?.toInt();
        if (id != null) return id;
      }
    }
  }
  return null;
}

/// Best-effort Discogs client. Null on any failure, never throws.
class DiscogsClient {
  static const userAgent =
      'MusicMan/1.0.0 (https://github.com/naruba200/MusicMap)';

  final Dio _dio;
  final String? _token;
  final RequestThrottler _throttler;

  /// [token]: user-supplied Discogs personal access token, or
  /// null for unauthenticated fetches. Default throttle: 2.5s
  /// unauthenticated (25/min), 1s with a token (60/min).
  DiscogsClient([Dio? dio, String? token, RequestThrottler? throttler])
      : _dio = dio ?? Dio(),
        _token = (token != null && token.trim().isNotEmpty)
            ? token.trim()
            : null,
        _throttler = throttler ??
            RequestThrottler(
                minInterval: Duration(
                    milliseconds:
                        (token != null && token.trim().isNotEmpty)
                            ? 1000
                            : 2500));

  Map<String, String> get _headers => {
        'User-Agent': userAgent,
        if (_token != null) 'Authorization': 'Discogs token=$_token',
      };

  Options get _options => Options(
        headers: _headers,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      );

  /// Known-release fetch. Works unauthenticated; null on failure.
  Future<DiscogsRelease?> fetchRelease(int releaseId) async {
    try {
      await _throttler.waitForSlot();
      final res = await _dio.get(
        'https://api.discogs.com/releases/$releaseId',
        options: _options,
      );
      return parseDiscogsRelease(_asMap(res.data));
    } catch (_) {
      return null;
    }
  }

  /// Token-based release search. Returns null immediately when no
  /// token is configured — search is token-only by Discogs' rules,
  /// so an unauthenticated call would just fail.
  Future<int?> searchRelease(String artist, String album) async {
    if (_token == null) return null;
    try {
      await _throttler.waitForSlot();
      final res = await _dio.get(
        'https://api.discogs.com/database/search',
        queryParameters: {
          'type': 'release',
          'artist': artist,
          'release': album,
        },
        options: _options,
      );
      return parseDiscogsSearchReleaseId(_asMap(res.data));
    } catch (_) {
      return null;
    }
  }
}

/// Hive cache for Discogs album entries in the shared enrichment
/// box (`discogs:album:` prefix, 30-day TTL, misses cached).
class DiscogsAlbumCache {
  final Box _box;

  DiscogsAlbumCache(this._box);

  static Future<DiscogsAlbumCache> open() async {
    final box = await Hive.openBox(EnrichmentCache.boxName);
    return DiscogsAlbumCache(box);
  }

  static String keyFor(String albumKey) => 'discogs:album:$albumKey';

  Map<String, dynamic>? _entry(String albumKey) {
    final value = _box.get(keyFor(albumKey));
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  AlbumEnrichment? lookup(String albumKey) {
    final entry = _entry(albumKey);
    if (!isCacheEntryFresh(entry, DateTime.now(),
        ttl: EnrichmentCache.ttl)) {
      return null;
    }
    final value = entry!['value'];
    if (value is Map) {
      try {
        return AlbumEnrichment.fromJson(value.cast<String, dynamic>());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  bool shouldRetry(String albumKey, DateTime now) =>
      !isCacheEntryFresh(_entry(albumKey), now, ttl: EnrichmentCache.ttl);

  void store(String albumKey, AlbumEnrichment enrichment) =>
      _box.put(keyFor(albumKey), {
        'cachedAt': DateTime.now().toIso8601String(),
        'value': enrichment.toJson(),
      });

  void storeMiss(String albumKey) => _box.put(keyFor(albumKey), {
        'cachedAt': DateTime.now().toIso8601String(),
        'miss': true,
      });
}

/// Post-score Discogs enrichment over top albums. Sequential,
/// cache-first, capped at [limit], deduped by artist|album key.
/// Ids resolve via token search, else via MusicBrainz relations
/// (a song whose release title matches the album). Failures store
/// a miss and are skipped silently.
class DiscogsEnricher {
  final DiscogsClient _client;
  final MusicBrainzClient _musicBrainz;
  final DiscogsAlbumCache? _cache;

  DiscogsEnricher(this._client, this._musicBrainz, [this._cache]);

  Future<Map<String, AlbumEnrichment>> enrichAlbums(
    List<AlbumRec> albums,
    Map<String, TrackEnrichment> trackEnrichments, {
    int limit = 5,
  }) async {
    final out = <String, AlbumEnrichment>{};
    final seen = <String>{};
    for (final album in albums) {
      if (out.length >= limit) break;
      final key = albumEnrichmentKey(album.artist, album.name);
      if (!seen.add(key)) continue;
      final cache = _cache;
      if (cache != null) {
        final cached = cache.lookup(key);
        if (cached != null) {
          out[key] = cached;
          continue;
        }
        if (!cache.shouldRetry(key, DateTime.now())) continue;
      }
      final releaseId = await _resolveReleaseId(album, trackEnrichments);
      if (releaseId == null) {
        cache?.storeMiss(key);
        continue;
      }
      final release = await _client.fetchRelease(releaseId);
      if (release == null) {
        cache?.storeMiss(key);
        continue;
      }
      final enrichment = release.toAlbumEnrichment();
      out[key] = enrichment;
      cache?.store(key, enrichment);
    }
    return out;
  }

  Future<int?> _resolveReleaseId(AlbumRec album, Map<String, TrackEnrichment> trackEnrichments) async {
    final tokenId =
        await _client.searchRelease(album.artist, album.name);
    if (tokenId != null) return tokenId;
    // Token-free path: a song on this album whose MusicBrainz
    // release title matches the album name gives a release MBID,
    // whose url-relations may link a Discogs release.
    final wanted = album.name.trim().toLowerCase();
    for (final song in album.songs) {
      final tKey = RecommendationEngine.normalizeKey(
          song.track.artist, song.track.title);
      final t = trackEnrichments[tKey];
      if (t == null) continue;
      if ((t.releaseTitle ?? '').trim().toLowerCase() != wanted) {
        continue;
      }
      final mbid = t.releaseMbid;
      if (mbid == null || mbid.isEmpty) continue;
      final discogsId =
          await _musicBrainz.lookupReleaseDiscogsId(mbid);
      if (discogsId != null) {
        final id = int.tryParse(discogsId);
        if (id != null) return id;
      }
    }
    return null;
  }
}
