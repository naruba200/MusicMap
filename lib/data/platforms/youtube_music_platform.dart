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
// Continuation reality check (2026-10-20, live): the section-list token
// can instead lead to `continuationContents.sectionListContinuation`,
// whose entries may be related-content carousels (no tracks at all) or a
// fresh musicPlaylistShelfRenderer; and a truncated shelf carries its
// OWN continuations token. fetchPlaylistTracks handles all shapes:
// shelf token first, both continuation shapes, carousel = end of pages.
//
// It can break without notice when Google changes the internal API — the UI
// shows a β badge, and every failure degrades to a clear PlatformException
// that never breaks the other platforms (per-source isolation).
//
// Phase 4a full import (2026-10-26, live Innertube spike, no key, no auth):
// WEB_REMIX caps a playlist shelf at exactly 100 tracks and its
// continuation token dead-ends (empty continuation, or a related-content
// carousel with no tracks). TVHTML5, by contrast, paginates the same
// playlists 15 tracks per page to the true end — DJMax OST 294/294, and
// the "Iconic songs of osu!" playlist 346 unique tracks with a clean
// 15×23+1 page pattern and its first 100 in exactly WEB_REMIX order
// (346 vs the 371 seen 2026-10-24 is most plausibly videos removed or
// privated since; TVHTML5 skips unavailable entries). WEB returns no
// playlist shelf in this shape, and ANDROID / IOS / WEB_EMBEDDED_PLAYER
// all 400. So the no-key full-import route is: WEB_REMIX first page for
// its richer artist/title columns, merged with a full TVHTML5 walk
// (WEB_REMIX entries win on videoId, TVHTML5 supplies the remainder).
// TVHTML5 tiles carry only a single "Artist - Title" string plus the
// uploader channel, so remainder tracks split that string (see
// _splitTitle). Because the no-key route fully works, the YouTube Data
// API v3 route from the plan is deliberately NOT built (it stays an
// optional future arbiter for removed/private-video counts, not a
// requirement). A failed or capped TVHTML5 walk never aborts the import:
// the WEB_REMIX tracks still return, and [TrackPage.truncated] tells the
// UI to say so instead of silently truncating.

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/constants.dart';
import '../models/music_models.dart';
import 'music_platform.dart';
import 'open_in_app.dart';

class YouTubeMusicPlatform extends MusicPlatform {
  final Dio _dio;

  YouTubeMusicPlatform(this._dio);

  static const _browseUrl = 'https://music.youtube.com/youtubei/v1/browse';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// TVHTML5 browse endpoint (www host, not music host) + TV user agent.
  /// This is the client that paginates full playlists (Phase 4a spike).
  static const _tvBrowseUrl = 'https://www.youtube.com/youtubei/v1/browse';
  static const _tvUserAgent =
      'Mozilla/5.0 (Chromium; TV) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// WEB_REMIX serves at most this many tracks on page 1; a full page
  /// with no usable continuation is the truncation signal.
  static const _webRemixPageCap = 100;

