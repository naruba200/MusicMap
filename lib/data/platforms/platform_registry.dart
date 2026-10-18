// All platforms in dropdown order (spec §8).

import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import '../models/music_models.dart';
import 'deezer_platform.dart';
// NOTE: SoundCloudPlatform is parked — SoundCloud now requires an Artist Pro
// account to register an API app (2026-10-18). The adapter
// (soundcloud_platform.dart) is kept for later; it is NOT in the dropdown.
import 'music_platform.dart';
import 'platform_oauth.dart';
import 'spotify_platform.dart';
import 'youtube_music_platform.dart';

class PlatformRegistry {
  final List<MusicPlatform> platforms;

  PlatformRegistry({
    required Dio dio,
    required TokenStore tokenStore,
    required OAuthRedirectListener redirectListener,
  }) : platforms = [
          SpotifyPlatform(dio, tokenStore, redirectListener),
          DeezerPlatform(dio),
          // SoundCloudPlatform(dio) — parked: needs an Artist Pro account
          // for API access (2026-10-18). Re-add when a client_id exists.
          YouTubeMusicPlatform(),
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
