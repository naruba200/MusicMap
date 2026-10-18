// Screen exports. Home is fully built (M1); News/Favorites/History/Settings
// land in M3–M4 and show honest placeholders until then.

import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'playlist_detail_screen.dart';

export 'home_screen.dart';
export 'playlist_detail_screen.dart';

/// Placeholder body for not-yet-built milestones.
class PlaceholderBody extends StatelessWidget {
  final IconData icon;
  final String label;
  final String milestone;

  const PlaceholderBody({
    super.key,
    required this.icon,
    required this.label,
    required this.milestone,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56),
          const SizedBox(height: 12),
          Text(label, style: textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(milestone, style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

class NewsScreen extends StatelessWidget {
  const NewsScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: PlaceholderBody(
          icon: Icons.newspaper_outlined,
          label: 'News',
          milestone: 'M4: RSS feed + For you ranking',
        ),
      );
}

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: PlaceholderBody(
          icon: Icons.favorite_outline,
          label: 'Favorites',
          milestone: 'M3: saved recommendations + Daily picks',
        ),
      );
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: PlaceholderBody(
          icon: Icons.history_outlined,
          label: 'History',
          milestone: 'M3: past recommendation runs',
        ),
      );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: PlaceholderBody(
          icon: Icons.settings_outlined,
          label: 'Settings',
          milestone: 'M3: sign-in, sources, export, about',
        ),
      );
}
