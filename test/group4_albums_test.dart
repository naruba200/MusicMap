// Group 4 Albums tests.
//
// - Last.fm album.getInfo tracklist fetch (service + Hive cache).
// - Album detail: full tracklist with recommended rows badged and
//   playable, name-only rows display-only, loading / error / empty
//   states, and the same row interactions as result songs.
// - Cover chain (shared AlbumArtImage) and the cover fallback
//   (track image, album art, artist thumb, placeholder).
// - Generation-time backfill in deriveAlbums.
// - Player album-art threading (mini-player and full player).
//
// The player runs on a fake backend; the favorites + playlist repos
// are real, backed by fresh Hive boxes per test (never clear()
// shared boxes, no Hive.close() in widget tearDownAll, no
// pumpAndSettle: the loading states carry indeterminate indicators
// that never settle).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/enrichment/album_enrichment.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/lastfm/album_tracklist_cache.dart';
import 'package:music_man/data/lastfm/album_tracklist_service.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/album_detail_screen.dart';
import 'package:music_man/presentation/screens/full_player_screen.dart';
import 'package:music_man/presentation/widgets/album_art.dart';
import 'package:music_man/presentation/widgets/mini_player_bar.dart';
import 'package:music_man/presentation/widgets/song_row.dart';

import 'fake_audio_backend.dart';

const _trackA = Track(
  artist: 'Singer A',
  title: 'Song A',
  durationMs: 200000,
  streamUrl: 'https://example.com/a.m4a',
);
const _trackB = Track(
  artist: 'Singer B',
  title: 'Song B',
  durationMs: 183000,
  streamUrl: 'https://example.com/b.m4a',
);

const _albumWithRec = AlbumRec(
  name: 'Album A',
  artist: 'Singer A',
  artUrl: 'https://example.com/art.jpg',
  songCount: 1,
  bestScore: 2.0,
  songs: [
    ScoredTrack(track: _trackA, score: 2.0, reasons: ['Seed Song One']),
  ],
);

/// Same album, no art anywhere: the cover chain must fall through
/// to the lazy Last.fm step (or the placeholder).
const _albumNoArt = AlbumRec(
  name: 'Album A',
  artist: 'Singer A',
  songCount: 1,
  bestScore: 2.0,
  songs: [
    ScoredTrack(track: _trackA, score: 2.0, reasons: ['Seed Song One']),
  ],
);

/// Surprise album: no recommended songs, so every fetched track is
/// name-only.
const _albumSurprise = AlbumRec(
  name: 'Album S',
  artist: 'Singer S',
  songCount: 0,
  bestScore: 0,
  songs: [],
);

const _fetchedTracks = [
  AlbumTrack(name: 'Song A', artist: 'Singer A', durationMs: 200000),
  AlbumTrack(name: 'Deep Cut', artist: 'Singer A', durationMs: 180000),
  AlbumTrack(name: 'Outro', artist: 'Singer A', durationMs: 60000),
];

const _surpriseTracks = [
  AlbumTrack(name: 'First Song', artist: 'Singer S', durationMs: 210000),
  AlbumTrack(name: 'Second Song', artist: 'Singer S', durationMs: 150000),
];

