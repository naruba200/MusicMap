import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/theme.dart';
import 'data/network/retry_interceptor.dart';
import 'data/news/news_repository.dart';
import 'data/repositories/favorites_repository.dart';
import 'data/repositories/history_repository.dart';
import 'data/repositories/playlist_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'presentation/providers/providers.dart';
import 'presentation/screens/screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();

  final settingsRepo = await SettingsRepository.open();
  final playlistRepo = await PlaylistRepository.open();
  final favoritesRepo = await FavoritesRepository.open();
  final historyRepo = await HistoryRepository.open();
  final newsDio = Dio();
  newsDio.interceptors.add(ConnectionRetryInterceptor(newsDio));
  final newsRepo = await NewsRepository.open(newsDio);

  runApp(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        playlistRepositoryProvider.overrideWithValue(playlistRepo),
        favoritesRepositoryProvider.overrideWithValue(favoritesRepo),
        historyRepositoryProvider.overrideWithValue(historyRepo),
        newsRepositoryProvider.overrideWithValue(newsRepo),
      ],
      child: const MusicMapApp(),
    ),
  );
}

/// Bottom-nav tab index (Home, News, Favorites, History, Settings).

class MusicMapApp extends ConsumerWidget {
  const MusicMapApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Start listening for incoming playlist links (M1).
    ref.watch(deepLinkHandlerProvider);
    // Restore the last-selected platform (M1).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(selectedPlatformIdProvider.notifier).state =
          ref.read(settingsRepositoryProvider).selectedPlatformId;
    });

    return MaterialApp(
      title: 'Music Map',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      navigatorKey: navigatorKey,
      home: const _RootScaffold(),
    );
  }
}

class _RootScaffold extends ConsumerWidget {
  const _RootScaffold();

  static const _screens = [
    HomeScreen(),
    NewsScreen(),
    FavoritesScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.newspaper_outlined, Icons.newspaper, 'News'),
    (Icons.favorite_outline, Icons.favorite, 'Favorites'),
    (Icons.history_outlined, Icons.history, 'History'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(tabIndexProvider.notifier).state = i,
        destinations: [
          for (final (icon, selectedIcon, label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selectedIcon),
              label: label,
            ),
        ],
      ),
    );
  }
}
