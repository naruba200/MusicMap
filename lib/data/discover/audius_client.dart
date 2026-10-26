// Audius discovery client (Phase 4, push 1).
//
// Audius is a decentralized music platform with a public, no-auth API.
// A discovery host is resolved from https://api.audius.co (cached for the
// life of the client, with a hard-coded fallback host); all other calls go
// to that host's /v1 endpoints with app_name=MusicMan.
//
// Separation rule (plan §4): Audius tracks NEVER enter core Last.fm
// scoring. They live in the Discover tab only; an imported Audius playlist
// can be used as seeds for a one-off generation run from that tab, exactly
// like a Deezer/YouTube Music playlist detail run, but nothing from Audius
// is merged into the main recommendation pool.
//
// Failure tolerance (plan §0): every public method lets Dio errors
// propagate to the provider layer, which converts them into an empty
// DiscoverLoad with an error label — a dead Audius never aborts a tab load.
// Plain Dio, no retry interceptor, short timeouts (set on the provider's
// Dio instance). Call caps: trending/search capped by `limit`, playlist
// imports capped at 100 tracks, track batches chunked at 50 ids.

import 'package:dio/dio.dart';

import '../models/music_models.dart';
import 'music_platform.dart';

/// One Audius playlist: metadata + its tracks in playlist order.
class AudiusPlaylistData {
  final PlaylistInfo info;
  final List<Track> tracks;

  const AudiusPlaylistData({required this.info, required this.tracks});
}

class AudiusClient {
  final Dio _dio;
  final String? _hostOverride;

  /// Resolved discovery host, cached after the first successful resolve.
  String? _host;

  /// [hostOverride] is for tests: skips the api.audius.co lookup.
  AudiusClient(this._dio, {String? hostOverride})
      : _hostOverride = hostOverride;

  static const String appName = 'MusicMan';
  static const String fallbackHost = 'https://discoveryprovider.audius.co';
  static const int maxPlaylistTracks = 100;
  static const int trackBatchSize = 50;

  /// Full-stream URL for a track on [host]. Audius streams play in full;
  /// they are stored on [Track.streamUrl], never on [Track.previewUrl]
  /// (which means a 30-second iTunes/Deezer preview elsewhere in the app).
  static String streamUrl(String host, String trackId) =>
      '$host/v1/tracks/$trackId/stream?app_name=$appName';

  Future<String> _resolveHost() async {
    if (_hostOverride != null) return _hostOverride!;
    if (_host != null) return _host!;
    try {
      final res = await _dio.get('https://api.audius.co');
      final data = (res.data as Map?)?['data'] as List?;
      final first = data?.isNotEmpty == true ? data!.first : null;
      if (first is String && first.isNotEmpty) {
        _host = first;
        return first;
      }
    } catch (_) {
      // Fall through to the hard-coded host below.
    }
    _host = fallbackHost;
    return fallbackHost;
  }

  /// Trending tracks, optionally filtered by genre ('all' = unfiltered).
  /// Audius genre slugs are title-cased ('Electronic', 'Hip-Hop/Rap').
  Future<List<Track>> trending(
      {String genre = 'all', int limit = 20}) async {
    final host = await _resolveHost();
    final res = await _dio.get(
      '$host/v1/tracks/trending',
      queryParameters: {
        'genre': genre,
        'time': 'week',
        'limit': limit,
        'app_name': appName,
      },
    );
    return parseTracks(res.data, host);
  }

