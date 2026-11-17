// Phase C Group 2: full player screen + mini-player hoist. Widget
// tests for the hoisted shell (mini-player visible on a pushed route),
// the full player (queue, shuffle, repeat, scrub bubble, swipe-down
// dismiss, reorder, swipe-remove with Undo, related picks), the player
// route durations, and the live rule ("Live" only when isLive).
//
// The player runs on a fake backend and is loaded with playStream, so
// no network resolution is involved. The favorites + playlist repos
// are real, backed by Hive boxes in a temp dir.
//
// NOTE: fresh boxes per test instead of clearing shared ones (see
// mini_player_bar_test.dart), no Hive.close() in widget tearDownAll,
// and no pumpAndSettle: the "Live" indicator never settles.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/news/news_repository.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/main.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/news_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/full_player_screen.dart';
import 'package:music_man/presentation/widgets/editorial_route.dart';
import 'package:music_man/presentation/widgets/mini_player_bar.dart';

import 'fake_audio_backend.dart';

const _trackA = Track(
  artist: 'Singer A',
  title: 'Song A',
  streamUrl: 'https://example.com/a.m4a',
);
const _trackB = Track(
  artist: 'Singer B',
  title: 'Song B',
  album: 'Album B',
  streamUrl: 'https://example.com/b.m4a',
);
const _trackC = Track(
  artist: 'Singer C',
  title: 'Song C',
  streamUrl: 'https://example.com/c.m4a',
);

const _queue = [_trackA, _trackB, _trackC];