  /// TVHTML5 serves 15 tracks per page, so this many pages covers ~1000
  /// tracks — the same sane bound as the plan's 20 Data API pages.
  /// Hitting it with a token still pending stops cleanly + truncated.
  static const _maxTvPages = 67;

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
        options: Options(
          headers: {'User-Agent': _userAgent},
          // youtubei browse is a read-only query over POST — opt in to
          // connection retries so TLS-resetting networks recover the way
          // the GET platforms do. Never set this on an OAuth POST.
          extra: const {'retryReadOnly': true},
        ),
      );
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      throw const PlatformException(
          'YouTube Music returned an unexpected response.');
    } on DioException catch (e) {
      throw PlatformException(_friendlyError(e));
    }
  }

  /// TVHTML5 browse call, mirroring [_browse] but on the www host with
  /// the TV client. Throws [PlatformException] on any Dio failure.
  Future<Map<String, dynamic>> _browseTv(
      {String? browseId, String? continuation}) async {
    try {
      final res = await _dio.post(
        _tvBrowseUrl,
        data: {
          'context': {
            'client': {
              'clientName': 'TVHTML5',
              'clientVersion': '7.20240111.09.00',
            },
          },
          if (browseId != null) 'browseId': browseId,
          if (continuation != null) 'continuation': continuation,
        },
        options: Options(
          headers: {'User-Agent': _tvUserAgent},
          // Same read-only POST reasoning as _browse.
          extra: const {'retryReadOnly': true},
        ),
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
    if (cursor == null) {
      final data = await _browse(browseId: 'VL$playlistId');
      final shelf = _shelfOf(data);
      if (shelf == null) {
        throw const PlatformException(
            'Could not read tracks from that YouTube Music playlist.');
      }
      final tracks = _itemsOf(shelf['contents']);
      // The track continuation hangs off the shelf itself when the
      // shelf is truncated; the section-list token is the fallback
      // (following it can also yield non-track sections — the
      // continuation branch below ends paging cleanly then).
      final next = _tokenOf(shelf) ?? _continuationOf(data);
      // Phase 4a: a full WEB_REMIX page means the shelf probably stopped
      // at its 100-track cap (its continuation dead-ends — verified
      // live). Walk the same playlist via TVHTML5 and merge, keeping
      // the richer WEB_REMIX artist/title entries for their videoIds.
      // Any TV failure falls through to WEB_REMIX paging exactly as
      // before: a failed full import never aborts the import.
      if (tracks.length >= _webRemixPageCap) {
        try {
          final tv = await _fetchTvFull(playlistId);
          if (tv.tracks.isNotEmpty) {
            return TrackPage(
              tracks: _mergePreferFirst(tracks, tv.tracks),
              hasMore: false,
              truncated: !tv.complete,
            );
          }
        } catch (_) {
          // Fall through to the WEB_REMIX page below.
        }
      }
      return TrackPage(
          tracks: tracks,
          hasMore: next != null && tracks.isNotEmpty,
          cursor: next);
    }
    final data = await _browse(continuation: cursor as String);
    // Shape 1: musicPlaylistShelfContinuation — track items directly.
    final shelfCont = _asMap(_dig(
        data, ['continuationContents', 'musicPlaylistShelfContinuation']));
    if (shelfCont != null) {
      final tracks = _itemsOf(shelfCont['contents']);
      final next = _tokenOf(shelfCont);
      return TrackPage(
          tracks: tracks,
          hasMore: next != null && tracks.isNotEmpty,
          cursor: next);
    }
    // Shape 2: sectionListContinuation wrapping a fresh shelf (seen
    // live 2026-10-20; its other entries are related-content carousels,
    // which carry no track shelf and end the paging).
    final sectionCont = _asMap(
        _dig(data, ['continuationContents', 'sectionListContinuation']));
    if (sectionCont != null) {
      final shelf = _shelfIn(sectionCont['contents']);
      if (shelf != null) {
        final tracks = _itemsOf(shelf['contents']);
        final next = _tokenOf(shelf) ?? _tokenOf(sectionCont);
        return TrackPage(
            tracks: tracks,
            hasMore: next != null && tracks.isNotEmpty,
            cursor: next);
      }
    }
    // Empty continuation: the known WEB_REMIX dead-end (token existed
    // but yielded no tracks — an empty continuation, or only carousels).
    // This is NOT a normal end: a genuinely finished shelf ends with a
    // page of tracks and no token, never with an empty page. Flag it so
    // the UI says the import stopped early instead of silently showing
    // the first 100 tracks as if that were the whole playlist.
    return const TrackPage(tracks: [], hasMore: false, truncated: true);
  }

  /// Walks a playlist end to end via the TVHTML5 client (15 tracks per
  /// page). Returns the tracks in playlist order plus whether the walk
  /// ran to the true end ([complete] is false when the page cap was hit
  /// with a token still pending). Throws on any page failure — the
  /// caller falls back to WEB_REMIX paging.
  Future<({List<Track> tracks, bool complete})> _fetchTvFull(
      String playlistId) async {
    final tracks = <Track>[];
    final seen = <String>{};
    var data = await _browseTv(browseId: 'VL$playlistId');
    var node = _findRenderer(data, 'playlistVideoListRenderer');
    var pages = 0;
    while (node != null) {
      pages++;
      for (final t in _tvTracksOf(node)) {
        final key = t.platformTrackId ??
            '${t.artist}::${t.title}'.toLowerCase();
        if (key.isNotEmpty && seen.add(key)) tracks.add(t);
      }
      final token = _tokenOf(node);
      if (token == null) return (tracks: tracks, complete: true);
      if (pages >= _maxTvPages) {
        return (tracks: tracks, complete: false);
      }
      data = await _browseTv(continuation: token);
      node = _asMap(_dig(
          data, ['continuationContents', 'playlistVideoListContinuation']));
      if (node == null) {
        // Token existed but the continuation carried no list: the walk
        // stopped early, not at a clean end.
        return (tracks: tracks, complete: false);
      }
    }
    return (tracks: tracks, complete: true);
  }

  /// Tracks from one TVHTML5 playlistVideoListRenderer page: tile
  /// entries only (continuation/carousel entries carry no track).
  List<Track> _tvTracksOf(Map<String, dynamic> node) {
    final out = <Track>[];
    final contents = node['contents'];
    if (contents is! List) return out;
    for (final item in contents) {
      if (item is! Map<String, dynamic>) continue;
      final tile = _asMap(item['tileRenderer']);
      if (tile == null) continue;
      final endpoint =
          _asMap(_dig(tile, ['onSelectCommand', 'watchEndpoint']));
      final vidRaw = endpoint?['videoId'];
      final contentId = tile['contentId'];
      final videoId = vidRaw is String
          ? vidRaw
          : (contentId is String ? contentId : null);
      final title = _tileTitle(tile);
      if (title == null || title.isEmpty) continue;
      final split = _splitTitle(title);
      out.add(Track(
        title: split.title,
        artist: split.artist,
        platformTrackId:
            (videoId != null && videoId.isNotEmpty) ? videoId : null,
      ));
    }
    return out;
  }

  /// A tile's title: simpleText when present, else the first text run.
  String? _tileTitle(Map<String, dynamic> tile) {
    final titleNode =
        _asMap(_dig(tile, ['metadata', 'tileMetadataRenderer', 'title']));
    if (titleNode == null) return null;
    final simple = titleNode['simpleText'];
    if (simple is String && simple.isNotEmpty) return simple;
    final runs = titleNode['runs'];
    if (runs is List && runs.isNotEmpty && runs.first is Map) {
      final text = (runs.first as Map)['text'];
      if (text is String && text.isNotEmpty) return text;
    }
    return null;
  }

  /// Splits a TVHTML5 single-string title ("Artist - Title") on the
  /// FIRST separator. Titles without a separator keep the whole string
  /// as the title with an unknown artist — never invent an artist.
  ({String artist, String title}) _splitTitle(String title) {
    for (final sep in [' - ', ' \u2013 ', ' \u2014 ']) {
      final idx = title.indexOf(sep);
      if (idx > 0 && idx + sep.length < title.length) {
        final artist = title.substring(0, idx).trim();
        final rest = title.substring(idx + sep.length).trim();
        if (artist.isNotEmpty && rest.isNotEmpty) {
          return (artist: artist, title: rest);
        }
      }
    }
    return (artist: 'Unknown artist', title: title);
  }

  /// Merges two track lists in order, deduplicating by videoId (or by
  /// artist::title when a track has none). Entries from [first] win:
  /// the WEB_REMIX columns carry a real artist field, while TVHTML5
  /// remainder tracks only have a split title string.
  List<Track> _mergePreferFirst(List<Track> first, List<Track> second) {
    final seen = <String>{};
    final out = <Track>[];
    for (final t in [...first, ...second]) {
      final id = t.platformTrackId;
      final key = (id != null && id.isNotEmpty)
          ? id
          : '${t.artist}::${t.title}'.toLowerCase();
      if (key.isEmpty) {
        out.add(t);
      } else if (seen.add(key)) {
        out.add(t);
      }
    }
    return out;
  }

  /// A renderer node's own continuation token, if it carries one.
  String? _tokenOf(Map<String, dynamic> node) {
    final token = _asMap(_dig(node, [
      'continuations',
      0,
      'nextContinuationData',
    ]))?['continuation'];
    return token is String && token.isNotEmpty ? token : null;
  }

  /// First musicPlaylistShelfRenderer inside a section contents list.
  Map<String, dynamic>? _shelfIn(dynamic contents) {
    if (contents is! List) return null;
    for (final entry in contents) {
      if (entry is Map<String, dynamic>) {
        final shelf = _asMap(entry['musicPlaylistShelfRenderer']);
        if (shelf != null) return shelf;
      }
    }
    return null;
  }

  /// First map node anywhere under [root] carrying [key] (TVHTML5 nests
  /// the playlist list deep inside tvBrowseRenderer/twoColumnRenderer).
  /// Returns null when the key never appears.
  Map<String, dynamic>? _findRenderer(dynamic root, String key) {
    if (root is Map<String, dynamic>) {
      final direct = root[key];
      if (direct is Map<String, dynamic>) return direct;
      for (final value in root.values) {
        final found = _findRenderer(value, key);
        if (found != null) return found;
      }
    } else if (root is List) {
      for (final value in root) {
        final found = _findRenderer(value, key);
        if (found != null) return found;
      }
    }
    return null;
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
    await openLinkInAppFirst(
        Uri.parse('https://music.youtube.com/search?q=$query'));
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    await openLinkInAppFirst(
        Uri.parse('https://music.youtube.com/playlist?list=$playlistId'));
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
