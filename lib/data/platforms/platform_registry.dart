// All platforms in dropdown order (spec §8).

import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import '../models/music_models.dart';
import '../spotify/spotify_client.dart';
import '../spotify/spotify_session.dart';
import 'deezer_platform.dart';
// NOTE: Spotify reads playlists through the internal web-player API
// (api-partner GraphQL, live-verified 2026-11-14), NOT the official
// Web API: Spotify's Feb 2026 Dev Mode changes block the Web API unless
// the app owner holds Premium. Sign-in is the user's own Spotify
// session (sp_dc cookie from the WebView login); there is no developer
// key and no anonymous route. The old OAuth PKCE adapter was replaced
// in 2026-11-14.
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
    SpotifyLoginRunner? spotifyLogin,
  }) : platforms = [
          DeezerPlatform(dio),
          SpotifyPlatform(
            SpotifyInternalClient(dio, SpotifySession()),
            loginRunner: spotifyLogin,
          ),
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
