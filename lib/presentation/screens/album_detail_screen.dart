// Album detail (FR-11b): large art header, track list with "Recommended"
// badges on the recommended tracks, per-track hearts and outbound links.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../widgets/favorite_button.dart';
import '../widgets/outbound_sheet.dart';

class AlbumDetailScreen extends ConsumerWidget {
  final AlbumRec album;

  const AlbumDetailScreen({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final recommendedKeys = {
      for (final s in album.songs)
        RecommendationEngine.normalizeKey(s.track.artist, s.track.title)
    };
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(album.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              background: album.artUrl != null && album.artUrl!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: album.artUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          const Icon(Icons.album_outlined, size: 96),
                    )
                  : const Icon(Icons.album_outlined, size: 96),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(album.artist, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    album.songCount > 0
                        ? '${album.songCount} recommended tracks on this album'
                        : 'Surprise album pick',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => showAlbumOutboundSheet(
                        context, album.artist, album.name),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open album in…'),
                  ),
                ],
              ),
            ),
          ),
          if (album.songs.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Track listing unavailable for this surprise pick — '
                  'open it in Spotify or Deezer to explore.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final track = album.songs[i].track;
                  final isRec = recommendedKeys.contains(
                      RecommendationEngine.normalizeKey(
                          track.artist, track.title));
                  return ListTile(
                    leading: Text('${i + 1}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    title: Text(track.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: isRec
                        ? Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('Recommended',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme
                                        .colorScheme.onPrimaryContainer)),
                          )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FavoriteButton(track: track),
                        _PreviewButton(track: track),
                        IconButton(
                          icon: const Icon(Icons.open_in_new),
                          tooltip: 'Open in…',
                          onPressed: () => showOutboundSheet(context, track),
                        ),
                      ],
                    ),
                  );
                },
                childCount: album.songs.length,
              ),
            ),
        ],
      ),
    );
  }
}

/// Play/pause button for a 30-second track preview (iTunes preview URL).
/// Uses a shared audio player so only one preview plays at a time.
class _PreviewButton extends ConsumerWidget {
  final Track track;

  const _PreviewButton({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the player state (not just read the notifier) so the icon
    // rebuilds on play / pause / resolve transitions.
    final playerState = ref.watch(audioPlayerProvider);
    final player = ref.read(audioPlayerProvider.notifier);
    // Same normalization as the player and the fallback layer, so the
    // playing key matches even for remaster-suffixed titles.
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    final isPlaying = playerState.valueOrNull == key;
    final isResolving =
        playerState is AsyncLoading && player.resolvingKey == key;

    // Always tappable: a tap on a preview-less track runs the on-demand
    // iTunes lookup in AudioPlayerNotifier instead of doing nothing.
    if (isResolving) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return IconButton(
      icon: Icon(isPlaying ? Icons.pause : Icons.play_circle_outline,
          color: isPlaying ? Theme.of(context).colorScheme.primary : null),
      tooltip: isPlaying ? 'Pause preview' : 'Play preview',
      onPressed: () => player.play(track),
    );
  }
}
