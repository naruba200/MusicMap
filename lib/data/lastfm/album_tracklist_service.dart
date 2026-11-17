// Album tracklist fetch with Hive caching (Group 4, part 1).
// Pure except for the injected fetcher and the optional cache, so
// widget tests can stub the network and unit tests can use a real
// Hive box without touching Last.fm.
//
// Rules: a fresh cached hit is returned without a fetch; a fresh
// cached miss returns an empty list without a fetch; a successful
// fetch stores a hit, an empty fetch stores a miss; a failed fetch
// stores nothing, so reopening retries it.

import 'album_tracklist_cache.dart';
import 'lastfm_client.dart';

typedef AlbumInfoFetcher = Future<AlbumInfo> Function(
  String artist,
  String album,
);

class AlbumTracklistService {
  final AlbumInfoFetcher _fetch;
  final AlbumTracklistCache? _cache;

  const AlbumTracklistService({
    required AlbumInfoFetcher fetch,
    AlbumTracklistCache? cache,
  })  : _fetch = fetch,
        _cache = cache;

  Future<List<AlbumTrack>> getTracklist(
    String artist,
    String album,
  ) async {
    final cache = _cache;
    if (cache != null) {
      final cached = cache.lookup(artist, album);
      if (cached != null) return cached;
      if (!cache.shouldRetry(artist, album, DateTime.now())) {
        return const [];
      }
    }
    final info = await _fetch(artist, album);
    final tracks = info.tracks;
    if (cache != null) {
      if (tracks.isEmpty) {
        cache.storeMiss(artist, album);
      } else {
        cache.store(artist, album, tracks);
      }
    }
    return tracks;
  }
}
