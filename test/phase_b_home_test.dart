// Phase B group 1 widget tests: redesigned Home (S-02) and
// Generating (S-04) screens.
//
// Hive lesson (see test/appearance_test.dart): fresh boxes per test
// opened in setUp (real async), never clear() shared boxes, no
// Hive.close() in widget tearDownAll. The generation provider is
// overridden with a no-op fake so no test ever hits Last.fm.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/platforms/music_platform.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/history_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/data/repositories/settings_repository.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/generating_screen.dart';
import 'package:music_man/presentation/screens/home_screen.dart';

/// GenerationNotifier that never touches the network: the real
/// surprise/generate calls are replaced with call counters, and the
/// test drives the state directly.
class _FakeGenerationNotifier extends GenerationNotifier {
  int surpriseCalls = 0;
  int generateCalls = 0;
  int cancelCalls = 0;

  _FakeGenerationNotifier(
    super.dio,
    super.history,
    super.favorites, [
    super.settings,
  ]);

  @override
  Future<void> surprise({required DiscoverySettings settings}) async {
    surpriseCalls++;
  }

  @override
  Future<void> generateFromPlaylist({
    required String seedName,
    required List<Track> tracks,
    required DiscoverySettings settings,
    String? seedPlaylistId,
    String? seedPlatformId,
  }) async {
    generateCalls++;
  }

  @override
  void cancel() {
    cancelCalls++;
  }

  void showProgress(String phase, int done, int total) {
    state = GenerationState(
      running: true,
      progress: GenerationProgress(phase: phase, done: done, total: total),
    );
  }

  void showError(String message, {bool canRetry = true}) {
    state = GenerationState(error: message, canRetry: canRetry);
  }
}

/// SavedPlaylistsNotifier pre-seeded with a fixed list, so the
/// imported-playlists contents list can be tested without Hive writes
/// inside the widget test body.
class _SeededSavedPlaylistsNotifier extends SavedPlaylistsNotifier {
  _SeededSavedPlaylistsNotifier(super.repo, List<SavedPlaylist> initial) {
    state = initial;
  }
}

/// AuthNotifier with Spotify signed in, so the playlist picker takes
/// the signed-in path (used for the picker error state).
class _SignedInAuth extends AuthNotifier {
  _SignedInAuth(super.registry) {
    state = {'spotify': true};
  }

  @override
  Future<void> refresh() async {}
}

