// Phase B group 3 widget tests: Playlist detail, Favorites, History.
//
// - Playlist track tap plays at once (no 250 ms wait): the test never
//   advances the fake clock, so a play proves the tap did not wait
//   the double-tap window out. The heart likes without playing.
// - Favorites groups render with counts; the empty state names the
//   action that fills it.
// - History run tap reopens the cached result; swiping a run deletes it.
//
// Hive lesson (see appearance_test.dart): fresh boxes per test in
// setUp (real async), never clear() shared boxes, runAsync + a short
// real delay after taps that write to Hive, no Hive.close() in a
// widget tearDownAll. No pumpAndSettle anywhere: the loading states
// carry indeterminate indicators that never settle.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/history_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/data/repositories/settings_repository.dart';
import 'package:music_man/presentation/providers/daily_picks_provider.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/favorites_screen.dart';
import 'package:music_man/presentation/screens/history_screen.dart';
import 'package:music_man/presentation/screens/playlist_detail_screen.dart';
import 'package:music_man/presentation/screens/results_screen.dart';

import 'fake_audio_backend.dart';

List<Track> _tracks(int count) => [
      for (var i = 0; i < count; i++)
        Track(
          artist: 'Singer ${i + 1}',
          title: 'Song ${i + 1}',
          streamUrl: 'https://example.com/${i + 1}.m4a',
          durationMs: 200000 + i * 1000,
        ),
    ];

const _favTrack = Track(
  artist: 'Singer A',
  title: 'Song A',
  streamUrl: 'https://example.com/a.m4a',
);

const _favAlbum = AlbumRec(
  name: 'Album X',
  artist: 'Singer B',
  songCount: 4,
  bestScore: 9.0,
  songs: [],
);

MaterialApp _themedApp(Widget home) => MaterialApp(
      theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
      home: home,
    );

