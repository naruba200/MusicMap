// Multi-source fallback for a seed whose track is not found on Last.fm
// (API error 6). All no-auth sources (Last.fm, Deezer, iTunes) run
// concurrently for every seed; their results are merged into the
// candidate pool with Last.fm similars weighted at 1.0 and everything
// else at 0.4. Deezer is DNS-sinkholed on some networks, so every
// cross-source call is best-effort: a failure returns [] and must
// never abort the generation run. No Spotify (Premium-gated) and no
// YouTube Music youtubei "related" calls (reverse-engineered) here.
//
// Cross-source calls use a plain Dio (no retry interceptor): the
// shared dioProvider retries GETs up to 5x, which would turn a
// sinkholed Deezer host into a long backoff per failed seed instead
// of a fast fail-over to iTunes.

import 'dart:async';

import 'package:dio/dio.dart';

import '../engine/recommendation_engine.dart';
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
  if (value is Map) return [value.cast<String, dynamic>()];
  return const [];
}

String? _artistName(dynamic artist) {
  if (artist is Map) return (artist['name'] as String?)?.trim();
  if (artist is String) return artist.trim();
  return null;
}

/// First artist id from a Deezer /search/artist response, or null.
String? parseDeezerArtistId(Map<String, dynamic> json) {
  final data = _asMapList(json['data']);
  if (data.isEmpty) return null;
  final id = data.first['id'];
  if (id == null) return null;
  final s = '$id'.trim();
  return s.isEmpty ? null : s;
}

/// Artist ids from a Deezer /artist/{id}/related response.
List<String> parseDeezerRelatedIds(Map<String, dynamic> json) {
  final ids = <String>[];
  for (final a in _asMapList(json['data'])) {
    final id = a['id'];
    if (id != null && '$id'.trim().isNotEmpty) ids.add('$id');
  }
  return ids;
}

/// Tracks from a Deezer /artist/{id}/top (or /search) response.
List<SimilarTrack> parseDeezerTracks(Map<String, dynamic> json) {
  return parseDeezerTracksWithPreviews(json).tracks;
}

/// Tracks plus 30-second preview URLs from a Deezer response.
/// Deezer already returns a `preview` field per track; it was parsed
/// away until now. Preview keys use [RecommendationEngine.normalizeKey],
/// the same function generation uses to look them up.
({List<SimilarTrack> tracks, Map<String, String> previews})
    parseDeezerTracksWithPreviews(Map<String, dynamic> json) {
  final tracks = <SimilarTrack>[];
  final previews = <String, String>{};
  for (final item in _asMapList(json['data'])) {
    final artist = _artistName(item['artist']) ?? '';
    final title = (item['title'] as String?)?.trim() ?? '';
    if (artist.isEmpty || title.isEmpty) continue;
    tracks.add(SimilarTrack(artist: artist, title: title, match: 0));
    final preview = (item['preview'] as String?)?.trim();
    if (preview != null && preview.isNotEmpty) {
      previews[RecommendationEngine.normalizeKey(artist, title)] = preview;
    }
  }
  return (tracks: tracks, previews: previews);
}

/// Tracks from an iTunes Search API response (results: trackName/artistName).
// iTunes also returns previewUrl per track; callers extract it via
// [parseITunesTrackPreview].
List<SimilarTrack> parseITunesTracks(Map<String, dynamic> json) {
  final tracks = <SimilarTrack>[];
  for (final item in _asMapList(json['results'])) {
    final artist = (item['artistName'] as String?)?.trim() ?? '';
    final title = (item['trackName'] as String?)?.trim() ?? '';
    if (artist.isEmpty || title.isEmpty) continue;
    tracks.add(SimilarTrack(artist: artist, title: title, match: 0));
  }
  return tracks;
}

/// Preview URL from a single iTunes result item, or null.
String? parseITunesPreviewUrl(dynamic item) {
  if (item is! Map) return null;
  final url = (item['previewUrl'] as String?)?.trim();
  return (url != null && url.isNotEmpty) ? url : null;
}

