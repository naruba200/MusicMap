// Group 3 QA fix round: full-player rise, toast auto-dismiss, and
// mini-player dismiss. The player runs on a fake backend and the
// shell is the real AppShell (root navigator key, route observer),
// so the push path and the toast messenger are the ones the app
// actually uses. No network is touched: the resolving test drives a
// canned Audius adapter.
//
// NOTE: never pumpAndSettle here: the shell can hold a live progress
// indicator, and the rise tests need mid-flight frames.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/discover/audius_client.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/fullsong/full_song_resolver.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/news/news_repository.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/main.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/news_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/full_player_screen.dart';
import 'package:music_man/presentation/widgets/mini_player_bar.dart';
import 'package:music_man/presentation/widgets/undo_snackbar.dart';

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

/// Track B with no own stream URL, so playing it resolves first
/// (and the resolve can still be in flight when the bar is
/// dismissed). A track with a streamUrl resolves instantly.
const _trackBNoStream = Track(
  artist: 'Singer B',
  title: 'Song B',
);

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

/// Canned Audius adapter whose search answers after a delay, so a
/// resolve is still in flight when the test dismisses the bar. Every
/// other host returns an empty body, so the fallback phases find
/// nothing and the Audius match is the one that resolves.
class _SlowAudiusAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final host = options.uri.host;
    final path = options.uri.path;
    Map<String, dynamic> body;
    if (host == 'audius.test' && path.endsWith('/v1/tracks/search')) {
      await Future.delayed(const Duration(milliseconds: 500));
      body = {
        'data': [
          {
            'id': '7',
            'title': 'Song B',
            'user': {'name': 'Singer B'},
          },
        ],
      };
    } else {
      body = {};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory dir;
  late FavoritesRepository favorites;
  late PlaylistRepository playlists;
  late NewsRepository newsRepo;
  int boxCounter = 0;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_group3_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  setUp(() async {
    fullPlayerOnTop.value = false;
    final n = boxCounter++;
    favorites = FavoritesRepository(await Hive.openBox('fav_$n'));
    playlists = PlaylistRepository(await Hive.openBox('pl_$n'));
    newsRepo = _FakeNewsRepository(await Hive.openBox('news_$n'), Dio());
  });

  /// The real app shell (AppShell above the root Navigator) with the
  /// loaded player, in [design]. The theme is built with
  /// reduceMotion false unless [reduceMotion] is set, so the flag-on
  /// test isolates the framework layer from the app token layer.
  Future<void> pumpShell(
    WidgetTester tester,
    AudioPlayerNotifier player, {
    AppDesign design = AppDesign.complex,
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioPlayerProvider.overrideWith((ref) => player),
          favoritesRepositoryProvider.overrideWithValue(favorites),
          playlistRepositoryProvider.overrideWithValue(playlists),
          newsRepositoryProvider.overrideWithValue(newsRepo),
        ],
        child: MaterialApp(
          theme: AppTheme.themeData(
            AppThemeName.editorial,
            design,
            reduceMotion: reduceMotion,
          ),
          navigatorKey: navigatorKey,
          navigatorObservers: [musicManRouteObserver],
          builder: (context, child) =>
              AppShell(child: child ?? const SizedBox.shrink()),
          home: const Scaffold(
            body: Center(child: Text('Home tab')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<AudioPlayerNotifier> loadedPlayer({
    FakeAudioBackend? backend,
    FullSongResolver? resolver,
  }) async {
    final usedBackend = backend ?? FakeAudioBackend()
      ..fakeDuration = const Duration(minutes: 3);
    final player = AudioPlayerNotifier(
      FallbackSources(),
      backend: usedBackend,
      resolver: resolver,
    );
    await player.playStream(
      _trackA,
      'https://example.com/a.m4a',
      queue: [_trackA, _trackB],
    );
    return player;
  }

  /// The effective playerRise at the exact context the mini-player
  /// push reads it from.
  Duration pushContextPlayerRise(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(MiniPlayerBar)))
          .extension<MusicManDesignTokens>()!
          .playerRise;

  group('(a) full-player rise', () {
    testWidgets(
        'Complex: the player rises over 220 ms through the '
        'real shell', (tester) async {
      final player = await loadedPlayer();
      await pumpShell(tester, player, design: AppDesign.complex);
      expect(find.text('Song A'), findsOneWidget);
      // The duration at the push site itself: 220 ms, Complex.
      expect(pushContextPlayerRise(tester), const Duration(milliseconds: 220));
      await tester.tap(find.text('Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      final route = ModalRoute.of(tester.element(find.byType(FullPlayerScreen)))
          as PageRoute;
      expect(route.transitionDuration, const Duration(milliseconds: 220));
      // Mid-flight, not already there and not yet settled.
      expect(route.animation?.value ?? 1.0, greaterThan(0.0));
      expect(route.animation?.value ?? 0.0, lessThan(1.0));
      expect(route.animation?.status, AnimationStatus.forward);
      expect(tester.getTopLeft(find.byType(FullPlayerScreen)).dy,
          greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getTopLeft(find.byType(FullPlayerScreen)).dy, 0.0);
    });

    testWidgets(
        'disableAnimations on: the rise completes at once, '
        'even with a 220 ms route', (tester) async {
      addTearDown(() =>
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue());
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      expect(SemanticsBinding.instance.disableAnimations, isTrue);
      final player = await loadedPlayer();
      await pumpShell(tester, player, design: AppDesign.complex);
      // The route is still built with the full duration: the
      // framework's route animation controller scales it to 5%
      // (11 ms) while the OS flag is on, so the player lands at
      // once. The app layer zeroes the tokens too when the flag is
      // on (see the reduceMotion token test); both layers honor the
      // same flag, and DESIGN.md says motion stops under
      // prefers-reduced-motion.
      expect(pushContextPlayerRise(tester), const Duration(milliseconds: 220));
      await tester.tap(find.text('Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final route = ModalRoute.of(tester.element(find.byType(FullPlayerScreen)))
          as PageRoute;
      expect(route.transitionDuration, const Duration(milliseconds: 220));
      expect(route.animation?.value, 1.0);
      expect(tester.getTopLeft(find.byType(FullPlayerScreen)).dy, 0.0);
    });
  });

  group('(b) toast auto-dismiss', () {
    // A SnackBar timer starts only once its entrance animation has
    // completed, so the pumps step: entrance, then the duration,
    // then the exit.
    Future<void> pumpPastToast(WidgetTester tester, String text) async {
      await tester.pump();
      expect(find.text(text), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(text), findsNothing);
    }

    testWidgets('Undo toast disappears on its own', (tester) async {
      final player = await loadedPlayer();
      await pumpShell(tester, player, design: AppDesign.compact);
      final element = tester.element(find.text('Home tab'));
      showUndoSnackBar(element, message: 'Added to favorites', onUndo: () {});
      await pumpPastToast(tester, 'Added to favorites');
    });

    testWidgets(
        'an action toast with persist false disappears on '
        'its own', (tester) async {
      // The same shape as the YouTube Retry toast: an action, an
      // explicit 4 s duration, persist false. (An action SnackBar
      // defaults to persist true in the framework, which is what
      // kept every Undo toast on screen forever.)
      final player = await loadedPlayer();
      await pumpShell(tester, player, design: AppDesign.compact);
      final element = tester.element(find.text('Home tab'));
      ScaffoldMessenger.of(element).showSnackBar(
        SnackBar(
          content: const Text('Could not resolve YouTube videos'),
          action: SnackBarAction(label: 'Retry', onPressed: () {}),
          duration: const Duration(seconds: 4),
          persist: false,
        ),
      );
      await pumpPastToast(tester, 'Could not resolve YouTube videos');
    });
  });

  group('(c) mini-player dismiss', () {
    Future<FakeAudioBackend> pumpedBar(
      WidgetTester tester, {
      AppDesign design = AppDesign.complex,
    }) async {
      final backend = FakeAudioBackend()
        ..fakeDuration = const Duration(minutes: 3);
      final player = await loadedPlayer(backend: backend);
      await pumpShell(tester, player, design: design);
      expect(find.text('Song A'), findsOneWidget);
      return backend;
    }

    // The title sits inside the slide transform, so its global top
    // moves with the bar. (The Transform widget's own origin never
    // moves, so measuring the bar itself shows nothing.)
    double titleTop(WidgetTester tester) =>
        tester.getTopLeft(find.text('Song A')).dy;

    /// A slow downward drag from the title: 10 px per 100 ms, so the
    /// release velocity stays under the fling threshold and only the
    /// distance decides.
    Future<void> slowDragDown(WidgetTester tester, double distance) async {
      final start = tester.getCenter(find.text('Song A'));
      final gesture = await tester.startGesture(start);
      var moved = 0.0;
      while (moved < distance) {
        final step = (distance - moved).clamp(0.0, 10.0);
        await gesture.moveBy(Offset(0, step));
        moved += step;
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.up();
    }

    testWidgets('X button dismisses and stops playback', (tester) async {
      final backend = await pumpedBar(tester);
      final stopsBefore = backend.stopCalls;
      final restTop = titleTop(tester);
      await tester.tap(find.byTooltip('Dismiss player'));
      // The first pump is the exit animation's warm-up frame; the
      // second advances it mid-flight.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      // Mid-exit: the bar is sliding down, still on screen.
      expect(find.text('Song A'), findsOneWidget);
      expect(titleTop(tester), greaterThan(restTop));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      expect(backend.stopCalls, stopsBefore + 1);
    });

    testWidgets('swipe-down past threshold dismisses', (tester) async {
      final backend = await pumpedBar(tester);
      final stopsBefore = backend.stopCalls;
      await slowDragDown(tester, 80);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      expect(backend.stopCalls, stopsBefore + 1);
    });

    testWidgets(
        'a downward fling dismisses even below the distance '
        'threshold', (tester) async {
      final backend = await pumpedBar(tester);
      final stopsBefore = backend.stopCalls;
      // A fast drag: 45 px in about 48 ms, so about 900 px/s, but
      // under the 56 px distance threshold, so only the fling can
      // dismiss it. timedDrag stamps its moves over the duration,
      // which is what the release velocity is computed from.
      // (tester.fling and bare moveBy calls cannot drive this:
      // their moves carry zero or near-zero timestamps, so the
      // drag recognizer reports a 0.0 release velocity.)
      await tester.timedDrag(
        find.text('Song A'),
        const Offset(0, 45),
        const Duration(milliseconds: 48),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      expect(backend.stopCalls, stopsBefore + 1);
    });

    testWidgets('swipe below threshold springs back', (tester) async {
      final backend = await pumpedBar(tester);
      final stopsBefore = backend.stopCalls;
      final restTop = titleTop(tester);
      // Drag down 30 px slowly, and check the bar follows the finger
      // before releasing.
      final start = tester.getCenter(find.text('Song A'));
      final gesture = await tester.startGesture(start);
      for (var i = 0; i < 3; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(titleTop(tester), greaterThan(restTop));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Song A'), findsOneWidget);
      expect(titleTop(tester), restTop);
      expect(backend.stopCalls, stopsBefore);
    });

    testWidgets('swipe-down dismisses instantly in Compact', (tester) async {
      final backend = await pumpedBar(tester, design: AppDesign.compact);
      final stopsBefore = backend.stopCalls;
      await slowDragDown(tester, 80);
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      expect(backend.stopCalls, stopsBefore + 1);
    });

    testWidgets('tap still opens the full player', (tester) async {
      await pumpedBar(tester);
      await tester.tap(find.text('Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullPlayerScreen), findsOneWidget);
    });

    testWidgets('dismiss during resolve does not resurrect the bar',
        (tester) async {
      final backend = FakeAudioBackend()
        ..fakeDuration = const Duration(minutes: 3);
      final dio = Dio()..httpClientAdapter = _SlowAudiusAdapter();
      final resolver = FullSongResolver(
        fallbacks: FallbackSources(dio),
        audius: AudiusClient(dio, hostOverride: 'https://audius.test'),
      );
      final player = await loadedPlayer(backend: backend, resolver: resolver);
      await pumpShell(tester, player, design: AppDesign.complex);
      expect(find.text('Song A'), findsOneWidget);
      // Track B has no stream URL, so playing it resolves first:
      // start the resolve and dismiss while it is still in flight.
      unawaited(
          player.play(_trackBNoStream, queue: [_trackA, _trackBNoStream]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.state.isResolving, isTrue);
      await tester.tap(find.byTooltip('Dismiss player'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      // Let the delayed Audius answer land: the token stop() bumped
      // drops it, so nothing plays and the bar stays gone.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Song A'), findsNothing);
      expect(find.text('Song B'), findsNothing);
      expect(player.state.currentTrack, isNull);
      expect(
        backend.playedUrls,
        isNot(contains(
            'https://audius.test/v1/tracks/7/stream?app_name=MusicMan')),
      );
    });
  });
}
