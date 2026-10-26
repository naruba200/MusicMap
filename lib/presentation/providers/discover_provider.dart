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

import '../../core/constants.dart';
import '../../data/discover/audius_client.dart';
import '../../data/discover/jamendo_client.dart';
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

// -- Jamendo --------------------------------------------------------------

// Overridable in tests so the placeholder check can be bypassed with a
// test id; production reads the constants.dart placeholder.
final jamendoClientIdProvider =
    Provider<String>((ref) => jamendoClientId);

/// True when a real Jamendo client_id is configured (not the placeholder).
bool _jamendoReady(Ref ref) {
  final id = ref.watch(jamendoClientIdProvider);
  return id.isNotEmpty && !id.startsWith('YOUR_');
}

const _jamendoSetupError = 'Jamendo needs a client_id — register a free '
    'app at devportal.jamendo.com and put its client_id in '
    'jamendoClientId (lib/core/constants.dart).';

final jamendoClientProvider = Provider<JamendoClient>((ref) =>
    JamendoClient(ref.watch(discoverDioProvider),
        clientId: ref.watch(jamendoClientIdProvider)));

/// Jamendo track search for [query].
final jamendoSearchProvider =
    FutureProvider.family<DiscoverLoad<Track>, String>((ref, query) async {
  if (query.trim().isEmpty) return const DiscoverLoad(items: []);
  if (!_jamendoReady(ref)) {
    return const DiscoverLoad(items: [], error: _jamendoSetupError);
  }
  try {
    final tracks =
        await ref.watch(jamendoClientProvider).searchTracks(query.trim());
    return DiscoverLoad(items: tracks);
  } catch (_) {
    return const DiscoverLoad(
        items: [], error: 'Jamendo search failed — check your connection.');
  }
});

/// Jamendo playlist search for [query].
final jamendoPlaylistSearchProvider =
    FutureProvider.family<DiscoverLoad<PlaylistInfo>, String>(
        (ref, query) async {
  if (query.trim().isEmpty) return const DiscoverLoad(items: []);
  if (!_jamendoReady(ref)) {
    return const DiscoverLoad(items: [], error: _jamendoSetupError);
  }
  try {
    final playlists = await ref
        .watch(jamendoClientProvider)
        .searchPlaylists(query.trim());
    return DiscoverLoad(items: playlists);
  } catch (_) {
    return const DiscoverLoad(
        items: [], error: 'Jamendo search failed — check your connection.');
  }
});

/// Full Jamendo playlist import for [playlistId].
final jamendoPlaylistProvider =
    FutureProvider.family<PlaylistLoad, String>((ref, playlistId) async {
  if (!_jamendoReady(ref)) {
    return const PlaylistLoad(error: _jamendoSetupError);
  }
  try {
    final data =
        await ref.watch(jamendoClientProvider).playlist(playlistId);
    return PlaylistLoad(info: data.info, tracks: data.tracks);
  } catch (_) {
    return const PlaylistLoad(
        error: 'Couldn't import that Jamendo playlist — '
            'check the link and your connection.');
  }
});

/// Curated Jamendo radios.
final jamendoRadiosProvider =
    FutureProvider<DiscoverLoad<JamendoRadio>>((ref) async {
  if (!_jamendoReady(ref)) {
    return const DiscoverLoad(items: [], error: _jamendoSetupError);
  }
  try {
    final radios = await ref.watch(jamendoClientProvider).radios();
    return DiscoverLoad(items: radios);
  } catch (_) {
    return const DiscoverLoad(
        items: [], error: 'Couldn't load Jamendo radios.');
  }
});
