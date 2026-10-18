// Home screen (S-02): platform dropdown, Surprise me, playlist picker,
// paste-a-link, imported playlists, how-it-works.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/time_ago.dart';
import '../../data/models/music_models.dart';
import '../../data/platforms/music_platform.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import 'generating_screen.dart';
import 'playlist_detail_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _linkController = TextEditingController();
  final _surpriseMoods = <String>{};
  final _surpriseGenres = <String>{};

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _importLink(MusicPlatform platform) async {
    final text = _linkController.text.trim();
    if (text.isEmpty) {
      _snack('Paste a playlist link first.');
      return;
    }
    final parsed = ref.read(platformRegistryProvider).parseAnyLink(text);
    if (parsed == null) {
      _snack('That doesn\'t look like a playlist link from a supported platform.');
      return;
    }
    _linkController.clear();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailScreen(
          platformId: parsed.ref.platformId,
          playlistId: parsed.ref.playlistId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(platformRegistryProvider);
    final platformId = ref.watch(selectedPlatformIdProvider);
    final platform = registry.byId(platformId);
    final authState = ref.watch(authStateProvider);
    final signedIn = authState[platformId] ?? false;
    final saved = ref.watch(savedPlaylistsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Music Map')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Surprise me (M2 engine, no seed playlist — FR-19).
          FilledButton.icon(
            onPressed: () {
              final settingsRepo = ref.read(settingsRepositoryProvider);
              ref.read(generationProvider.notifier).reset();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GeneratingScreen(
                    args: GenerationArgs(
                      surprise: true,
                      seedName: 'Surprise picks',
                      tracks: const [],
                      settings: DiscoverySettings(
                        songCount: settingsRepo.songCount,
                        albumCount: settingsRepo.albumCount,
                        moods: Set.of(_surpriseMoods),
                        genres: Set.of(_surpriseGenres),
                      ),
                    ),
                  ),
                ),
              );
            },
            icon: const Icon(Icons.shuffle),
            label: const Text('Surprise me'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final mood in moodChips.take(7))
                FilterChip(
                  label: Text(mood),
                  selected: _surpriseMoods.contains(mood),
                  onSelected: (v) => setState(() {
                    v ? _surpriseMoods.add(mood) : _surpriseMoods.remove(mood);
                  }),
                ),
              for (final genre in ['J-Pop', 'Rock', 'Electronic'])
                FilterChip(
                  label: Text(genre),
                  selected: _surpriseGenres.contains(genre),
                  onSelected: (v) => setState(() {
                    v
                        ? _surpriseGenres.add(genre)
                        : _surpriseGenres.remove(genre);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Platform picker.
          DropdownButtonFormField<String>(
            initialValue: platformId,
            decoration: const InputDecoration(
              labelText: 'Platform',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final p in registry.platforms)
                DropdownMenuItem(
                  value: p.id,
                  child: Row(
                    children: [
                      Text(p.displayName),
                      if (p.isBeta)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                          ),
                          child: Text('β',
                              style: Theme.of(context).textTheme.labelSmall),
                        ),
                    ],
                  ),
                ),
            ],
            onChanged: (v) {
              if (v == null) return;
              ref.read(selectedPlatformIdProvider.notifier).state = v;
              ref.read(settingsRepositoryProvider).setSelectedPlatformId(v);
            },
          ),
          const SizedBox(height: 12),

          // Sign in / out.
          if (platform.requiresAuthForLibrary)
            signedIn
                ? OutlinedButton.icon(
                    onPressed: () async {
                      await ref
                          .read(authStateProvider.notifier)
                          .signOut(platform);
                    },
                    icon: const Icon(Icons.logout),
                    label: Text('Sign out of ${platform.displayName}'),
                  )
                : FilledButton.tonalIcon(
                    onPressed: () async {
                      try {
                        final ok = await ref
                            .read(authStateProvider.notifier)
                            .signIn(platform);
                        if (!ok && mounted) {
                          _snack('Sign-in cancelled.');
                        }
                      } on PlatformException catch (e) {
                        _snack(e.message);
                      }
                    },
                    icon: const Icon(Icons.login),
                    label: Text('Connect ${platform.displayName}'),
                  ),
          const SizedBox(height: 12),

          // Playlist picker.
          Text('Your playlists', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _PlaylistPicker(
            platform: platform,
            signedIn: signedIn,
            onPick: (info) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaylistDetailScreen(
                    platformId: info.platformId,
                    playlistId: info.id,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // Paste a link.
          Text('…or paste a playlist link',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _linkController,
                  decoration: InputDecoration(
                    hintText: platform.id == PlatformIds.youTubeMusic
                        ? 'https://music.youtube.com/playlist?list=…'
                        : 'https://www.deezer.com/playlist/…',
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _importLink(platform),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _importLink(platform),
                child: const Text('Import'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Imported playlists.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Imported playlists',
                  style: Theme.of(context).textTheme.titleSmall),
              Text('${saved.length}',
                  style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 8),
          if (saved.isEmpty)
            Text(
              'Nothing imported yet — pick a playlist above or paste a link.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            for (final s in saved)
              Card(
                child: ListTile(
                  leading: s.info.coverUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(s.info.coverUrl!,
                              width: 48, height: 48, fit: BoxFit.cover),
                        )
                      : const Icon(Icons.queue_music, size: 40),
                  title: Text(s.info.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${registry.byId(s.info.platformId).displayName} · '
                      '${s.tracks.length} tracks · scanned ${timeAgo(s.lastScannedAt)}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => ref
                        .read(savedPlaylistsProvider.notifier)
                        .remove(s.info.platformId, s.info.id),
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailScreen(
                          platformId: s.info.platformId,
                          playlistId: s.info.id,
                        ),
                      ),
                    );
                  },
                ),
              ),
          const SizedBox(height: 16),
          Text(
            'How it works: import a playlist, tune the discovery filters, and '
            'Music Map finds similar songs and albums via Last.fm — no account, '
            'everything stays on your device.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PlaylistPicker extends ConsumerWidget {
  final MusicPlatform platform;
  final bool signedIn;
  final void Function(dynamic info) onPick;

  const _PlaylistPicker({
    required this.platform,
    required this.signedIn,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (platform.requiresAuthForLibrary && !signedIn) {
      return Text(
        'Connect ${platform.displayName} to browse your playlists, '
        'or paste a link below — no sign-in needed.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    if (!platform.requiresAuthForLibrary) {
      return Text(
        '${platform.displayName} has no sign-in here — paste a public '
        'playlist link below.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final playlists = ref.watch(userPlaylistsProvider);
    return playlists.when(
      data: (list) {
        if (list.isEmpty) {
          return Text('No playlists found.',
              style: Theme.of(context).textTheme.bodySmall);
        }
        return SizedBox(
          height: 132,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final p = list[i];
              return InkWell(
                onTap: () => onPick(p),
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 104,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: p.coverUrl != null
                            ? Image.network(p.coverUrl!,
                                width: 104, height: 88, fit: BoxFit.cover)
                            : Container(
                                width: 104,
                                height: 88,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: const Icon(Icons.queue_music),
                              ),
                      ),
                      const SizedBox(height: 4),
                      Text(p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium),
                      Text('${p.trackCount} tracks',
                          style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
      loading: () => const Center(
          child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator())),
      error: (e, _) => Text(
        e is PlatformException ? e.message : 'Could not load playlists.',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
