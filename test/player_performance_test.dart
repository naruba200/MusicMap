// Group 1 (Performance): the position throttle, the .select split,
// and the sliver queue.
//
// The stutter came from unthrottled playback-position ticks: every
// audioplayers event rebuilt the whole PlaybackState, and every
// widget watching the player (every song row on every kept-alive
// tab) rebuilt with it. These tests pin the fix: position state
// moves at most 4 times a second on a 250 ms grid, a .select on an
// untouched field never fires on a tick, and the full-player queue
// is a sliver list instead of a shrink-wrapped list inside a scroll
// view.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/full_player_screen.dart';

import 'fake_audio_backend.dart';

const _trackA = Track(
  artist: 'Singer A',
  title: 'Song A',
  streamUrl: 'https://example.com/a.m4a',
);
const _trackB = Track(
  artist: 'Singer B',
  title: 'Song B',
  streamUrl: 'https://example.com/b.m4a',
);
const _trackC = Track(
  artist: 'Singer C',
  title: 'Song C',
  streamUrl: 'https://example.com/c.m4a',
);

const _queue = [_trackA, _trackB, _trackC];

AudioPlayerNotifier _notifier(FakeAudioBackend backend) =>
    AudioPlayerNotifier(FallbackSources(), backend: backend);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpTimes(int n) async {
  for (var i = 0; i < n; i++) {
    await _pump();
  }
}

