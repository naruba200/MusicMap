// Deezer adapter: public API, no auth needed (spec §8, US-02).
// Docs: https://developers.deezer.com/api

import 'package:dio/dio.dart';

import '../../core/constants.dart';
import '../models/music_models.dart';
import 'music_platform.dart';
import 'open_in_app.dart';

class DeezerPlatform extends MusicPlatform {
  final Dio _dio;

  DeezerPlatform(this._dio);

  @override
  String get id => PlatformIds.deezer;

  @override
  String get displayName => 'Deezer';

  @override
  bool get requiresAuthForLibrary => false;

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> get isSignedIn async => true;

  static final _linkPattern =
      RegExp(r'deezer\.com/(?:[a-z]{2}/)?playlist/(\d+)');

  @override
  PlaylistRef? parseLink(String url) {
    final match = _linkPattern.firstMatch(url);
    if (match == null) return null;
    return PlaylistRef(
        platformId: id, playlistId: match.group(1)!, rawUrl: url);
  }

  @override
  Future<List<PlaylistInfo>> fetchUserPlaylists() async => const [];

  @override
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    final res = await _dio.get('https://api.deezer.com/playlist/$playlistId');
    final m = res.data as Map<String, dynamic>;
    if (m.containsKey('error')) {
      throw PlatformException(
          'Deezer: ${(m['error'] as Map?)?['message'] ?? 'playlist not found'}');
    }
    return PlaylistInfo(
      platformId: id,
      id: '${m['id']}',
      name: m['title'] as String? ?? 'Untitled playlist',
      description: m['description'] as String?,
      coverUrl: m['picture_big'] as String?,
      owner: (m['creator'] as Map?)?['name'] as String?,
      trackCount: (m['nb_tracks'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<TrackPage> fetchPlaylistTracks(String playlistId,
      {Object? cursor}) async {
    // Deezer paginates with `index` + `limit`, returning a `next` URL.
    final start = (cursor as int?) ?? 0;
    final res = await _dio.get(
      'https://api.deezer.com/playlist/$playlistId/tracks',
      queryParameters: {'limit': 100, 'index': start},
    );
    final data = res.data as Map<String, dynamic>;
    final tracks = <Track>[];
    for (final item in (data['data'] as List? ?? [])) {
      final m = item as Map<String, dynamic>;
      final artist = (m['artist'] as Map?)?['name'] as String?;
      tracks.add(Track(
        title: m['title'] as String? ?? 'Unknown title',
        artist: artist ?? 'Unknown artist',
        album: (m['album'] as Map?)?['title'] as String?,
        imageUrl: (m['album'] as Map?)?['cover_big'] as String?,
        durationMs: ((m['duration'] as num?)?.toInt() ?? 0) * 1000,
        platformTrackId: '${m['id']}',
      ));
    }
    final total = (data['total'] as num?)?.toInt() ?? start + tracks.length;
    final nextStart = start + tracks.length;
    return TrackPage(
      tracks: tracks,
      hasMore: nextStart < total && data['next'] != null,
      cursor: nextStart,
    );
  }

  @override
  Future<void> openTrack(Track track) async {
    final query = Uri.encodeComponent('${track.artist} ${track.title}');
    await openLinkInAppFirst(
        Uri.parse('https://www.deezer.com/search/$query'));
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    await openLinkInAppFirst(
        Uri.parse('https://www.deezer.com/playlist/$playlistId'));
  }
}
