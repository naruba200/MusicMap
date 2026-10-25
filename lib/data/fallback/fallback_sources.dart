// Multi-source fallback for a seed whose track is not found on Last.fm
// (API error 6). Order per seed: Last.fm cleaned-title retry, Last.fm
// artist top tracks, similar artists' top tracks, Deezer, iTunes.
// Deezer is DNS-sinkholed on the user's home network, so every
// cross-source call is best-effort: a failure returns [] and must
// never abort the generation run. No Spotify (Premium-gated) and no
// YouTube Music youtubei "related" calls (reverse-engineered) here.
//
// Cross-source calls use a plain Dio (no retry interceptor): the
// shared dioProvider retries GETs up to 5x, which would turn a
// sinkholed Deezer host into a long backoff per failed seed instead
// of a fast fail-over to iTunes.

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
  final tracks = <SimilarTrack>[];
  for (final item in _asMapList(json['data'])) {
    final artist = _artistName(item['artist']) ?? '';
    final title = (item['title'] as String?)?.trim() ?? '';
    if (artist.isEmpty || title.isEmpty) continue;
    tracks.add(SimilarTrack(artist: artist, title: title, match: 0));
  }
  return tracks;
}

/// Tracks from an iTunes Search API response (results: trackName/artistName).
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

/// Best-effort Deezer + iTunes clients. Every method returns [] on any
/// failure (including Deezer's home-network connection refusal).
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
    final res = await _dio.get(
      'https://api.deezer.com/artist/$artistId/top',
      queryParameters: {'limit': 8},
    );
    return parseDeezerTracks(_asMap(res.data));
  }

  Future<List<SimilarTrack>> itunesArtistTracks(String artist) async {
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
      return parseITunesTracks(_asMap(res.data));
    } catch (_) {
      return const [];
    }
  }
}

/// Result of resolving one seed. [fallbackReason] is null for a true
/// track.getSimilar hit; otherwise it names the fallback source, e.g.
/// "More from <artist>", "From Deezer", "From iTunes".
class SeedSimilarResult {
  final List<SimilarTrack> tracks;
  final String? fallbackReason;

  const SeedSimilarResult(this.tracks, [this.fallbackReason]);

  bool get isFallback => fallbackReason != null;
}

/// Resolve similar tracks for one seed, in fallback order. Only a
/// Last.fm error 6 is treated as "not found" and stepped over; any
/// other LastFmException (or a transport error) is rethrown so the
/// caller still aborts the run on network / key / rate-limit errors,
/// exactly as before. Cross-source failures are swallowed here too
/// (in addition to FallbackSources itself) so they can never abort.
///
/// Call caps per failed seed: 1 cleaned retry, 1 artist-top call,
/// 1 similar-artists call + up to 2 similar-artist top calls, then
/// Deezer (search + top, + up to 2 related tops) and 1 iTunes search.
/// A seed whose artist exists usually stops at the artist-top call.
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
  required Future<List<SimilarTrack>> Function(String artist)
      itunesArtistTracks,
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

  var sims = await trySimilar(title);
  if (sims != null && sims.isNotEmpty) return SeedSimilarResult(sims);
  final cleaned = RecommendationEngine.cleanTrackTitle(title);
  if (cleaned != title) {
    sims = await trySimilar(cleaned);
    if (sims != null && sims.isNotEmpty) return SeedSimilarResult(sims);
  }

  var top = await tryArtistTop(artist, 8);
  if (top.isNotEmpty) {
    return SeedSimilarResult(toSimilars(top), 'More from $artist');
  }
  final similars = await trySimilarArtists(artist);
  for (final similar in similars.take(2)) {
    top = await tryArtistTop(similar, 5);
    if (top.isNotEmpty) {
      return SeedSimilarResult(toSimilars(top), 'More from $similar');
    }
  }

  List<SimilarTrack> cross;
  try {
    cross = await deezerArtistTracks(artist);
  } catch (_) {
    cross = const [];
  }
  if (cross.isNotEmpty) return SeedSimilarResult(cross, 'From Deezer');
  try {
    cross = await itunesArtistTracks(artist);
  } catch (_) {
    cross = const [];
  }
  if (cross.isNotEmpty) return SeedSimilarResult(cross, 'From iTunes');
  return const SeedSimilarResult([]);
}
