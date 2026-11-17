// Group 5 QA fix round: nav highlight, nav on sub-screens, the
// Favorites select bar as an overlay, and the swipe-row trailing
// icon fade.
//
// - Nav highlight: the shell used to read the tab index in
//   AppShell.build, but the shell renders inside an Overlay whose
//   initial entries are inserted once and never rebuilt, so the
//   highlight froze on Home. The bar is now its own ConsumerWidget
//   below the entry. These tests tap real nav destinations and read
//   the real NavigationBar.selectedIndex back.
// - Nav on sub-screens: a nav tap pops to the root first, so the tab
//   switch is visible instead of hidden behind the pushed route, and
//   the tabs are keep-alive, so the pop loses no tab state.
// - Favorites select bar: it used to be a second bottom bar stacked
//   inside the tab body (a Scaffold bottomNavigationBar). It is now
//   an OverlayPortal above the shell bar, so it floats over the list
//   instead of shrinking it.
// - Swipe fade: a row's trailing icons (heart, overflow) fade out as
//   the swipe row opens, so they never sit on top of the revealed
//   actions mid-swipe.
//
// The app is pumped whole (MusicManApp), like
// phase_c_interactions_test.dart: real Hive repos in fresh boxes, a
// no-op deep-link handler, empty playlists, canned Audius trending,
// and a seeded daily-picks cache so no test touches the network. No
// pumpAndSettle: loading states carry indeterminate indicators.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/enrichment/enrichment_models.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/lyrics/lyrics_cache.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/news/news_repository.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/history_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/data/repositories/settings_repository.dart';
import 'package:music_man/main.dart';
import 'package:music_man/presentation/providers/daily_picks_provider.dart';
import 'package:music_man/presentation/providers/discover_provider.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/news_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/playback_log_screen.dart';
import 'package:music_man/presentation/screens/results_screen.dart';
import 'package:music_man/presentation/widgets/swipe_action_row.dart';

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
const _trackC = Track(
  artist: 'Singer C',
  title: 'Song C',
  durationMs: 210000,
  streamUrl: 'https://example.com/c.m4a',
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
    ScoredTrack(
      track: _trackC,
      score: 0.5,
      reasons: ['Seed Song Three'],
    ),
  ],
  albums: [],
  seedName: 'My Mix',
  isSurprise: false,
  seedCount: 5,
  skippedSeeds: 0,
  enrichments: {
    'singer a - song a':
        TrackEnrichment(releaseDate: '2020-05-01', tags: ['j-pop']),
  },
);

/// A news repo whose fetch returns no articles, so the shell's News
/// dot stays off without any network.
class _EmptyNewsRepository extends NewsRepository {
  // ignore: use_super_parameters
  _EmptyNewsRepository(Box box, Dio dio) : super(box, dio);

