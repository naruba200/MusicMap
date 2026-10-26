// Openwhyd discovery client (Phase 4, push 3).
//
// Openwhyd is a small-community music curation service. Its Data Export
// API needs no auth: appending `?format=json` to any public playlist URL
// returns its tracks as JSON. Each track resolves back to its source
// platform (YouTube, SoundCloud, Deezer, Vimeo…), so import reuses the
// existing outbound resolution (open the original) instead of inventing
// playback — Openwhyd itself streams nothing in-app.
//
// Separation rule (plan §4): same as Audius/Jamendo — Openwhyd tracks
// NEVER enter core Last.fm scoring. They live in the Discover tab only;
// an imported playlist can seed a one-off generation run from that tab.
// Failure tolerance (plan §0): errors propagate to the provider layer,
// which converts them into an empty load with an error label. Plain Dio,
// no retry interceptor, short timeouts (set on the provider's Dio).
// Call caps: pages of 200 posts, at most 5 pages (1000 tracks).

import 'package:dio/dio.dart';

import '../models/music_models.dart';
import '../platforms/music_platform.dart';

/// One Openwhyd playlist: metadata + its tracks in export order.
class OpenwhydPlaylistData {
  final PlaylistInfo info;
  final List<Track> tracks;

  const OpenwhydPlaylistData({required this.info, required this.tracks});
}

/// Parsed Openwhyd playlist link: `openwhyd.org/<user>/playlist/<id>`.
class OpenwhydRef {
  final String user;
  final String playlistId;

  const OpenwhydRef({required this.user, required this.playlistId});
}

class OpenwhydClient {
  final Dio _dio;

  OpenwhydClient(this._dio);

  static const String baseUrl = 'https://openwhyd.org';
  static const int pageSize = 200;
  static const int maxPages = 5;

  /// Full playlist import via the Data Export API. The export returns a
  /// JSON array of posts (or, defensively, a map with a `tracks` list);
  /// pages follow the `after` (last post id) cursor until a short page.
  Future<OpenwhydPlaylistData> playlist(String user, String playlistId,
      {int pageSize = OpenwhydClient.pageSize}) async {
    final tracks = <Track>[];
    String? after;
    for (var page = 0; page < maxPages; page++) {
      final res = await _dio.get(
        '$baseUrl/$user/playlist/$playlistId',
        queryParameters: {
          'format': 'json',
          'limit': pageSize,
          if (after != null) 'after': after,
        },
      );
      final posts = _posts(res.data);
      if (posts.isEmpty) break;
      tracks.addAll(parseTracks(posts));
      if (posts.length < pageSize) break;
      final lastId = (posts.last as Map?)?['_id'];
      if (lastId == null) break;
      after = '$lastId';
    }
    if (tracks.isEmpty) {
      throw PlatformException(
          'Openwhyd: playlist not found or empty');
    }
    return OpenwhydPlaylistData(
      info: PlaylistInfo(
        platformId: 'openwhyd',
        id: playlistId,
        // The export carries no playlist name, only posts, so the name
        // is derived honestly from the URL instead of guessed.
        name: 'Openwhyd playlist $playlistId',
        owner: user,
        trackCount: tracks.length,
      ),
      tracks: tracks,
    );
  }

  /// Parses an Openwhyd playlist link into its user + id, or null.
  static OpenwhydRef? parsePlaylistLink(String text) {
    final trimmed = text.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.host.contains('openwhyd.org')) return null;
    final match = RegExp(r'^/([^/]+)/playlist/(\d+)')
        .firstMatch(uri.path);
    if (match == null) return null;
    return OpenwhydRef(user: match.group(1)!, playlistId: match.group(2)!);
  }

  /// Parses export posts into [Track]s. `name` is "Artist - Title"
  /// (split on the FIRST ' - '); without a separator the whole name is
  /// the title and the artist is unknown, never guessed from the source.
  /// The source-platform id is kept on [Track.platformTrackId] so the UI
  /// can open the original; [Track.streamUrl] stays null (no in-app
  /// Openwhyd playback exists).
  static List<Track> parseTracks(List posts) {
    final tracks = <Track>[];
    for (final post in posts) {
      if (post is! Map) continue;
      final name = post['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final sep = name.indexOf(' - ');
      final artist =
          sep >= 0 ? name.substring(0, sep) : 'Unknown artist';
      final title = sep >= 0 ? name.substring(sep + 3) : name;
      tracks.add(Track(
        title: title,
        artist: artist,
        imageUrl: post['img'] as String?,
        platformTrackId: post['eId'] as String?,
      ));
    }
    return tracks;
  }

  /// The original source-platform URL for an export post, or null when
  /// the eId prefix is unknown and no `src.id` fallback exists. Used by
  /// the UI's "Open original" button — the existing outbound resolution.
  static String? originalUrl(Map post) {
    final eId = post['eId'] as String?;
    if (eId != null) {
      if (eId.startsWith('/yt/')) {
        return 'https://youtube.com/watch?v=${eId.substring(4)}';
      }
      if (eId.startsWith('/sc/')) {
        // '/sc/user/slug#https://api.soundcloud.com/...' — the part
        // before '#' is the public SoundCloud path.
        final path = eId.substring(4).split('#').first;
        if (path.isNotEmpty) return 'https://soundcloud.com/$path';
      }
      if (eId.startsWith('/dz/')) {
        return 'https://www.deezer.com/track/${eId.substring(4)}';
      }
      if (eId.startsWith('/vi/')) {
        return 'https://vimeo.com/${eId.substring(4)}';
      }
    }
    final src = post['src'];
    if (src is Map) {
      final id = src['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  static List _posts(dynamic json) {
    if (json is List) return json;
    if (json is Map) {
      final tracks = json['tracks'];
      if (tracks is List) return tracks;
    }
    return const [];
  }
}