MaterialApp _themedApp(Widget home, {AppDesign design = AppDesign.compact}) =>
    MaterialApp(
      theme: AppTheme.themeData(AppThemeName.editorial, design),
      home: home,
    );

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  late Box tracklistCacheBox;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_group4_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    final n = boxCounter++;
    favorites = FavoritesRepository(await Hive.openBox('g4_fav_$n'));
    playlists = PlaylistRepository(await Hive.openBox('g4_pl_$n'));
    // Opened here, not in a test body: opening a Hive box inside a
    // widget test body hangs under the fake clock (and poisons the
    // next test). The tracklist-cache widget test uses this box.
    tracklistCacheBox = await Hive.openBox('g4_tlcache_$n');
    await playlists.save(SavedPlaylist(
      info: const PlaylistInfo(
          platformId: 'deezer', id: 'pl1', name: 'My Mix'),
      tracks: const [],
      settings: const DiscoverySettings(songCount: 30, albumCount: 10),
      importedAt: DateTime.utc(2026, 11, 1),
      lastScannedAt: DateTime.utc(2026, 11, 1),
    ));
  });

  /// Lets real async work (a stub fetch, a Hive write) finish under
  /// runAsync, then pumps. Mirrors the phase_c settle helper.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  AlbumTracklistService stubService({
    List<AlbumTrack>? tracks,
    Object? error,
    void Function()? onFetch,
    AlbumTracklistCache? cache,
  }) =>
      AlbumTracklistService(
        fetch: (_, __) async {
          onFetch?.call();
          if (error != null) throw error;
          return AlbumInfo(tracks: tracks ?? const []);
        },
        cache: cache,
      );

  Future<void> pumpDetail(
    WidgetTester tester, {
    required AlbumRec album,
    AlbumEnrichment? enrichment,
    required AlbumTracklistService service,
    AudioPlayerNotifier? player,
    Dio? dio,
  }) async {
    final backend = FakeAudioBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioPlayerProvider.overrideWith((ref) =>
              player ?? AudioPlayerNotifier(FallbackSources(), backend: backend)),
          favoritesRepositoryProvider.overrideWithValue(favorites),
          playlistRepositoryProvider.overrideWithValue(playlists),
          albumTracklistServiceProvider.overrideWithValue(service),
          if (dio != null) dioProvider.overrideWithValue(dio),
          // The header cover resolves to the placeholder (no network
          // image load) in the interaction tests: the cover chain
          // itself is covered by the AlbumArtImage group, and a
          // network image load here can throw an uncaught async
          // error from the image cache manager that deadlocks the
          // test binding inside runAsync.
          albumArtCacheProvider.overrideWith((ref) => {
                'singer a|album a': null,
                'singer s|album s': null,
              }),
        ],
        child: _themedApp(
            AlbumDetailScreen(album: album, enrichment: enrichment)),
      ),
    );
    await tester.pump();
  }

  group('AlbumTracklistCache (Hive)', () {
    test('stores and returns a tracklist, keyed case-insensitively',
        () async {
      final n = boxCounter++;
      final cache =
          AlbumTracklistCache(await Hive.openBox('g4_cache_$n'));
      cache.store('Singer A', 'Album A', _fetchedTracks);
      final hit = cache.lookup('singer a', '  ALBUM A  ');
      expect(hit?.length, 3);
      expect(hit?[1].name, 'Deep Cut');
      expect(hit?[1].durationMs, 180000);
      expect(cache.shouldRetry('Singer A', 'Album A', DateTime.now()),
          isFalse);
    });

    test('a miss suppresses refetch until TTL expiry', () async {
      final n = boxCounter++;
      final cache =
          AlbumTracklistCache(await Hive.openBox('g4_cache_$n'));
      expect(cache.lookup('Singer A', 'Album A'), isNull);
      expect(cache.shouldRetry('Singer A', 'Album A', DateTime.now()),
          isTrue);
      cache.storeMiss('Singer A', 'Album A');
      expect(cache.lookup('Singer A', 'Album A'), isNull);
      expect(cache.shouldRetry('Singer A', 'Album A', DateTime.now()),
          isFalse);
      expect(
          cache.shouldRetry('Singer A', 'Album A',
              DateTime.now().add(const Duration(days: 31))),
          isTrue);
    });

    test('a stale hit reads as a miss', () async {
      final n = boxCounter++;
      final box = await Hive.openBox('g4_cache_$n');
      final cache = AlbumTracklistCache(box);
      await box.put(AlbumTracklistCache.keyFor('Singer A', 'Album A'), {
        'cachedAt': DateTime.now()
            .subtract(const Duration(days: 31))
            .toIso8601String(),
        'value': {
          'tracks': [
            {'name': 'Old', 'artist': 'Singer A'},
          ],
        },
      });
      expect(cache.lookup('Singer A', 'Album A'), isNull);
      expect(cache.shouldRetry('Singer A', 'Album A', DateTime.now()),
          isTrue);
    });
  });

  group('AlbumTracklistService', () {
    test('returns the fetched list and stores it', () async {
      final n = boxCounter++;
      final cache =
          AlbumTracklistCache(await Hive.openBox('g4_cache_$n'));
      var fetches = 0;
      final service = stubService(
        tracks: _fetchedTracks,
        onFetch: () => fetches++,
        cache: cache,
      );
      expect(await service.getTracklist('Singer A', 'Album A'),
          hasLength(3));
      expect(fetches, 1);
      // Second call reads the cache, not the fetcher.
      expect(await service.getTracklist('Singer A', 'Album A'),
          hasLength(3));
      expect(fetches, 1);
    });

    test('an empty fetch stores a miss and returns empty', () async {
      final n = boxCounter++;
      final cache =
          AlbumTracklistCache(await Hive.openBox('g4_cache_$n'));
      var fetches = 0;
      final service = stubService(
        tracks: const [],
        onFetch: () => fetches++,
        cache: cache,
      );
      expect(await service.getTracklist('Singer A', 'Album A'), isEmpty);
      expect(fetches, 1);
      expect(await service.getTracklist('Singer A', 'Album A'), isEmpty);
      expect(fetches, 1);
    });

    test('a failed fetch stores nothing, so reopening retries',
        () async {
      final n = boxCounter++;
      final cache =
          AlbumTracklistCache(await Hive.openBox('g4_cache_$n'));
      var fetches = 0;
      final failing = stubService(
        error: Exception('down'),
        onFetch: () => fetches++,
        cache: cache,
      );
      await expectLater(failing.getTracklist('Singer A', 'Album A'),
          throwsA(isA<Exception>()));
      expect(
          cache.shouldRetry('Singer A', 'Album A', DateTime.now()),
          isTrue);
      expect(fetches, 1);
    });

    test('without a cache every call fetches', () async {
      var fetches = 0;
      final service =
          stubService(tracks: _fetchedTracks, onFetch: () => fetches++);
      await service.getTracklist('Singer A', 'Album A');
      await service.getTracklist('Singer A', 'Album A');
      expect(fetches, 2);
    });
  });

  group('deriveAlbums backfill', () {
    Track t(String artist, String title,
            {String? album, String? imageUrl}) =>
        Track(
            artist: artist, title: title, album: album, imageUrl: imageUrl);

    test('copies album art into member tracks with no cover', () {
      final albums = RecommendationEngine.deriveAlbums([
        ScoredTrack(
            track: t('A', 'T1',
                album: 'Alpha', imageUrl: 'https://x/cover.jpg'),
            score: 3.0,
            reasons: const []),
        ScoredTrack(
            track: t('A', 'T2', album: 'Alpha'), score: 1.0, reasons: const []),
      ], 10);
      expect(albums.single.artUrl, 'https://x/cover.jpg');
      expect(albums.single.songs[0].track.imageUrl, 'https://x/cover.jpg');
      expect(albums.single.songs[1].track.imageUrl, 'https://x/cover.jpg');
    });

    test('a track with its own cover keeps it', () {
      final albums = RecommendationEngine.deriveAlbums([
        ScoredTrack(
            track: t('A', 'T1',
                album: 'Alpha', imageUrl: 'https://x/own.jpg'),
            score: 3.0,
            reasons: const []),
        ScoredTrack(
            track: t('A', 'T2',
                album: 'Alpha', imageUrl: 'https://x/album.jpg'),
            score: 1.0,
            reasons: const []),
      ], 10);
      expect(albums.single.songs[0].track.imageUrl, 'https://x/own.jpg');
      expect(albums.single.songs[1].track.imageUrl, 'https://x/album.jpg');
    });

    test('no art anywhere leaves imageUrl null', () {
      final albums = RecommendationEngine.deriveAlbums([
        ScoredTrack(
            track: t('A', 'T1', album: 'Alpha'), score: 3.0, reasons: const []),
      ], 10);
      expect(albums.single.artUrl, isNull);
      expect(albums.single.songs.single.track.imageUrl, isNull);
    });
  });

  group('cover chain (pure resolvers)', () {
    test('resolveAlbumArtUrl follows album, enrichment, thumb, cache',
        () {
      const album = AlbumRec(
          name: 'Alb', artist: 'Art', songCount: 0, bestScore: 0, songs: []);
      const withArt = AlbumRec(
          name: 'Alb',
          artist: 'Art',
          artUrl: 'https://x/album.jpg',
          songCount: 0,
          bestScore: 0,
          songs: []);
      const enrichment = AlbumEnrichment(
        artUrl: 'https://x/enrich.jpg',
        artistThumbUrl: 'https://x/thumb.jpg',
      );
      const thumbOnly =
          AlbumEnrichment(artistThumbUrl: 'https://x/thumb.jpg');
      expect(
          resolveAlbumArtUrl(
              album: withArt,
              enrichment: enrichment,
              cachedArtUrl: 'https://x/lazy.jpg'),
          'https://x/album.jpg');
      expect(
          resolveAlbumArtUrl(
              album: album,
              enrichment: enrichment,
              cachedArtUrl: 'https://x/lazy.jpg'),
          'https://x/enrich.jpg');
      expect(
          resolveAlbumArtUrl(
              album: album,
              enrichment: thumbOnly,
              cachedArtUrl: 'https://x/lazy.jpg'),
          'https://x/thumb.jpg');
      expect(
          resolveAlbumArtUrl(
              album: album, cachedArtUrl: 'https://x/lazy.jpg'),
          'https://x/lazy.jpg');
      expect(resolveAlbumArtUrl(album: album), isNull);
    });

    test('coverUrlFor prefers the track cover, then the fallback', () {
      expect(
          coverUrlFor(
              imageUrl: 'https://x/track.jpg',
              fallbackImageUrl: 'https://x/album.jpg'),
          'https://x/track.jpg');
      expect(
          coverUrlFor(
              imageUrl: '', fallbackImageUrl: 'https://x/album.jpg'),
          'https://x/album.jpg');
      expect(coverUrlFor(imageUrl: null, fallbackImageUrl: null), isNull);
      expect(coverUrlFor(imageUrl: '', fallbackImageUrl: ''), isNull);
    });
  });

  group('AlbumArtImage (shared cover chain)', () {
    testWidgets('album art renders without a lazy fetch', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: _themedApp(const AlbumArtImage.square(
              album: _albumWithRec, size: 72)),
        ),
      );
      await tester.pump();
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });

    testWidgets('enrichment art renders and skips the lazy fetch',
        (tester) async {
      var getInfoCalls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CountingAdapter((method) {
        if (method == 'track.getInfo') getInfoCalls++;
        return {'track': {}};
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dioProvider.overrideWithValue(dio)],
          child: _themedApp(const AlbumArtImage.square(
            album: _albumNoArt,
            size: 72,
            enrichment: AlbumEnrichment(
                artUrl: 'https://x/enrich.jpg', sources: ['TheAudioDB']),
          )),
        ),
      );
      await tester.pump();
      await settle(tester);
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      expect(getInfoCalls, 0);
    });

    testWidgets('no art anywhere shows the placeholder icon',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: _themedApp(const AlbumArtImage.square(
              album: _albumSurprise, size: 72)),
        ),
      );
      await tester.pump();
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.byIcon(Icons.album_outlined), findsOneWidget);
    });

    testWidgets('lazy Last.fm art fills in on the first song',
        (tester) async {
      var getInfoCalls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CountingAdapter((method) {
        if (method == 'track.getInfo') getInfoCalls++;
        return {
          'track': {
            'album': {
              'title': 'Album A',
              'artist': 'Singer A',
              'image': [
                {'#text': 'https://x/lazy.jpg', 'size': 'extralarge'},
              ],
            }
          }
        };
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dioProvider.overrideWithValue(dio)],
          child: _themedApp(
              const AlbumArtImage.square(album: _albumNoArt, size: 72)),
        ),
      );
      await tester.pump();
      // Dio's request chain runs on zero-duration timers, which the
      // widget test's fake clock only fires when fake time elapses:
      // pump with real durations until the lazy fetch lands.
      for (var i = 0; i < 10 && getInfoCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();
      expect(getInfoCalls, 1);
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });
  });

  group('Album detail tracklist', () {
    testWidgets('surprise album shows the full list, all name-only',
        (tester) async {
      await pumpDetail(
        tester,
        album: _albumSurprise,
        service: stubService(tracks: _surpriseTracks),
      );
      await settle(tester);

      expect(find.text('First Song'), findsOneWidget);
      expect(find.text('Second Song'), findsOneWidget);
      expect(find.text('Recommended'), findsNothing);
      expect(find.byType(EditorialSongRow), findsNothing);
      expect(find.text('2 tracks'), findsOneWidget);
    });

    testWidgets('recommended rows are badged and playable, others are names',
        (tester) async {
      final backend = FakeAudioBackend();
      final player =
          AudioPlayerNotifier(FallbackSources(), backend: backend);
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: _fetchedTracks),
        player: player,
      );
      await settle(tester);

      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Deep Cut'), findsOneWidget);
      expect(find.text('Outro'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.byType(EditorialSongRow), findsOneWidget);
      expect(find.text('3 tracks, 1 recommended'), findsOneWidget);
      // Name-only rows carry their Last.fm duration, muted, with no
      // heart or overflow of their own: the one overflow on screen
      // is the recommended row's.
      expect(find.text('3:00'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);

      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(backend.playedUrls, contains('https://example.com/a.m4a'));
      expect(player.state.currentTrack?.title, 'Song A');
    });

    testWidgets('recommended tracks Last.fm missed stay at the end',
        (tester) async {
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: const [
          AlbumTrack(
              name: 'Deep Cut', artist: 'Singer A', durationMs: 180000),
        ]),
      );
      await settle(tester);

      expect(find.text('Deep Cut'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('2 tracks, 1 recommended'), findsOneWidget);
    });

    testWidgets('loading shows the recommended rows plus a loading line',
        (tester) async {
      final completer = Completer<List<AlbumTrack>>();
      final service = AlbumTracklistService(
        fetch: (_, __) async {
          final tracks = await completer.future;
          return AlbumInfo(tracks: tracks);
        },
      );
      await pumpDetail(tester, album: _albumNoArt, service: service);
      await tester.pump();

      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Loading full tracklist'), findsOneWidget);
      expect(find.text('Deep Cut'), findsNothing);

      completer.complete(_fetchedTracks);
      await settle(tester);
      expect(find.text('Deep Cut'), findsOneWidget);
      expect(find.text('Loading full tracklist'), findsNothing);
    });

    testWidgets('a failed fetch keeps the recommendations and offers Retry',
        (tester) async {
      var fetches = 0;
      final service = AlbumTracklistService(
        fetch: (_, __) async {
          fetches++;
          if (fetches == 1) throw Exception('down');
          return const AlbumInfo(tracks: _fetchedTracks);
        },
      );
      await pumpDetail(tester, album: _albumNoArt, service: service);
      await settle(tester);

      expect(find.text('Song A'), findsOneWidget);
      expect(
          find.text('Could not load the full tracklist. '
              'Check your connection and retry.'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(fetches, 2);
      expect(find.text('Deep Cut'), findsOneWidget);
      expect(find.text('Could not load the full tracklist. '
              'Check your connection and retry.'),
          findsNothing);
    });

    testWidgets('no tracklist anywhere shows the honest empty state',
        (tester) async {
      await pumpDetail(
        tester,
        album: _albumSurprise,
        service: stubService(tracks: const []),
      );
      await settle(tester);

      expect(
          find.text('No track listing available for this album. '
              'Open it in platform to explore.'),
          findsOneWidget);
    });

    testWidgets('a cached tracklist never calls the fetcher',
        (tester) async {
      final cache = AlbumTracklistCache(tracklistCacheBox);
      cache.store('Singer S', 'Album S', _surpriseTracks);
      var fetches = 0;
      final service = stubService(
        error: Exception('must not fetch'),
        onFetch: () => fetches++,
        cache: cache,
      );
      await pumpDetail(
        tester,
        album: _albumSurprise,
        service: service,
      );
      await settle(tester);

      expect(fetches, 0);
      expect(find.text('First Song'), findsOneWidget);
    });

    testWidgets('a name-only row has no play gesture', (tester) async {
      final backend = FakeAudioBackend();
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: _fetchedTracks),
        player: AudioPlayerNotifier(FallbackSources(), backend: backend),
      );
      await settle(tester);

      await tester.tap(find.text('Deep Cut'));
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(backend.playedUrls, isEmpty);
    });
  });

  group('Album detail row interactions', () {
    testWidgets('fast double-tap likes instead of playing', (tester) async {
      final backend = FakeAudioBackend();
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: _fetchedTracks),
        player: AudioPlayerNotifier(FallbackSources(), backend: backend),
      );
      await settle(tester);

      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Song A'));
      await settle(tester);

      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
      expect(find.text('Added to favorites'), findsOneWidget);
      expect(backend.playedUrls, isEmpty);
    });

    testWidgets('swipe reveals Like, Add, Remove; Remove hides the row',
        (tester) async {
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: _fetchedTracks),
      );
      await settle(tester);

      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();

      expect(find.text('Like'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      expect(
          find.text('Removed Song A from this album view'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Song A'), findsOneWidget);
    });

    testWidgets('long-press opens the context sheet', (tester) async {
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: _fetchedTracks),
      );
      await settle(tester);

      await tester.longPress(find.text('Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
    });

    testWidgets('overflow opens the same context sheet', (tester) async {
      await pumpDetail(
        tester,
        album: _albumNoArt,
        service: stubService(tracks: _fetchedTracks),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Play next'), findsOneWidget);
    });
  });

  group('Album cover as song cover (player fallback)', () {
    testWidgets('a row with no cover uses the album art fallback',
        (tester) async {
      const track = Track(
          artist: 'Singer A', title: 'Song A', durationMs: 200000);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => AudioPlayerNotifier(
                FallbackSources(),
                backend: FakeAudioBackend())),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: _themedApp(
            const Scaffold(
              body: EditorialSongRow(
                track: track,
                fallbackImageUrl: 'https://example.com/album.jpg',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });

    testWidgets('a row with no cover and no fallback shows the tile',
        (tester) async {
      const track = Track(
          artist: 'Singer A', title: 'Song A', durationMs: 200000);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => AudioPlayerNotifier(
                FallbackSources(),
                backend: FakeAudioBackend())),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: _themedApp(
            const Scaffold(
              body: EditorialSongRow(track: track),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.byIcon(Icons.music_note), findsOneWidget);
    });

    testWidgets('mini-player shows album art for a coverless track',
        (tester) async {
      final backend = FakeAudioBackend();
      final player =
          AudioPlayerNotifier(FallbackSources(), backend: backend);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => player),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox.shrink(),
              bottomNavigationBar: MiniPlayerBar(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        await player.play(_trackA, albumArtUrl: 'https://x/album.jpg');
      });
      await tester.pump();
      expect(player.state.currentAlbumArtUrl, 'https://x/album.jpg');
      expect(find.byType(CachedNetworkImage), findsOneWidget);

      // Advancing to a track played without album context clears it.
      await tester.runAsync(() async {
        await player.play(_trackB);
      });
      await tester.pump();
      expect(player.state.currentAlbumArtUrl, isNull);
      expect(find.byType(CachedNetworkImage), findsNothing);
    });

    testWidgets('full player shows album art for a coverless track',
        (tester) async {
      final backend = FakeAudioBackend();
      final player =
          AudioPlayerNotifier(FallbackSources(), backend: backend);
      await tester.runAsync(() async {
        await player.play(_trackA, albumArtUrl: 'https://x/album.jpg');
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => player),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: const MaterialApp(home: FullPlayerScreen()),
        ),
      );
      await tester.pump();
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });

    test('a track with its own cover never takes the fallback', () async {
      final backend = FakeAudioBackend();
      final player =
          AudioPlayerNotifier(FallbackSources(), backend: backend);
      const withCover = Track(
        artist: 'Singer A',
        title: 'Song A',
        imageUrl: 'https://x/own.jpg',
        streamUrl: 'https://example.com/a.m4a',
      );
      await player.play(withCover, albumArtUrl: 'https://x/album.jpg');
      expect(player.state.currentAlbumArtUrl, isNull);
      expect(backend.playedUrls, contains('https://example.com/a.m4a'));
    });
  });
}

/// Answers Last.fm calls with a canned envelope and records the
/// methods requested.
class _CountingAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(String method) respond;
  _CountingAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final method = options.queryParameters['method'] as String? ?? '';
    return ResponseBody.fromString(
      jsonEncode(respond(method)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
