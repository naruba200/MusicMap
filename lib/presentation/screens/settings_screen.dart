// Settings (S-09): accounts, default counts, data export (FR-14b),
// cache clearing, news sources (M4), about + API status.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants.dart';
import '../../data/news/news_source.dart';
import '../providers/news_provider.dart';
import '../providers/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final settingsRepo = ref.watch(settingsRepositoryProvider);
    final registry = ref.watch(platformRegistryProvider);
    final auth = ref.watch(authStateProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _sectionHeader('Accounts'),
          for (final p in registry.platforms)
            ListTile(
              leading: Icon(
                (auth[p.id] ?? false)
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: (auth[p.id] ?? false) ? Colors.green : null,
              ),
              title: Text(p.displayName),
              subtitle: Text(p.isBeta
                  ? 'Experimental — no sign-in needed'
                  : (auth[p.id] ?? false)
                      ? 'Signed in'
                      : 'No sign-in needed'),
            ),
          const Divider(),
          _sectionHeader('Defaults'),
          _countRow(
            label: 'Songs per run',
            value: settingsRepo.songCount,
            presets: songCountPresets,
            onPick: (n) async {
              await settingsRepo.setDefaultSongCount(n);
              setState(() {});
            },
          ),
          _countRow(
            label: 'Albums per run',
            value: settingsRepo.albumCount,
            presets: albumCountPresets,
            onPick: (n) async {
              await settingsRepo.setDefaultAlbumCount(n);
              setState(() {});
            },
          ),
          const Divider(),
          _sectionHeader('ListenBrainz'),
          ListTile(
            leading: const Icon(Icons.music_note_outlined),
            title: const Text('ListenBrainz username'),
            subtitle: Text(settingsRepo.listenBrainzUsername == null
                ? 'Not set — ListenBrainz stays off'
                : 'Recommendations for ${settingsRepo.listenBrainzUsername} '
                    'join results as "From ListenBrainz"'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _editListenBrainzUsername,
          ),
          const Divider(),
          _sectionHeader('Data'),
          ListTile(
            leading: const Icon(Icons.ios_share_outlined),
            title: const Text('Export my data'),
            subtitle: const Text(
                'Favorites, history, saved playlists and settings as JSON'),
            trailing: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _exporting ? null : _exportData,
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear cached picks'),
            subtitle:
                const Text('Removes the daily-picks cache from this device'),
            onTap: () async {
              await Hive.deleteBoxFromDisk('daily_picks');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cache cleared.')),
                );
              }
            },
          ),
          const Divider(),
          _sectionHeader('News'),
          _newsSourcesSection(ref),
          const Divider(),
          _sectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Music Man'),
            subtitle: Text('Turn a playlist into your next favorite songs.\n'
                'All data stays on this device — no account, no cloud.'),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              lastFmApiKey == 'YOUR_LASTFM_API_KEY' ||
                      lastFmApiKey.trim().isEmpty
                  ? 'Last.fm: no API key set — recommendations are disabled '
                      'until you add one in lib/core/constants.dart.'
                  : 'Last.fm: API key set. Recommendations engine online.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _countRow({
    required String label,
    required int value,
    required List<int> presets,
    required Future<void> Function(int) onPick,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final n in presets)
                  ChoiceChip(
                    label: Text('$n'),
                    selected: value == n,
                    onSelected: (_) => onPick(n),
                  ),
              ],
            ),
          ],
        ),
      );

  /// FR-27: per-source toggles; a failing source shows an "unavailable" note.
  Widget _newsSourcesSection(WidgetRef ref) {
    final repo = ref.watch(newsRepositoryProvider);
    final sourceOk = ref.watch(newsProvider).sourceOk;
    return Column(
      children: [
        for (final s in newsSources)
          SwitchListTile(
            title: Text(s.name),
            subtitle: sourceOk[s.id] == false
                ? const Text('Unavailable right now')
                : null,
            value: repo.isEnabled(s.id),
            onChanged: (v) async {
              await repo.setEnabled(s.id, v);
              setState(() {});
              // Re-fetch so the feed reflects the new source set.
              await ref.read(newsProvider.notifier).refresh(force: true);
            },
          ),
      ],
    );
  }

  /// Phase 3: optional ListenBrainz username. Blank saves as cleared,
  /// which turns the whole ListenBrainz layer off (no key, no sign-in).
  Future<void> _editListenBrainzUsername() async {
    final repo = ref.read(settingsRepositoryProvider);
    final controller =
        TextEditingController(text: repo.listenBrainzUsername ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ListenBrainz username'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'e.g. your-listenbrainz-name',
            helperText: 'Optional. Public recommendations only — '
                'no key, no sign-in. Leave blank to turn it off.',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await repo.setListenBrainzUsername(controller.text);
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) setState(() {});
  }

  /// FR-14b: one JSON bundle via the Android share sheet.
  Future<void> _exportData() async {
    setState(() => _exporting = true);
    try {
      final bundle = {
        'formatVersion': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'favorites':
            ref.read(favoritesRepositoryProvider).exportJson(),
        'history': ref.read(historyRepositoryProvider).exportJson(),
        'savedPlaylists':
            ref.read(playlistRepositoryProvider).exportJson(),
        'settings': {
          'platform':
              ref.read(settingsRepositoryProvider).selectedPlatformId,
          'songCount': ref.read(settingsRepositoryProvider).songCount,
          'albumCount': ref.read(settingsRepositoryProvider).albumCount,
          'listenBrainzUsername':
              ref.read(settingsRepositoryProvider).listenBrainzUsername,
        },
      };
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/music-map-export-${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(bundle));
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        text: 'Music Man data export',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}
