// Phase B Results tests (DESIGN.md, rounds 4-5): the double-tap
// tap rules on result rows, the heart, and the reason line opening
// Why this song. The player runs on a fake backend; the favorites
// + playlist repos are real, backed by fresh Hive boxes per test.
//
// Timing: the 250 ms double-tap window is a real Timer under the
// widget test's fake clock, so tester.pump(Duration) advances it
// exactly. Taps that write to Hive get a short real delay under
// runAsync afterwards, like appearance_test.dart.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/enrichment/enrichment_models.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/results_screen.dart';

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

const _result = GenerationResult(
  songs: [
    ScoredTrack(
      track: _trackA,
      score: 2.0,
      reasons: ['Seed Song One', 'Seed Song Two'],
    ),
    ScoredTrack(
      track: _trackB,
      score: 1.0,
      reasons: ['Trending now'],
    ),
  ],
  albums: [
    AlbumRec(
      name: 'Album A',
      artist: 'Singer A',
      artUrl: 'https://example.com/art.jpg',
      songCount: 1,
      bestScore: 2.0,
      songs: [
        ScoredTrack(
          track: _trackA,
          score: 2.0,
          reasons: ['Seed Song One'],
        ),
      ],
    ),
  ],
  seedName: 'My Mix',
  isSurprise: false,
  seedCount: 5,
  skippedSeeds: 0,
  enrichments: {
    'singer a - song a':
        TrackEnrichment(releaseDate: '2020-05-01', tags: ['j-pop']),
  },
);

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_results_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    // NOTE: Hive.close() hangs in widget tests once a box has been
    // written to (see appearance_test.dart). Skip it: the temp dir
    // is deleted below and the test process exits right after.
    await dir.delete(recursive: true);
  });

  setUp(() async {
    // Fresh boxes per test instead of clearing shared ones: opening
    // a box inside the test body hangs in the widget test's fake
    // async, and clearing a box hangs even under runAsync. setUp
    // runs outside the fake clock, so opening the box here works.
    final n = boxCounter++;
    final favBox = await Hive.openBox('fav_$n');
    final plBox = await Hive.openBox('pl_$n');
    favorites = FavoritesRepository(favBox);
    playlists = PlaylistRepository(plBox);
  });

  AudioPlayerNotifier playerFor(FakeAudioBackend backend) =>
      AudioPlayerNotifier(FallbackSources(), backend: backend);

  Future<void> pumpResults(
    WidgetTester tester,
    AudioPlayerNotifier player, {
    AppDesign design = AppDesign.compact,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioPlayerProvider.overrideWith((ref) => player),
          favoritesRepositoryProvider.overrideWithValue(favorites),
          playlistRepositoryProvider.overrideWithValue(playlists),
        ],
        child: MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, design),
          home: const ResultsScreen(result: _result),
        ),
      ),
    );
    await tester.pump();
  }

  // Lets a real async write (Hive) or resolve (player) finish after
  // a tap: the widget test's fake clock does not advance real I/O.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  group('Results tap rules', () {
    testWidgets('single tap plays after the 250 ms window',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);

      expect(backend.playedUrls, ['https://example.com/a.m4a']);
      expect(favorites.isFavorite('Singer A', 'Song A'), isFalse);
    });

    testWidgets('double-tap inside the window likes without playing',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);

      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
      expect(backend.playedUrls, isEmpty);
    });

    testWidgets(
        'two taps 400 ms apart do not like; the second tap reaches '
        'the player', (tester) async {
      final backend = FakeAudioBackend();
      final player = playerFor(backend);
      await pumpResults(tester, player);

      // First tap plays Song A.
      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(backend.playedUrls, ['https://example.com/a.m4a']);
      expect(favorites.isFavorite('Singer A', 'Song A'), isFalse);

      // Second tap, after the window closed: a new single tap, so
      // it reaches play() instead of liking. The shared player
      // toggles pause on a retap of the playing track, so the
      // observable effect is a pause, not a second backend play.
      await tester.tap(find.text('Song A'));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(backend.playedUrls, ['https://example.com/a.m4a']);
      expect(backend.pauseCalls, 1);
      expect(favorites.isFavorite('Singer A', 'Song A'), isFalse);

      // A tap on the other row plays it: two plays, no likes.
      await tester.tap(find.text('Song B'));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(backend.playedUrls,
          ['https://example.com/a.m4a', 'https://example.com/b.m4a']);
      expect(favorites.isFavorite('Singer B', 'Song B'), isFalse);
    });

    testWidgets('heart likes immediately without playing',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.byTooltip('Add to favorites').first);
      await settle(tester);

      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
      expect(backend.playedUrls, isEmpty);
    });

    testWidgets('reason tap opens Why this song, back returns',
        (tester) async {
      final backend = FakeAudioBackend();
      favorites.toggle(
          const Track(artist: 'Liked Artist', title: 'Fav Song'));
      await pumpResults(tester, playerFor(backend));

      await tester.tap(
          find.text('Because you liked Seed Song One and Seed Song Two'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Why this song'), findsOneWidget);
      expect(
          find.text('Seed song from your playlist: Seed Song One'),
          findsOneWidget);
      expect(
          find.text('Seed song from your playlist: Seed Song Two'),
          findsOneWidget);
      expect(find.text('Liked artists'), findsOneWidget);
      expect(find.text('liked artist'), findsOneWidget);
      expect(backend.playedUrls, isEmpty);

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Song A'), findsOneWidget);
    });
  });

  group('Results Complex additions', () {
    testWidgets('summary header, chips, and per-track meta',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend),
          design: AppDesign.complex);

      expect(find.text('Picks'), findsOneWidget);
      expect(find.text('2 songs • 1 albums • 5 seeds'), findsOneWidget);
      expect(find.text('All (2)'), findsOneWidget);
      expect(find.text('Similar (1)'), findsOneWidget);
      expect(find.text('Trending (1)'), findsOneWidget);
      // Year from the MusicBrainz enrichment, duration from the
      // track, tags from the enrichment. No platform is shown:
      // Track carries none.
      expect(find.text('2020 • 3:20 • j-pop'), findsOneWidget);
      expect(find.text('3:03'), findsOneWidget);
      expect(backend.playedUrls, isEmpty);
    });

    testWidgets('albums tab shows the cover-led card', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.text('Albums'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Album A'), findsOneWidget);
      expect(find.text('1 songs recommended from this album'),
          findsOneWidget);
    });
  });
}
