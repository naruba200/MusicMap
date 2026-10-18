// Last.fm API client (spec §10, FR-06/FR-07b/FR-07c/FR-10/FR-11/FR-19).
// Read-only methods need no auth — just a free API key (last.fm/api).
// All parsing is defensive: Last.fm sometimes returns a single object
// instead of a one-element list, and error payloads use {error, message}.

import 'dart:async';

import 'package:dio/dio.dart';

class LastFmException implements Exception {
  final String message;
  const LastFmException(this.message);
  @override
  String toString() => message;
}

/// A track similar to a seed (track.getSimilar).
class SimilarTrack {
  final String artist;
  final String title;
  final double match; // 0..1

  const SimilarTrack({
    required this.artist,
    required this.title,
    required this.match,
  });

  factory SimilarTrack.fromJson(Map<String, dynamic> json) {
    final artist = json['artist'];
    return SimilarTrack(
      artist: artist is Map ? (artist['name'] as String? ?? '') : (artist as String? ?? ''),
      title: json['name'] as String? ?? '',
      match: double.tryParse('${json['match'] ?? 0}') ?? 0,
    );
  }
}

/// A track from tag.getTopTracks / chart.getTopTracks.
class TagTrack {
  final String artist;
  final String title;
  final int listeners;

  const TagTrack({required this.artist, required this.title, required this.listeners});

  factory TagTrack.fromJson(Map<String, dynamic> json) {
    final artist = json['artist'];
    return TagTrack(
      artist: artist is Map ? (artist['name'] as String? ?? '') : (artist as String? ?? ''),
      title: json['name'] as String? ?? '',
      listeners: int.tryParse('${json['listeners'] ?? 0}') ?? 0,
    );
  }
}

/// An album from tag.getTopAlbums.
class TagAlbum {
  final String artist;
  final String name;

  const TagAlbum({required this.artist, required this.name});

  factory TagAlbum.fromJson(Map<String, dynamic> json) {
    final artist = json['artist'];
    return TagAlbum(
      artist: artist is Map ? (artist['name'] as String? ?? '') : (artist as String? ?? ''),
      name: json['name'] as String? ?? '',
    );
  }
}

/// Album metadata for a track (track.getInfo) — used for lazy album art (FR-11).
class TrackAlbumInfo {
  final String? album;
  final String? artist;
  final String? imageUrl;

  const TrackAlbumInfo({this.album, this.artist, this.imageUrl});

  factory TrackAlbumInfo.fromJson(Map<String, dynamic> json) {
    final track = json['track'] as Map<String, dynamic>? ?? const {};
    final album = track['album'] as Map<String, dynamic>?;
    return TrackAlbumInfo(
      album: album?['title'] as String?,
      artist: album?['artist'] as String?,
      imageUrl: _largestImage(album?['image']),
    );
  }
}

String? _largestImage(dynamic images) {
  if (images is! List) return null;
  String? best;
  for (final item in images) {
    if (item is Map) {
      final url = (item['#text'] as String?)?.trim();
      if (url != null && url.isNotEmpty) best = url; // last = largest
    }
  }
  return best;
}

/// Last.fm sometimes returns a single object where a list is expected.
List<Map<String, dynamic>> _asList(dynamic value) {
  if (value is List) return value.whereType<Map<String, dynamic>>().toList();
  if (value is Map<String, dynamic>) return [value];
  return const [];
}

class LastFmClient {
  static const _base = 'https://ws.audioscrobbler.com/2.0/';

  final Dio _dio;
  final String apiKey;

  DateTime? _lastCallAt;
  int _consecutiveFailures = 0;

  LastFmClient({required Dio dio, required this.apiKey}) : _dio = dio;

  /// Throttle to ≤4 req/s (FR-10).
  Future<void> _throttle() async {
    final last = _lastCallAt;
    if (last != null) {
      final wait =
          const Duration(milliseconds: 260) - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastCallAt = DateTime.now();
  }

  Future<Map<String, dynamic>> _get(
      String method, Map<String, String> params) async {
    var backoffAttempt = 0;
    while (true) {
      await _throttle();
      try {
        final res = await _dio.get(
          _base,
          queryParameters: {
            'method': method,
            'api_key': apiKey,
            'format': 'json',
            ...params,
          },
        );
        final data = res.data as Map<String, dynamic>;
        if (data.containsKey('error')) {
          throw LastFmException(
              'Last.fm error ${data['error']}: ${data['message'] ?? 'unknown'}');
        }
        _consecutiveFailures = 0;
        return data;
      } on DioException catch (e) {
        // Exponential backoff on 429 (FR-10).
        if (e.response?.statusCode == 429 && backoffAttempt < 3) {
          backoffAttempt++;
          await Future<void>.delayed(Duration(seconds: 1 << backoffAttempt));
          continue;
        }
        _consecutiveFailures++;
        if (_consecutiveFailures >= 3) {
          throw const LastFmException(
              'Last.fm is unreachable after 3 consecutive failures. Check your connection and retry.');
        }
        rethrow;
      }
    }
  }

  /// Similar tracks for a seed (FR-06). Uses the primary artist only —
  /// callers pass `primaryArtist(seed.artist)`.
  Future<List<SimilarTrack>> getSimilarTracks(String artist, String title,
      {int limit = 30}) async {
    final data = await _get('track.getSimilar', {
      'artist': artist,
      'track': title,
      'autocorrect': '1',
      'limit': '$limit',
    });
    final tracks = (data['similartracks'] as Map?)?['track'];
    return _asList(tracks).map(SimilarTrack.fromJson).toList();
  }

  /// Top tracks for a discovery-modifier tag (FR-07b) or Surprise me (FR-19).
  Future<List<TagTrack>> getTagTopTracks(String tag, {int limit = 50}) async {
    final data = await _get('tag.getTopTracks', {
      'tag': tag,
      'limit': '$limit',
    });
    final tracks = (data['tracks'] as Map?)?['track'];
    return _asList(tracks).map(TagTrack.fromJson).toList();
  }

  /// Top albums for a tag — Surprise me albums (FR-19).
  Future<List<TagAlbum>> getTagTopAlbums(String tag, {int limit = 30}) async {
    final data = await _get('tag.getTopAlbums', {
      'tag': tag,
      'limit': '$limit',
    });
    final albums = (data['albums'] as Map?)?['album'];
    return _asList(albums).map(TagAlbum.fromJson).toList();
  }

  /// Tags similar to [tag] — related-genre chips (FR-04e).
  Future<List<String>> getSimilarTags(String tag) async {
    final data = await _get('tag.getSimilar', {'tag': tag});
    final tags = (data['similartags'] as Map?)?['tag'];
    return _asList(tags)
        .map((t) => (t['name'] as String?)?.trim())
        .whereType<String>()
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// Currently trending tracks — Fresh finds boost (FR-07c).
  Future<List<TagTrack>> getChartTopTracks({int limit = 50}) async {
    final data = await _get('chart.getTopTracks', {'limit': '$limit'});
    final tracks = (data['tracks'] as Map?)?['track'];
    return _asList(tracks).map(TagTrack.fromJson).toList();
  }

  /// Album metadata for a track — lazy album art (FR-11).
  Future<TrackAlbumInfo> getTrackInfo(String artist, String title) async {
    final data = await _get('track.getInfo', {
      'artist': artist,
      'track': title,
      'autocorrect': '1',
    });
    return TrackAlbumInfo.fromJson(data);
  }
}
