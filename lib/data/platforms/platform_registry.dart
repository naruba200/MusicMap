// All platforms in dropdown order (spec §8).

import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import '../models/music_models.dart';
import 'deezer_platform.dart';
// NOTE: SpotifyPlatform is parked for v1 (2026-10-18) — Spotify's Feb 2026
// Dev Mode changes block the Web API unless the app owner holds Premium, and
// writing to Spotify (playlist creation) is impossible without user OAuth.
// v1 covers intake via Deezer (no auth) and outbound links via Spotify search
// URLs (no auth). The adapter (spotify_platform.dart, incl. the desktop
// TEST-ONLY signInDesktop scaffolding) is kept for later; it is NOT in the
// dropdown. token_store.dart / platform_oauth.dart remain as infra for its
// return.
// NOTE: SoundCloudPlatform is parked — SoundCloud now requires an Artist Pro
// account to register an API app (2026-10-18). The adapter
// (soundcloud_platform.dart) is kept for later; it is NOT in the dropdown.
import 'music_platform.dart';
import 'platform_oauth.dart';
import 'youtube_music_platform.dart';

class PlatformRegistry {
  final List<MusicPlatform> platforms;

  PlatformRegistry({
    required Dio dio,
    required TokenStore tokenStore,
    required OAuthRedirectListener redirectListener,
  }) : platforms = [
          // SpotifyPlatform(dio, tokenStore, redirectListener) — parked for
          // v1 (2026-10-18): needs Premium-owning app + user OAuth; v1 uses
          // Deezer intake + Spotify search-URL outbound links instead.
          DeezerPlatform(dio),
          // SoundCloudPlatform(dio) — parked: needs an Artist Pro account
          // for API access (2026-10-18). Re-add when a client_id exists.
          YouTubeMusicPlatform(dio),
        ];

  MusicPlatform byId(String id) => platforms.firstWhere(
        (p) => p.id == id,
        orElse: () => platforms.first,
      );

  /// Tries every platform's link parser; returns the first match.
  PlaylistRefResult? parseAnyLink(String url) {
    for (final platform in platforms) {
      final ref = platform.parseLink(url.trim());
      if (ref != null) return PlaylistRefResult(platform, ref);
    }
    return null;
  }
}

class PlaylistRefResult {
  final MusicPlatform platform;
  final PlaylistRef ref;

  PlaylistRefResult(this.platform, this.ref);
}
