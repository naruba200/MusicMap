// Phase C Group 3 widget tests: row gestures.
//
// - Swipe quick actions (Results + Playlist detail): reveal, Like,
//   Add to playlist, Remove, and the row winning the gesture arena
//   over an ancestor horizontal drag (the tab swipe).
// - Long-press context sheet: entries present, each action works,
//   overflow opens the same sheet, Why hidden without a reason.
// - Drag to playlist: drop adds the track, Undo removes it.
// - Cover double-tap to like (Results album cards, Album detail
//   art header) vs single tap to expand.
//
// The player runs on a fake backend; the favorites + playlist
// repos are real, backed by fresh Hive boxes per test (never
// clear() shared boxes, no Hive.close() in widget tearDownAll,
// no pumpAndSettle: the loading states carry indeterminate
// indicators that never settle).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/enrichment/enrichment_models.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/lastfm/album_tracklist_service.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/history_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/data/repositories/settings_repository.dart';
import 'package:music_man/presentation/providers/daily_picks_provider.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/album_detail_screen.dart';
import 'package:music_man/presentation/screens/favorites_screen.dart';
import 'package:music_man/presentation/screens/playlist_detail_screen.dart';
import 'package:music_man/presentation/screens/results_screen.dart';
import 'package:music_man/presentation/widgets/album_art.dart';
import 'package:music_man/presentation/widgets/song_actions_sheet.dart';
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

