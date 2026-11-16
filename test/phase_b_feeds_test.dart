// Phase B feeds tests: the News dot cycle, Discover tabs with their
// own states, and the Lyrics / Artist events / Playback log empty and
// loaded states.
//
// Hive lesson (see appearance_test.dart): fresh boxes per test opened
// in setUp (real async), never clear() on shared boxes, runAsync plus
// a short real delay after taps that write to Hive, and no
// Hive.close() in widget tearDownAll.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/discover/mixcloud_client.dart';
import 'package:music_man/data/events/bandsintown_client.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/fullsong/resolution_log.dart';
import 'package:music_man/data/lyrics/lrclib_client.dart';
import 'package:music_man/data/lyrics/lyrics_cache.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/news/news_repository.dart';
import 'package:music_man/data/news/rss_parser.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/presentation/providers/discover_provider.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/news_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/screens/artist_events_screen.dart';
import 'package:music_man/presentation/screens/discover_screen.dart';
import 'package:music_man/presentation/screens/lyrics_screen.dart';
import 'package:music_man/presentation/screens/playback_log_screen.dart';

import 'fake_audio_backend.dart';

NewsArticle _article(String link, String title) => NewsArticle(
      title: title,
      link: link,
      sourceId: 'pitchfork',
      sourceName: 'Pitchfork',
      publishedAt: DateTime.utc(2026, 11, 16, 12),
    );

/// A news repo whose fetch returns whatever [articles] currently
/// holds, so the test can add a story and refresh.
class _FakeNewsRepository extends NewsRepository {
  List<NewsArticle> articles;

  // ignore: use_super_parameters
  _FakeNewsRepository(Box box, Dio dio, this.articles) : super(box, dio);

  @override
  Future<NewsFetchResult> fetch({bool forceRefresh = false}) async =>
      NewsFetchResult(
        articles: List.of(articles),
        fetchedAt: DateTime.now(),
        sourceOk: const {},
      );
}

class _FakeLrclibAdapter implements HttpClientAdapter {
  final int status;
  final Map<String, dynamic>? payload;

