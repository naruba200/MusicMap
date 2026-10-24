// YouTube export (M6, FR-28..FR-31): resolve result songs to YouTube video
// IDs via the youtubei search endpoint (no OAuth, no YouTube Data API),
// cache them, and open watch_videos links in chunks of at most 50 songs.
//
// The search shape was live-verified 2026-10-24: the top hit lives at
// contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content
// .sectionListRenderer.contents[0].musicCardShelfRenderer.title.runs[0]
// .navigationEndpoint.watchEndpoint.videoId. If the card is absent, the
// first videoId in a musicShelfRenderer / musicResponsiveListItemRenderer
// item is used instead. Matching is best-effort: YouTube may return a
// cover or live version instead of the official audio (spec GAP-2).

import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../engine/recommendation_engine.dart';
import '../models/music_models.dart';

/// One watch_videos URL carries at most this many songs (URL length, FR-30).
const int maxSongsPerPlaylistLink = 50;

/// A song with its resolved YouTube video ID, or null if unmatched.
class ResolvedSong {
  final Track track;
  final String? videoId;

  const ResolvedSong({required this.track, required this.videoId});

  bool get matched => videoId != null && videoId!.isNotEmpty;
}

/// One chunk of a result set: songs [start]..[end] (1-based, in the
/// original result order), carrying only the songs that were matched.
class ExportChunk {
  final int part;
  final int start;
  final int end;
  final List<String> videoIds;

  const ExportChunk({
    required this.part,
    required this.start,
    required this.end,
    required this.videoIds,
  });

  String get label => 'Part $part (songs $start–$end)';

  String get url =>
      'https://www.youtube.com/watch_videos?video_ids=${videoIds.join(',')}';

  int get songCount => videoIds.length;
}

/// Split resolved songs into ≤50-song chunks. Groups that are entirely
/// unmatched produce no chunk (those songs are reported as unmatched,
/// never silently dropped). Part numbers follow the original position
/// (part = group index + 1), so labels stay aligned with the result set.
List<ExportChunk> buildExportChunks(List<ResolvedSong> resolved) {
  final chunks = <ExportChunk>[];
  for (var i = 0; i < resolved.length; i += maxSongsPerPlaylistLink) {
    final end = math.min(i + maxSongsPerPlaylistLink, resolved.length);
    final group = resolved.sublist(i, end);
    final ids = <String>[];
    for (final song in group) {
      if (song.matched) ids.add(song.videoId!);
    }
    if (ids.isEmpty) continue;
    chunks.add(ExportChunk(
      part: i ~/ maxSongsPerPlaylistLink + 1,
      start: i + 1,
      end: end,
      videoIds: ids,
    ));
  }
  return chunks;
}

/// A miss is retried only after this long (FR-29).
const Duration missRetryAfter = Duration(days: 7);

/// Pure miss-retry rule, kept separate from any storage backend so it is
/// unit-testable: no recorded miss means "try now".
bool shouldRetryMissAfter(DateTime? missedAt, DateTime now) =>
    missedAt == null || now.difference(missedAt) >= missRetryAfter;

/// Storage for resolved video IDs. Implementations must be cheap to
/// construct; [lookup] returns null for both "never seen" and "miss".
abstract class VideoIdCache {
  String? lookup(String key);
  void storeHit(String key, String videoId);
  void storeMiss(String key, DateTime now);
  bool shouldRetryMiss(String key, DateTime now);
}

/// In-memory cache, used by unit tests (production uses Hive, see
/// youtube_video_cache.dart).
class InMemoryVideoIdCache implements VideoIdCache {
  final _hits = <String, String>{};
  final _misses = <String, DateTime>{};

  @override
  String? lookup(String key) => _hits[key];

  @override
  void storeHit(String key, String videoId) => _hits[key] = videoId;

  @override
  void storeMiss(String key, DateTime now) => _misses[key] = now;

  @override
  bool shouldRetryMiss(String key, DateTime now) {
    if (_hits.containsKey(key)) return false;
    return shouldRetryMissAfter(_misses[key], now);
  }
}

/// Outcome of resolving a whole song list.
class ExportResolution {
  final List<ResolvedSong> songs;
  final bool cancelled;

  const ExportResolution({required this.songs, this.cancelled = false});

  List<ResolvedSong> get resolved =>
      [for (final song in songs) if (song.matched) song];

  List<Track> get unmatched =>
      [for (final song in songs) if (!song.matched) song.track];

  List<ExportChunk> get chunks => buildExportChunks(songs);
}

/// Resolves songs to YouTube video IDs via the youtubei search endpoint,
/// following the same Dio + WEB_REMIX + retryReadOnly pattern as the
/// YouTube Music intake adapter. A Dio error on a single song propagates
/// (the UI shows a plain error with Retry) rather than silently marking
/// every song unmatched on a dead network.
class YouTubeVideoResolver {
  final Dio _dio;
  final VideoIdCache? cache;

  /// At most this many search requests in flight (FR-29 politeness).
  static const int maxInFlight = 4;

