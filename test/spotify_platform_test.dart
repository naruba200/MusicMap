// Spotify platform adapter tests (fixture-based, no network): link
// parsing, metadata + paging through the internal client, the
// metadata-omits-total fallback, sign-in/out via the login runner, and
// the registry wiring. The HTTP fixtures live in
// spotify_client_test.dart and are imported, not duplicated.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/auth/token_store.dart';
import 'package:music_man/data/platforms/music_platform.dart';
import 'package:music_man/data/platforms/platform_oauth.dart';
import 'package:music_man/data/platforms/platform_registry.dart';
import 'package:music_man/data/platforms/spotify_platform.dart';
import 'package:music_man/data/spotify/spotify_client.dart';
import 'package:music_man/data/spotify/spotify_session.dart';

import 'spotify_client_test.dart';

/// Wraps [FakeSpotifyAdapter] and strips `content.totalCount` from the
/// metadata response only, so the platform under test must learn the
/// total from a contents page (the metadata-omits-total path).
class MetadataWithoutTotalAdapter implements HttpClientAdapter {
  final FakeSpotifyAdapter inner;

  MetadataWithoutTotalAdapter(this.inner);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final res = await inner.fetch(options, requestStream, cancelFuture);
    if (_operation(options) != 'fetchPlaylistWithGatedEntityRelations') {
      return res;
    }
    final bytes = await res.stream.fold<List<int>>(
      [],
      (acc, chunk) => acc..addAll(chunk),
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) {
      final playlist =
          (decoded['data'] as Map?)?['playlistV2'] as Map<String, dynamic>?;
      (playlist?['content'] as Map<String, dynamic>?)?.remove('totalCount');
    }
    return ResponseBody.fromString(
      jsonEncode(decoded),
      res.statusCode,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  String? _operation(RequestOptions options) {
    final data = options.data;
    final Map<String, dynamic> json;
    if (data is Map<String, dynamic>) {
      json = data;
    } else if (data is Map) {
      json = data.cast<String, dynamic>();
    } else if (data is String) {
      json = jsonDecode(data) as Map<String, dynamic>;
    } else {
      return null;
    }
    return json['operationName'] as String?;
  }

  @override
  void close({bool force = false}) {}
}

({
  SpotifyPlatform platform,
  MemorySpotifyStore store,
  FakeSpotifyAdapter adapter,
}) makePlatform({
  bool omitMetadataTotal = false,
  SpotifyLoginRunner? loginRunner,
}) {
  final dio = Dio();
  final adapter = FakeSpotifyAdapter();
  dio.httpClientAdapter =
      omitMetadataTotal ? MetadataWithoutTotalAdapter(adapter) : adapter;
  final store = MemorySpotifyStore();
  final client = SpotifyInternalClient(dio, SpotifySession(store));
  return (
    platform: SpotifyPlatform(
      client,
      loginRunner: loginRunner ?? () async => 'cookie-x',
    ),
    store: store,
    adapter: adapter,
  );
}

void main() {
  const playlistId = '1RzNon113Yc4MkC6OOXwIB';

  group('SpotifyPlatform.parseLink', () {
    test('accepts open.spotify.com links and strips ?si=', () {
      final made = makePlatform();
      final ref = made.platform.parseLink(
        'https://open.spotify.com/playlist/3I2599XfiqunvBzyIZXW0m?si=f344e43e302b45d3',
      );
      expect(ref, isNotNull);
      expect(ref!.platformId, 'spotify');
      expect(ref.playlistId, '3I2599XfiqunvBzyIZXW0m');
    });

    test('accepts spotify:playlist: URIs', () {
      final made = makePlatform();
      final ref = made.platform
          .parseLink('spotify:playlist:1RzNon113Yc4MkC6OOXwIB');
      expect(ref?.playlistId, playlistId);
    });

    test('accepts bare 22-character ids', () {
      final made = makePlatform();
      expect(
        made.platform.parseLink(playlistId)?.playlistId,
        playlistId,
      );
    });

    test('rejects other platforms and garbage', () {
      final made = makePlatform();
      expect(
        made.platform.parseLink('https://www.deezer.com/playlist/123'),
        isNull,
      );
      expect(
        made.platform.parseLink(
          'https://music.youtube.com/playlist?list=PLabc',
        ),
        isNull,
      );
      expect(made.platform.parseLink('not a link'), isNull);
      expect(made.platform.parseLink(''), isNull);
    });
  });

  group('SpotifyPlatform intake', () {
    test('identifies as the beta Spotify platform', () {
      final made = makePlatform();
      expect(made.platform.id, 'spotify');
      expect(made.platform.displayName, 'Spotify');
      expect(made.platform.isBeta, isTrue);
      expect(made.platform.requiresAuthForLibrary, isTrue);
      expect(made.platform.linkNeedsAuth, isTrue);
    });

    test('fetchPlaylistInfo parses metadata', () async {
      final made = makePlatform();
      await made.store.write(SpotifySession.spDcKey, 'cookie-value');
      final info = await made.platform.fetchPlaylistInfo(playlistId);
      expect(info.platformId, 'spotify');
      expect(info.id, playlistId);
      expect(info.name, 'osu! Bangers');
      expect(info.trackCount, 320);
    });

    test('fetchPlaylistInfo learns the total from the first page when '
        'metadata omits it', () async {
      final made = makePlatform(omitMetadataTotal: true);
      await made.store.write(SpotifySession.spDcKey, 'cookie-value');
      final info = await made.platform.fetchPlaylistInfo(playlistId);
      expect(info.name, 'osu! Bangers');
      expect(info.trackCount, 5);
    });

    test('fetchPlaylistTracks pages by offset and drops restricted items',
        () async {
      final made = makePlatform();
      await made.store.write(SpotifySession.spDcKey, 'cookie-value');
      final first =
          await made.platform.fetchPlaylistTracks(playlistId);
      expect(first.tracks.length, 2);
      expect(first.tracks.first.title, 'circles!');
      expect(first.hasMore, isTrue);
      expect(first.cursor, 3);

      final second = await made.platform.fetchPlaylistTracks(
        playlistId,
        cursor: first.cursor,
      );
      expect(second.tracks.length, 1);
      expect(second.tracks.first.title, 'Sound Chimera');
      expect(second.hasMore, isFalse);
    });

    test('fetchUserPlaylists is empty: import is link-based', () async {
      final made = makePlatform();
      expect(await made.platform.fetchUserPlaylists(), isEmpty);
    });
  });

  group('SpotifyPlatform signIn', () {
    test('stores the cookie from the login runner', () async {
      final made = makePlatform();
      expect(await made.platform.signIn(), isTrue);
      expect(await made.store.read(SpotifySession.spDcKey), 'cookie-x');
      expect(await made.platform.isSignedIn, isTrue);
    });

    test('returns false when the user backs out of login', () async {
      final made = makePlatform(loginRunner: () async => null);
      expect(await made.platform.signIn(), isFalse);
      expect(await made.platform.isSignedIn, isFalse);
    });

    test('skips the login runner when already signed in', () async {
      final made = makePlatform(
        loginRunner: () async => throw StateError('must not run'),
      );
      await made.store.write(SpotifySession.spDcKey, 'existing-cookie');
      expect(await made.platform.signIn(), isTrue);
    });

    test('throws a readable error when no login runner is wired',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = FakeSpotifyAdapter();
      final platform = SpotifyPlatform(
        SpotifyInternalClient(dio, SpotifySession(MemorySpotifyStore())),
      );
      await expectLater(
        platform.signIn(),
        throwsA(isA<PlatformException>()),
      );
    });

    test('signOut clears the session', () async {
      final made = makePlatform();
      await made.platform.signIn();
      expect(await made.platform.isSignedIn, isTrue);
      await made.platform.signOut();
      expect(await made.platform.isSignedIn, isFalse);
      expect(await made.store.read(SpotifySession.spDcKey), isNull);
    });
  });

  group('PlatformRegistry', () {
    test('wires Spotify in and parses Spotify links', () {
      final registry = PlatformRegistry(
        dio: Dio(),
        tokenStore: TokenStore(),
        redirectListener: OAuthRedirectListener(),
        spotifyLogin: () async => null,
      );
      final platform = registry.byId('spotify');
      expect(platform, isA<SpotifyPlatform>());
      expect(platform.displayName, 'Spotify');
      final parsed = registry.parseAnyLink(
        'https://open.spotify.com/playlist/3I2599XfiqunvBzyIZXW0m?si=abc',
      );
      expect(parsed, isNotNull);
      expect(parsed!.platform.id, 'spotify');
      expect(parsed.ref.playlistId, '3I2599XfiqunvBzyIZXW0m');
    });
  });
}
