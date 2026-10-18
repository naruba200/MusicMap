import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'favorites_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'news_screen.dart';
import 'settings_screen.dart';

/// Placeholder body for M0 — each screen gets its real UI in its milestone.
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderBody(
        icon: Icons.home_outlined,
        label: 'Home',
        milestone: 'M1: platform picker + playlist intake',
      );
}

class NewsScreen extends StatelessWidget {
  const NewsScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderBody(
        icon: Icons.newspaper_outlined,
        label: 'News',
        milestone: 'M4: RSS feed + For you ranking',
      );
}

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderBody(
        icon: Icons.favorite_outline,
        label: 'Favorites',
        milestone: 'M3: saved recommendations',
      );
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderBody(
        icon: Icons.history_outlined,
        label: 'History',
        milestone: 'M3: past recommendation runs',
      );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderBody(
        icon: Icons.settings_outlined,
        label: 'Settings',
        milestone: 'M3: sign-in, sources, about',
      );
}