  static const _searchUrl = 'https://music.youtube.com/youtubei/v1/search';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  YouTubeVideoResolver(this._dio, {this.cache});

  /// Cache key, identical to the favorites key so the same song dedupes.
  String cacheKey(String artist, String title) =>
      RecommendationEngine.normalizeKey(artist, title);

  Future<String?> resolve(Track track, {DateTime? now}) async {
    final current = now ?? DateTime.now();
    final key = cacheKey(track.artist, track.title);
    final cached = cache?.lookup(key);
    if (cached != null) return cached;
    if (cache != null && !cache!.shouldRetryMiss(key, current)) {
      return null;
    }
    final id = await _search('${track.artist} ${track.title}');
    if (id != null) {
      cache?.storeHit(key, id);
    } else {
      cache?.storeMiss(key, current);
    }
    return id;
  }

  /// Resolves [tracks] in order, in batches of [maxInFlight]. [onProgress]
  /// fires after each batch as ("done", "total"). If [isCancelled] returns
  /// true between batches, resolution stops and the partial result is
  /// returned with [ExportResolution.cancelled] set; the caller discards
  /// it, so cancelling never touches the underlying results screen.
  Future<ExportResolution> resolveAll(
    List<Track> tracks, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    DateTime Function()? now,
  }) async {
    final out = <ResolvedSong>[];
    var done = 0;
    for (var i = 0; i < tracks.length; i += maxInFlight) {
      if (isCancelled != null && isCancelled()) {
        return ExportResolution(songs: out, cancelled: true);
      }
      final end = math.min(i + maxInFlight, tracks.length);
      final batch = tracks.sublist(i, end);
      final ids = await Future.wait(
          [for (final track in batch) resolve(track, now: now?.call())]);
      for (var j = 0; j < batch.length; j++) {
        out.add(ResolvedSong(track: batch[j], videoId: ids[j]));
        done++;
      }
      onProgress?.call(done, tracks.length);
    }
    return ExportResolution(songs: out);
  }

  Future<String?> _search(String query) async {
    final res = await _dio.post(
      _searchUrl,
      data: {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240101.00.00',
          },
        },
        'query': query,
      },
      options: Options(
        headers: {'User-Agent': _userAgent},
        // youtubei search is a read-only query over POST — opt in to
        // connection retries so TLS-resetting networks recover the way
        // the GET platforms do. Never set this on an OAuth POST.
        extra: const {'retryReadOnly': true},
      ),
    );
    final data = res.data;
    final map = data is Map<String, dynamic>
        ? data
        : (data is String
            ? jsonDecode(data) as Map<String, dynamic>
            : null);
    if (map == null) return null;
    return parseSearchVideoId(map);
  }

  /// Extracts the top video ID from a youtubei search envelope: the card
  /// title's navigation endpoint first, then the first video ID inside a
  /// musicShelfRenderer / musicResponsiveListItemRenderer item.
  static String? parseSearchVideoId(Map<String, dynamic> data) {
    final card = _asMap(_dig(data, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicCardShelfRenderer',
    ]));
    if (card != null) {
      final id = _deepVideoId(
          _dig(card, ['title', 'runs', 0, 'navigationEndpoint']));
      if (id != null) return id;
    }
    final contents = _dig(data, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (contents is List) {
      for (final entry in contents) {
        final id = _shelfVideoId(entry);
        if (id != null) return id;
      }
    }
    return null;
  }

  /// First video ID inside a shelf / list-item node, or null.
  static String? _shelfVideoId(dynamic node) {
    if (node is! Map) return null;
    final shelf = node['musicShelfRenderer'];
    if (shelf != null) {
      final id = _deepVideoId(shelf);
      if (id != null) return id;
    }
    final item = node['musicResponsiveListItemRenderer'];
    if (item != null) {
      final id = _deepVideoId(item);
      if (id != null) return id;
    }
    for (final value in node.values) {
      final id = _shelfVideoId(value);
      if (id != null) return id;
    }
    return null;
  }

  /// First videoId found under a watchEndpoint or playlistItemData,
  /// depth-first in document order.
  static String? _deepVideoId(dynamic node) {
    if (node is Map) {
      final watch = node['watchEndpoint'];
      if (watch is Map) {
        final id = watch['videoId'];
        if (id is String && id.isNotEmpty) return id;
      }
      final playlistItem = node['playlistItemData'];
      if (playlistItem is Map) {
        final id = playlistItem['videoId'];
        if (id is String && id.isNotEmpty) return id;
      }
      for (final value in node.values) {
        final id = _deepVideoId(value);
        if (id != null) return id;
      }
    } else if (node is List) {
      for (final value in node) {
        final id = _deepVideoId(value);
        if (id != null) return id;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  static dynamic _dig(dynamic node, List<Object> path) {
    dynamic current = node;
    for (final step in path) {
      if (step is String) {
        if (current is Map) {
          current = current[step];
        } else {
          return null;
        }
      } else if (step is int) {
        if (current is List && step < current.length) {
          current = current[step];
        } else {
          return null;
        }
      }
    }
    return current;
  }
}
