// Riverpod providers for the Discover tab (Phase 4).
//
// One plain Dio (no retry interceptor, short timeouts) is shared by all
// Discover sources, so a sinkholed or dead host fails fast instead of
// stalling the tab. Each provider converts any source failure into a
// [DiscoverLoad] with an empty list and an honest error label: a failed
// source shows an error state in its own tab and never aborts the others,
// and nothing from these tabs feeds core Last.fm scoring.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/discover/audius_client.dart';
import '../../data/models/music_models.dart';

/// A Discover load: items on success, or an empty list plus [error] when
/// the source failed. The UI shows the error label with a retry button.
class DiscoverLoad<T> {
  final List<T> items;
  final String? error;

  const DiscoverLoad({required this.items, this.error});
}

/// A playlist load: metadata + tracks, or an empty load plus [error].
class PlaylistLoad {
  final PlaylistInfo? info;
  final List<Track> tracks;
  final String? error;

  const PlaylistLoad({this.info, this.tracks = const [], this.error});
}

/// Plain Dio for Discover sources: no retry interceptor, short timeouts.
final discoverDioProvider = Provider<Dio>((ref) {
  return Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));
});

// -- Audius ---------------------------------------------------------------

final audiusClientProvider = Provider<AudiusClient>(
    (ref) => AudiusClient(ref.watch(discoverDioProvider)));

/// Trending Audius tracks for [genre] ('all' = unfiltered).
final audiusTrendingProvider =
    FutureProvider.family<DiscoverLoad<Track>, String>((ref, genre) async {
  try {
    final tracks =
        await ref.watch(audiusClientProvider).trending(genre: genre);
    return DiscoverLoad(items: tracks);
  } catch (_) {
    return const DiscoverLoad(
        items: [], error: 'Couldn\'t reach Audius — check your connection.');
  }
});

/// Audius track search for [query].
final audiusSearchProvider =
    FutureProvider.family<DiscoverLoad<Track>, String>((ref, query) async {
  if (query.trim().isEmpty) return const DiscoverLoad(items: []);
  try {
    final tracks =
        await ref.watch(audiusClientProvider).searchTracks(query.trim());
    return DiscoverLoad(items: tracks);
  } catch (_) {
    return const DiscoverLoad(
        items: [], error: 'Audius search failed — check your connection.');
  }
});

/// Audius playlist search for [query].
final audiusPlaylistSearchProvider =
    FutureProvider.family<DiscoverLoad<PlaylistInfo>, String>(
        (ref, query) async {
  if (query.trim().isEmpty) return const DiscoverLoad(items: []);
  try {
    final playlists = await ref
        .watch(audiusClientProvider)
        .searchPlaylists(query.trim());
    return DiscoverLoad(items: playlists);
  } catch (_) {
    return const DiscoverLoad(
        items: [], error: 'Audius search failed — check your connection.');
  }
});

/// Full Audius playlist import for [playlistId].
final audiusPlaylistProvider =
    FutureProvider.family<PlaylistLoad, String>((ref, playlistId) async {
  try {
    final data =
        await ref.watch(audiusClientProvider).playlist(playlistId);
    return PlaylistLoad(info: data.info, tracks: data.tracks);
  } catch (_) {
    return const PlaylistLoad(
        error: 'Couldn\'t import that Audius playlist — '
            'check the link and your connection.');
  }
});
