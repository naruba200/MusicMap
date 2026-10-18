// SoundCloud adapter: public resolve API + client_id (spec §8, US-02).
// Register an app at https://developers.soundcloud.com and set
// soundCloudClientId in lib/core/constants.dart.

import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../models/music_models.dart';
import 'music_platform.dart';

class SoundCloudPlatform extends MusicPlatform {
  final Dio _dio;

  SoundCloudPlatform(this._dio);

  @override
  String get id => PlatformIds.soundCloud;

  @override
  String get displayName => 'SoundCloud';

  @override
  bool get requiresAuthForLibrary => false;

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> get isSignedIn async => true;

  void _requireClientId() {
    if (soundCloudClientId == 'YOUR_SOUNDCLOUD_CLIENT_ID') {
      throw const PlatformException(
          'Set your SoundCloud client ID in lib/core/constants.dart first (see README).');
    }
  }

  static final _linkPattern =
      RegExp(r'soundcloud\.com/[^/]+/sets/[^/?#]+');

  @override
  PlaylistRef? parseLink(String url) {
    final match = _linkPattern.firstMatch(url);
    if (match == null) return null;
    // Resolve the pretty URL to a numeric playlist id lazily via fetchPlaylistInfo.
    return PlaylistRef(platformId: id, playlistId: match.group(0)!, rawUrl: url);
  }

  Future<Map<String, dynamic>> _resolve(String urlOrId) async {
    _requireClientId();
    final target = urlOrId.startsWith('http')
        ? urlOrId
        : 'https://$urlOrId';
    final res = await _dio.get(
      'https://api.soundcloud.com/resolve',
      queryParameters: {'url': target, 'client_id': soundCloudClientId},
    );
    return res.data as Map<String, dynamic>;
  }

  @override
  Future<List<PlaylistInfo>> fetchUserPlaylists() async => const [];

  @override
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    final m = await _resolve(playlistId);
    return PlaylistInfo(
      platformId: id,
      id: '${m['id']}',
      name: m['title'] as String? ?? 'Untitled playlist',
      description: m['description'] as String?,
      coverUrl: (m['artwork_url'] as String?)?.replaceAll('large', 't500x500'),
      owner: (m['user'] as Map?)?['username'] as String?,
      trackCount: (m['track_count'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<TrackPage> fetchPlaylistTracks(String playlistId,
      {Object? cursor}) async {
    _requireClientId();
    // Resolve once to get the numeric id, then page /playlists/{id}/tracks.
    final info = await _resolve(playlistId);
    final numericId = '${info['id']}';
    final offset = (cursor as int?) ?? 0;
    final res = await _dio.get(
      'https://api.soundcloud.com/playlists/$numericId/tracks',
      queryParameters: {
        'client_id': soundCloudClientId,
        'limit': 100,
        'offset': offset,
        'linked_partitioning': 1,
      },
    );
    final data = res.data as Map<String, dynamic>;
    final tracks = <Track>[];
    for (final item in (data['collection'] as List? ?? [])) {
      final m = item as Map<String, dynamic>;
      final title = m['title'] as String? ?? 'Unknown title';
      // SoundCloud titles are often "Artist - Title".
      var artist = (m['user'] as Map?)?['username'] as String? ?? '';
      var trackTitle = title;
      final dash = title.indexOf(' - ');
      if (dash > 0) {
        artist = title.substring(0, dash).trim();
        trackTitle = title.substring(dash + 3).trim();
      }
      tracks.add(Track(
        title: trackTitle.isEmpty ? title : trackTitle,
        artist: artist.isEmpty ? 'Unknown artist' : artist,
        imageUrl:
            (m['artwork_url'] as String?)?.replaceAll('large', 't500x500'),
        durationMs: (m['duration'] as num?)?.toInt(),
        platformTrackId: '${m['id']}',
      ));
    }
    final nextHref = data['next_href'] as String?;
    final nextOffset = offset + tracks.length;
    return TrackPage(
      tracks: tracks,
      hasMore: nextHref != null,
      cursor: nextOffset,
    );
  }

  @override
  Future<void> openTrack(Track track) async {
    final query = Uri.encodeComponent('${track.artist} ${track.title}');
    await launchUrl(Uri.parse('https://soundcloud.com/search?q=$query'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    final url = playlistId.startsWith('http')
        ? playlistId
        : 'https://soundcloud.com/$playlistId';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
