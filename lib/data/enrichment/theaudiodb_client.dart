// TheAudioDB enrichment (Phase 2, step 3). Album artwork and
// discography, keyed off MusicBrainz IDs where available. Runs
// after scoring, on top albums only — never a candidate pool.
//
// Key: the documented public shared test key '123' (see
// theaudiodb.com/free_music_api: "The current free API key is:
// 123", free 30 req/min). It is shared, so it may 429 under load;
// 429s and every other failure return null / [], never aborting
// a run. A personal key (Patreon supporter key) replaces it with
// no code change — pass it to the constructor, never commit it.
// TheAudioDB contributes artwork + discography only: year/style
// stay Discogs-owned, so nothing here can overwrite them.
// Plain Dio, no retry interceptor, short timeouts.

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../engine/recommendation_engine.dart';
import 'album_enrichment.dart';
import 'enrichment_cache.dart';
import 'enrichment_models.dart';
import 'rate_limiter.dart';

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

String? _nonEmpty(dynamic value) {
  final s = value?.toString().trim() ?? '';
  return s.isEmpty ? null : s;
}

/// Artist thumbnail from an artist lookup/search response, or null.
String? parseArtistThumb(Map<String, dynamic> json) {
  for (final artist in _asMapList(json['artists'])) {
    final thumb = _nonEmpty(artist['strArtistThumb']);
    if (thumb != null) return thumb;
  }
  return null;
}

/// Album artwork from a searchalbum response, or null.
String? parseAlbumArtwork(Map<String, dynamic> json) {
  for (final album in _asMapList(json['album'])) {
    final art = _nonEmpty(album['strAlbumThumb']);
    if (art != null) return art;
  }
  return null;
}

/// Album names from a discography response, in source order.
List<String> parseDiscography(Map<String, dynamic> json) {
  final names = <String>[];
  for (final album in _asMapList(json['album'])) {
    final name = _nonEmpty(album['strAlbum']);
    if (name != null) names.add(name);
  }
  return names;
}

/// Best-effort TheAudioDB client. Null / [] on any failure.
class TheAudioDBClient {
  /// Documented public shared test key (see header). Personal keys
  /// replace it via the constructor; never commit a personal key.
  static const testApiKey = '123';

  final Dio _dio;
  final String _apiKey;
  final RequestThrottler _throttler;

  TheAudioDBClient(
      [Dio? dio, String? apiKey, RequestThrottler? throttler])
      : _dio = dio ?? Dio(),
        _apiKey = (apiKey != null && apiKey.trim().isNotEmpty)
            ? apiKey.trim()
            : testApiKey,
        _throttler = throttler ??
            RequestThrottler(
                minInterval: const Duration(milliseconds: 500));

  String get _base => 'https://www.theaudiodb.com/api/v1/json/$_apiKey';