/// A news repo whose fetch returns no articles, so the shell's News
/// dot stays off without any network.
class _FakeNewsRepository extends NewsRepository {
  // ignore: use_super_parameters
  _FakeNewsRepository(Box box, Dio dio) : super(box, dio);

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
  late NewsRepository newsRepo;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_player_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    final n = boxCounter++;
    final favBox = await Hive.openBox('fav_$n');
    final plBox = await Hive.openBox('pl_$n');
    final newsBox = await Hive.openBox('news_$n');
    favorites = FavoritesRepository(favBox);
    playlists = PlaylistRepository(plBox);
    newsRepo = _FakeNewsRepository(newsBox, Dio());
  });

  AudioPlayerNotifier notifier(FakeAudioBackend backend) =>
      AudioPlayerNotifier(FallbackSources(), backend: backend);

  List<Override> playerOverrides(AudioPlayerNotifier player) => [
        audioPlayerProvider.overrideWith((ref) => player),
        favoritesRepositoryProvider.overrideWithValue(favorites),
        playlistRepositoryProvider.overrideWithValue(playlists),
      ];

  /// Loads [track] on the fake backend with a 3 minute duration, so
  /// the player shows real times and a seekable rule.
  Future<AudioPlayerNotifier> loadedPlayer({
    List<Track> queue = _queue,
    bool live = false,
    Duration? fakeDuration = const Duration(minutes: 3),
  }) async {
    final backend = FakeAudioBackend()..fakeDuration = fakeDuration;
    final player = notifier(backend);
    await player.playStream(
      queue.first,
      'https://example.com/stream.m4a',
      queue: queue,
      live: live,
    );
    return player;
  }

  Future<void> pumpPlayer(
    WidgetTester tester,
    AudioPlayerNotifier player, {
    AppDesign design = AppDesign.compact,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: playerOverrides(player),
        child: MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, design),
          home: const FullPlayerScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpBar(
    WidgetTester tester,
    AudioPlayerNotifier player,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: playerOverrides(player),
        child: MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
          home: const Scaffold(
            body: SizedBox.shrink(),
            bottomNavigationBar: MiniPlayerBar(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('hoisted mini-player', () {
    testWidgets('mini-player stays visible on a pushed route',
        (tester) async {
      final player = await loadedPlayer();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...playerOverrides(player),
            newsRepositoryProvider.overrideWithValue(newsRepo),
          ],
          child: MaterialApp(
            theme:
                AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
            navigatorKey: navigatorKey,
            builder: (context, child) =>
                AppShell(child: child ?? const SizedBox.shrink()),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const Scaffold(
                            body: Text('Pushed page'),
                          ),
                        ),
                      );
                    },
                    child: const Text('Go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Song A'), findsOneWidget);
      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Pushed page'), findsOneWidget);
      expect(find.byType(MiniPlayerBar), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);
    });

    testWidgets('tapping the mini-player strip opens the full player',
        (tester) async {
      final player = await loadedPlayer();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...playerOverrides(player),
            newsRepositoryProvider.overrideWithValue(newsRepo),
          ],
          child: MaterialApp(
            theme:
                AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
            navigatorKey: navigatorKey,
            builder: (context, child) =>
                AppShell(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: Text('Home tab')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Now playing'), findsNothing);
      await tester.tap(find.text('Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Queue'), findsOneWidget);
    });

    testWidgets('mini-player shows album or source under the artist',
        (tester) async {
      // Track B carries an album: the line below the artist shows it.
      final playerB = await loadedPlayer(queue: [_trackB]);
      await pumpBar(tester, playerB);
      expect(find.text('Singer B'), findsOneWidget);
      expect(find.text('Album B'), findsOneWidget);
    });

    testWidgets('mini-player shows the source when there is no album',
        (tester) async {
      // Track A has no album; playStream records the source label.
      final playerA = await loadedPlayer(queue: [_trackA]);
      await pumpBar(tester, playerA);
      expect(find.text('Singer A'), findsOneWidget);
      expect(find.text('audius'), findsOneWidget);
    });
  });

  group('full player', () {
    testWidgets('renders queue, shuffle, and repeat states',
        (tester) async {
      final player = await loadedPlayer();
      await pumpPlayer(tester, player);
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Song A'), findsWidgets);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
      expect(find.text('Playing'), findsOneWidget);
      expect(find.byTooltip('Shuffle off'), findsOneWidget);
      expect(find.byTooltip('Repeat off'), findsOneWidget);
      // The button rows sit below the fold in the test viewport:
      // scroll them into view before tapping.
      await tester.ensureVisible(find.byTooltip('Shuffle off'));
      await tester.pump();
      // Shuffle toggles on.
      await tester.tap(find.byTooltip('Shuffle off'));
      await tester.pump();
      expect(find.byTooltip('Shuffle on'), findsOneWidget);
      expect(player.state.shuffleEnabled, isTrue);
      // Repeat cycles off to all to one and back to off.
      await tester.tap(find.byTooltip('Repeat off'));
      await tester.pump();
      expect(find.byTooltip('Repeat all'), findsOneWidget);
      await tester.tap(find.byTooltip('Repeat all'));
      await tester.pump();
      expect(find.byTooltip('Repeat one'), findsOneWidget);
      await tester.tap(find.byTooltip('Repeat one'));
      await tester.pump();
      expect(find.byTooltip('Repeat off'), findsOneWidget);
    });

    testWidgets('scrub bubble appears while dragging, release seeks',
        (tester) async {
      final backend = FakeAudioBackend()
        ..fakeDuration = const Duration(minutes: 3);
      final player = notifier(backend);
      await player.playStream(
        _trackA,
        'https://example.com/stream.m4a',
        queue: _queue,
      );
      await pumpPlayer(tester, player);
      expect(
        find.byKey(const ValueKey('scrub-bubble')),
        findsNothing,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('scrub-area'))),
      );
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('scrub-bubble')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pump();
      expect(backend.lastSeek, isNotNull);
      expect(
        find.byKey(const ValueKey('scrub-bubble')),
        findsNothing,
      );
    });

    testWidgets('swipe-down dismiss pops the player', (tester) async {
      final player = await loadedPlayer();
      await tester.pumpWidget(
        ProviderScope(
          overrides: playerOverrides(player),
          child: MaterialApp(
            theme:
                AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        playerRoute(
                          context,
                          (_) => const FullPlayerScreen(),
                        ),
                      );
                    },
                    child: const Text('Open player'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Open player'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Queue'), findsOneWidget);
      await tester.fling(
        find.byKey(const ValueKey('player-cover')),
        const Offset(0, 400),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Queue'), findsNothing);
      expect(find.text('Open player'), findsOneWidget);
    });

    testWidgets('queue reorder via the move buttons', (tester) async {
      final player = await loadedPlayer();
      await pumpPlayer(tester, player);
      final rowA =
          find.byKey(const ValueKey('queue-row:Singer A::Song A'));
      final rowB =
          find.byKey(const ValueKey('queue-row:Singer B::Song B'));
      expect(
        tester.getTopLeft(rowA).dy,
        lessThan(tester.getTopLeft(rowB).dy),
      );
      await tester.ensureVisible(
        find.descendant(
          of: rowA,
          matching: find.byTooltip('Move down'),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: rowA,
          matching: find.byTooltip('Move down'),
        ),
      );
      await tester.pump();
      expect(player.state.queue, [_trackB, _trackA, _trackC]);
      expect(
        tester.getTopLeft(rowB).dy,
        lessThan(tester.getTopLeft(rowA).dy),
      );
    });

    testWidgets('queue swipe-remove with Undo', (tester) async {
      final player = await loadedPlayer();
      await pumpPlayer(tester, player);
      expect(find.text('Song B'), findsOneWidget);
      const rowKey = ValueKey('queue-row:Singer B::Song B');
      await tester.ensureVisible(find.byKey(rowKey));
      await tester.pump();
      // Swipe the row left to reveal Remove (a swipe alone only
      // reveals the action; it never removes by itself), then tap
      // the revealed Remove button at the row's right edge.
      await tester.drag(find.byKey(rowKey), const Offset(-100, 0));
      await tester.pump();
      expect(find.text('Song B'), findsOneWidget);
      expect(player.state.queue, [_trackA, _trackB, _trackC]);
      final rowRight = tester.getBottomRight(find.byKey(rowKey)).dx;
      final rowCenter = tester.getCenter(find.text('Song B'));
      await tester.tapAt(Offset(rowRight - 36, rowCenter.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('Song B'), findsNothing);
      expect(player.state.queue, [_trackA, _trackC]);
      expect(find.text('Removed Song B'), findsOneWidget);
      // Let the SnackBar slide in before tapping its action.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Song B'), findsOneWidget);
      expect(player.state.queue, [_trackA, _trackB, _trackC]);
    });

    testWidgets('related picks hidden when the queue is too small',
        (tester) async {
      // Complex, but a one-track queue has nothing to relate.
      final player = await loadedPlayer(queue: [_trackA]);
      await pumpPlayer(tester, player, design: AppDesign.complex);
      expect(find.text('Related picks'), findsNothing);
    });

    testWidgets('related picks hidden in Compact even with a full queue',
        (tester) async {
      // Compact never shows related picks, even with a full queue.
      final player = await loadedPlayer();
      await pumpPlayer(tester, player, design: AppDesign.compact);
      expect(find.text('Related picks'), findsNothing);
    });

    testWidgets('related picks show the other queue tracks in Complex',
        (tester) async {
      final player = await loadedPlayer();
      await pumpPlayer(tester, player, design: AppDesign.complex);
      expect(find.text('Related picks'), findsOneWidget);
      // Song B and Song C each appear twice: once in the queue, once
      // in related picks.
      expect(find.text('Song B'), findsNWidgets(2));
      expect(find.text('Song C'), findsNWidgets(2));
    });

    testWidgets('double-tap the cover likes the current song',
        (tester) async {
      final player = await loadedPlayer();
      await pumpPlayer(tester, player);
      expect(favorites.isFavorite('Singer A', 'Song A'), isFalse);
      await tester.tap(find.byKey(const ValueKey('player-cover')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('player-cover')));
      await tester.pump();
      // Let the double-tap recognizer's timer settle.
      await tester.pump(const Duration(milliseconds: 500));
      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
    });
  });

  group('player route', () {
    testWidgets('Compact player appears instantly', (tester) async {
      late final PageRoute<Object?> pushed;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  pushed = playerRoute<Object?>(
                    context,
                    (_) => const Scaffold(body: Text('Player page')),
                  ) as PageRoute<Object?>;
                  Navigator.of(context).push(pushed);
                },
                child: const Text('Go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(pushed.transitionDuration, Duration.zero);
      expect(pushed.reverseTransitionDuration, Duration.zero);
      expect(find.text('Player page'), findsOneWidget);
    });

    testWidgets('Complex player rises over 220 ms', (tester) async {
      late final PageRoute<Object?> pushed;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.complex),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  pushed = playerRoute<Object?>(
                    context,
                    (_) => const Scaffold(body: Text('Player page')),
                  ) as PageRoute<Object?>;
                  Navigator.of(context).push(pushed);
                },
                child: const Text('Go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(
        pushed.transitionDuration,
        const Duration(milliseconds: 220),
      );
      expect(
        pushed.reverseTransitionDuration,
        const Duration(milliseconds: 220),
      );
      expect(find.text('Player page'), findsOneWidget);
    });
  });

  group('live handling', () {
    testWidgets('mini-player shows Live only for a live stream',
        (tester) async {
      final live = await loadedPlayer(live: true, fakeDuration: null);
      await pumpBar(tester, live);
      expect(find.text('Live'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('mini-player never shows Live for a non-live track',
        (tester) async {
      final notLive = await loadedPlayer(live: false, fakeDuration: null);
      await pumpBar(tester, notLive);
      expect(find.text('Live'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('0:00'), findsNWidgets(2));
    });

    testWidgets('full player shows Live for a live stream',
        (tester) async {
      final live = await loadedPlayer(live: true, fakeDuration: null);
      await pumpPlayer(tester, live);
      expect(find.text('Live'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('full player never shows Live for a non-live track',
        (tester) async {
      final notLive = await loadedPlayer(live: false, fakeDuration: null);
      await pumpPlayer(tester, notLive);
      expect(find.text('Live'), findsNothing);
      expect(find.text('0:00'), findsNWidgets(2));
    });
  });
}