/// Best-effort Deezer + iTunes clients. Every method returns [] on any
// failure (including Deezer's home-network connection refusal).
class FallbackSources {
  final Dio _dio;

  /// [dio] defaults to a plain Dio without the shared retry interceptor,
  /// so a sinkholed host fails fast instead of burning retries per seed.
  FallbackSources([Dio? dio]) : _dio = dio ?? Dio();

  Future<List<SimilarTrack>> deezerArtistTracks(String artist) async {
    try {
      final search = await _dio.get(
        'https://api.deezer.com/search/artist',
        queryParameters: {'q': artist},
      );
      final id = parseDeezerArtistId(_asMap(search.data));
      if (id == null) return const [];
      var tracks = await _deezerTop(id);
      if (tracks.isNotEmpty) return tracks;
      final related = await _dio.get(
        'https://api.deezer.com/artist/$id/related',
      );
      for (final rid in parseDeezerRelatedIds(_asMap(related.data)).take(2)) {
        tracks = await _deezerTop(rid);
        if (tracks.isNotEmpty) return tracks;
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<List<SimilarTrack>> _deezerTop(String artistId) async {
    return (await _deezerTopWithPreviews(artistId)).tracks;
  }

  Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      _deezerTopWithPreviews(String artistId) async {
    final res = await _dio.get(
      'https://api.deezer.com/artist/$artistId/top',
      queryParameters: {'limit': 8},
    );
    return parseDeezerTracksWithPreviews(_asMap(res.data));
  }

  /// Deezer artist tracks plus their preview URLs, mirroring
  /// [itunesArtistTracksWithPreviews]. Same search → top → related
  /// chain as [deezerArtistTracks]; failures still return empty.
  Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      deezerArtistTracksWithPreviews(String artist) async {
    try {
      final search = await _dio.get(
        'https://api.deezer.com/search/artist',
        queryParameters: {'q': artist},
      );
      final id = parseDeezerArtistId(_asMap(search.data));
      if (id == null) {
        return (tracks: const <SimilarTrack>[], previews: <String, String>{});
      }
      var result = await _deezerTopWithPreviews(id);
      if (result.tracks.isNotEmpty) return result;
      final related = await _dio.get(
        'https://api.deezer.com/artist/$id/related',
      );
      for (final rid in parseDeezerRelatedIds(_asMap(related.data)).take(2)) {
        result = await _deezerTopWithPreviews(rid);
        if (result.tracks.isNotEmpty) return result;
      }
      return (tracks: const <SimilarTrack>[], previews: <String, String>{});
    } catch (_) {
      return (tracks: const <SimilarTrack>[], previews: <String, String>{});
    }
  }

  /// iTunes artist search; returns tracks plus a parallel map of
  /// normalized track key -> previewUrl.
  Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      itunesArtistTracksWithPreviews(String artist) async {
    try {
      final res = await _dio.get(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': artist,
          'media': 'music',
          'entity': 'song',
          'attribute': 'artistTerm',
          'limit': 10,
        },
      );
      final data = _asMap(res.data);
      final results = _asMapList(data['results']);
      final tracks = <SimilarTrack>[];
      final previews = <String, String>{};
      for (final item in results) {
        final artistName = (item['artistName'] as String?)?.trim() ?? '';
        final title = (item['trackName'] as String?)?.trim() ?? '';
        if (artistName.isEmpty || title.isEmpty) continue;
        tracks.add(SimilarTrack(artist: artistName, title: title, match: 0));
        final preview = parseITunesPreviewUrl(item);
        if (preview != null) {
          // Same normalization generation uses to look previews up
          // (see generation_provider.dart): a raw lowercased string
          // misses keys with remaster/version suffixes.
          final key =
              RecommendationEngine.normalizeKey(artistName, title);
          previews[key] = preview;
        }
      }
      return (tracks: tracks, previews: previews);
    } catch (_) {
      return (tracks: const <SimilarTrack>[], previews: const <String, String>{});
    }
  }

  /// Backwards-compatible wrapper: iTunes tracks only (no previews).
  Future<List<SimilarTrack>> itunesArtistTracks(String artist) async {
    final r = await itunesArtistTracksWithPreviews(artist);
    return r.tracks;
  }

  /// Look up a single track's preview URL on iTunes by artist + title.
  /// Returns the preview URL (30-second sample) or null when not found.
  Future<String?> itunesTrackPreview(String artist, String title) async {
    try {
      final res = await _dio.get(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': '$artist $title',
          'media': 'music',
          'entity': 'song',
          'limit': 5,
        },
      );
      final results = _asMapList(_asMap(res.data)['results']);
      for (final item in results) {
        final itemArtist = (item['artistName'] as String?)?.trim() ?? '';
        final itemTitle = (item['trackName'] as String?)?.trim() ?? '';
        if (itemArtist.isEmpty || itemTitle.isEmpty) continue;
        // Prefer an exact-ish match on title.
        if (itemTitle.toLowerCase() == title.toLowerCase().trim() &&
            itemArtist.toLowerCase().contains(artist.toLowerCase().trim().split(' ').first)) {
          final preview = parseITunesPreviewUrl(item);
          if (preview != null) return preview;
        }
      }
      // Fall back to the first result's preview URL.
      if (results.isNotEmpty) {
        final preview = parseITunesPreviewUrl(results.first);
        if (preview != null) return preview;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Result of resolving one seed. [similars] are Last.fm track.getSimilar
/// hits (weight 1.0). [fallbacks] are Deezer + iTunes + Last.fm
/// artist-top tracks (weight 0.4). Both lists are merged by the caller.
class SeedSimilarResult {
  final List<SimilarTrack> similars;
  final List<SimilarTrack> fallbacks;
  final String? fallbackReason;
  /// iTunes preview URLs keyed by normalized "artist - title" track key
  /// (only when the fallback came from iTunes).
  final Map<String, String> fallbackPreviews;

  const SeedSimilarResult({
    this.similars = const [],
    this.fallbacks = const [],
    this.fallbackReason,
    this.fallbackPreviews = const {},
  });

  bool get hasSimilars => similars.isNotEmpty;
  bool get hasFallbacks => fallbacks.isNotEmpty;
  bool get isEmpty => similars.isEmpty && fallbacks.isEmpty;
}

/// Resolve similar tracks for one seed, running all no-auth sources
/// concurrently. Only a Last.fm error 6 is treated as "not found" and
/// stepped over; any other LastFmException (or a transport error) is
/// rethrown so the caller still aborts the run on network / key /
/// rate-limit errors. Cross-source failures are swallowed so they can
/// never abort.
///
/// Deezer and iTunes always run alongside Last.fm — they are not a
/// fallback-of-last-resort anymore. Their results are merged into
/// [fallbacks] with a shared [fallbackReason].
Future<SeedSimilarResult> resolveSeedSimilars({
  required String artist,
  required String title,
  required Future<List<SimilarTrack>> Function(String artist, String title)
      getSimilar,
  required Future<List<TagTrack>> Function(String artist, int limit)
      getArtistTopTracks,
  required Future<List<String>> Function(String artist) getSimilarArtists,
  required Future<List<SimilarTrack>> Function(String artist)
      deezerArtistTracks,
  required Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      Function(String artist) itunesArtistTracksWithPreviews,
  // Optional Deezer-with-previews variant. When given, it replaces
  // [deezerArtistTracks] (one Deezer call chain, not two) and its
  // previews join [SeedSimilarResult.fallbackPreviews].
  Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      Function(String artist)? deezerArtistTracksWithPreviews,
}) async {
  Future<List<SimilarTrack>?> trySimilar(String t) async {
    try {
      return await getSimilar(artist, t);
    } on LastFmException catch (e) {
      if (e.isTrackNotFound) return null;
      rethrow;
    }
  }

  Future<List<TagTrack>> tryArtistTop(String a, int limit) async {
    try {
      return await getArtistTopTracks(a, limit);
    } on LastFmException catch (e) {
      if (e.isTrackNotFound) return const [];
      rethrow;
    }
  }

  Future<List<String>> trySimilarArtists(String a) async {
    try {
      return await getSimilarArtists(a);
    } on LastFmException catch (e) {
      if (e.isTrackNotFound) return const [];
      rethrow;
    }
  }

  List<SimilarTrack> toSimilars(List<TagTrack> tracks) => [
        for (final t in tracks)
          if (t.artist.trim().isNotEmpty && t.title.trim().isNotEmpty)
            SimilarTrack(artist: t.artist, title: t.title, match: 0),
      ];

  // --- Always-run sources (concurrent with Last.fm primary).
  // Safe wrappers catch errors inside the async function so the returned
  // Future never completes with an error — Deezer/iTunes can never abort.
  Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      safeDeezer() async {
    try {
      if (deezerArtistTracksWithPreviews != null) {
        return await deezerArtistTracksWithPreviews(artist);
      }
      return (
        tracks: await deezerArtistTracks(artist),
        previews: <String, String>{}
      );
    } catch (_) {
      return (tracks: const <SimilarTrack>[], previews: <String, String>{});
    }
  }

  Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
      safeItunes() async {
    try {
      return await itunesArtistTracksWithPreviews(artist);
    } catch (_) {
      return (tracks: const <SimilarTrack>[], previews: const <String, String>{});
    }
  }

  final deezerFuture = safeDeezer();
  final itunesFuture = safeItunes();

  // --- Primary: Last.fm track.getSimilar + cleaned-title retry ---
  var sims = await trySimilar(title);
  if (sims == null || sims.isEmpty) {
    final cleaned = RecommendationEngine.cleanTrackTitle(title);
    if (cleaned != title) {
      sims = await trySimilar(cleaned);
    }
  }

  // Await the always-run sources (errors already swallowed).
  final deezerResult = await deezerFuture;
  final deezer = deezerResult.tracks;
  final itunesResult = await itunesFuture;
  final alwaysFallbacks = <SimilarTrack>[];
  alwaysFallbacks.addAll(deezer);
  alwaysFallbacks.addAll(itunesResult.tracks);
  // Deezer previews fill gaps; iTunes wins on a key conflict (it was
  // the established preview source).
  final fallbackPreviews = {
    ...deezerResult.previews,
    ...itunesResult.previews,
  };

  if (sims != null && sims.isNotEmpty) {
    // Last.fm similars are primary; Deezer/iTunes join as fallbacks.
    return SeedSimilarResult(
      similars: sims,
      fallbacks: alwaysFallbacks,
      fallbackReason:
          alwaysFallbacks.isNotEmpty ? 'More from $artist' : null,
      fallbackPreviews: fallbackPreviews,
    );
  }

  // --- Last.fm didn't know this track: try artist-top chains ---
  var top = await tryArtistTop(artist, 8);
  if (top.isNotEmpty) {
    return SeedSimilarResult(
      similars: const [],
      fallbacks: [...toSimilars(top), ...alwaysFallbacks],
      fallbackReason: 'More from $artist',
      fallbackPreviews: fallbackPreviews,
    );
  }

  final similars = await trySimilarArtists(artist);
  for (final similar in similars.take(2)) {
    top = await tryArtistTop(similar, 5);
    if (top.isNotEmpty) {
      return SeedSimilarResult(
        similars: const [],
        fallbacks: [...toSimilars(top), ...alwaysFallbacks],
        fallbackReason: 'More from $similar',
        fallbackPreviews: fallbackPreviews,
      );
    }
  }

  // --- Deezer + iTunes already fetched above as always-run sources ---
  if (alwaysFallbacks.isNotEmpty) {
    return SeedSimilarResult(
      similars: const [],
      fallbacks: alwaysFallbacks,
      fallbackReason: 'More from $artist',
      fallbackPreviews: fallbackPreviews,
    );
  }

  return const SeedSimilarResult();
}