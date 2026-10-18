// YouTube Music adapter — EXPERIMENTAL (β).
//
// There is no official YouTube Music API. This adapter talks to the
// reverse-engineered internal `youtubei/v1/browse` endpoint (the same one the
// web client uses): no key, no auth, no quota. The response shape was mapped
// against a live response on 2026-10-18:
//
//   browseId "VL{playlistId}" →
//     contents.twoColumnBrowseResultsRenderer
//       .tabs[0].tabRenderer.content.sectionListRenderer.contents[0]
//         .musicResponsiveHeaderRenderer            (title, thumbnail)
//       .secondaryContents.sectionListRenderer.contents[0]
//         .musicPlaylistShelfRenderer               (tracks, playlistId)
//       .secondaryContents.sectionListRenderer
//         .continuations[0].nextContinuationData    (next page token)
//
// Continuation responses come back as
//   continuationContents.musicPlaylistShelfContinuation(.continuations…).
//
// It can break without notice when Google changes the internal API — the UI
// shows a β badge, and every failure degrades to a clear PlatformException
// that never breaks the other platforms (per-source isolation).

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../models/music_models.dart';
import 'music_platform.dart';

class YouTubeMusicPlatform extends MusicPlatform {
  final Dio _dio;

  YouTubeMusicPlatform(this._dio);

  static const _browseUrl = 'https://music.youtube.com/youtubei/v1/browse';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  String get id => PlatformIds.youTubeMusic;

  @override
  String get displayName => 'YouTube Music';

  @override
  bool get isBeta => true;

  @override
  bool get requiresAuthForLibrary => false;

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> get isSignedIn async => true;

  static final _linkPattern = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');

  @override
  PlaylistRef? parseLink(String url) {
    if (!url.contains('music.youtube.com') && !url.contains('youtube.com')) {
      return null;
    }
    final match = _linkPattern.firstMatch(url);
    if (match == null) return null;
    return PlaylistRef(
        platformId: id, playlistId: match.group(1)!, rawUrl: url);
  }

  @override
  Future<List<PlaylistInfo>> fetchUserPlaylists() async => const [];

