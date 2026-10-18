// Riverpod providers for the intake layer (M1).

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'dart:io' show Platform;

import '../../core/constants.dart';
import '../../data/auth/token_store.dart';
import '../../data/models/music_models.dart';
import '../../data/network/retry_interceptor.dart';
import '../../data/platforms/music_platform.dart';
import '../../data/platforms/platform_oauth.dart';
import '../../data/platforms/platform_registry.dart';
import '../../data/repositories/playlist_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../screens/playlist_detail_screen.dart';

/// Global navigator key so deep links can push routes from providers.
final navigatorKey = GlobalKey<NavigatorState>();

// -- Core singletons --------------------------------------------------------

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio();
  dio.interceptors.add(ConnectionRetryInterceptor(dio));
  return dio;
});

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final redirectListenerProvider =
    Provider<OAuthRedirectListener>((ref) => OAuthRedirectListener());

final platformRegistryProvider = Provider<PlatformRegistry>((ref) {
  return PlatformRegistry(
    dio: ref.watch(dioProvider),
    tokenStore: ref.watch(tokenStoreProvider),
    redirectListener: ref.watch(redirectListenerProvider),
  );
});

/// Overridden in main() after Hive opens.
final settingsRepositoryProvider =
    Provider<SettingsRepository>((ref) => throw UnimplementedError());

/// Overridden in main() after Hive opens.
final playlistRepositoryProvider =
    Provider<PlaylistRepository>((ref) => throw UnimplementedError());

// -- Selection & auth -------------------------------------------------------

final selectedPlatformIdProvider =
    StateProvider<String>((ref) => PlatformIds.deezer);

class AuthNotifier extends StateNotifier<Map<String, bool>> {
  final PlatformRegistry _registry;

  AuthNotifier(this._registry) : super({}) {
    refresh();
  }

  Future<void> refresh() async {
    final entries = <String, bool>{};
    for (final p in _registry.platforms) {
      try {
        entries[p.id] = await p.isSignedIn;
      } catch (_) {
        entries[p.id] = false;
      }
    }
    state = entries;
  }

  bool isSignedIn(String platformId) => state[platformId] ?? false;

  Future<bool> signIn(MusicPlatform platform) async {
    final ok = await platform.signIn();
    await refresh();
    return ok;
  }

  Future<void> signOut(MusicPlatform platform) async {
    await platform.signOut();
    await refresh();
  }
}

final authStateProvider =
    StateNotifierProvider<AuthNotifier, Map<String, bool>>(
        (ref) => AuthNotifier(ref.watch(platformRegistryProvider)));

// -- Playlists --------------------------------------------------------------

/// The signed-in user's playlists for the selected platform.
final userPlaylistsProvider = FutureProvider<List<PlaylistInfo>>((ref) async {
  final platformId = ref.watch(selectedPlatformIdProvider);
  ref.watch(authStateProvider); // reload when auth changes
  final platform =
      ref.watch(platformRegistryProvider).byId(platformId);
  if (platform.requiresAuthForLibrary &&
      !(ref.read(authStateProvider)[platformId] ?? false)) {
    return const [];
  }
  try {
    return await platform.fetchUserPlaylists();
  } on PlatformException {
    rethrow;
  } catch (e) {
    throw PlatformException('Could not load playlists: $e');
  }
});

/// Fully-loaded playlist detail: info + ALL tracks (paginated) + saved copy.
class PlaylistDetailData {
  final MusicPlatform platform;
  final PlaylistInfo info;
  final List<Track> tracks;

  PlaylistDetailData({
    required this.platform,
    required this.info,
    required this.tracks,
  });
}

