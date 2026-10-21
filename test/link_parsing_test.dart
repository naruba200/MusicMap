// Unit tests for per-platform playlist link parsing (M1, US-02).

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/core/constants.dart';
import 'package:music_man/data/auth/token_store.dart';
import 'package:music_man/data/platforms/deezer_platform.dart';
import 'package:music_man/data/platforms/platform_oauth.dart';
import 'package:music_man/data/platforms/platform_registry.dart';
import 'package:music_man/data/platforms/soundcloud_platform.dart';
import 'package:music_man/data/platforms/spotify_platform.dart';
import 'package:music_man/data/platforms/youtube_music_platform.dart';

void main() {
  final dio = Dio();
  late final PlatformRegistry registry;

  setUpAll(() {
    registry = PlatformRegistry(
      dio: dio,
      tokenStore: TokenStore(),
      redirectListener: OAuthRedirectListener(),
    );
  });

  group('Spotify link parsing', () {
    final platform = SpotifyPlatform(dio, TokenStore(), OAuthRedirectListener());

    test('parses open.spotify.com playlist URLs', () {
      final ref = platform.parseLink(
          'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc');
      expect(ref?.platformId, PlatformIds.spotify);
      expect(ref?.playlistId, '37i9dQZF1DXcBWIGoYBM5M');
    });

    test('parses spotify: URIs', () {
      final ref = platform.parseLink('spotify:playlist:37i9dQZF1DXcBWIGoYBM5M');
      expect(ref?.playlistId, '37i9dQZF1DXcBWIGoYBM5M');
    });

    test('rejects non-playlist URLs', () {
      expect(
          platform.parseLink('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQ'),
          isNull);
      expect(platform.parseLink('https://example.com/playlist/123'), isNull);
    });
  });

  group('Deezer link parsing', () {
    final platform = DeezerPlatform(dio);

    test('parses deezer.com playlist URLs', () {
      final ref =
          platform.parseLink('https://www.deezer.com/playlist/123456789');
      expect(ref?.platformId, PlatformIds.deezer);
      expect(ref?.playlistId, '123456789');
    });

    test('parses localized deezer URLs', () {
      final ref =
          platform.parseLink('https://www.deezer.com/us/playlist/987654321');
      expect(ref?.playlistId, '987654321');
    });

    test('rejects track URLs', () {
      expect(
          platform.parseLink('https://www.deezer.com/track/12345'), isNull);
    });
  });

  group('SoundCloud link parsing', () {
    final platform = SoundCloudPlatform(dio);

    test('parses /sets/ URLs', () {
      final ref = platform
          .parseLink('https://soundcloud.com/someuser/sets/late-night-drive');
      expect(ref?.platformId, PlatformIds.soundCloud);
      expect(ref?.playlistId, contains('sets/late-night-drive'));
    });

    test('rejects single-track URLs', () {
      expect(
          platform.parseLink('https://soundcloud.com/someuser/some-track'),
          isNull);
    });
  });

  group('YouTube Music link parsing', () {
    final platform = YouTubeMusicPlatform(dio);

    test('parses playlist list params', () {
      final ref = platform.parseLink(
          'https://music.youtube.com/playlist?list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPbo2');
      expect(ref?.platformId, PlatformIds.youTubeMusic);
      expect(ref?.playlistId, 'PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPbo2');
    });

    test('rejects watch URLs without a list param', () {
      expect(
          platform.parseLink(
              'https://music.youtube.com/watch?v=dQw4w9WgXcQ'),
          isNull);
      expect(platform.parseLink('https://example.com/playlist?list=abc'),
          isNull);
    });
  });

  group('PlatformRegistry.parseAnyLink', () {
    test('routes each URL to the right platform', () {
      // Spotify is parked for v1 (not in the registry): its links no longer
      // resolve via parseAnyLink, even though SpotifyPlatform.parseLink
      // itself still works (tested above).
      expect(
          registry.parseAnyLink('https://open.spotify.com/playlist/abc123'),
          isNull);
      expect(
          registry
              .parseAnyLink('https://www.deezer.com/playlist/12345')
              ?.platform
              .id,
          PlatformIds.deezer);
      expect(
          registry
              .parseAnyLink('https://music.youtube.com/playlist?list=PLxyz')
              ?.platform
              .id,
          PlatformIds.youTubeMusic);
    });

    test('SoundCloud is parked: registry returns null for its URLs', () {
      // The adapter still parses links, but it is out of the v1 dropdown
      // (SoundCloud API access now needs an Artist Pro account).
      expect(registry.parseAnyLink('https://soundcloud.com/u/sets/mix'),
          isNull);
    });

    test('returns null for unknown URLs', () {
      expect(registry.parseAnyLink('https://example.com/foo'), isNull);
      expect(registry.parseAnyLink('not a url at all'), isNull);
    });
  });
}