  Future<Map<String, dynamic>> _browse(
      {String? browseId, String? continuation}) async {
    try {
      final res = await _dio.post(
        _browseUrl,
        data: {
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20240101.00.00',
            },
          },
          if (browseId != null) 'browseId': browseId,
          if (continuation != null) 'continuation': continuation,
        },
        options: Options(headers: {'User-Agent': _userAgent}),
      );
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      throw const PlatformException(
          'YouTube Music returned an unexpected response.');
    } on DioException catch (e) {
      throw PlatformException(_friendlyError(e));
    }
  }

  static String _friendlyError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 429) {
      return 'YouTube Music is rate-limiting right now. Wait a minute and retry.';
    }
    return 'YouTube Music is temporarily unavailable '
        '(experimental feature${code != null ? ', HTTP $code' : ''}). '
        'Try again later or use Deezer.';
  }

  @override
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    final data = await _browse(browseId: 'VL$playlistId');
    final header = _asMap(_dig(data, [
      'contents',
      'twoColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicResponsiveHeaderRenderer',
    ]));
    if (header == null) {
      throw const PlatformException(
          'Could not read that YouTube Music playlist. '
          'Make sure the link is a public playlist.');
    }
    final title = _runsText(header['title']) ?? 'YouTube Music playlist';
    final thumbs = _dig(header, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails'
    ]);
    String? coverUrl;
    if (thumbs is List && thumbs.isNotEmpty) {
      final last = thumbs.last;
      if (last is Map && last['url'] is String) {
        coverUrl = last['url'] as String;
      }
    }
    // Total track count, e.g. "109 tracks" in the header subtitle.
    var trackCount = 0;
    final m =
        RegExp(r'(\d[\d,]*)\s+tracks?').firstMatch(jsonEncode(header));
    if (m != null) {
      trackCount = int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
    }
    return PlaylistInfo(
      platformId: id,
      id: playlistId,
      name: title,
      coverUrl: coverUrl,
      trackCount: trackCount,
    );
  }

  @override
  Future<TrackPage> fetchPlaylistTracks(String playlistId,
      {Object? cursor}) async {
    final Map<String, dynamic> data;
    if (cursor == null) {
      data = await _browse(browseId: 'VL$playlistId');
      final shelf = _shelfOf(data);
      if (shelf == null) {
        throw const PlatformException(
            'Could not read tracks from that YouTube Music playlist.');
      }
      final tracks = _itemsOf(shelf['contents']);
      final next = _continuationOf(data);
      return TrackPage(
          tracks: tracks,
          hasMore: next != null && tracks.isNotEmpty,
          cursor: next);
    }
    data = await _browse(continuation: cursor as String);
    final cont = _asMap(_dig(data,
        ['continuationContents', 'musicPlaylistShelfContinuation']));
    if (cont == null) return const TrackPage(tracks: [], hasMore: false);
    final tracks = _itemsOf(cont['contents']);
    final next = _asMap(_dig(cont, [
      'continuations',
      0,
      'nextContinuationData'
    ]))?['continuation'] as String?;
    return TrackPage(
        tracks: tracks, hasMore: next != null && tracks.isNotEmpty, cursor: next);
  }

  Map<String, dynamic>? _shelfOf(Map<String, dynamic> data) => _asMap(_dig(data, [
        'contents',
        'twoColumnBrowseResultsRenderer',
        'secondaryContents',
        'sectionListRenderer',
        'contents',
        0,
        'musicPlaylistShelfRenderer',
      ]));

  String? _continuationOf(Map<String, dynamic> data) {
    final token = _dig(data, [
      'contents',
      'twoColumnBrowseResultsRenderer',
      'secondaryContents',
      'sectionListRenderer',
      'continuations',
      0,
      'nextContinuationData',
      'continuation',
    ]);
    return token is String && token.isNotEmpty ? token : null;
  }

  List<Track> _itemsOf(dynamic contents) {
    if (contents is! List) return const [];
    final tracks = <Track>[];
    for (final item in contents) {
      if (item is Map<String, dynamic>) {
        final t = _parseItem(item);
        if (t != null) tracks.add(t);
      }
    }
    return tracks;
  }

  Track? _parseItem(Map<String, dynamic> item) {
    final li = _asMap(item['musicResponsiveListItemRenderer']);
    if (li == null) return null;
    final flex = li['flexColumns'];
    if (flex is! List || flex.isEmpty) return null;
    final title = flex[0] is Map<String, dynamic>
        ? _firstRunText(flex[0] as Map<String, dynamic>)
        : null;
    if (title == null || title.isEmpty) return null;
    // Subtitle runs look like [artist, "•", album] or just [artist].
    final subRuns = flex.length > 1 && flex[1] is Map<String, dynamic>
        ? _meaningfulRuns(flex[1] as Map<String, dynamic>)
        : const <String>[];
    final artist = subRuns.isNotEmpty ? subRuns[0] : null;
    var album = subRuns.length > 1 ? subRuns[1] : null;
    // Some layouts put the album in its own column instead.
    album ??= flex.length > 2 && flex[2] is Map<String, dynamic>
        ? _firstRunText(flex[2] as Map<String, dynamic>)
        : null;
    int? durationMs;
    final fixed = li['fixedColumns'];
    if (fixed is List && fixed.isNotEmpty && fixed[0] is Map<String, dynamic>) {
      durationMs =
          _parseDuration(_firstRunText(fixed[0] as Map<String, dynamic>));
    }
    final pid = _asMap(li['playlistItemData']);
    final videoId = pid?['videoId'] is String ? pid!['videoId'] as String : null;
    return Track(
      title: title,
      artist: (artist == null || artist.isEmpty) ? 'Unknown artist' : artist,
      album: (album == null || album.isEmpty) ? null : album,
      durationMs: durationMs,
      platformTrackId: videoId,
    );
  }

  @override
  Future<void> openTrack(Track track) async {
    final query = Uri.encodeComponent('${track.artist} ${track.title}');
    await launchUrl(Uri.parse('https://music.youtube.com/search?q=$query'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    await launchUrl(
        Uri.parse('https://music.youtube.com/playlist?list=$playlistId'),
        mode: LaunchMode.externalApplication);
  }
}

/// Safe navigation through the deeply nested youtubei JSON.
/// Path elements are String (map key) or int (list index).
dynamic _dig(dynamic root, List<dynamic> path) {
  dynamic cur = root;
  for (final key in path) {
    if (cur is Map<String, dynamic> && key is String) {
      cur = cur[key];
    } else if (cur is List && key is int) {
      cur = key < cur.length ? cur[key] : null;
    } else {
      return null;
    }
  }
  return cur;
}

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map<String, dynamic> ? v : null;

/// First non-empty run text from any *Renderer.text.runs in a column map.
String? _firstRunText(Map<String, dynamic> column) {
  final runs = _meaningfulRuns(column);
  return runs.isEmpty ? null : runs.first;
}

/// All meaningful run texts in a column map, skipping "•" separators.
List<String> _meaningfulRuns(Map<String, dynamic> column) {
  final out = <String>[];
  for (final key in column.keys) {
    final runs = _dig(column, [key, 'text', 'runs']);
    if (runs is List) {
      for (final run in runs) {
        if (run is Map) {
          final t = run['text'];
          if (t is String) {
            final s = t.trim();
            if (s.isNotEmpty && s != '•' && s != '·') out.add(s);
          }
        }
      }
    }
  }
  return out;
}

/// First non-empty run text from a {'runs': [...]} object.
String? _runsText(dynamic textObj) {
  final runs = _asMap(textObj)?['runs'];
  if (runs is List) {
    for (final run in runs) {
      if (run is Map) {
        final t = run['text'];
        if (t is String && t.trim().isNotEmpty) return t.trim();
      }
    }
  }
  return null;
}

/// "12:18" / "1:02:03" → milliseconds.
int? _parseDuration(String? s) {
  if (s == null) return null;
  final parts = s.trim().split(':');
  if (parts.length != 2 && parts.length != 3) return null;
  var total = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null) return null;
    total = total * 60 + n;
  }
  return total * 1000;
}