  @override
  Future<NewsFetchResult> fetch({bool forceRefresh = false}) async =>
      NewsFetchResult(
        articles: const [],
        fetchedAt: DateTime.now(),
        sourceOk: const {},
      );
}

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  late SettingsRepository settingsRepo;
  late HistoryRepository historyRepo;
  late _EmptyNewsRepository newsRepo;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_group5_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    fullPlayerOnTop.value = false;
    final n = boxCounter++;
    favorites = FavoritesRepository(await Hive.openBox('g5_fav_$n'));
    playlists = PlaylistRepository(await Hive.openBox('g5_pl_$n'));
    settingsRepo = SettingsRepository(await Hive.openBox('g5_set_$n'));
    historyRepo = HistoryRepository(await Hive.openBox('g5_hist_$n'));
    newsRepo = _EmptyNewsRepository(await Hive.openBox('g5_news_$n'), Dio());
    for (final (id, name) in [('pl1', 'Chill Mix'), ('pl2', 'Late Night')]) {
      await playlists.save(SavedPlaylist(
        info: PlaylistInfo(platformId: 'deezer', id: id, name: name),
        tracks: const [],
        settings: const DiscoverySettings(songCount: 30, albumCount: 10),
        importedAt: DateTime.utc(2026, 11, 1),
        lastScannedAt: DateTime.utc(2026, 11, 1),
      ));
    }
    // Seed today's picks cache so the Favorites screen's picks
    // notifier never hits the network (mirrors
    // phase_c_interactions_test.dart). The PageView builds adjacent
    // tabs, so Favorites can be built while sitting on News.
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
    // A fresh cached lyrics miss for Song A, so the lyrics view
    // never hits the network.
    final lyricsBox = await Hive.openBox(LyricsCache.boxName);
    LyricsCache(lyricsBox).storeMiss('Singer A', 'Song A');
  });

  AudioPlayerNotifier playerFor(FakeAudioBackend backend) =>
      AudioPlayerNotifier(FallbackSources(), backend: backend);

  List<Override> appOverrides(AudioPlayerNotifier player) => [
        audioPlayerProvider.overrideWith((ref) => player),
        favoritesRepositoryProvider.overrideWithValue(favorites),
        playlistRepositoryProvider.overrideWithValue(playlists),
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        historyRepositoryProvider.overrideWithValue(historyRepo),
        newsRepositoryProvider.overrideWithValue(newsRepo),
        // The app root listens for incoming links; the test
        // harness has no link source, so the handler is a no-op.
        deepLinkHandlerProvider.overrideWith((ref) {}),
        // Home's playlist shelf without a platform fetch.
        userPlaylistsProvider
            .overrideWith((ref) async => const <PlaylistInfo>[]),
        // No real network in widget tests: the Discover tab fetches
        // Audius trending on build, and a failed fetch schedules
        // retry timers that stay pending after short tests and fail
        // the framework's post-test timer check.
        audiusTrendingProvider('all')
            .overrideWith((ref) async => const DiscoverLoad(items: [])),
      ];

  /// Pumps the whole app (shell + tab PageView) at [design]. The
  /// design is stored before pumping: the appearance notifier reads
  /// it from the settings repo when it is first created.
  Future<void> pumpApp(
    WidgetTester tester,
    AudioPlayerNotifier player, {
    AppDesign design = AppDesign.compact,
  }) async {
    await tester.runAsync(() async {
      await settingsRepo.setDesign(design.name);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: appOverrides(player),
        child: const MusicManApp(),
      ),
    );
    await tester.pump();
  }

  int selectedIndex(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  Future<void> tapNav(WidgetTester tester, int index) async {
    await tester.tap(find.byType(NavigationDestination).at(index));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Favorites tab with one favorited song, in select mode with that
  /// song selected, so the select bar is showing.
  Future<void> pumpFavoritesSelected(
    WidgetTester tester,
    AudioPlayerNotifier player,
  ) async {
    favorites.toggle(_trackA);
    await pumpApp(tester, player);
    await tapNav(tester, 3);
    expect(find.text('Songs (1)'), findsOneWidget);
    await tester.tap(find.byTooltip('Select'));
    await tester.pump();
    await tester.tap(find.text('Song A'));
    await tester.pump();
    // The bar is shown from a post-frame callback, and the portal
    // renders its child on the frame after that: one more pump.
    await tester.pump();
    expect(find.text('Remove (1)'), findsOneWidget);
  }

  group('Nav highlight follows the current tab', () {
    testWidgets('tapping each destination selects it', (tester) async {
      await pumpApp(tester, playerFor(FakeAudioBackend()));

      expect(selectedIndex(tester), 0);
      expect(find.text('Surprise me'), findsOneWidget);

      await tapNav(tester, 1);
      expect(selectedIndex(tester), 1);
      expect(find.text('Audius'), findsOneWidget);

      await tapNav(tester, 2);
      expect(selectedIndex(tester), 2);
      expect(find.text('Latest'), findsOneWidget);

      await tapNav(tester, 4);
      expect(selectedIndex(tester), 4);
      expect(
        find.text(
          'No runs yet. Generate recommendations and they will show up here.',
        ),
        findsOneWidget,
      );

      await tapNav(tester, 0);
      expect(selectedIndex(tester), 0);
      expect(find.text('Surprise me'), findsOneWidget);
    });
  });

  group('Nav works on sub-screens', () {
    testWidgets('a nav tap pops the sub-screen, switches tab, and '
        'keeps the tab state', (tester) async {
      final player = playerFor(FakeAudioBackend());
      await pumpFavoritesSelected(tester, player);

      // A pushed sub-screen on top of Favorites.
      navigatorKey.currentState!.push(
        MaterialPageRoute(builder: (_) => const PlaybackLogScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlaybackLogScreen), findsOneWidget);

      // Tapping the nav item pops to the root and switches tabs.
      await tapNav(tester, 1);
      // The pushed route's pop animation runs 300 ms; let it finish
      // before asserting the sub-screen is gone.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlaybackLogScreen), findsNothing);
      expect(selectedIndex(tester), 1);
      expect(find.text('Audius'), findsOneWidget);

      // Back on Favorites, the select state survived the pop: the
      // tabs are keep-alive.
      await tapNav(tester, 3);
      expect(selectedIndex(tester), 3);
      expect(find.text('Songs (1)'), findsOneWidget);
      expect(find.text('Remove (1)'), findsOneWidget);
    });
  });

  group('Favorites select bar is an overlay above the shell bar', () {
    testWidgets('the bar floats above the nav instead of stacking '
        'inside the tab body', (tester) async {
      final player = playerFor(FakeAudioBackend());
      favorites.toggle(_trackA);
      await pumpApp(tester, player);
      await tapNav(tester, 3);
      expect(find.text('Songs (1)'), findsOneWidget);
      final bodyHeightBefore =
          tester.getRect(find.byType(TabBarView)).height;

      await tester.tap(find.byTooltip('Select'));
      await tester.pump();
      await tester.tap(find.text('Song A'));
      await tester.pump();
      // The bar is shown from a post-frame callback, and the portal
      // renders its child on the frame after that: one more pump.
      await tester.pump();
      expect(find.text('Remove (1)'), findsOneWidget);

      // The bar floats over the list instead of shrinking it: the
      // tab body is the same height with the bar showing as without.
      expect(
        tester.getRect(find.byType(TabBarView)).height,
        bodyHeightBefore,
      );
      // Its bottom edge sits at the top of the shell bar (the nav,
      // with no track loaded the mini-player is empty).
      final barRect = tester.getRect(
          find.byKey(const ValueKey('favorites-select-bar')));
      final navRect = tester.getRect(find.byType(NavigationBar));
      expect(barRect.bottom, lessThanOrEqualTo(navRect.top + 0.5));
      expect(barRect.top, lessThan(navRect.top));

      // Clearing the selection hides the bar again (the hide runs
      // from a post-frame callback, so one more pump).
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Remove (1)'), findsNothing);
    });

    testWidgets('the bar hides on other tabs', (tester) async {
      final player = playerFor(FakeAudioBackend());
      await pumpFavoritesSelected(tester, player);

      await tapNav(tester, 0);
      expect(find.text('Remove (1)'), findsNothing);

      await tapNav(tester, 3);
      expect(find.text('Remove (1)'), findsOneWidget);
    });
  });

  group('Swipe row fades the trailing icons', () {
    Future<void> pumpResults(
      WidgetTester tester,
      AudioPlayerNotifier player,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => player),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: MaterialApp(
            theme:
                AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
            home: const ResultsScreen(result: _result),
          ),
        ),
      );
      await tester.pump();
    }

    Finder fadeOfRow(String title) => find.descendant(
          of: find.ancestor(
            of: find.text(title),
            matching: find.byType(SwipeActionRow),
          ),
          matching: find.byType(SwipeTrailingFade),
        );

    double fadeOpacity(WidgetTester tester, String title) =>
        tester
            .widget<AnimatedOpacity>(
              find.descendant(
                of: fadeOfRow(title),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity;

    testWidgets('trailing icons are full when shut, gone when open',
        (tester) async {
      await pumpResults(tester, playerFor(FakeAudioBackend()));

      expect(fadeOpacity(tester, 'Song A'), 1.0);

      final before = tester.getTopLeft(find.text('Song A')).dx;
      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();

      // The row snapped open (three actions at 72 each) and the
      // trailing icons faded out instead of sitting on the actions.
      final after = tester.getTopLeft(find.text('Song A')).dx;
      expect(after - before, closeTo(-216, 1));
      expect(fadeOpacity(tester, 'Song A'), 0.0);
      expect(find.text('Like'), findsWidgets);
    });
  });
}