void main() {
  late Directory dir;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_phase_b3');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  // Lets a real Hive write finish after a tap (runAsync: the widget
  // test's fake clock does not advance real I/O), then pumps so the
  // UI reflects the stored state. No fake-clock time passes here.
  Future<void> settleHiveWrite(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  group('Playlist detail', () {
    late PlaylistRepository playlistRepo;
    late SettingsRepository settingsRepo;
    late FavoritesRepository favoritesRepo;
    late HistoryRepository historyRepo;
    late FakeAudioBackend backend;
    late AudioPlayerNotifier player;

    setUp(() async {
      final n = boxCounter++;
      playlistRepo = PlaylistRepository(await Hive.openBox('b3_pl_$n'));
      settingsRepo = SettingsRepository(await Hive.openBox('b3_set_$n'));
      favoritesRepo = FavoritesRepository(await Hive.openBox('b3_fav_$n'));
      historyRepo = HistoryRepository(await Hive.openBox('b3_hist_$n'));
      backend = FakeAudioBackend();
      player = AudioPlayerNotifier(FallbackSources(), backend: backend);
    });

    Future<void> pumpDetail(WidgetTester tester, List<Track> tracks) async {
      // The platform instance is display-only here (name, beta flag);
      // read it from a throwaway container so no network is touched.
      final registryContainer = ProviderContainer();
      final platform = registryContainer
          .read(platformRegistryProvider)
          .byId('deezer');
      registryContainer.dispose();
      final data = PlaylistDetailData(
        platform: platform,
        info: PlaylistInfo(
          platformId: 'deezer',
          id: 'pl1',
          name: 'My Mix',
          owner: 'Me',
          trackCount: tracks.length,
        ),
        tracks: tracks,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistDetailProvider('deezer::pl1')
                .overrideWith((ref) async => data),
            playlistRepositoryProvider.overrideWithValue(playlistRepo),
            settingsRepositoryProvider.overrideWithValue(settingsRepo),
            favoritesRepositoryProvider.overrideWithValue(favoritesRepo),
            historyRepositoryProvider.overrideWithValue(historyRepo),
            audioPlayerProvider.overrideWith((ref) => player),
          ],
          child: _themedApp(
            const PlaylistDetailScreen(
                platformId: 'deezer', playlistId: 'pl1'),
          ),
        ),
      );
      await tester.pump();
      // Lets the auto-save of the import land.
      await settleHiveWrite(tester);
    }

    testWidgets('tapping a track plays it at once, no 250 ms wait',
        (tester) async {
      await pumpDetail(tester, _tracks(6));
      // The track list virtualizes below the tall header, so scroll
      // the row into view before tapping it.
      await tester.scrollUntilVisible(find.text('Song 1'), 200);
      await tester.pump();
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.text('Get recommendations'), findsOneWidget);

      await tester.tap(find.text('Song 1'));
      // Zero-duration pumps only: the fake clock never advances, so
      // a play here proves the tap did not wait the 250 ms
      // double-tap window out. The short delay below is real time
      // (runAsync), not fake-clock time.
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(backend.playedUrls, ['https://example.com/1.m4a']);
      expect(player.state.currentTrack?.title, 'Song 1');
      expect(player.state.isPlaying, isTrue);
    });

    testWidgets('heart on a playlist row likes without playing',
        (tester) async {
      await pumpDetail(tester, _tracks(6));
      // Scroll until the first row is built: the list virtualizes
      // below the tall header. Then tap that row's heart (found as
      // a descendant, so the other rows' hearts never match).
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('playlist-track-0')), 200);
      await tester.pump();
      final heart = find.descendant(
        of: find.byKey(const ValueKey('playlist-track-0')),
        matching: find.byTooltip('Add to favorites'),
      );
      expect(heart, findsOneWidget);
      await tester.tap(heart);
      await settleHiveWrite(tester);

      expect(favoritesRepo.isFavorite('Singer 1', 'Song 1'), isTrue);
      expect(backend.playedUrls, isEmpty);
    });

    testWidgets(
        'Get recommendations is disabled below 5 tracks, with guidance',
        (tester) async {
      await pumpDetail(tester, _tracks(3));
      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Get recommendations'));
      expect(button.onPressed, isNull);
      expect(
        find.text(
          'Need at least 5 tracks to generate recommendations. '
          'This playlist has 3.',
        ),
        findsOneWidget,
      );
    });
  });

  group('Favorites', () {
    late FavoritesRepository favorites;
    late FakeAudioBackend backend;
    late AudioPlayerNotifier player;

    setUp(() async {
      final n = boxCounter++;
      favorites = FavoritesRepository(await Hive.openBox('b3_favs_$n'));
      backend = FakeAudioBackend();
      player = AudioPlayerNotifier(FallbackSources(), backend: backend);
      // Seed today's picks cache so the picks notifier never hits
      // the network (the real Last.fm key is compiled in).
      final picksBox = await Hive.openBox('daily_picks');
      final now = DateTime.now();
      final key = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      await picksBox.put('picks', {
        'date': key,
        'picks': DailyPicks(
          songs: const [],
          albums: const [],
          generatedAt: now,
        ).toJson(),
      });
    });

    Future<void> pumpFavorites(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            favoritesRepositoryProvider.overrideWithValue(favorites),
            audioPlayerProvider.overrideWith((ref) => player),
          ],
          child: _themedApp(const FavoritesScreen()),
        ),
      );
      await tester.pump();
      await settleHiveWrite(tester);
    }

    testWidgets('Songs and Albums groups render with counts',
        (tester) async {
      favorites.toggle(_favTrack);
      favorites.toggleAlbum(_favAlbum);
      await pumpFavorites(tester);

      expect(find.text("Today's picks"), findsOneWidget);
      expect(find.text('Songs (1)'), findsOneWidget);
      expect(find.text('Albums (1)'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);

      await tester.tap(find.text('Albums (1)'));
      // Let the tab switch settle fully before looking for the album.
      await tester.pumpAndSettle(const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      expect(find.text('Album X'), findsOneWidget);
    });

    testWidgets('empty state names the action that fills it',
        (tester) async {
      await pumpFavorites(tester);
      expect(
        find.text(
          'No favorite songs yet. Tap the heart on any recommendation.',
        ),
        findsOneWidget,
      );
      expect(find.text('Browse home'), findsWidgets);
    });
  });

  group('History', () {
    late HistoryRepository history;
    late FavoritesRepository favorites;
    late PlaylistRepository playlists;
    late SettingsRepository settings;
    late FakeAudioBackend backend;
    late AudioPlayerNotifier player;

    setUp(() async {
      final n = boxCounter++;
      history = HistoryRepository(await Hive.openBox('b3_h_$n'));
      favorites = FavoritesRepository(await Hive.openBox('b3_hf_$n'));
      playlists = PlaylistRepository(await Hive.openBox('b3_hp_$n'));
      settings = SettingsRepository(await Hive.openBox('b3_hs_$n'));
      backend = FakeAudioBackend();
      player = AudioPlayerNotifier(FallbackSources(), backend: backend);
    });

    HistoryRun makeRun() => HistoryRun(
          id: 'run1',
          timestamp: DateTime.now().subtract(const Duration(hours: 2)),
          seedName: 'My Mix',
          isSurprise: false,
          resultJson: const GenerationResult(
            songs: [
              ScoredTrack(
                track: _favTrack,
                score: 9.0,
                reasons: ['Seed song'],
              ),
            ],
            albums: [],
            seedName: 'My Mix',
            isSurprise: false,
            seedCount: 6,
            skippedSeeds: 0,
          ).toJson(),
        );

    Future<void> pumpHistory(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            historyRepositoryProvider.overrideWithValue(history),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
            settingsRepositoryProvider.overrideWithValue(settings),
            audioPlayerProvider.overrideWith((ref) => player),
          ],
          child: _themedApp(const HistoryScreen()),
        ),
      );
      await tester.pump();
      await settleHiveWrite(tester);
    }

    testWidgets('run tap reopens the cached result', (tester) async {
      // Seeding under runAsync: awaiting a Hive write in the test
      // body hangs in the widget test's fake async.
      await tester.runAsync(() async {
        await history.add(makeRun());
      });
      await pumpHistory(tester);
      expect(find.text('My Mix'), findsOneWidget);
      expect(find.text('Past runs'), findsOneWidget);

      await tester.tap(find.text('My Mix'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ResultsScreen), findsOneWidget);
    });

    testWidgets('swiping a run deletes it', (tester) async {
      await tester.runAsync(() async {
        await history.add(makeRun());
      });
      await pumpHistory(tester);
      expect(find.text('My Mix'), findsOneWidget);

      // A slow drag past the Dismissible threshold (half the row
      // width): timed steps, so the drag recognizer sees the move.
      await tester.timedDrag(
        find.text('My Mix'),
        const Offset(-600, 0),
        const Duration(milliseconds: 500),
      );
      // The dismiss runs two animations back to back after the
      // pointer lifts: the move off screen (200 ms) then the resize
      // to zero (300 ms), and onDismissed fires only when the resize
      // completes. Advance the fake clock past both, in separate
      // pumps, so the resize actually starts and finishes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await settleHiveWrite(tester);

      expect(find.text('My Mix'), findsNothing);
      // The swipe already removed the row from the UI; the Hive
      // delete lands on disk after the write completes, so poll the
      // repo in real time instead of asserting on the first check.
      await tester.runAsync(() async {
        final deadline =
            DateTime.now().add(const Duration(seconds: 5));
        while (history.getAll().isNotEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(
              const Duration(milliseconds: 100));
        }
      });
      await tester.pump();
      expect(history.getAll(), isEmpty);
      expect(
        find.text(
          'No runs yet. Generate recommendations and they will '
          'show up here.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('empty state', (tester) async {
      await pumpHistory(tester);
      expect(
        find.text(
          'No runs yet. Generate recommendations and they will '
          'show up here.',
        ),
        findsOneWidget,
      );
      expect(find.text('Generate recommendations'), findsOneWidget);
    });
  });
}
