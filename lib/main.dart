import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'presentation/screens/screens.dart';

void main() {
  runApp(const ProviderScope(child: MusicMapApp()));
}

/// Bottom-nav tab index (spec §7: Home, News, Favorites, History, Settings).
final _tabIndexProvider = StateProvider<int>((ref) => 0);

class MusicMapApp extends StatelessWidget {
  const MusicMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Map',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
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
    final index = ref.watch(_tabIndexProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(_tabIndexProvider.notifier).state = i,
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