/// Family key: "<platformId>::<playlistId>".
final playlistDetailProvider =
    FutureProvider.family<PlaylistDetailData, String>((ref, key) async {
  final sep = key.indexOf('::');
  final platformId = key.substring(0, sep);
  final playlistId = key.substring(sep + 2);
  final platform = ref.watch(platformRegistryProvider).byId(platformId);

  final info = await platform.fetchPlaylistInfo(playlistId);
  final tracks = <Track>[];
  Object? cursor;
  do {
    final page =
        await platform.fetchPlaylistTracks(playlistId, cursor: cursor);
    tracks.addAll(page.tracks);
    cursor = page.hasMore ? page.cursor : null;
  } while (cursor != null);

  return PlaylistDetailData(platform: platform, info: info, tracks: tracks);
});

// -- Saved playlists --------------------------------------------------------

class SavedPlaylistsNotifier extends StateNotifier<List<SavedPlaylist>> {
  final PlaylistRepository _repo;

  SavedPlaylistsNotifier(this._repo) : super(_repo.getAll());

  Future<void> save(SavedPlaylist playlist) async {
    await _repo.save(playlist);
    state = _repo.getAll();
  }

  Future<void> remove(String platformId, String playlistId) async {
    await _repo.remove(platformId, playlistId);
    state = _repo.getAll();
  }

  Future<void> updateSettings(
      String platformId, String playlistId, DiscoverySettings s) async {
    await _repo.updateSettings(platformId, playlistId, s);
    state = _repo.getAll();
  }

  /// Re-fetches a saved playlist and returns the number of new tracks.
  Future<int> rescan(MusicPlatform platform, SavedPlaylist saved) async {
    final tracks = <Track>[];
    Object? cursor;
    do {
      final page =
          await platform.fetchPlaylistTracks(saved.info.id, cursor: cursor);
      tracks.addAll(page.tracks);
      cursor = page.hasMore ? page.cursor : null;
    } while (cursor != null);

    final known = saved.tracks
        .map((t) => '${t.artist}::${t.title}'.toLowerCase())
        .toSet();
    final newCount = tracks
        .where((t) => !known.contains('${t.artist}::${t.title}'.toLowerCase()))
        .length;

    await _repo.save(SavedPlaylist(
      info: saved.info,
      tracks: tracks,
      settings: saved.settings,
      importedAt: saved.importedAt,
      lastScannedAt: DateTime.now(),
    ));
    state = _repo.getAll();
    return newCount;
  }
}

final savedPlaylistsProvider =
    StateNotifierProvider<SavedPlaylistsNotifier, List<SavedPlaylist>>(
        (ref) => SavedPlaylistsNotifier(ref.watch(playlistRepositoryProvider)));

// -- Deep links -------------------------------------------------------------

/// Listens for incoming playlist links and opens the detail screen:
/// - deep links via app_links (https links, musicmap:// URIs),
/// - shared text via receive_sharing_intent (Android share sheet).
/// Call once from the app root.
final deepLinkHandlerProvider = Provider<void>((ref) {
  final registry = ref.watch(platformRegistryProvider);

  void openLink(String text) {
    final parsed = registry.parseAnyLink(text);
    if (parsed == null) return;
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailScreen(
          platformId: parsed.ref.platformId,
          playlistId: parsed.ref.playlistId,
        ),
      ),
    );
  }

  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen((uri) => openLink(uri.toString()));
  appLinks.getInitialLink().then((uri) {
    if (uri != null) openLink(uri.toString());
  });

  void openSharedFiles(List<SharedMediaFile> files) {
    for (final f in files) {
      // Shared text arrives as a media file of type text; the text itself
      // is in `path`.
      if (f.type == SharedMediaType.text) openLink(f.path);
    }
  }

  // receive_sharing_intent is Android/iOS only — guard so the app also
  // runs on Windows/macOS/Linux for UI testing (share-receive just
  // doesn't exist there).
  if (Platform.isAndroid || Platform.isIOS) {
    ReceiveSharingIntent.instance.getMediaStream().listen(openSharedFiles);
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      openSharedFiles(files);
      ReceiveSharingIntent.instance.reset();
    });
  }
});