  _FakeLrclibAdapter({this.status = 200, this.payload});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(payload ?? {}),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeBandsintownAdapter implements HttpClientAdapter {
  final dynamic payload;

  _FakeBandsintownAdapter({this.payload = const []});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

const _event = {
  'datetime': '2026-11-05T20:00:00',
  'venue': {
    'name': 'Paradise Rock Club',
    'city': 'Boston',
    'region': 'MA',
    'country': 'United States',
  },
  'url': 'https://www.bandsintown.com/e/123',
  'lineup': ['Artist', 'Support Act'],
  'description': 'A show.',
  'offers': [
    {'url': 'https://tickets.example.com/123', 'type': 'Tickets'},
  ],
};

/// Turns an AsyncValue into a FutureProvider override: data returns
/// the value, loading never completes, error throws.
FutureOr<T> Function(Ref) _asOverride<T>(AsyncValue<T> value) {
  return (ref) => value.when(
        data: (v) => v,
        loading: () => Completer<T>().future,
        error: (e, _) => throw e,
      );
}

void main() {
  group('News dot state cycle', () {
    late Directory dir;
    int boxCounter = 0;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_phase_b');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    Future<ProviderContainer> containerWith(
        _FakeNewsRepository repo) async {
      final container = ProviderContainer(
        overrides: [newsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      // The notifier refreshes on creation; wait for that first load
      // to land so the seen baseline is established.
      await container.read(newsProvider.notifier).refresh(force: true);
      return container;
    }

    Future<_FakeNewsRepository> fakeRepo(
        List<NewsArticle> articles) async {
      final n = boxCounter++;
      final box = await Hive.openBox('news_dot_$n');
      return _FakeNewsRepository(box, Dio(), articles);
    }

    test('first load does not count as new', () async {
      final repo = await fakeRepo([_article('https://x/1', 'Story one')]);
      final container = await containerWith(repo);
      expect(container.read(newsProvider).hasNew, isFalse);
      expect(container.read(newsProvider).seenBaseline, isTrue);
    });

    test('refresh with a new article shows the dot', () async {
      final repo = await fakeRepo([_article('https://x/1', 'Story one')]);
      final container = await containerWith(repo);
      repo.articles = [
        _article('https://x/1', 'Story one'),
        _article('https://x/2', 'Story two'),
      ];
      await container.read(newsProvider.notifier).refresh(force: true);
      expect(container.read(newsProvider).hasNew, isTrue);
    });

    test('refresh with no new articles leaves the dot off', () async {
      final repo = await fakeRepo([_article('https://x/1', 'Story one')]);
      final container = await containerWith(repo);
      await container.read(newsProvider.notifier).refresh(force: true);
      expect(container.read(newsProvider).hasNew, isFalse);
    });

    test('markSeen clears the dot and re-arms it for later news',
        () async {
      final repo = await fakeRepo([_article('https://x/1', 'Story one')]);
      final container = await containerWith(repo);
      repo.articles = [
        _article('https://x/1', 'Story one'),
        _article('https://x/2', 'Story two'),
      ];
      await container.read(newsProvider.notifier).refresh(force: true);
      expect(container.read(newsProvider).hasNew, isTrue);

      container.read(newsProvider.notifier).markSeen();
      expect(container.read(newsProvider).hasNew, isFalse);

      // Same articles again: still no dot.
      await container.read(newsProvider.notifier).refresh(force: true);
      expect(container.read(newsProvider).hasNew, isFalse);

      // One more story: the dot returns.
      repo.articles = [
        ...repo.articles,
        _article('https://x/3', 'Story three'),
      ];
      await container.read(newsProvider.notifier).refresh(force: true);
      expect(container.read(newsProvider).hasNew, isTrue);
    });

    test('an empty first load still arms the dot for later news',
        () async {
      final repo = await fakeRepo([]);
      final container = await containerWith(repo);
      expect(container.read(newsProvider).hasNew, isFalse);
      repo.articles = [_article('https://x/1', 'Story one')];
      await container.read(newsProvider.notifier).refresh(force: true);
      expect(container.read(newsProvider).hasNew, isTrue);
    });
  });

  group('News dot in the bottom nav', () {
    late Directory dir;
    late _FakeNewsRepository repo;
    late ProviderContainer container;
    int boxCounter = 0;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_phase_b_nav');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    setUp(() async {
      final n = boxCounter++;
      final box = await Hive.openBox('news_nav_$n');
      repo = _FakeNewsRepository(
          box, Dio(), [_article('https://x/1', 'Story one')]);
      container = ProviderContainer(
        overrides: [newsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
    });

    // The same nav the app root builds (main.dart _RootScaffold):
    // six destinations, a small accent dot on News while hasNew is
    // true, and selecting News marks the feed seen.
    Future<void> pumpNav(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _NavHarness(),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    testWidgets('dot appears on new content, selecting News clears it',
        (tester) async {
      await pumpNav(tester);
      expect(find.byKey(const ValueKey('news-dot')), findsNothing);

      repo.articles = [
        _article('https://x/1', 'Story one'),
        _article('https://x/2', 'Story two'),
      ];
      await tester.runAsync(() async {
        await container
            .read(newsProvider.notifier)
            .refresh(force: true);
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('news-dot')), findsOneWidget);

      await tester.tap(find.text('News'));
      await tester.pump();
      expect(find.byKey(const ValueKey('news-dot')), findsNothing);
      expect(container.read(tabIndexProvider), 2);
    });
  });

  group('Discover tabs', () {
    late Directory dir;
    late FavoritesRepository favorites;
    late ProviderContainer container;
    int boxCounter = 0;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_phase_b_dis');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    setUp(() async {
      // Fresh favorites box per test, opened here in real async:
      // opening a box inside the test body hangs under the widget
      // test's fake clock.
      final n = boxCounter++;
      favorites = FavoritesRepository(await Hive.openBox('dis_fav_$n'));
    });

    const trackA = Track(
      artist: 'Singer A',
      title: 'Song A',
      durationMs: 200000,
    );
    const trackB = Track(
      artist: 'Singer B',
      title: 'Song B',
      durationMs: 180000,
    );

    Future<void> pumpDiscover(
      WidgetTester tester, {
      AsyncValue<DiscoverLoad<Track>>? audiusTrending,
      AsyncValue<DiscoverLoad<MixcloudShow>>? mixcloudFeed,
      AppDesign design = AppDesign.compact,
    }) async {
      final player =
          AudioPlayerNotifier(FallbackSources(), backend: FakeAudioBackend());
      container = ProviderContainer(
        overrides: [
          favoritesRepositoryProvider.overrideWithValue(favorites),
          audioPlayerProvider.overrideWith((ref) => player),
          jamendoClientIdProvider.overrideWithValue(''),
          jamendoRadiosProvider.overrideWith(
              (ref) async => const DiscoverLoad(items: [])),
          audiusTrendingProvider('all').overrideWith(_asOverride(
              audiusTrending ??
                  const AsyncValue.data(
                      DiscoverLoad(items: [trackA, trackB])))),
          mixcloudFeedProvider('popular').overrideWith(_asOverride(
              mixcloudFeed ??
                  const AsyncValue.data(DiscoverLoad(items: [])))),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.themeData(AppThemeName.editorial, design),
            home: const DiscoverScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('Audius tab renders its trending list', (tester) async {
      await pumpDiscover(tester);
      expect(find.text('Audius'), findsWidgets);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Trending'), findsOneWidget);
    });

    testWidgets('Audius tab shows its own loading state', (tester) async {
      await pumpDiscover(tester,
          audiusTrending: const AsyncValue.loading());
      expect(find.text('Loading Audius trending'), findsOneWidget);
      expect(find.text('Song A'), findsNothing);
    });

    testWidgets('Audius tab shows its own error state with Retry',
        (tester) async {
      await pumpDiscover(tester,
          audiusTrending: AsyncValue.error(
              Exception('offline'), StackTrace.empty));
      expect(
          find.text('Could not load Audius trending. Check your '
              'connection and retry.'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('Complex Audius tab shows the trending count',
        (tester) async {
      await pumpDiscover(tester, design: AppDesign.complex);
      expect(find.text('2 tracks trending'), findsOneWidget);
    });

    testWidgets('Jamendo tab shows the setup hint and empty radios',
        (tester) async {
      await pumpDiscover(tester);
      await tester.tap(find.text('Jamendo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Jamendo needs a free client_id'),
          findsOneWidget);
      expect(find.text('No radios here yet.'), findsOneWidget);
    });

    testWidgets('Openwhyd tab renders its import section',
        (tester) async {
      await pumpDiscover(tester);
      await tester.tap(find.text('Openwhyd'));
      await tester.pumpAndSettle();
      expect(find.text('Import a public Openwhyd playlist'),
          findsOneWidget);
      expect(find.text('Import'), findsWidgets);
    });

    testWidgets('Mixcloud tab shows its own error state',
        (tester) async {
      await pumpDiscover(tester,
          mixcloudFeed: AsyncValue.error(
              Exception('offline'), StackTrace.empty));
      await tester.tap(find.text('Mixcloud'));
      await tester.pumpAndSettle();
      expect(
          find.text('Could not load Mixcloud shows. Check your '
              'connection and retry.'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('Mixcloud tab shows its own empty state', (tester) async {
      await pumpDiscover(tester);
      await tester.tap(find.text('Mixcloud'));
      await tester.pumpAndSettle();
      expect(find.text('No shows here yet.'), findsOneWidget);
    });
  });

  group('Lyrics screen', () {
    late Directory dir;
    late LyricsCache cache;
    int boxCounter = 0;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_phase_b_lyr');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    setUp(() async {
      // Fresh cache box per test, opened here in real async, never
      // inside the test body (see the Discover group note).
      final n = boxCounter++;
      cache = LyricsCache(await Hive.openBox('lyrics_$n'));
    });

    Future<void> pumpLyrics(
      WidgetTester tester, {
      required LrclibClient client,
      AppDesign design = AppDesign.compact,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeData(AppThemeName.editorial, design),
          home: LyricsScreen(
            track: const Track(artist: 'Artist', title: 'Song'),
            client: client,
            cache: cache,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('loaded lyrics render with the album line in Complex',
        (tester) async {
      final client = LrclibClient(_dioWith(_FakeLrclibAdapter(payload: {
        'trackName': 'Song',
        'artistName': 'Artist',
        'albumName': 'Album One',
        'plainLyrics': 'line one\nline two',
        'instrumental': false,
      })));
      await pumpLyrics(tester, client: client, design: AppDesign.complex);
      expect(find.text('From the album Album One'), findsOneWidget);
      expect(find.text('line one\nline two'), findsOneWidget);
      expect(find.text('Lyrics: LRCLIB'), findsOneWidget);
    });

    testWidgets('loaded lyrics render without the album line in Compact',
        (tester) async {
      final client = LrclibClient(_dioWith(_FakeLrclibAdapter(payload: {
        'trackName': 'Song',
        'artistName': 'Artist',
        'albumName': 'Album One',
        'plainLyrics': 'line one\nline two',
        'instrumental': false,
      })));
      await pumpLyrics(tester, client: client);
      expect(find.text('line one\nline two'), findsOneWidget);
      expect(find.text('From the album Album One'), findsNothing);
    });

    testWidgets('a track LRCLIB does not know lands on an empty state',
        (tester) async {
      final client =
          LrclibClient(_dioWith(_FakeLrclibAdapter(status: 404)));
      await pumpLyrics(tester, client: client);
      expect(
          find.textContaining('LRCLIB has no lyrics for "Song"'),
          findsOneWidget);
    });

    testWidgets('an instrumental track lands on an honest empty state',
        (tester) async {
      final client = LrclibClient(_dioWith(_FakeLrclibAdapter(payload: {
        'trackName': 'Song',
        'artistName': 'Artist',
        'instrumental': true,
      })));
      await pumpLyrics(tester, client: client);
      expect(find.textContaining('instrumental track'), findsOneWidget);
    });
  });

  group('Artist events screen', () {
    testWidgets('unconfigured app id shows the setup hint',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ArtistEventsScreen(artists: ['Artist']),
        ),
      );
      await tester.pump();
      expect(find.text('Events are not set up yet'), findsOneWidget);
      expect(find.textContaining('Bandsintown'), findsWidgets);
    });

    testWidgets('loaded events render date and venue', (tester) async {
      final client = BandsintownClient(
        _dioWith(_FakeBandsintownAdapter(payload: [_event])),
        appId: 'real-app-id',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeData(
              AppThemeName.editorial, AppDesign.compact),
          home: ArtistEventsScreen(
            artists: const ['Artist'],
            appId: 'real-app-id',
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026-11-05 20:00'), findsOneWidget);
      expect(find.text('Paradise Rock Club, Boston, MA, United States'),
          findsOneWidget);
    });

    testWidgets('Complex shows the venue detail lines', (tester) async {
      final client = BandsintownClient(
        _dioWith(_FakeBandsintownAdapter(payload: [_event])),
        appId: 'real-app-id',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeData(
              AppThemeName.editorial, AppDesign.complex),
          home: ArtistEventsScreen(
            artists: const ['Artist'],
            appId: 'real-app-id',
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Paradise Rock Club'), findsOneWidget);
      expect(find.text('Boston, MA, United States'), findsOneWidget);
      expect(find.text('A show.'), findsOneWidget);
    });

    testWidgets('no events names the artist', (tester) async {
      final client = BandsintownClient(
        _dioWith(_FakeBandsintownAdapter(payload: [])),
        appId: 'real-app-id',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ArtistEventsScreen(
            artists: const ['Artist'],
            appId: 'real-app-id',
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No upcoming events for Artist right now.'),
          findsOneWidget);
    });
  });

  group('Playback log screen', () {
    late Directory dir;
    late ProviderContainer container;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_phase_b_log');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    ResolutionEntry entry({
      String title = 'Song A',
      String artist = 'Singer A',
      String result = 'Audius stream',
      List<SourceAttempt> attempts = const [
        SourceAttempt(
            source: 'audius',
            outcome: SourceOutcome.matched,
            detail: 'title and artist matched'),
        SourceAttempt(
            source: 'youtube',
            outcome: SourceOutcome.noMatch,
            detail: 'no strict title match'),
      ],
    }) =>
        ResolutionEntry(
          trackKey: 'singer a::song a',
          title: title,
          artist: artist,
          time: DateTime(2026, 11, 16, 21, 30, 5),
          attempts: attempts,
          result: result,
        );

    Future<void> pumpLog(
      WidgetTester tester, {
      List<ResolutionEntry> entries = const [],
      AppDesign design = AppDesign.compact,
    }) async {
      container = ProviderContainer(
        overrides: [
          resolutionLogProvider.overrideWith(
              (ref) => ResolutionLogNotifier()),
        ],
      );
      addTearDown(container.dispose);
      for (final e in entries) {
        container.read(resolutionLogProvider.notifier).record(e);
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.themeData(AppThemeName.editorial, design),
            home: const PlaybackLogScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('empty state names the log', (tester) async {
      await pumpLog(tester);
      expect(find.textContaining('No playback attempts yet.'),
          findsOneWidget);
    });

    testWidgets('loaded attempts render newest first with outcomes',
        (tester) async {
      await pumpLog(tester, entries: [
        entry(),
        entry(
            title: 'Song B',
            artist: 'Singer B',
            result: 'No full stream found'),
      ]);
      expect(find.text('Singer B - Song B'), findsOneWidget);
      expect(find.text('Singer A - Song A'), findsOneWidget);
      // Newest first: B sits above A.
      final b = tester.getTopLeft(find.text('Singer B - Song B'));
      final a = tester.getTopLeft(find.text('Singer A - Song A'));
      expect(b.dy, lessThan(a.dy));
      await tester.tap(find.text('Singer A - Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('audius'), findsOneWidget);
      expect(find.text('Matched'), findsOneWidget);
      // Compact keeps the reason behind the attempt row's expansion.
      expect(find.text('title and artist matched'), findsNothing);
      await tester.tap(find.text('audius'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('title and artist matched'), findsOneWidget);
    });

    testWidgets('Complex shows the per-source reason inline',
        (tester) async {
      await pumpLog(tester,
          entries: [entry()], design: AppDesign.complex);
      await tester.tap(find.text('Singer A - Song A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Matched: title and artist matched'),
          findsOneWidget);
    });

    testWidgets('Clear empties the log', (tester) async {
      await pumpLog(tester, entries: [entry()]);
      expect(find.text('Singer A - Song A'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear log'));
      await tester.pump();
      expect(find.textContaining('No playback attempts yet.'),
          findsOneWidget);
    });
  });
}

/// The nav the app root builds (main.dart _RootScaffold), for the dot
/// test: six destinations, the accent dot on News while hasNew holds,
/// selecting News marks the feed seen.
class _NavHarness extends ConsumerWidget {
  const _NavHarness();

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.explore_outlined, Icons.explore, 'Discover'),
    (Icons.newspaper_outlined, Icons.newspaper, 'News'),
    (Icons.favorite_outline, Icons.favorite, 'Favorites'),
    (Icons.history_outlined, Icons.history, 'History'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    final hasNew = ref.watch(newsProvider.select((s) => s.hasNew));
    return MaterialApp(
      theme: AppTheme.themeData(AppThemeName.editorial, AppDesign.compact),
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) {
            if (i == 2) ref.read(newsProvider.notifier).markSeen();
            ref.read(tabIndexProvider.notifier).state = i;
          },
          destinations: [
            for (var d = 0; d < _destinations.length; d++)
              NavigationDestination(
                icon: _icon(context, d, false, hasNew),
                selectedIcon: _icon(context, d, true, hasNew),
                label: _destinations[d].$3,
              ),
          ],
        ),
      ),
    );
  }

  Widget _icon(
      BuildContext context, int destination, bool selected, bool hasNew) {
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
          child: Container(
            key: const ValueKey('news-dot'),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }
}
