// Jamendo discovery client (Phase 4, push 2).
//
// Jamendo is a Creative Commons music catalog (500,000+ tracks) with a
// public read API at https://api.jamendo.com/v3.0/. Reads need a
// `client_id` query parameter, kept OUT of the repo: the code ships the
// placeholder `jamendoClientId` (see lib/core/constants.dart) and the
// user puts their own id there locally, exactly like the Last.fm key
// pattern. Until a real id is set, the Jamendo tab shows a setup hint
// instead of making failing calls (see discover_provider.dart).
//
// Separation rule (plan §4): same as Audius — Jamendo tracks NEVER enter
// core Last.fm scoring. They live in the Discover tab only; an imported
// Jamendo playlist can seed a one-off generation run from that tab.
// Failure tolerance (plan §0): errors propagate to the provider layer,
// which converts them into an empty load with an error label. Plain Dio,
// no retry interceptor, short timeouts (set on the provider's Dio).
// Call caps: search/playlist lists capped by `limit`, playlist imports
// capped at 100 tracks.
//
// NOTE on radios: the Jamendo radios/stream endpoint shape is
// best-effort (parsed defensively — any of `stream`/`audio`/`url` on the
// first result, null otherwise). If phone QA finds it does not return a
// stream, the radios section degrades to browse-only and this method is
// cut; nothing else depends on it.

import 'package:dio/dio.dart';

import '../models/music_models.dart';
import 'music_platform.dart';

/// One Jamendo playlist: metadata + its tracks in playlist order.
class JamendoPlaylistData {
  final PlaylistInfo info;
  final List<Track> tracks;

  const JamendoPlaylistData({required this.info, required this.tracks});
}

class JamendoClient {
  final Dio _dio;
  final String clientId;

  JamendoClient(this._dio, {required this.clientId});

  static const String baseUrl = 'https://api.jamendo.com/v3.0';
  static const int maxPlaylistTracks = 100;

  Map<String, dynamic> _params([Map<String, dynamic>? extra]) => {
        'client_id': clientId,
        'format': 'json',
        ...?extra,
      };

  /// Track search by free text. Full streams come from the `audio` field.
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    final res = await _dio.get(
      '$baseUrl/tracks/',
      queryParameters: _params({'search': query, 'limit': limit}),
    );
    return parseTracks(res.data);
  }

  /// Playlist search by name.
  Future<List<PlaylistInfo>> searchPlaylists(String query,
      {int limit = 20}) async {
    final res = await _dio.get(
      '$baseUrl/playlists/',
      queryParameters: _params({'namesearch': query, 'limit': limit}),
    );
    final results = _results(res.data);
    return [
      for (final item in results)
        if (item is Map) parsePlaylistInfo(item),
    ];
  }

  /// Full playlist import: metadata + tracks in playlist order.
  Future<JamendoPlaylistData> playlist(String playlistId) async {
    final infoRes = await _dio.get(
      '$baseUrl/playlists/',
      queryParameters: _params({'id': playlistId}),
    );
    final infoResults = _results(infoRes.data);
    if (infoResults.isEmpty || infoResults.first is! Map) {
      throw const PlatformException('Jamendo: playlist not found');
    }
    final tracksRes = await _dio.get(
      '$baseUrl/playlists/tracks/',
      queryParameters: _params({'id': playlistId}),
    );
    final trackResults = _results(tracksRes.data);
    final rawTracks = trackResults.isNotEmpty && trackResults.first is Map
        ? (trackResults.first as Map)['tracks'] as List? ?? []
        : <dynamic>[];
    final tracks = parseTracks({'results': rawTracks})
        .take(maxPlaylistTracks)
        .toList();
    return JamendoPlaylistData(
      info: parsePlaylistInfo(infoResults.first as Map),
      tracks: tracks,
    );
  }

  /// Curated Jamendo radios (browse list; playback is best-effort, see
  /// [radioStreamUrl]).
  Future<List<JamendoRadio>> radios({int limit = 20}) async {
    final res = await _dio.get(
      '$baseUrl/radios/',
      queryParameters: _params({'limit': limit}),
    );
    return [
      for (final item in _results(res.data))
        if (item is Map) JamendoRadio.fromJson(item),
    ];
  }

  /// Best-effort stream URL for a radio, or null when the API does not
  /// return one (the radios section then degrades to browse-only).
  /// Never throws: any failure returns null.
  Future<String?> radioStreamUrl(String radioId) async {
    try {
      final res = await _dio.get(
        '$baseUrl/radios/stream/',
        queryParameters: _params({'id': radioId}),
      );
      final results = _results(res.data);
      if (results.isEmpty || results.first is! Map) return null;
      final first = results.first as Map;
      for (final key in ['stream', 'audio', 'url']) {
        final value = first[key];
        if (value is String && value.isNotEmpty) return value;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Parses a Jamendo playlist link (or a bare numeric id) into a
  /// playlist id, or null when the text is not one.
  static String? parsePlaylistLink(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.host.contains('jamendo.com')) return null;
    final match = RegExp(r'playlist/(\d+)').firstMatch(uri.path);
    return match?.group(1);
  }

  /// Parses a Jamendo /tracks or /playlists/tracks response into [Track]s
  /// with full-stream URLs on [Track.streamUrl].
  static List<Track> parseTracks(dynamic json) {
    final tracks = <Track>[];
    for (final item in _results(json)) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id == null) continue;
      tracks.add(Track(
        title: item['name'] as String? ?? 'Unknown title',
        artist: item['artist_name'] as String? ?? 'Unknown artist',
        album: item['album_name'] as String?,
        imageUrl: item['album_image'] as String?,
        durationMs: ((item['duration'] as num?)?.toInt() ?? 0) * 1000,
        platformTrackId: '$id',
        streamUrl: item['audio'] as String?,
      ));
    }
    return tracks;
  }

  /// Parses one /playlists entry into [PlaylistInfo].
  static PlaylistInfo parsePlaylistInfo(Map playlist) {
    return PlaylistInfo(
      platformId: 'jamendo',
      id: '${playlist['id']}',
      name: playlist['name'] as String? ?? 'Untitled playlist',
      owner: playlist['user_name'] as String?,
      trackCount: (playlist['tracks_count'] as num?)?.toInt() ?? 0,
    );
  }

  static List _results(dynamic json) {
    if (json is Map) {
      final results = json['results'];
      if (results is List) return results;
    }
    return const [];
  }
}

/// One Jamendo radio (curated stream station).
class JamendoRadio {
  final String id;
  final String name;
  final String? imageUrl;

  const JamendoRadio(
      {required this.id, required this.name, this.imageUrl});

  factory JamendoRadio.fromJson(Map json) => JamendoRadio(
        id: '${json['id']}',
        name: json['name'] as String? ??
            json['dispname'] as String? ??
            'Untitled radio',
        imageUrl: json['image'] as String?,
      );
}