  /// Track search by free text.
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    final host = await _resolveHost();
    final res = await _dio.get(
      '$host/v1/tracks/search',
      queryParameters: {
        'query': query,
        'limit': limit,
        'app_name': appName,
      },
    );
    return parseTracks(res.data, host);
  }

  /// Playlist search by free text (for finding a playlist to import).
  Future<List<PlaylistInfo>> searchPlaylists(String query,
      {int limit = 20}) async {
    final host = await _resolveHost();
    final res = await _dio.get(
      '$host/v1/playlists/search',
      queryParameters: {
        'query': query,
        'limit': limit,
        'app_name': appName,
      },
    );
    final items = _dataList(res.data);
    return [
      for (final item in items)
        if (item is Map) parsePlaylistInfo(item),
    ];
  }

  /// Full playlist import: metadata + tracks in playlist order.
  /// Track ids are capped at [maxPlaylistTracks] and fetched in batches
  /// of [trackBatchSize]; ids the batch lookup does not return are skipped
  /// (deleted/unavailable tracks), never fabricated.
  Future<AudiusPlaylistData> playlist(String playlistId) async {
    final host = await _resolveHost();
    final res = await _dio.get(
      '$host/v1/playlists/$playlistId',
      queryParameters: {'app_name': appName},
    );
    final data = (res.data as Map?)?['data'];
    if (data is List) {
      if (data.isEmpty) throw const PlatformException('Audius: playlist not found');
      return _playlistFromJson(data.first as Map, host);
    }
    if (data is Map) return _playlistFromJson(data, host);
    throw const PlatformException('Audius: playlist not found');
  }

  Future<AudiusPlaylistData> _playlistFromJson(
      Map playlist, String host) async {
    final info = parsePlaylistInfo(playlist);
    final contents = playlist['playlist_contents'] as List? ?? [];
    final ids = <String>[];
    for (final entry in contents) {
      final id = (entry as Map?)?['track_id'];
      if (id != null) ids.add('$id');
      if (ids.length >= maxPlaylistTracks) break;
    }
    final byId = <String, Track>{};
    for (var i = 0; i < ids.length; i += trackBatchSize) {
      final end =
          i + trackBatchSize > ids.length ? ids.length : i + trackBatchSize;
      final chunk = ids.sublist(i, end);
      final res = await _dio.get(
        '$host/v1/tracks',
        queryParameters: {'id': chunk, 'app_name': appName},
      );
      for (final track in parseTracks(res.data, host)) {
        byId[track.platformTrackId!] = track;
      }
    }
    // Preserve playlist order; drop ids that no longer resolve.
    final tracks = [for (final id in ids) if (byId.containsKey(id)) byId[id]!];
    return AudiusPlaylistData(info: info, tracks: tracks);
  }

  /// Parses an Audius playlist/album link (or a bare numeric id) into a
  /// playlist id, or null when the text is not an Audius playlist link.
  /// Audius playlist URLs look like
  /// `audius.co/<handle>/playlist/<slug>-<numericId>`; the numeric id is
  /// the part after the last dash of the final path segment.
  static String? parsePlaylistLink(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.host.contains('audius.co')) return null;
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final marker = segments.indexWhere(
        (s) => s == 'playlist' || s == 'album');
    if (marker < 0 || marker + 1 >= segments.length) return null;
    final slug = segments[marker + 1];
    final match = RegExp(r'-(\d+)$').firstMatch(slug);
    return match?.group(1);
  }

  /// Parses a /v1/tracks response (a bare list, or a map with a `data`
  /// list) into [Track]s, attaching full-stream URLs.
  static List<Track> parseTracks(dynamic json, String host) {
    final items = _dataList(json);
    final tracks = <Track>[];
    for (final item in items) {
      if (item is! Map) continue;
      final user = item['user'] as Map?;
      final artwork = item['artwork'] as Map?;
      final id = item['id'];
      if (id == null) continue;
      final idStr = '$id';
      tracks.add(Track(
        title: item['title'] as String? ?? 'Unknown title',
        artist: user?['name'] as String? ??
            user?['handle'] as String? ??
            'Unknown artist',
        album: item['album'] as String?,
        imageUrl: artwork?['150x150'] as String? ??
            artwork?['480x480'] as String? ??
            artwork?['1000x1000'] as String?,
        durationMs: ((item['duration'] as num?)?.toInt() ?? 0) * 1000,
        platformTrackId: idStr,
        streamUrl: streamUrl(host, idStr),
      ));
    }
    return tracks;
  }

  /// Parses one /v1/playlists entry into [PlaylistInfo].
  static PlaylistInfo parsePlaylistInfo(Map playlist) {
    final user = playlist['user'] as Map?;
    final artwork = playlist['artwork'] as Map?;
    return PlaylistInfo(
      platformId: 'audius',
      id: '${playlist['id']}',
      name: playlist['playlist_name'] as String? ?? 'Untitled playlist',
      description: playlist['description'] as String?,
      coverUrl: artwork?['480x480'] as String? ??
          artwork?['1000x1000'] as String?,
      owner: user?['name'] as String? ?? user?['handle'] as String?,
      trackCount: (playlist['playlist_contents'] as List?)?.length ?? 0,
    );
  }

  static List _dataList(dynamic json) {
    if (json is List) return json;
    if (json is Map) {
      final data = json['data'];
      if (data is List) return data;
    }
    return const [];
  }
}