  Future<Map<String, dynamic>?> _get(
      String path, Map<String, dynamic> params) async {
    try {
      await _throttler.waitForSlot();
      final res = await _dio.get(
        '$_base/$path',
        queryParameters: params,
        options: Options(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      return _asMap(res.data);
    } catch (_) {
      return null;
    }
  }

  /// Artist thumbnail by MusicBrainz artist ID.
  Future<String?> artistThumbByMbid(String mbid) async {
    final json = await _get('artist-mb.php', {'i': mbid});
    return json == null ? null : parseArtistThumb(json);
  }

  /// Artist thumbnail by artist name.
  Future<String?> artistThumbByName(String name) async {
    final json = await _get('search.php', {'s': name});
    return json == null ? null : parseArtistThumb(json);
  }

  /// Album artwork by artist + album name.
  Future<String?> albumArtwork(String artist, String album) async {
    final json =
        await _get('searchalbum.php', {'s': artist, 'a': album});
    return json == null ? null : parseAlbumArtwork(json);
  }

  /// Discography by MusicBrainz artist ID.
  Future<List<String>> discographyByMbid(String mbid) async {
    final json = await _get('discography-mb.php', {'s': mbid});
    return json == null ? const [] : parseDiscography(json);
  }

  /// Discography by artist name.
  Future<List<String>> discographyByName(String name) async {
    final json = await _get('discography.php', {'s': name});
    return json == null ? const [] : parseDiscography(json);
  }
}

/// Hive cache for TheAudioDB album contributions in the shared
/// enrichment box (`tadb:album:` prefix, 30-day TTL, misses cached).
/// Entries hold only TheAudioDB's own fields; merging with the
/// Discogs entry happens at runtime in [TheAudioDBEnricher].
class TheAudioDBAlbumCache {
  final Box _box;

  TheAudioDBAlbumCache(this._box);

  static Future<TheAudioDBAlbumCache> open() async {
    final box = await Hive.openBox(EnrichmentCache.boxName);
    return TheAudioDBAlbumCache(box);
  }

  static String keyFor(String albumKey) => 'tadb:album:$albumKey';

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

  void store(String albumKey, AlbumEnrichment partial) =>
      _box.put(keyFor(albumKey), {
        'cachedAt': DateTime.now().toIso8601String(),
        'value': partial.toJson(),
      });

  void storeMiss(String albumKey) => _box.put(keyFor(albumKey), {
        'cachedAt': DateTime.now().toIso8601String(),
        'miss': true,
      });
}

/// Post-score TheAudioDB enrichment over top albums. Starts from
/// the existing (Discogs) map so nothing already enriched is lost,
/// then merges artwork + discography per album. Artist thumbnails
/// and discographies are fetched once per distinct artist (caps:
/// [limit] albums, 5 discography artists). Failures store a miss
/// and are skipped silently.
class TheAudioDBEnricher {
  final TheAudioDBClient _client;
  final TheAudioDBAlbumCache? _cache;

  TheAudioDBEnricher(this._client, [this._cache]);

  Future<Map<String, AlbumEnrichment>> enrichAlbums(
    List<AlbumRec> albums,
    Map<String, AlbumEnrichment> existing,
    Map<String, TrackEnrichment> trackEnrichments, {
    int limit = 10,
  }) async {
    final out = Map<String, AlbumEnrichment>.from(existing);
    final seen = <String>{};
    final thumbsByArtist = <String, String?>{};
    final discographyByArtist = <String, List<String>>{};
    var processed = 0;
    for (final album in albums) {
      if (processed >= limit) break;
      final key = albumEnrichmentKey(album.artist, album.name);
      if (!seen.add(key)) continue;
      processed++;
      final cache = _cache;
      if (cache != null) {
        final cached = cache.lookup(key);
        if (cached != null) {
          out[key] = (out[key] ?? const AlbumEnrichment())
              .merge(cached);
          continue;
        }
        if (!cache.shouldRetry(key, DateTime.now())) continue;
      }
      final partial = await _fetchPartial(
        album,
        trackEnrichments,
        thumbsByArtist,
        discographyByArtist,
      );
      if (partial == null || partial.isEmpty) {
        cache?.storeMiss(key);
        continue;
      }
      cache?.store(key, partial);
      out[key] =
          (out[key] ?? const AlbumEnrichment()).merge(partial);
    }
    return out;
  }

  /// MusicBrainz artist ID for an album, from any of its songs'
  /// track enrichments, or null when none is known.
  String? _artistMbid(
      AlbumRec album, Map<String, TrackEnrichment> trackEnrichments) {
    for (final song in album.songs) {
      final t = trackEnrichments[RecommendationEngine.normalizeKey(
          song.track.artist, song.track.title)];
      if (t?.artistMbid != null && t!.artistMbid!.isNotEmpty) {
        return t.artistMbid;
      }
    }
    return null;
  }

  Future<AlbumEnrichment?> _fetchPartial(
    AlbumRec album,
    Map<String, TrackEnrichment> trackEnrichments,
    Map<String, String?> thumbsByArtist,
    Map<String, List<String>> discographyByArtist,
  ) async {
    final art = await _client.albumArtwork(album.artist, album.name);
    String? thumb;
    // Artist thumbnail only fills an artwork gap: when the album
    // already has Last.fm art, the card never needs it.
    if (album.artUrl == null || album.artUrl!.isEmpty) {
      final artistKey = album.artist.toLowerCase().trim();
      if (!thumbsByArtist.containsKey(artistKey)) {
        final mbid = _artistMbid(album, trackEnrichments);
        thumbsByArtist[artistKey] = mbid != null
            ? await _client.artistThumbByMbid(mbid)
            : await _client.artistThumbByName(album.artist);
      }
      thumb = thumbsByArtist[artistKey];
    }
    List<String>? discography;
    if (discographyByArtist.length < 5) {
      final artistKey = album.artist.toLowerCase().trim();
      if (!discographyByArtist.containsKey(artistKey)) {
        final mbid = _artistMbid(album, trackEnrichments);
        final names = mbid != null
            ? await _client.discographyByMbid(mbid)
            : await _client.discographyByName(album.artist);
        final wanted = album.name.trim().toLowerCase();
        discographyByArtist[artistKey] = names
            .where((n) => n.trim().toLowerCase() != wanted)
            .take(10)
            .toList();
      }
      discography = discographyByArtist[artistKey];
    }
    if (art == null &&
        thumb == null &&
        (discography == null || discography.isEmpty)) {
      return null;
    }
    return AlbumEnrichment(
      artUrl: art,
      artistThumbUrl: thumb,
      discography: discography ?? const [],
      sources: const ['TheAudioDB'],
    );
  }
}
