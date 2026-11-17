import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'core/appearance.dart';
import 'core/theme.dart';
import 'data/network/retry_interceptor.dart';
import 'data/news/news_repository.dart';
import 'data/repositories/favorites_repository.dart';
import 'data/repositories/history_repository.dart';
import 'data/repositories/playlist_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'presentation/providers/appearance_provider.dart';
import 'presentation/providers/generation_provider.dart';
import 'presentation/providers/media_notification_handler.dart';
import 'presentation/providers/news_provider.dart';
import 'presentation/providers/providers.dart';
import 'presentation/screens/screens.dart';
import 'presentation/widgets/mini_player_bar.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Warm the display fonts before the first frame: a weight that
    // has never rendered fetches over the network on first use,
    // which stalls a theme change or a first render mid-animation.
    // Best effort and time-boxed: on a slow or failed fetch the app
    // starts anyway with the platform fallback, and google_fonts
    // retries the fetch on first use.
    try {
      await AppTheme.warmFonts().timeout(const Duration(seconds: 10));
    } catch (_) {
      // Font warming never blocks startup.
    }

    // Show a readable error screen instead of dying silently, so a
    // startup failure can be reported with the actual error attached.
    FlutterError.onError = (details) {
      _showStartupError(details.exceptionAsString(), details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _showStartupError(error.toString(), stack);
      return true; // handled: don't kill the isolate
    };

    await Hive.initFlutter();

    final settingsRepo = await SettingsRepository.open();
    final playlistRepo = await PlaylistRepository.open();
    final favoritesRepo = await FavoritesRepository.open();
    final historyRepo = await HistoryRepository.open();
    final newsDio = Dio();
    newsDio.interceptors.add(ConnectionRetryInterceptor(newsDio));
    final newsRepo = await NewsRepository.open(newsDio);

    // One container for the whole app, so the media notification
    // handler (created below) drives the SAME player instance the UI
    // watches. A second container would mean a second player.
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        playlistRepositoryProvider.overrideWithValue(playlistRepo),
        favoritesRepositoryProvider.overrideWithValue(favoritesRepo),
        historyRepositoryProvider.overrideWithValue(historyRepo),
        newsRepositoryProvider.overrideWithValue(newsRepo),
      ],
    );

    // Android media notification (item 5): the handler mirrors the
    // shared player into the status-bar shade. Init is guarded to
    // Android only, and best-effort: if init fails, playback still
    // works in-app, just without the shade notification.
    if (Platform.isAndroid) {
      try {
        await AudioService.init(
          builder: () => MusicManAudioHandler(
            container.read(audioPlayerProvider.notifier),
          ),
          config: const AudioServiceConfig(
            androidNotificationChannelId:
                'com.naruba200.musicman.channel.audio',
            androidNotificationChannelName: 'Music Man playback',
            // Keep the notification while paused so the user can
            // resume from the shade; stopping removes it. (Dropping
            // the foreground service on pause would also risk a
            // ForegroundServiceStartNotAllowedException when
            // resuming from the background on Android 12+.)
            androidStopForegroundOnPause: false,
          ),
        );
      } catch (e) {
        debugPrint('Media notification unavailable: $e');
      }
    }

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const MusicManApp(),
      ),
    );
  }, (error, stack) {
    _showStartupError(error.toString(), stack);
  });
}

/// Replaces the app with a plain screen carrying the crash details, so a
/// startup failure is reportable without a connected debugger.
void _showStartupError(String error, StackTrace? stack) {
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Music Man: startup error')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            'Something went wrong on launch:\n\n$error\n\n${stack ?? ''}',
          ),
        ),
      ),
    ),
  );
}

/// Bottom-nav tab index (Home, Discover, News, Favorites, History,
/// Settings).