void main() {
  group('position throttle', () {
    test('position events are rounded to the 250 ms grid and deduped',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      addTearDown(() async {
        await backend.dispose();
        notifier.dispose();
      });
      await notifier.play(_trackA);

      // Nine backend ticks, 100 ms apart on and off the grid.
      final observed = <Duration>[];
      // StateNotifier.addListener fires once immediately with the
      // current state; skip that call so only real updates count.
      var skippedFirst = false;
      notifier.addListener((state) {
        if (!skippedFirst) {
          skippedFirst = true;
          return;
        }
        observed.add(state.position);
      });
      for (final ms in [100, 200, 240, 300, 490, 500, 510, 750, 1000]) {
        backend.positionController.add(Duration(milliseconds: ms));
      }
      await _pumpTimes(3);

      // Rounded to the nearest 250 ms step, identical values dropped:
      // 100 rounds to 0 (no move), 200/240/300 all land on 250,
      // 490/500/510 all land on 500. Four state updates for nine
      // ticks, about 4 per second, not one per event.
      expect(observed, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 750),
        const Duration(milliseconds: 1000),
      ]);
      expect(notifier.state.position,
          const Duration(milliseconds: 1000));
    });

    test('ticks inside one grid step do not notify at all', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      addTearDown(() async {
        await backend.dispose();
        notifier.dispose();
      });
      await notifier.play(_trackA);

      var notifications = 0;
      // StateNotifier.addListener fires once immediately with the
      // current state; skip that call so only real updates count.
      var skippedFirst = false;
      notifier.addListener((_) {
        if (!skippedFirst) {
          skippedFirst = true;
          return;
        }
        notifications++;
      });
      for (final ms in [100, 110, 120, 124]) {
        backend.positionController.add(Duration(milliseconds: ms));
      }
      await _pumpTimes(3);

      // Every value rounds to 0, the position already in state.
      expect(notifications, 0);
      expect(notifier.state.position, Duration.zero);
    });

    test('a seek is rounded by the next backend tick, never more',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      addTearDown(() async {
        await backend.dispose();
        notifier.dispose();
      });
      await notifier.play(_trackA);
      await notifier.seek(const Duration(milliseconds: 12345));
      expect(backend.lastSeek, const Duration(milliseconds: 12345));
      await _pumpTimes(3);
      // The seek lands exactly: the echoed tick is rounded first,
      // then the seek's own state assignment runs after it, so the
      // exact value wins until the next real tick.
      expect(notifier.state.position,
          const Duration(milliseconds: 12345));
      // The next real tick rounds again: 12.1 s lands on 12.0 s.
      backend.positionController.add(const Duration(milliseconds: 12100));
      await _pumpTimes(3);
      expect(notifier.state.position,
          const Duration(milliseconds: 12000));
    });
  });

  group('select split', () {
    test('a select on an untouched field never fires on a tick',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);

      final container = ProviderContainer(
        overrides: [audioPlayerProvider.overrideWith((ref) => notifier)],
      );
      // The container owns the overridden notifier and disposes it;
      // only the backend needs its own teardown.
      addTearDown(() async => backend.dispose());
      addTearDown(container.dispose);

      var currentKeyFires = 0;
      container.listen(
        audioPlayerProvider.select((s) => s.currentKey),
        (_, __) => currentKeyFires++,
      );
      var isPlayingFires = 0;
      container.listen(
        audioPlayerProvider.select((s) => s.isPlaying),
        (_, __) => isPlayingFires++,
      );
      final positionValues = <Duration>[];
      container.listen(
        audioPlayerProvider.select((s) => s.position),
        (_, next) => positionValues.add(next),
      );

      for (final ms in [100, 200, 240, 300, 490, 500, 510, 750, 1000]) {
        backend.positionController.add(Duration(milliseconds: ms));
      }
      await _pumpTimes(3);

      // The row fields never moved, so their selects never fired,
      // while the position select fired once per grid step.
      expect(currentKeyFires, 0);
      expect(isPlayingFires, 0);
      expect(positionValues, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 750),
        const Duration(milliseconds: 1000),
      ]);
    });
  });

  group('theme cache', () {
    test('themeData reuses one TextTheme per named theme', () {
      // ThemeData merges the passed theme into its default, so the
      // built theme is a new object per call; the cache is observed
      // through its size instead. Other tests in this process may
      // have cached themes already, so assert growth, not totals.
      final before = AppTheme.textThemeCacheSize;
      final first =
          AppTheme.themeData(AppThemeName.editorial, AppDesign.compact);
      final second =
          AppTheme.themeData(AppThemeName.editorial, AppDesign.compact);
      expect(AppTheme.textThemeCacheSize, lessThanOrEqualTo(before + 1));
      // Same values either way: the cached theme is the one rendered.
      expect(first.textTheme.displayLarge?.fontFamily,
          second.textTheme.displayLarge?.fontFamily);
      expect(first.textTheme.displayLarge?.fontFamily, 'Archivo_800');
    });
  });

  group('sliver queue', () {
    late Directory dir;
    late FavoritesRepository favorites;
    late PlaylistRepository playlists;
    int boxCounter = 0;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_perf_test');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    setUp(() async {
      final n = boxCounter++;
      favorites = FavoritesRepository(await Hive.openBox('fav_$n'));
      playlists = PlaylistRepository(await Hive.openBox('pl_$n'));
    });

    Future<AudioPlayerNotifier> loadedPlayer() async {
      final backend = FakeAudioBackend()
        ..fakeDuration = const Duration(minutes: 3);
      final player = _notifier(backend);
      await player.playStream(
        _trackA,
        'https://example.com/stream.m4a',
        queue: _queue,
      );
      return player;
    }

    testWidgets('queue is a sliver list, not a shrink-wrapped list',
        (tester) async {
      final player = await loadedPlayer();
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
            home: const FullPlayerScreen(),
          ),
        ),
      );
      await tester.pump();

      // The queue rows sit below the fold in the test viewport and
      // a sliver builds lazily, so scroll the last row into view
      // before asserting the structure and the rows.
      await tester.scrollUntilVisible(find.text('Song C'), 300);
      await tester.pump();
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byType(SliverReorderableList), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(find.text('Queue'), findsOneWidget);
      expect(find.text('Song A'), findsWidgets);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
    });

    testWidgets('queue reorder via the move buttons still works',
        (tester) async {
      final player = await loadedPlayer();
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
            home: const FullPlayerScreen(),
          ),
        ),
      );
      await tester.pump();

      // The queue rows sit below the fold in the test viewport and
      // a sliver builds them lazily, so scroll the first row's
      // Move down button into view before tapping it. The finder
      // must match one button only: scrollUntilVisible throws on
      // several matches, so scope it to the first row.
      final firstRowMoveDown = find.descendant(
        of: find.byKey(const ValueKey('queue-row:Singer A::Song A')),
        matching: find.byTooltip('Move down'),
      );
      await tester.scrollUntilVisible(firstRowMoveDown, 300);
      await tester.pump();
      await tester.tap(firstRowMoveDown);
      await tester.pump();
      expect(player.state.queue, [_trackB, _trackA, _trackC]);
    });
  });
}
