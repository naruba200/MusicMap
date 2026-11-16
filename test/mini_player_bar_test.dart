// Widget tests for the global mini-player bar: shows/hides with the
// shared player, next/previous/play/stop drive the player, the
// progress slider seeks, and add-to-playlist appends to a saved
// playlist (never twice). The player runs on a fake backend; the
// favorites + playlist repos are real, backed by Hive boxes in a
// temp dir.
//
// NOTE: these tests never use pumpAndSettle — the bar shows an
// indeterminate "Live" progress indicator while a stream reports no
// duration, and that animation never settles. Pump past the bottom
// sheet's animation with an explicit duration instead.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
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
  streamUrl: 'https://example.com/b.m4a',
);

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_bar_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    // NOTE: Hive.close() hangs in widget tests once a box has been
    // written to (its close awaits a flush that never fires under the
    // test binding) — the same close works fine in the plain-Dart
    // repositories_test. Skip it here: the temp dir is deleted below
    // and the test process exits right after, closing the handles.
    await dir.delete(recursive: true);
  });

  setUp(() async {
    // Fresh boxes per test instead of clearing shared ones: clearing
    // a box that holds entries hangs inside the widget test's fake
    // async (the clear never completes), even under runAsync. Each
    // test therefore gets its own boxes, seeded with one playlist.
    final n = boxCounter++;
    final favBox = await Hive.openBox('fav_$n');
    final plBox = await Hive.openBox('pl_$n');
    favorites = FavoritesRepository(favBox);
    playlists = PlaylistRepository(plBox);
    await playlists.save(SavedPlaylist(
      info: const PlaylistInfo(
          platformId: 'deezer', id: 'pl1', name: 'My Mix'),
      tracks: const [],
      settings: const DiscoverySettings(songCount: 30, albumCount: 10),
      importedAt: DateTime.utc(2026, 11, 1),
      lastScannedAt: DateTime.utc(2026, 11, 1),
    ));
  });

  AudioPlayerNotifier notifier(FakeAudioBackend backend) =>
      AudioPlayerNotifier(FallbackSources(), backend: backend);

  Future<void> pumpBar(
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
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox.shrink(),
            bottomNavigationBar: MiniPlayerBar(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Taps the playlist in the sheet, lets the real Hive write finish
  // (runAsync: the widget test's fake clock does not advance real
  // I/O), then pumps the sheet's pop animation and the SnackBar.
  Future<void> tapPlaylist(WidgetTester tester) async {
    await tester.tap(find.text('My Mix'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  group('MiniPlayerBar', () {
    testWidgets('hidden when nothing is loaded', (tester) async {
      final backend = FakeAudioBackend();
      await pumpBar(tester, notifier(backend));
      expect(find.text('Song A'), findsNothing);
      expect(find.byTooltip('Next'), findsNothing);
    });

    testWidgets('shows the playing track with working controls',
        (tester) async {
      final backend = FakeAudioBackend();
      final player = notifier(backend);
      await player.play(_trackA, queue: [_trackA, _trackB]);
      await pumpBar(tester, player);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Singer A'), findsOneWidget);
      // First track: previous disabled, next enabled. (byTooltip
      // finds the Tooltip, not the button — match the button by icon.)
      expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(
                  IconButton, Icons.skip_previous))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.skip_next))
              .onPressed,
          isNotNull);
      // Next walks the queue.
      await tester.tap(find.byTooltip('Next'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song A'), findsNothing);
    });

    testWidgets('pause toggles and stop hides the bar', (tester) async {
      final backend = FakeAudioBackend();
      final player = notifier(backend);
      await player.play(_trackA, queue: [_trackA, _trackB]);
      await pumpBar(tester, player);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(backend.pauseCalls, 1);
      expect(find.byTooltip('Play'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop'));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
    });

    testWidgets('slider appears with a duration and seeks on drag',
        (tester) async {
      final backend = FakeAudioBackend();
      final player = notifier(backend);
      await player.play(_trackA, queue: [_trackA]);
      await pumpBar(tester, player);
      // A stream with no duration reports "Live", not a slider.
      expect(find.text('Live'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      backend.durationController.add(const Duration(seconds: 30));
      backend.positionController.add(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Live'), findsNothing);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('0:05'), findsOneWidget);
      expect(find.text('0:30'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(100, 0));
      await tester.pump();
      expect(backend.lastSeek, isNotNull);
    });

    testWidgets('like button favorites the playing track',
        (tester) async {
      final backend = FakeAudioBackend();
      final player = notifier(backend);
      await player.play(_trackA, queue: [_trackA]);
      await pumpBar(tester, player);
      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pump();
      expect(favorites.isFavorite('Singer A', 'Song A'), isTrue);
    });

    testWidgets('add-to-playlist appends once, then reports a duplicate',
        (tester) async {
      final backend = FakeAudioBackend();
      final player = notifier(backend);
      await player.play(_trackA, queue: [_trackA]);
      await pumpBar(tester, player);
      await tester.tap(find.byTooltip('Add to playlist'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('My Mix'), findsOneWidget);
      await tapPlaylist(tester);
      expect(find.text('Added to My Mix'), findsOneWidget);
      expect(playlists.get('deezer', 'pl1')!.tracks, hasLength(1));
      // Dismiss the first SnackBar now: ScaffoldMessenger queues the
      // next one behind it, so the duplicate message would otherwise
      // never become visible during this test.
      ScaffoldMessenger.of(tester.element(find.byType(MiniPlayerBar)))
          .hideCurrentSnackBar();
      await tester.pump();
      // Second time the same track is refused, not duplicated.
      await tester.tap(find.byTooltip('Add to playlist'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tapPlaylist(tester);
      expect(find.text('Already in My Mix'), findsOneWidget);
      expect(playlists.get('deezer', 'pl1')!.tracks, hasLength(1));
    });
  });
}