void main() {
  late Directory dir;
  late SettingsRepository settingsRepo;
  late PlaylistRepository playlistRepo;
  late FavoritesRepository favoritesRepo;
  late HistoryRepository historyRepo;
  late _FakeGenerationNotifier fakeGeneration;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_phase_b_home');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    final n = boxCounter++;
    settingsRepo =
        SettingsRepository(await Hive.openBox('phase_b_settings_$n'));
    playlistRepo =
        PlaylistRepository(await Hive.openBox('phase_b_playlists_$n'));
    favoritesRepo =
        FavoritesRepository(await Hive.openBox('phase_b_favorites_$n'));
    historyRepo =
        HistoryRepository(await Hive.openBox('phase_b_history_$n'));
    fakeGeneration = _FakeGenerationNotifier(
      Dio(),
      historyRepo,
      favoritesRepo,
      settingsRepo,
    );
  });

  ProviderContainer makeContainer({
    List<SavedPlaylist>? saved,
    bool spotifySignedIn = false,
    Future<List<PlaylistInfo>> Function()? userPlaylists,
    String? platformId,
  }) {
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        playlistRepositoryProvider.overrideWithValue(playlistRepo),
        favoritesRepositoryProvider.overrideWithValue(favoritesRepo),
        historyRepositoryProvider.overrideWithValue(historyRepo),
        generationProvider.overrideWith((ref) => fakeGeneration),
        if (saved != null)
          savedPlaylistsProvider.overrideWith(
            (ref) => _SeededSavedPlaylistsNotifier(playlistRepo, saved),
          ),
        if (spotifySignedIn)
          authStateProvider.overrideWith(
            (ref) => _SignedInAuth(ref.watch(platformRegistryProvider)),
          ),
        if (userPlaylists != null)
          userPlaylistsProvider.overrideWith((ref) => userPlaylists()),
        if (platformId != null)
          selectedPlatformIdProvider.overrideWith((ref) => platformId),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpHome(
    WidgetTester tester,
    ProviderContainer container, {
    AppDesign design = AppDesign.compact,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _HomeHarness(design: design),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Home is a tall ListView: sections below the fold are not built
  // until scrolled into view, so tests scroll to what they assert on.
  // The scrollable is named explicitly: the link TextField adds its
  // own horizontal Scrollable inside the same ListView, so the
  // default lookup would find two.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    await tester.pump();
  }

  Future<void> pumpGenerating(
    WidgetTester tester,
    ProviderContainer container, {
    bool surprise = true,
    AppDesign design = AppDesign.compact,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _GeneratingHarness(surprise: surprise, design: design),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  SavedPlaylist testSavedPlaylist() => SavedPlaylist(
        info: const PlaylistInfo(
          platformId: 'deezer',
          id: 'pl1',
          name: 'Test Mix',
          trackCount: 3,
        ),
        tracks: const [
          Track(title: 'Song One', artist: 'Artist A'),
          Track(title: 'Song Two', artist: 'Artist B'),
          Track(title: 'Song Three', artist: 'Artist C'),
        ],
        settings: const DiscoverySettings(songCount: 30, albumCount: 10),
        importedAt: DateTime.now(),
        lastScannedAt: DateTime.now(),
      );

  group('Home (redesigned)', () {
    testWidgets('masthead, lead story, and all sections render',
        (tester) async {
      await pumpHome(tester, makeContainer());

      expect(find.text('Music Man'), findsOneWidget);
      expect(find.text('Not sure where to start?'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Surprise me'),
          findsOneWidget);
      expect(find.text('Mood'), findsOneWidget);
      expect(find.text('Genre'), findsOneWidget);
      expect(find.text('Platform'), findsOneWidget);
      await scrollTo(tester, find.text('Your playlists'));
      expect(find.text('Your playlists'), findsOneWidget);
      await scrollTo(tester, find.text('Paste a playlist link'));
      expect(find.text('Paste a playlist link'), findsOneWidget);
      await scrollTo(tester, find.text('Imported playlists'));
      expect(find.text('Imported playlists'), findsOneWidget);
      await scrollTo(tester, find.textContaining('How it works'));
      expect(find.textContaining('How it works'), findsOneWidget);
      // The Deezer picker explains there is no sign-in here.
      await scrollTo(tester, find.textContaining('has no sign-in here'));
      expect(find.textContaining('has no sign-in here'), findsOneWidget);
    });

    testWidgets('no em dashes in Home copy', (tester) async {
      await pumpHome(tester, makeContainer());
      expect(find.textContaining(String.fromCharCode(0x2014)), findsNothing);
    });

    testWidgets('Complex adds the second block and This week strip',
        (tester) async {
      await pumpHome(tester, makeContainer(), design: AppDesign.complex);
      await scrollTo(tester, find.text('Start from a playlist you already love.'));
      expect(find.text('Start from a playlist you already love.'),
          findsOneWidget);
      await scrollTo(tester, find.text('This week'));
      expect(find.text('This week'), findsOneWidget);
      expect(find.text('Nothing imported yet this week.'), findsOneWidget);
    });

    testWidgets('Compact has no second block or This week strip',
        (tester) async {
      await pumpHome(tester, makeContainer());
      expect(find.text('Start from a playlist you already love.'),
          findsNothing);
      expect(find.text('This week'), findsNothing);
    });

    testWidgets('mood and genre chips toggle', (tester) async {
      await pumpHome(tester, makeContainer());

      await tester.tap(find.text('Chill'));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Chill'))
            .selected,
        isTrue,
      );
      await tester.tap(find.text('J-Pop'));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'J-Pop'))
            .selected,
        isTrue,
      );
    });

    testWidgets('Surprise me opens Generating', (tester) async {
      await pumpHome(tester, makeContainer());

      await tester.tap(find.widgetWithText(FilledButton, 'Surprise me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Warming up'), findsOneWidget);
      expect(fakeGeneration.surpriseCalls, 1);
    });

    testWidgets('empty imported list names the fix and focuses the link',
        (tester) async {
      await pumpHome(tester, makeContainer());

      await scrollTo(tester, find.textContaining('Nothing imported yet.'));
      expect(find.textContaining('Nothing imported yet.'), findsOneWidget);
      await tester.tap(find.text('Paste a link'));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
    });

    testWidgets('imported playlists render as a numbered contents list',
        (tester) async {
      final saved = testSavedPlaylist();
      await pumpHome(tester, makeContainer(saved: [saved]));

      await scrollTo(tester, find.text('Imported playlists'));
      expect(find.text('1'), findsOneWidget);
      await scrollTo(tester, find.text('Test Mix'));
      expect(find.text('Test Mix'), findsOneWidget);
      expect(find.text('01'), findsOneWidget);
      expect(find.textContaining('Deezer'), findsWidgets);
      expect(find.textContaining('3 tracks'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('delete asks first, Cancel keeps the playlist',
        (tester) async {
      final saved = testSavedPlaylist();
      await pumpHome(tester, makeContainer(saved: [saved]));

      await scrollTo(tester, find.byTooltip('Delete Test Mix'));
      await tester.tap(find.byTooltip('Delete Test Mix'));
      await tester.pump();
      expect(find.text('Delete saved playlist?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Delete saved playlist?'), findsNothing);
      expect(find.text('Test Mix'), findsOneWidget);
    });

    testWidgets('playlist picker error state offers Retry', (tester) async {
      final container = makeContainer(
        spotifySignedIn: true,
        platformId: 'spotify',
        userPlaylists: () async {
          throw const PlatformException('Spotify is unreachable right now.');
        },
      );
      await pumpHome(tester, container);

      await scrollTo(tester, find.text('Spotify is unreachable right now.'));
      expect(find.text('Spotify is unreachable right now.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Spotify is unreachable right now.'), findsOneWidget);
    });

    testWidgets('empty link import asks for a link first', (tester) async {
      await pumpHome(tester, makeContainer());

      await scrollTo(
          tester, find.widgetWithText(FilledButton, 'Import'));
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pump();
      expect(find.text('Paste a playlist link first.'), findsOneWidget);
    });
  });

  group('Generating (redesigned)', () {
    testWidgets('idle shows Warming up with an indeterminate rule',
        (tester) async {
      await pumpGenerating(tester, makeContainer());

      expect(find.text('Warming up'), findsOneWidget);
      expect(find.text('Surprise picks'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNull);
      expect(indicator.minHeight, 2);
    });

    testWidgets('progress shows the phase and the count', (tester) async {
      fakeGeneration.showProgress('Finding similar tracks', 12, 20);
      await pumpGenerating(tester, makeContainer());

      expect(find.text('Finding similar tracks'), findsOneWidget);
      expect(find.text('12 of 20'), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, closeTo(0.6, 0.001));
    });

    testWidgets('Complex progress rule animates to the new value',
        (tester) async {
      fakeGeneration.showProgress('Finding similar tracks', 12, 20);
      await pumpGenerating(tester, makeContainer(),
          design: AppDesign.complex);

      expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
      expect(find.text('12 of 20'), findsOneWidget);
    });

    testWidgets('error state offers Retry and Back', (tester) async {
      fakeGeneration.showError('Last.fm is down right now.');
      await pumpGenerating(tester, makeContainer());

      expect(find.text('Could not generate recommendations'), findsOneWidget);
      expect(find.text('Last.fm is down right now.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
      // initState already ran the (no-op) surprise once; Retry runs it again.
      expect(fakeGeneration.surpriseCalls, 1);
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      expect(fakeGeneration.surpriseCalls, 2);
    });

    testWidgets('error without retry shows Back only', (tester) async {
      fakeGeneration.showError('Add your Last.fm API key first.',
          canRetry: false);
      await pumpGenerating(tester, makeContainer());

      expect(find.text('Add your Last.fm API key first.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
    });

    testWidgets('Cancel cancels the run', (tester) async {
      await pumpGenerating(tester, makeContainer());

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      expect(fakeGeneration.cancelCalls, 1);
    });
  });
}

/// App root around Home: the MaterialApp theme follows the design
/// under test, like main.dart's MusicManApp.
class _HomeHarness extends ConsumerWidget {
  final AppDesign design;

  const _HomeHarness({required this.design});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeData = AppTheme.themeData(AppThemeName.editorial, design);
    return MaterialApp(
      theme: themeData,
      darkTheme: themeData,
      home: const Scaffold(body: HomeScreen()),
    );
  }
}

/// App root around Generating with a surprise run.
class _GeneratingHarness extends ConsumerWidget {
  final bool surprise;
  final AppDesign design;

  const _GeneratingHarness({required this.surprise, required this.design});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeData = AppTheme.themeData(AppThemeName.editorial, design);
    return MaterialApp(
      theme: themeData,
      darkTheme: themeData,
      home: Scaffold(
        body: GeneratingScreen(
          args: GenerationArgs(
            surprise: surprise,
            seedName: 'Surprise picks',
            tracks: const [],
            settings: const DiscoverySettings(songCount: 30, albumCount: 10),
          ),
        ),
      ),
    );
  }
}
