// Album detail (FR-11b): large art header, track list with "Recommended"
// badges on the recommended tracks, per-track hearts and outbound links.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/engine/recommendation_engine.dart';
import '../widgets/favorite_button.dart';
import '../widgets/outbound_sheet.dart';

class AlbumDetailScreen extends StatelessWidget {
  final AlbumRec album;

  const AlbumDetailScreen({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
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
