// Home screen (S-02): the cover.
//
// DESIGN.md: masthead with the 音 stamp, Surprise me as the lead
// story, mood and genre chips as a column, platform dropdown, your
// playlists, paste a link, imported playlists as a contents list,
// how it works as a footnote. Complex adds a second editorial block
// and a "This week" strip built from the real imported library.
// Restyle only: every behavior below (chips, dropdown, sign in,
// navigation, generation entry points) is unchanged.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/constants.dart';
import '../../core/time_ago.dart';
import '../../data/models/music_models.dart';
import '../../data/platforms/music_platform.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/editorial_route.dart';
import '../widgets/editorial_widgets.dart';
import 'generating_screen.dart';
import 'playlist_detail_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _linkController = TextEditingController();
  final _linkFocusNode = FocusNode();
  final _surpriseMoods = <String>{};
  final _surpriseGenres = <String>{};

  @override
  void dispose() {
    _linkController.dispose();
    _linkFocusNode.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDelete(
      String platformId, String playlistId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved playlist?'),
        content: Text(
            'Remove "$name" from your library? Its rescans and history stay on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(savedPlaylistsProvider.notifier)
          .remove(platformId, playlistId);
      if (mounted) _snack('Deleted "$name".');
    }
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
      editorialRoute(
        context,
        (_) => PlaylistDetailScreen(
          platformId: parsed.ref.platformId,
          playlistId: parsed.ref.playlistId,
        ),
      ),
    );
  }

  void _surpriseMe() {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    ref.read(generationProvider.notifier).reset();
    Navigator.of(context).push(
      editorialRoute(
        context,
        (_) => GeneratingScreen(
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
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(platformRegistryProvider);
    final platformId = ref.watch(selectedPlatformIdProvider);
    final platform = registry.byId(platformId);
    final authState = ref.watch(authStateProvider);
    final signedIn = authState[platformId] ?? false;
    final saved = ref.watch(savedPlaylistsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = theme.extension<MusicManDesignTokens>();
    final isComplex = tokens?.design == AppDesign.complex;

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          // Masthead: the 音 stamp and the name, like a magazine cover.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const StampSquare(kanji: '音', size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Music Man',
                        style: theme.textTheme.displayMedium),
                    const SizedBox(height: 2),
                    Text(
                      'A playlist you love, turned into the next songs you should hear.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 24),

          // Surprise me, the lead story.
          _LeadPanel(
            isComplex: isComplex,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Not sure where to start?',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Pick a mood or a genre below, and let Music Man choose the first songs.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _surpriseMe,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Surprise me'),
                ),
                const SizedBox(height: 20),
                // Mood and genre chips as a column, not one flat row.
                Text('Mood', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mood in moodChips.take(7))
                      FilterChip(
                        label: Text(mood),
                        selected: _surpriseMoods.contains(mood),
                        onSelected: (v) => setState(() {
                          v
                              ? _surpriseMoods.add(mood)
                              : _surpriseMoods.remove(mood);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Genre', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
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
              ],
            ),
          ),

          // Complex only: a second editorial block and a "This week"
          // strip, both built from the real imported library.
          if (isComplex) ...[
            const SizedBox(height: 24),
            _LeadPanel(
              isComplex: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Start from a playlist you already love.',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'The picks follow your taste, not the charts. Import one playlist and Music Man does the rest.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _ThisWeekStrip(saved: saved),
          ],
          const SizedBox(height: 32),

          // Platform picker.
          Text('Platform', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
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
                            borderRadius: BorderRadius.circular(2),
                            color: scheme.surface,
                          ),
                          child: Text('Beta',
                              style: theme.textTheme.labelSmall),
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
          const SizedBox(height: 24),

          // Playlist picker.
          Text('Your playlists', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _PlaylistPicker(
            platform: platform,
            signedIn: signedIn,
            onPick: (info) {
              Navigator.of(context).push(
                editorialRoute(
                  context,
                  (_) => PlaylistDetailScreen(
                    platformId: info.platformId,
                    playlistId: info.id,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),

          // Paste a link.
          Text('Paste a playlist link',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Or paste a link instead of browsing your library.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _linkController,
                  focusNode: _linkFocusNode,
                  decoration: InputDecoration(
                    hintText: platform.id == PlatformIds.youTubeMusic
                        ? 'https://music.youtube.com/playlist?list=…'
                        : platform.id == PlatformIds.spotify
                            ? 'https://open.spotify.com/playlist/…'
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
          const SizedBox(height: 32),

          // Imported playlists as a contents list.
          SectionHeader(
            kanji: '音',
            title: 'Imported playlists',
            trailing: Text(
              '${saved.length}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (saved.isEmpty)
            EditorialEmptyState(
              message:
                  'Nothing imported yet. Pick a playlist above or paste a link below.',
              actionLabel: 'Paste a link',
              onAction: () => _linkFocusNode.requestFocus(),
            )
          else
            for (var i = 0; i < saved.length; i++)
              _ContentsRow(
                index: i + 1,
                saved: saved[i],
                platformName:
                    registry.byId(saved[i].info.platformId).displayName,
                onTap: () {
                  Navigator.of(context).push(
                    editorialRoute(
                      context,
                      (_) => PlaylistDetailScreen(
                        platformId: saved[i].info.platformId,
                        playlistId: saved[i].info.id,
                      ),
                    ),
                  );
                },
                onDelete: () => _confirmDelete(saved[i].info.platformId,
                    saved[i].info.id, saved[i].info.name),
              ),
          const SizedBox(height: 32),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Text(
            'How it works: import a playlist, tune the discovery filters, and '
            'Music Man finds similar songs and albums via Last.fm. No account '
            'needed. Everything stays on your device.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A paper 2 panel for the lead story and the second editorial block.
/// In Complex it sits raised above the page; in Compact it stays
/// flat behind a hairline border (DESIGN.md: one-shadow rule).
class _LeadPanel extends StatelessWidget {
  final bool isComplex;
  final Widget child;

  const _LeadPanel({required this.isComplex, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(tokens?.cardRadius ?? 4),
        boxShadow:
            isComplex ? (tokens?.raisedShadow ?? const []) : const [],
      ),
      child: child,
    );
  }
}

/// The Complex "This week" strip: real counts from the imported
/// library only, never invented numbers.
class _ThisWeekStrip extends StatelessWidget {
  final List<SavedPlaylist> saved;

  const _ThisWeekStrip({required this.saved});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totalTracks =
        saved.fold<int>(0, (sum, s) => sum + s.tracks.length);
    final latest = saved.isEmpty
        ? null
        : saved.reduce(
            (a, b) => a.lastScannedAt.isAfter(b.lastScannedAt) ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('This week', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          saved.isEmpty
              ? 'Nothing imported yet this week.'
              : '${saved.length} imported playlists, $totalTracks tracks in your library.'
                  ' Last scanned: ${latest!.info.name}, ${timeAgo(latest.lastScannedAt)}.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
      ],
    );
  }
}

/// One row of the imported-playlists contents list: number, cover,
/// name, platform and track count, delete. A ruled list, not cards.
class _ContentsRow extends StatelessWidget {
  final int index;
  final SavedPlaylist saved;
  final String platformName;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ContentsRow({
    required this.index,
    required this.saved,
    required this.platformName,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outline),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                index.toString().padLeft(2, '0'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            saved.info.coverUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Image.network(
                      saved.info.coverUrl!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, __) => Container(
                        width: 48,
                        height: 48,
                        color: scheme.surface,
                        alignment: Alignment.center,
                        child: const Icon(Icons.queue_music),
                      ),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    color: scheme.surface,
                    alignment: Alignment.center,
                    child: const Icon(Icons.queue_music),
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    saved.info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '$platformName · ${saved.tracks.length} tracks · scanned ${timeAgo(saved.lastScannedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete ${saved.info.name}',
              onPressed: onDelete,
            ),
          ],
        ),
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
        platform.linkNeedsAuth
            ? 'Connect ${platform.displayName} to browse your playlists. Pasted links need your ${platform.displayName} session too.'
            : 'Connect ${platform.displayName} to browse your playlists, or paste a link below. No sign-in needed.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    if (!platform.requiresAuthForLibrary) {
      return Text(
        '${platform.displayName} has no sign-in here. Paste a public '
        'playlist link below.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final playlists = ref.watch(userPlaylistsProvider);
    return playlists.when(
      data: (list) {
        if (list.isEmpty) {
          return Text(
            platform.id == PlatformIds.spotify
                ? 'Spotify imports work from pasted links. Paste one below.'
                : 'No playlists found.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return SizedBox(
          // Square covers (104x104) plus two label lines: 104 + 4
          // + name + count.
          height: 144,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final p = list[i];
              return InkWell(
                onTap: () => onPick(p),
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 104,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: p.coverUrl != null
                            ? Image.network(p.coverUrl!,
                                width: 104, height: 104, fit: BoxFit.cover)
                            : Container(
                                width: 104,
                                height: 104,
                                color: Theme.of(context).colorScheme.surface,
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
      loading: () => const EditorialLoadingState(
        message: 'Loading your playlists',
      ),
      error: (e, _) => EditorialErrorState(
        message: e is PlatformException
            ? e.message
            : 'Could not load playlists. Check your connection and retry.',
        onRetry: () => ref.invalidate(userPlaylistsProvider),
      ),
    );
  }
}
