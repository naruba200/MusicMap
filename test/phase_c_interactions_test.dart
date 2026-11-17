// Phase C Group 4 widget tests: tab swipe, pull-to-refresh, the
// shell hiding under the full player, queue swipe through
// SwipeActionRow, Lyrics from the context sheet, and reduced motion.
//
// - Tab swipe: swiping moves between the six tabs with the next tab
//   previewing mid-drag in both designs (Compact settles instantly,
//   Complex animates); a drag past the first or last tab moves
//   nothing; a swipe starting on a swipeable row acts on the row.
// - Pull to refresh: Discover re-runs its current tab's fetch;
//   News still refreshes after the tab restructure.
// - Shell: opening the full player hides the mini-player and the
//   nav bar; dismissing it brings them back.
// - Queue: a swipe reveals Remove instantly in Compact; tapping it
//   removes the track with an Undo toast that restores it.
// - Lyrics: the context sheet carries a Lyrics entry that opens the
//   lyrics view for the track.
// - Reduced motion: reduceMotion zeroes every token duration without
//   changing density, and MusicManApp honours MediaQuery
//   disableAnimations.
//
// The player runs on a fake backend; the favorites + playlist +
// settings + history + news repos are real, backed by fresh Hive
// boxes per test (never clear() shared boxes, no Hive.close() in
// widget tearDownAll, no pumpAndSettle: the loading states carry
// indeterminate indicators that never settle).

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
import 'package:music_man/data/news/rss_parser.dart';
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
import 'package:music_man/presentation/screens/discover_screen.dart';
import 'package:music_man/presentation/screens/full_player_screen.dart';
import 'package:music_man/presentation/screens/lyrics_screen.dart';
import 'package:music_man/presentation/screens/playlist_detail_screen.dart';
import 'package:music_man/presentation/screens/results_screen.dart';
import 'package:music_man/presentation/widgets/mini_player_bar.dart';
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

const _queue = [_trackA, _trackB, _trackC];

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

List<Track> _playlistTracks(int count) => [
      for (var i = 0; i < count; i++)
        Track(
          artist: 'Singer ${i + 1}',
          title: 'Song ${i + 1}',
          streamUrl: 'https://example.com/${i + 1}.m4a',
          durationMs: 200000 + i * 1000,
        ),
    ];

/// A news repo that counts fetches and always returns two articles,
/// so pull-to-refresh is observable without any network.
class _CountingNewsRepository extends NewsRepository {
  // ignore: use_super_parameters
  _CountingNewsRepository(Box box, Dio dio) : super(box, dio);

  int fetchCount = 0;