/// The same album as in [_result], but with no art URL, so the
/// album detail header renders its placeholder icon immediately
/// (no network art fetch to wait for in tests).
const _albumNoArt = AlbumRec(
  name: 'Album A',
  artist: 'Singer A',
  songCount: 1,
  bestScore: 2.0,
  songs: [
    ScoredTrack(
      track: _trackA,
      score: 2.0,
      reasons: ['Seed Song One'],
    ),
  ],
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

MaterialApp _themedApp(Widget home, {AppDesign design = AppDesign.compact}) =>
    MaterialApp(
      theme: AppTheme.themeData(AppThemeName.editorial, design),
      home: home,
    );

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  late SettingsRepository settingsRepo;
  late HistoryRepository historyRepo;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_gestures_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    final n = boxCounter++;
    final favBox = await Hive.openBox('gest_fav_$n');
    final plBox = await Hive.openBox('gest_pl_$n');
    favorites = FavoritesRepository(favBox);
    playlists = PlaylistRepository(plBox);
    // Settings + history boxes too: opening a Hive box inside the
    // test body hangs under the fake clock, so every box opens here
    // in setUp (which runs outside the fake clock).
    settingsRepo = SettingsRepository(await Hive.openBox('gest_set_$n'));
    historyRepo = HistoryRepository(await Hive.openBox('gest_hist_$n'));
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
    // phase_b_playlist_test.dart). setUp runs outside the widget
    // test's fake clock, so opening the box here works.
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

  AudioPlayerNotifier playerFor(FakeAudioBackend backend) =>
      AudioPlayerNotifier(FallbackSources(), backend: backend);

  /// Lets a real Hive write finish after a tap (runAsync: the widget
  /// test's fake clock does not advance real I/O), then pumps.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

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
        child: _themedApp(const ResultsScreen(result: _result),
            design: design),
      ),
    );
    await tester.pump();
  }

  /// Seeds the saved copy of pl1 with the same tracks the detail
  /// view shows: the real imported state. The detail screen's
  /// auto-save re-saves an existing playlist as-is, so without this
  /// the saved copy would stay the empty one setUp created and
  /// Remove would have nothing to take out of it. Runs under
  /// runAsync so the Hive write uses real I/O, not the fake clock.
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
    List<Track> tracks,
  ) async {
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
        ],
        child: _themedApp(
          const PlaylistDetailScreen(platformId: 'deezer', playlistId: 'pl1'),
        ),
      ),
    );
    await tester.pump();
    // Lets the auto-save of the import land.
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

  /// Press and hold a row, then drag it onto a playlist in the drop
  /// bar and release.
  Future<void> dragRowToPlaylist(
    WidgetTester tester,
    Finder finder,
    String playlistName,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('Drop on a playlist'), findsOneWidget);
    // The drop bar labels a playlist "Name (N)"; the toast says
    // "Added to Name", so match the " (" to hit only the bar.
    await gesture.moveTo(
        tester.getCenter(find.textContaining('$playlistName (')));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// A swipe action label inside one Results row, scoped to that
  /// row: every row carries the same actions in its tree, so a
  /// bare find.text would match all of them.
  Finder resultRowAction(String artist, String title, String label) =>
      find.descendant(
        of: find.byKey(ValueKey(
            'result-track-${RecommendationEngine.normalizeKey(artist, title)}')),
        matching: find.text(label),
      );

  /// A swipe action label inside playlist row 0, scoped the same way.
  Finder playlistRowAction(String label) => find.descendant(
        of: find.byKey(const ValueKey('playlist-track-0')),
        matching: find.text(label),
      );

  group('Swipe quick actions (Results)', () {
    testWidgets('swipe left reveals Like, Add, Remove', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();

      expect(resultRowAction('Singer A', 'Song A', 'Like'), findsOneWidget);
      expect(resultRowAction('Singer A', 'Song A', 'Add'), findsOneWidget);
      expect(
          resultRowAction('Singer A', 'Song A', 'Remove'), findsOneWidget);
    });

    testWidgets('Compact reveal snaps open instantly', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      final before = tester.getTopLeft(find.text('Song A')).dx;
      await tester.drag(find.text('Song A'), const Offset(-150, 0));
      await tester.pump();

      // Compact micro is zero: the partial drag snaps fully open
      // with no animation, three actions at 72 each.
      final after = tester.getTopLeft(find.text('Song A')).dx;
      expect(after - before, closeTo(-216, 1));
    });

    testWidgets('Complex reveal slides over tokens.micro',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend),
          design: AppDesign.complex);

      final before = tester.getTopLeft(find.text('Song A')).dx;
      // tester.drag sends every move without a frame in between,
      // so the row cannot follow the finger mid-drag; drive the
      // drag by hand with a pump per step instead.
      final start = tester.getCenter(find.text('Song A'));
      final gesture = await tester.startGesture(start);
      for (var i = 1; i <= 6; i++) {
        await gesture.moveTo(start + Offset(-25.0 * i, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      final atRelease = tester.getTopLeft(find.text('Song A')).dx;
      // The row follows the finger while dragging, so it is
      // part-way open at release and still short of the full 216
      // snap: the snap is an animation, not instant.
      expect(atRelease - before, lessThan(-50));
      expect(atRelease - before, greaterThan(-216));

      await tester.pump(const Duration(milliseconds: 75));
      final mid = tester.getTopLeft(find.text('Song A')).dx;
      expect(mid - before, lessThan(atRelease - before));
      expect(mid - before, greaterThan(-216));

      await tester.pump(const Duration(milliseconds: 150));
      final done = tester.getTopLeft(find.text('Song A')).dx;
      expect(done - before, closeTo(-216, 1));
    });

    testWidgets('swipe Like likes with an Undo toast', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();
      await tester.tap(resultRowAction('Singer A', 'Song A', 'Like'));
      await settle(tester);

      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
      expect(find.text('Added to favorites'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(favorites.isFavorite('Singer A', 'Song A'), isFalse);
    });

    testWidgets('swipe Add opens the sheet and adds the track',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();
      await tester.tap(resultRowAction('Singer A', 'Song A', 'Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Add to playlist'), findsOneWidget);
      await tester.tap(find.text('Chill Mix'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        playlists
            .get('deezer', 'pl1')!
            .tracks
            .any((t) => t.title == 'Song A'),
        isTrue,
      );
      expect(find.text('Added to Chill Mix'), findsOneWidget);
    });

    testWidgets('swipe Remove hides the row; Undo restores it',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();
      await tester.tap(resultRowAction('Singer A', 'Song A', 'Remove'));
      await tester.pump();

      expect(find.text('Song A'), findsNothing);
      expect(find.text('Removed Song A from results'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Song A'), findsOneWidget);
    });

    testWidgets('a swipe starting on a row does not move the tab',
        (tester) async {
      var parentDrags = 0;
      var actionRan = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: _themedApp(
            Scaffold(
              body: GestureDetector(
                // The tab swipe, simulated: a horizontal drag on the
                // content area that is not a row.
                onHorizontalDragUpdate: (_) => parentDrags++,
                child: SwipeActionRow(
                  actions: [
                    SwipeAction(
                      label: 'Like',
                      icon: Icons.favorite_outline,
                      onTap: () => actionRan = true,
                    ),
                  ],
                  child: const SizedBox(
                    height: 64,
                    child: Center(child: Text('Row item')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.drag(find.text('Row item'), const Offset(-200, 0));
      await tester.pump();

      expect(parentDrags, 0);
      await tester.tap(find.text('Like'));
      expect(actionRan, isTrue);
    });
  });

  group('Swipe quick actions (Playlist detail)', () {
    testWidgets('swipe Remove takes the track out of the saved playlist',
        (tester) async {
      final backend = FakeAudioBackend();
      await seedSavedDetail(tester);
      await pumpDetail(tester, playerFor(backend), _playlistTracks(6));
      expect(
          playlists.get('deezer', 'pl1')!.tracks.length, 6);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('playlist-track-0')), 200);
      await tester.pump();
      await tester.drag(
          find.byKey(const ValueKey('playlist-track-0')),
          const Offset(-300, 0));
      await tester.pump();
      await tester.tap(playlistRowAction('Remove'));
      await settle(tester);

      expect(find.text('Song 1'), findsNothing);
      expect(
        playlists
            .get('deezer', 'pl1')!
            .tracks
            .any((t) => t.title == 'Song 1'),
        isFalse,
      );
      expect(find.text('Removed Song 1 from My Mix'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(
        playlists
            .get('deezer', 'pl1')!
            .tracks
            .any((t) => t.title == 'Song 1'),
        isTrue,
      );
      await tester.scrollUntilVisible(find.text('Song 1'), 200);
      expect(find.text('Song 1'), findsOneWidget);
    });

    testWidgets('swipe Like and Add work on playlist rows',
        (tester) async {
      final backend = FakeAudioBackend();
      await seedSavedDetail(tester);
      await pumpDetail(tester, playerFor(backend), _playlistTracks(6));

      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('playlist-track-0')), 200);
      await tester.pump();
      await tester.drag(
          find.byKey(const ValueKey('playlist-track-0')),
          const Offset(-300, 0));
      await tester.pump();
      await tester.tap(playlistRowAction('Like'));
      await settle(tester);
      expect(favorites.isFavorite('Singer 1', 'Song 1'), isTrue);

      await tester.drag(
          find.byKey(const ValueKey('playlist-track-0')),
          const Offset(-300, 0));
      await tester.pump();
      await tester.tap(playlistRowAction('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Late Night'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        playlists
            .get('deezer', 'pl2')!
            .tracks
            .any((t) => t.title == 'Song 1'),
        isTrue,
      );
      expect(find.text('Added to Late Night'), findsOneWidget);
    });
  });

  group('Favorites keeps its own swipe', () {
    testWidgets('swiping a favorite row reveals no quick actions',
        (tester) async {
      final backend = FakeAudioBackend();
      final player = playerFor(backend);
      favorites.toggle(_trackA);

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
      await settle(tester);

      expect(find.text('Song A'), findsOneWidget);
      await tester.drag(find.text('Song A'), const Offset(-300, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Like'), findsNothing);
      expect(find.text('Add'), findsNothing);
      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
    });
  });

  group('Long-press context sheet', () {
    testWidgets('long-press opens the sheet and does not play',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await longPressRow(tester, find.text('Song A'));

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Why this song'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(backend.playedUrls, isEmpty);
    });

    testWidgets('overflow opens the same sheet', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Why this song'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('Play next inserts after the current track',
        (tester) async {
      final backend = FakeAudioBackend();
      final player = playerFor(backend);
      await player.playStream(
        _trackA,
        'https://example.com/stream.m4a',
        queue: [_trackA, _trackC],
      );
      await pumpResults(tester, player);

      await longPressRow(tester, find.text('Song B'));
      await tester.tap(find.text('Play next'));
      await tester.pump();

      final queue = player.state.queue;
      expect([for (final t in queue) t.title],
          ['Song A', 'Song B', 'Song C']);
      expect(find.text('Will play next'), findsOneWidget);
    });

    testWidgets('Add to queue appends to the end', (tester) async {
      final backend = FakeAudioBackend();
      final player = playerFor(backend);
      await player.playStream(
        _trackA,
        'https://example.com/stream.m4a',
        queue: [_trackA, _trackC],
      );
      await pumpResults(tester, player);

      await longPressRow(tester, find.text('Song B'));
      await tester.tap(find.text('Add to queue'));
      await tester.pump();

      final queue = player.state.queue;
      expect([for (final t in queue) t.title],
          ['Song A', 'Song C', 'Song B']);
      expect(find.text('Added to queue'), findsOneWidget);
    });

    testWidgets('Add to playlist adds the track', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await longPressRow(tester, find.text('Song B'));
      await tester.tap(find.text('Add to playlist'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Late Night'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        playlists
            .get('deezer', 'pl2')!
            .tracks
            .any((t) => t.title == 'Song B'),
        isTrue,
      );
      expect(find.text('Added to Late Night'), findsOneWidget);
    });

    testWidgets('Why this song opens the reason view', (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await longPressRow(tester, find.text('Song A'));
      await tester.tap(find.text('Why this song'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Why this song'), findsOneWidget);
      expect(find.text('Because you liked Seed Song One and Seed Song Two'),
          findsOneWidget);
    });

    testWidgets('Share sends "artist - title" via share_plus',
        (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async {
          calls.add(call);
          return 'dev.fluttercommunity.plus/share/dismissed';
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/share'),
          null,
        );
      });

      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await longPressRow(tester, find.text('Song A'));
      // The Lyrics entry makes the sheet taller than the modal's
      // 9/16-height cap on the 600 px test viewport, so Share sits
      // below the fold; the sheet scrolls by design, so bring it
      // into view before tapping.
      await tester.ensureVisible(find.text('Share'));
      await tester.tap(find.text('Share'));
      await settle(tester);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'share');
      expect((calls.single.arguments as Map)['text'], 'Singer A - Song A');
    });

    testWidgets('Why is hidden when the track has no reason view',
        (tester) async {
      final backend = FakeAudioBackend();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => playerFor(backend)),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: _themedApp(
            const Scaffold(
              body: SongActionsSheet(track: _trackB),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Why this song'), findsNothing);
    });

    testWidgets('Why shows when a reason view is given', (tester) async {
      final backend = FakeAudioBackend();
      var whyTapped = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => playerFor(backend)),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
          ],
          child: _themedApp(
            Scaffold(
              body: SongActionsSheet(
                track: _trackA,
                reason: 'Because you liked Seed Song One',
                onShowWhy: () => whyTapped = true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Why this song'), findsOneWidget);
      // Tapping Why pops the sheet (here the home route), so only
      // assert the callback ran.
      await tester.tap(find.text('Why this song'));
      expect(whyTapped, isTrue);
    });
  });

  group('Drag a song onto a playlist', () {
    testWidgets('dropping on a playlist adds the track; Undo removes it',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await dragRowToPlaylist(tester, find.text('Song A'), 'Chill Mix');
      // The toast is shown after the async save lands; poll until
      // it appears instead of trusting one settle.
      for (var i = 0; i < 20; i++) {
        if (find.text('Added to Chill Mix').evaluate().isNotEmpty) break;
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 100));
        });
        await tester.pump();
      }

      expect(
        playlists
            .get('deezer', 'pl1')!
            .tracks
            .any((t) => t.title == 'Song A'),
        isTrue,
      );
      expect(find.text('Added to Chill Mix'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(
        playlists
            .get('deezer', 'pl1')!
            .tracks
            .any((t) => t.title == 'Song A'),
        isFalse,
      );
    });

    testWidgets('dropping the same track twice adds it once',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await dragRowToPlaylist(tester, find.text('Song A'), 'Chill Mix');
      await settle(tester);
      await dragRowToPlaylist(tester, find.text('Song A'), 'Chill Mix');
      await settle(tester);

      final tracks =
          playlists.get('deezer', 'pl1')!.tracks;
      expect(tracks.where((t) => t.title == 'Song A').length, 1);
      expect(find.text('Already in Chill Mix'), findsOneWidget);
    });
  });

  group('Cover double-tap to like', () {
    testWidgets('single tap on a Results album card expands the tracklist',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.text('Albums'));
      // The phase_b tab-switch pattern: one pump to start the
      // scroll and build the page, then 500 ms to finish it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('View album'), findsNothing);

      await tester.tap(find.text('Album A'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('View album'), findsOneWidget);
      expect(favorites.isAlbumFavorite('Singer A', 'Album A'), isFalse);
    });

    testWidgets('double-tap on a Results album card likes without expanding',
        (tester) async {
      final backend = FakeAudioBackend();
      await pumpResults(tester, playerFor(backend));

      await tester.tap(find.text('Albums'));
      // The phase_b tab-switch pattern: one pump to start the
      // scroll and build the page, then 500 ms to finish it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Album A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Album A'));
      await tester.pump();
      await settle(tester);

      expect(favorites.isAlbumFavorite('Singer A', 'Album A'), isTrue);
      expect(find.text('View album'), findsNothing);
      expect(find.text('Added to favorites'), findsOneWidget);
    });

    testWidgets('album detail art single tap collapses the tracklist',
        (tester) async {
      final backend = FakeAudioBackend();
      const album = _albumNoArt;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => playerFor(backend)),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
            // No network in this test: an empty tracklist and a
            // cached "no art" lookup for the header cover.
            albumTracklistServiceProvider.overrideWithValue(
              AlbumTracklistService(
                fetch: (_, __) async => const AlbumInfo(tracks: []),
              ),
            ),
            albumArtCacheProvider.overrideWith(
                (ref) => {'singer a|album a': null}),
          ],
          child: _themedApp(const AlbumDetailScreen(album: album)),
        ),
      );
      await tester.pump();

      expect(find.text('Song A'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.album_outlined));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Song A'), findsNothing);
      expect(find.text('Show tracks (1)'), findsOneWidget);

      await tester.tap(find.text('Show tracks (1)'));
      await tester.pump();
      expect(find.text('Song A'), findsOneWidget);
    });

    testWidgets('album detail art double-tap likes without collapsing',
        (tester) async {
      final backend = FakeAudioBackend();
      const album = _albumNoArt;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerProvider.overrideWith((ref) => playerFor(backend)),
            favoritesRepositoryProvider.overrideWithValue(favorites),
            playlistRepositoryProvider.overrideWithValue(playlists),
            // No network in this test: an empty tracklist and a
            // cached "no art" lookup for the header cover.
            albumTracklistServiceProvider.overrideWithValue(
              AlbumTracklistService(
                fetch: (_, __) async => const AlbumInfo(tracks: []),
              ),
            ),
            albumArtCacheProvider.overrideWith(
                (ref) => {'singer a|album a': null}),
          ],
          child: _themedApp(const AlbumDetailScreen(album: album)),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.album_outlined));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.album_outlined));
      await tester.pump();
      await settle(tester);

      expect(favorites.isAlbumFavorite('Singer A', 'Album A'), isTrue);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Added to favorites'), findsOneWidget);
    });
  });



}