class MusicManApp extends ConsumerWidget {
  const MusicManApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Start listening for incoming playlist links (M1).
    ref.watch(deepLinkHandlerProvider);
    // Restore the last-selected platform (M1).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(selectedPlatformIdProvider.notifier).state =
          ref.read(settingsRepositoryProvider).selectedPlatformId;
    });

    final appearance = ref.watch(appearanceProvider);
    // Reduced motion: the system disableAnimations flag zeroes
    // every token duration (see AppTheme.themeData). Read through
    // the dispatcher, which is available anywhere; the ambient
    // MediaQuery agrees with it in the real app and is the path a
    // widget test can set. Density never changes, only motion.
    final reduceMotion = WidgetsBinding.instance.platformDispatcher
            .accessibilityFeatures.disableAnimations ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final themeData = AppTheme.themeData(
      appearance.effectiveTheme,
      appearance.design,
      reduceMotion: reduceMotion,
    );

    return MaterialApp(
      title: 'Music Man',
      // Theme and darkTheme are the same selected ThemeData, so the
      // chosen theme always wins over the system brightness: the six
      // named themes each carry their own brightness (Editorial is
      // light, Tako and Midnight are dark).
      theme: themeData,
      darkTheme: themeData,
      navigatorKey: navigatorKey,
      // The route observer lets the full-player screen report when
      // it is the top route, so the shell can hide its bottom bar
      // under it (see fullPlayerOnTop in providers.dart).
      navigatorObservers: [musicManRouteObserver],
      home: const _RootScaffold(),
      // The shell wraps the root Navigator (child): the mini-player
      // and the bottom nav sit above it, so pushed routes cover the
      // tab content but never the player or the nav.
      builder: (context, child) =>
          AppShell(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// The outer shell above the root Navigator: the mini-player and the
/// bottom nav live here, so pushed routes (Results, Playlist detail,
/// the full player) cover the tab content but never the player or the
/// nav. The [child] is the root Navigator itself. Deep links and
/// [navigatorKey] pushes land on that Navigator, so they keep working.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.explore_outlined, Icons.explore, 'Discover'),
    (Icons.newspaper_outlined, Icons.newspaper, 'News'),
    (Icons.favorite_outline, Icons.favorite, 'Favorites'),
    (Icons.history_outlined, Icons.history, 'History'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  /// A nav icon, with the small accent News dot on destination 2
  /// while there is unseen content. The dot is a plain 6px accent
  /// circle on the icon corner: no glow, no pulse.
  Widget _destinationIcon(int destination, bool selected, bool hasNew) {
    final (icon, selectedIcon, _) = _destinations[destination];
    final base = Icon(selected ? selectedIcon : icon);
    if (destination != 2 || !hasNew) return base;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        base,
        Positioned(
          right: -2,
          top: -2,
          child: Builder(
            builder: (context) => Container(
              key: const ValueKey('news-dot'),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    // The News dot (DESIGN.md micro-interaction): a small accent dot
    // on the News tab while there is content newer than the last
    // visit. No glow, no pulse, it marks a real state.
    final hasNew = ref.watch(newsProvider.select((s) => s.hasNew));
    // Playback failures surface once as a small bottom message with
    // the reason (item 3): the player bumps errorSeq per failure, so
    // the same failure is never shown twice.
    ref.listen(
      audioPlayerProvider.select((s) => s.errorSeq),
      (previous, next) {
        if (next == 0) return;
        final message = ref.read(audioPlayerProvider).lastError;
        if (message == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
    );
    // The shell wraps its Scaffold in its own Overlay: the shell sits
    // above the root Navigator, so the Navigator's Overlay is not an
    // ancestor of the mini-player. IconButton tooltips (and any other
    // overlay user down here) need one, or they throw in debug builds.
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => ValueListenableBuilder<bool>(
            valueListenable: fullPlayerOnTop,
            builder: (context, playerOnTop, _) => Scaffold(
              body: child,
              // The mini-player sits above the nav on every tab and every
              // pushed route. It watches the player itself, so position
              // ticks rebuild only the bar; this shell stays out of it.
              // While the full player is the top route the whole bottom
              // bar hides: the player itself is on screen, so the strip
              // beneath it would be a dead duplicate. Dismissing the
              // player brings it back.
              bottomNavigationBar: playerOnTop
                  ? null
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const MiniPlayerBar(),
                        NavigationBar(
                          selectedIndex: index,
                          onDestinationSelected: (i) {
                            // Visiting News clears the dot and records the visit.
                            if (i == 2) {
                              ref.read(newsProvider.notifier).markSeen();
                            }
                            ref
                                .read(tabIndexProvider.notifier)
                                .state = i;
                          },
                          destinations: [
                            for (var d = 0; d < _destinations.length; d++)
                              NavigationDestination(
                                icon:
                                    _destinationIcon(d, false, hasNew),
                                selectedIcon:
                                    _destinationIcon(d, true, hasNew),
                                label: _destinations[d].$3,
                              ),
                          ],
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The PageController driving the tab PageView, shared between the
/// nav bar (taps drive it through tabIndexProvider) and the tab body
/// (swipes drive it directly). One controller for the app, created
/// on first use at the current tab.
final tabPageControllerProvider = Provider<PageController>((ref) {
  final controller =
      PageController(initialPage: ref.read(tabIndexProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

class _RootScaffold extends ConsumerWidget {
  const _RootScaffold();

  static const _screens = [
    HomeScreen(),
    DiscoverScreen(),
    NewsScreen(),
    FavoritesScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(tabPageControllerProvider);
    final tokens =
        Theme.of(context).extension<MusicManDesignTokens>();
    // Provider changes (nav taps, deep links) drive the controller;
    // swipes drive the provider through onPageChanged below. The
    // page check stops the two from ping-ponging: a provider change
    // that already matches the controller's page does nothing.
    ref.listen<int>(tabIndexProvider, (previous, next) {
      if (!controller.hasClients) return;
      if (controller.page?.round() == next) return;
      final tabSwitch = tokens?.tabSwitch ?? Duration.zero;
      if (tabSwitch == Duration.zero) {
        controller.jumpToPage(next);
      } else {
        controller.animateToPage(
          next,
          duration: tabSwitch,
          curve: Curves.easeOut,
        );
      }
    });
    // Tab swipe (DESIGN.md): the next tab previews as the drag
    // follows the finger, and the release completes or snaps back.
    // PageView gives that natively, with its own snap semantics
    // (nearest page on release, velocity-aware) instead of the
    // prototype's exact 60 px release threshold; the behavior is
    // the same. At the first or last tab there is no tab beyond, so
    // a drag that way moves nothing. Tab swipe lives on the tab
    // body only, never on pushed screens: this PageView is the tab
    // body, and pushed routes sit above it. A swipe starting on a
    // swipeable row acts on the row: the row's inner horizontal
    // drag recognizer wins the gesture arena over this PageView.
    return PageView(
      controller: controller,
      // pageSnapping is false on purpose: with snapping on, the
      // PageView inserts its own PageScrollPhysics above the widget
      // physics, and that copy intercepts the release snap (it
      // returns its own spring without delegating), so the Compact
      // instant settle below would never run. With snapping off,
      // the widget physics owns the snap: _CompactPagePhysics
      // settles instantly in Compact, plain PageScrollPhysics
      // springs in Complex. The drag preview and onPageChanged
      // reporting are unaffected.
      pageSnapping: false,
      // Compact is strictly MOTION 0, so the release settles
      // instantly instead of animating; Complex keeps the native
      // snap. The drag preview follows the finger in both designs.
      physics: tokens?.design == AppDesign.complex
          ? const PageScrollPhysics()
          : const _CompactPagePhysics(),
      onPageChanged: (page) {
        if (ref.read(tabIndexProvider) != page) {
          ref.read(tabIndexProvider.notifier).state = page;
        }
      },
      children: [
        for (final screen in _screens) _KeepAliveTab(child: screen),
      ],
    );
  }
}

/// Keeps one tab's state alive across swipes: a PageView only builds
/// the pages near the current one, so without this a tab would lose
/// its scroll position and loaded state when swiped away from.
class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({required this.child});

  final Widget child;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Page snap physics for Compact (MOTION 0): the release settles on
/// the target page at once instead of animating there. The target is
/// the same one the native snap would pick (nearest page, or one
/// page over on a fling), only the travel is instant.
class _CompactPagePhysics extends PageScrollPhysics {
  const _CompactPagePhysics({super.parent});

  @override
  _CompactPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _CompactPagePhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // An overscroll still springs back through the parent: the
    // instant settle only applies to a page change inside bounds.
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.pixels / position.viewportDimension;
    double targetPage;
    if (velocity.abs() > 50) {
      targetPage = velocity > 0 ? page.ceilToDouble() : page.floorToDouble();
      // A fling from exactly on a page still moves one page over.
      if (targetPage == page) {
        targetPage = velocity > 0 ? page + 1 : page - 1;
      }
    } else {
      targetPage = page.roundToDouble();
    }
    final maxPage =
        position.maxScrollExtent / position.viewportDimension;
    targetPage = targetPage.clamp(0.0, maxPage);
    final target = targetPage * position.viewportDimension;
    if ((target - position.pixels).abs() < 0.5) return null;
    return _InstantSimulation(target);
  }
}

/// A simulation that is already at its target: one step lands there.
class _InstantSimulation extends Simulation {
  _InstantSimulation(this._x);

  final double _x;

  @override
  double x(double time) => _x;

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => true;
}