  @override
  Future<NewsFetchResult> fetch({bool forceRefresh = false}) async {
    fetchCount++;
    return NewsFetchResult(
      articles: const [
        NewsArticle(
          title: 'Article One',
          link: 'https://example.com/1',
          sourceId: 's1',
          sourceName: 'Source One',
        ),
        NewsArticle(
          title: 'Article Two',
          link: 'https://example.com/2',
          sourceId: 's1',
          sourceName: 'Source One',
        ),
      ],
      fetchedAt: DateTime.now(),
      sourceOk: const {'s1': true},
    );
  }
}

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  late SettingsRepository settingsRepo;
  late HistoryRepository historyRepo;
  late _CountingNewsRepository newsRepo;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_phasec4_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    final n = boxCounter++;
    final favBox = await Hive.openBox('c4_fav_$n');
    final plBox = await Hive.openBox('c4_pl_$n');
    final newsBox = await Hive.openBox('c4_news_$n');
    favorites = FavoritesRepository(favBox);
    playlists = PlaylistRepository(plBox);
    // Settings + history boxes too: opening a Hive box inside the
    // test body hangs under the fake clock, so every box opens here
    // in setUp (which runs outside the fake clock).
    settingsRepo = SettingsRepository(await Hive.openBox('c4_set_$n'));
    historyRepo = HistoryRepository(await Hive.openBox('c4_hist_$n'));
    newsRepo = _CountingNewsRepository(newsBox, Dio());
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
    // phase_b_playlist_test.dart). The PageView builds adjacent
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
    // never hits the network in the Lyrics test.
    final lyricsBox = await Hive.openBox(LyricsCache.boxName);
    LyricsCache(lyricsBox).storeMiss('Singer A', 'Song A');
  });

  AudioPlayerNotifier playerFor(FakeAudioBackend backend) =>
      AudioPlayerNotifier(FallbackSources(), backend: backend);

  /// Loads [track] on the fake backend with a 3 minute duration, so
  /// the player shows real times and a seekable rule.
  Future<AudioPlayerNotifier> loadedPlayer({
    List<Track> queue = _queue,
  }) async {
    final backend = FakeAudioBackend()
      ..fakeDuration = const Duration(minutes: 3);
    final player = playerFor(backend);
    await player.playStream(
      queue.first,
      'https://example.com/stream.m4a',
      queue: queue,
    );
    return player;
  }

  /// Lets a real Hive write finish after a tap (runAsync: the widget
  /// test's fake clock does not advance real I/O), then pumps.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

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
        // retry timers (ConnectionRetryInterceptor, up to 5 attempts)
        // that stay pending after short tests and fail the
        // framework's post-test timer check.
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

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MusicManApp)));

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
          theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
          home: const ResultsScreen(result: _result),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpPlayer(
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
          home: const FullPlayerScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  /// Seeds the saved copy of pl1 with the same tracks the detail
  /// view shows: the real imported state (mirrors
  /// phase_c_gestures_test.dart).
  Future<void> seedSavedDetail(WidgetTester tester) async {
    await tester.runAsync(() async {
      await playlists.save(
        SavedPlaylist(
          info: const PlaylistInfo(
            platformId: 'deezer',
            id: 'pl1',
            name: 'My Mix',
          ),
          tracks: _playlistTracks(6),
          settings:
              const DiscoverySettings(songCount: 30, albumCount: 10),
          importedAt: DateTime.utc(2026, 11, 1),
          lastScannedAt: DateTime.utc(2026, 11, 1),
        ),
      );
    });
  }

  Future<void> pumpDetail(
    WidgetTester tester,
    AudioPlayerNotifier player,
    List<Track> tracks, {
    List<Override> extraOverrides = const [],
  }) async {
    final registryContainer = ProviderContainer();
    final platform =
        registryContainer.read(platformRegistryProvider).byId('deezer');
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
          playlistRepositoryProvider.overrideWithValue(playlists),
          settingsRepositoryProvider.overrideWithValue(settingsRepo),
          favoritesRepositoryProvider.overrideWithValue(favorites),
          historyRepositoryProvider.overrideWithValue(historyRepo),
          audioPlayerProvider.overrideWith((ref) => player),
          ...extraOverrides,
        ],
        child: MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
          home: const PlaylistDetailScreen(
              platformId: 'deezer', playlistId: 'pl1'),
        ),
      ),
    );
    await tester.pump();
    await settle(tester);
  }

  /// Press and hold a row past the 500 ms long-press delay, then
  /// release without moving: the context sheet opens.
  Future<void> longPressRow(WidgetTester tester, Finder finder) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Drags in small steps, the way a real finger moves: a single
  /// giant moveBy does not claim the gesture arena when a vertical
  /// scrollable sits in the hit path, so a nested PageView never
  /// moves. Returns the still-down gesture; the caller releases it.
  Future<TestGesture> dragStepped(
    WidgetTester tester,
    Offset start,
    Offset total, {
    int steps = 10,
  }) async {
    final gesture = await tester.startGesture(start);
    final step = total / steps.toDouble();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(step);
    }
    return gesture;
  }

  /// A nav destination's label, scoped to the bottom bar: the bar
  /// swaps each destination's icon as its selection animation runs,
  /// so an icon finder is stale right after a tap, and a bare text
  /// finder can match a screen title as well as the label.
  Finder navLabel(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );

  // -- Tab swipe ------------------------------------------------------

  testWidgets('tab swipe moves to the next tab with preview in Compact',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpApp(tester, player);
    final container = containerOf(tester);
    final controller = container.read(tabPageControllerProvider);
    expect(container.read(tabIndexProvider), 0);

    // Drag partway and hold: the next tab previews (the page sits
    // between tabs) while the tab has not changed yet.
    final gesture = await dragStepped(
        tester, const Offset(400, 100), const Offset(-200, 0));
    await tester.pump();
    final midPage = controller.page;
    expect(midPage, isNotNull);
    expect(midPage!, greaterThan(0.0));
    expect(midPage, lessThan(1.0));
    expect(container.read(tabIndexProvider), 0);
    expect(
      find.descendant(
        of: find.byType(PageView),
        matching: find.text('Audius'),
      ),
      findsOneWidget,
    );

    // Drag past halfway, then release: Compact settles instantly,
    // no animation frames.
    for (var i = 0; i < 15; i++) {
      await gesture.moveBy(const Offset(-20, 0));
    }
    await tester.pump();
    expect(container.read(tabIndexProvider), 1);
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(controller.page, 1.0);
    expect(container.read(tabIndexProvider), 1);
    expect(
      find.descendant(
        of: find.byType(PageView),
        matching: find.text('Discover'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tab swipe animates the completion in Complex',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpApp(tester, player, design: AppDesign.complex);
    final container = containerOf(tester);
    final controller = container.read(tabPageControllerProvider);

    // Drag partway and hold: the next tab previews while the tab
    // has not changed yet.
    final gesture = await dragStepped(
        tester, const Offset(400, 100), const Offset(-200, 0));
    await tester.pump();
    final midPage = controller.page;
    expect(midPage, isNotNull);
    expect(midPage!, greaterThan(0.0));
    expect(midPage, lessThan(1.0));
    expect(container.read(tabIndexProvider), 0);

    // Release below halfway: the snap back animates over the
    // tab-switch duration instead of jumping. Partway through it
    // the page is still in flight, closer to the first tab than
    // when it was released. (The first pump after release only
    // starts the snap; the next one advances it.)
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final snapPage = controller.page;
    expect(snapPage, isNotNull);
    expect(snapPage!, greaterThan(0.0));
    expect(snapPage, lessThan(midPage));
    expect(container.read(tabIndexProvider), 0);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.page, 0.0);
    expect(container.read(tabIndexProvider), 0);

    // Drag past halfway and release: the switch completes, still
    // animated.
    final gesture2 = await dragStepped(
        tester, const Offset(400, 100), const Offset(-500, 0));
    await tester.pump();
    expect(container.read(tabIndexProvider), 1);
    await gesture2.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final forwardPage = controller.page;
    expect(forwardPage, isNotNull);
    expect(forwardPage!, greaterThan(0.0));
    expect(forwardPage, lessThan(1.0));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.page, 1.0);
    expect(container.read(tabIndexProvider), 1);
  });

  testWidgets('nav taps jump instantly in Compact', (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpApp(tester, player);
    final container = containerOf(tester);
    final controller = container.read(tabPageControllerProvider);

    // Tapping Discover jumps with no animation frames.
    await tester.tap(navLabel('Discover'));
    await tester.pump();
    expect(controller.page, 1.0);
    expect(container.read(tabIndexProvider), 1);

    // And back home the same way.
    await tester.tap(navLabel('Home'));
    await tester.pump();
    expect(controller.page, 0.0);
    expect(container.read(tabIndexProvider), 0);
  });

  testWidgets('nav taps animate in Complex', (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpApp(tester, player, design: AppDesign.complex);
    final container = containerOf(tester);
    final controller = container.read(tabPageControllerProvider);

    // The tap switches the tab at once (the provider is the source
    // of truth), while the page itself animates there over the
    // tab-switch duration. The tap resolves on the next frame, so
    // one pump starts the animation and the next one advances it.
    await tester.tap(navLabel('Discover'));
    expect(container.read(tabIndexProvider), 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final midPage = controller.page;
    expect(midPage, isNotNull);
    expect(midPage!, greaterThan(0.0));
    expect(midPage, lessThan(1.0));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.page, 1.0);
  });

  testWidgets('dragging past the first or last tab moves nothing',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpApp(tester, player);
    final container = containerOf(tester);
    final controller = container.read(tabPageControllerProvider);

    // First tab: fling right, towards a tab that does not exist.
    // A fling is a real multi-step drag with velocity, so the
    // edge clamp is genuinely exercised, not just unclaimed.
    await tester.flingFrom(
        const Offset(400, 100), const Offset(300, 0), 1000);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(tabIndexProvider), 0);
    expect(controller.page, 0.0);

    // Last tab: tap the Settings nav item, then fling left.
    await tester.tap(navLabel('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(tabIndexProvider), 5);
    await tester.flingFrom(
        const Offset(400, 300), const Offset(-300, 0), 1000);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(tabIndexProvider), 5);
    expect(controller.page, 5.0);
  });

  testWidgets(
      'a swipe starting on a swipeable row acts on the row, not the tab',
      (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
        home: Scaffold(
          body: PageView(
            controller: controller,
            children: [
              ListView(
                children: [
                  SwipeActionRow(
                    actions: [
                      SwipeAction(
                        label: 'Remove',
                        icon: Icons.delete_outline,
                        onTap: () {},
                      ),
                    ],
                    child: const ListTile(title: Text('Row song')),
                  ),
                  const ListTile(title: Text('Plain row')),
                ],
              ),
              const Center(child: Text('Second tab')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Drag the row left: the row slides aside to reveal its action
    // and the page stays put (the row's inner horizontal drag wins
    // the gesture arena over the tab swipe).
    final before = tester.getTopLeft(find.text('Row song'));
    await tester.drag(find.text('Row song'), const Offset(-100, 0));
    await tester.pump();
    final after = tester.getTopLeft(find.text('Row song'));
    expect(after.dx, lessThan(before.dx));
    expect(controller.page, 0.0);

    // Dragging the plain area the same way switches tabs: past
    // halfway the release completes the switch.
    await tester.drag(find.text('Plain row'), const Offset(-500, 0));
    await tester.pump();
    expect(controller.page, greaterThan(0.5));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.page, 1.0);
  });

  // -- Pull to refresh --------------------------------------------------

  testWidgets('Discover pull-to-refresh re-runs the current tab fetch',
      (tester) async {
    var fetchCount = 0;
    final player = playerFor(FakeAudioBackend());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audiusTrendingProvider('all').overrideWith((ref) async {
            fetchCount++;
            return const DiscoverLoad(items: [_trackA, _trackB]);
          }),
          audioPlayerProvider.overrideWith((ref) => player),
          favoritesRepositoryProvider.overrideWithValue(favorites),
          playlistRepositoryProvider.overrideWithValue(playlists),
        ],
        child: MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
          home: const DiscoverScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(fetchCount, 1);
    expect(find.text('Song A'), findsOneWidget);

    await tester.drag(find.text('Song A'), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(fetchCount, 2);
    expect(find.text('Song A'), findsOneWidget);
  });

  testWidgets('News pull-to-refresh still works after the tab restructure',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpApp(tester, player);
    final container = containerOf(tester);
    container.read(tabIndexProvider.notifier).state = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(newsRepo.fetchCount, 1);
    expect(find.text('Article One'), findsOneWidget);

    await tester.drag(find.text('Article One'), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(newsRepo.fetchCount, 2);
    expect(find.text('Article One'), findsOneWidget);
  });

  // -- Shell hide -------------------------------------------------------

  testWidgets(
      'shell bar hides under the open full player and returns on dismiss',
      (tester) async {
    final player = await loadedPlayer();
    await pumpApp(tester, player);

    // Something is loaded, so the mini-player and nav are showing.
    expect(find.byType(MiniPlayerBar), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    // Open the player from the mini-player strip.
    await tester.tap(find.text('Song A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FullPlayerScreen), findsOneWidget);
    expect(find.byType(MiniPlayerBar), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);

    // Dismiss with the close button: the bar comes back.
    await tester.tap(find.byTooltip('Close player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FullPlayerScreen), findsNothing);
    expect(find.byType(MiniPlayerBar), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  // -- Queue swipe ------------------------------------------------------

  testWidgets('queue swipe-remove via SwipeActionRow is instant in Compact',
      (tester) async {
    final player = await loadedPlayer();
    await pumpPlayer(tester, player);
    expect(find.text('Song B'), findsOneWidget);
    const rowKey = ValueKey('queue-row:Singer B::Song B');

    // The row sits below the fold: bring it on screen first, or
    // the drag starts outside the surface and hits nothing.
    await tester.ensureVisible(find.byKey(rowKey));
    await tester.pump();

    // Swipe left: Compact applies the reveal instantly, with no
    // animation frames, and the track is still queued (a swipe only
    // reveals the action).
    final before = tester.getTopLeft(find.text('Song B'));
    final gesture = await dragStepped(tester,
        tester.getCenter(find.byKey(rowKey)), const Offset(-100, 0));
    await tester.pump();
    final after = tester.getTopLeft(find.text('Song B'));
    expect(after.dx, lessThan(before.dx));
    expect(player.state.queue, [_trackA, _trackB, _trackC]);
    await gesture.up();
    await tester.pump();

    // Tap the revealed Remove at the row's right edge.
    final rowRight = tester.getBottomRight(find.byKey(rowKey)).dx;
    final rowCenter = tester.getCenter(find.text('Song B'));
    await tester.tapAt(Offset(rowRight - 36, rowCenter.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Song B'), findsNothing);
    expect(player.state.queue, [_trackA, _trackC]);
    expect(find.text('Removed Song B'), findsOneWidget);

    // Undo puts it back in place.
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Song B'), findsOneWidget);
    expect(player.state.queue, [_trackA, _trackB, _trackC]);

    // Leave the player closed so the shell signal does not leak
    // into the next test.
    await tester.tap(find.byTooltip('Close player'));
    await tester.pump();
    await tester.pump();
  });

  // -- Lyrics -----------------------------------------------------------

  testWidgets('Lyrics is reachable from the context sheet',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await pumpResults(tester, player);

    await longPressRow(tester, find.text('Song A'));
    expect(find.text('Lyrics'), findsOneWidget);
    await tester.tap(find.text('Lyrics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LyricsScreen), findsOneWidget);
    // The cached miss lands on the honest empty state, never the
    // network.
    expect(find.textContaining('LRCLIB has no lyrics'), findsOneWidget);
  });

  // -- Reduced motion ---------------------------------------------------

  test('reduceMotion zeroes every token duration without changing density',
      () {
    final tokens = MusicManDesignTokens.forDesign(
      AppDesign.complex,
      isDark: false,
      reduceMotion: true,
    );
    expect(tokens.screenTransition, Duration.zero);
    expect(tokens.playerRise, Duration.zero);
    expect(tokens.tabSwitch, Duration.zero);
    expect(tokens.micro, Duration.zero);
    expect(tokens.progressTick, Duration.zero);
    // Density is untouched: the Complex elevations and radii stay.
    expect(tokens.raisedElevation, 2);
    expect(tokens.floatingElevation, 6);
    expect(tokens.cardRadius, 4);

    final theme = AppTheme.themeData(
      AppThemeName.editorial,
      AppDesign.complex,
      reduceMotion: true,
    );
    final themeTokens = theme.extension<MusicManDesignTokens>()!;
    expect(themeTokens.micro, Duration.zero);
    expect(themeTokens.tabSwitch, Duration.zero);

    // And without reduceMotion, Complex keeps its motion.
    final moving = MusicManDesignTokens.forDesign(
      AppDesign.complex,
      isDark: false,
    );
    expect(moving.micro, const Duration(milliseconds: 150));
    expect(moving.tabSwitch, const Duration(milliseconds: 220));
    expect(moving.playerRise, const Duration(milliseconds: 220));
  });

  testWidgets('MusicManApp honours MediaQuery disableAnimations',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await tester.pumpWidget(
      ProviderScope(
        overrides: appOverrides(player),
        child: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MusicManApp(),
        ),
      ),
    );
    await tester.pump();
    final theme = Theme.of(tester.element(find.byType(NavigationBar)));
    final tokens = theme.extension<MusicManDesignTokens>()!;
    expect(tokens.micro, Duration.zero);
    expect(tokens.tabSwitch, Duration.zero);
    expect(tokens.playerRise, Duration.zero);
    // Density is untouched: the Complex/Compact split still applies.
    expect(tokens.cardRadius, 4);
  });

  // -- Inline progress ----------------------------------------------------

  testWidgets(
      'Get recommendations turns into inline progress while a run is in flight',
      (tester) async {
    final player = playerFor(FakeAudioBackend());
    await seedSavedDetail(tester);
    final gen = _RunningGenerationNotifier(
      Dio(),
      historyRepo,
      favorites,
      settingsRepo,
      StateController(0),
    );
    await pumpDetail(
      tester,
      player,
      _playlistTracks(6),
      extraOverrides: [
        generationProvider.overrideWith((ref) => gen),
      ],
    );
    expect(find.text('Analyzing track 3 of 20'), findsOneWidget);
    expect(find.text('Get recommendations'), findsNothing);
  });

}

/// A generation notifier stuck mid-run, for the inline-progress
/// test. The state is set in the subclass constructor, where the
/// protected setter is reachable.
class _RunningGenerationNotifier extends GenerationNotifier {
  // ignore: use_super_parameters
  _RunningGenerationNotifier(
    Dio dio,
    HistoryRepository history,
    FavoritesRepository favorites,
    SettingsRepository? settings,
    StateController<int>? historyVersion,
  ) : super(dio, history, favorites, settings, historyVersion) {
    state = const GenerationState(
      running: true,
      progress: GenerationProgress(phase: 'scoring', done: 3, total: 20),
    );
  }
}
