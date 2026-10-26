// Results screen (S-05): Songs / Albums tabs over a GenerationResult.
// Hearts persist to the favorites repo (FR-12); album art fills in lazily
// via track.getInfo (FR-11); outbound links need no OAuth (v1).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../../data/enrichment/enrichment_models.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/favorite_button.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/youtube_export_sheet.dart';
import 'album_detail_screen.dart';

/// Session cache for lazily fetched album art (FR-11): key → image URL
/// (null = looked up, none found).
final _albumArtCacheProvider =
    StateProvider<Map<String, String?>>((ref) => {});

String _albumCacheKey(String artist, String album) =>
    '${artist.toLowerCase().trim()}|${album.toLowerCase().trim()}';

class ResultsScreen extends ConsumerWidget {
  final GenerationResult result;

  const ResultsScreen({super.key, required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(result.seedName),
          actions: [
            if (result.songs.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.playlist_add_outlined),
                tooltip: 'Export to YouTube',
                onPressed: () => showYouTubeExportSheet(
                    context, ref, [for (final s in result.songs) s.track]),
              ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Songs'),
            Tab(text: 'Albums'),
          ]),
        ),
        body: Column(
          children: [
            _statsBar(theme),
            if (result.sparseExplanation != null)
              _sparseBanner(theme, result.sparseExplanation!),
            Expanded(
              child: TabBarView(
                children: [
                  _songsTab(ref),
                  _albumsTab(ref),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsBar(ThemeData theme) {
    final parts = <String>[
      '${result.songs.length} songs',
      '${result.albums.length} albums',
    ];
    if (!result.isSurprise) {
      parts.add('${result.seedCount} seeds');
      if (result.skippedSeeds > 0) {
        parts.add('${result.skippedSeeds} seeds had no match data');
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        parts.join(' • '),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// Sparse-result explanation (Phase 1): when the sources ran dry
  /// and the list came up short, say why instead of silently showing
  /// few songs. Existing dark Material 3 styling, no redesign.
  Widget _sparseBanner(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outlined,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _songsTab(WidgetRef ref) {
    if (result.songs.isEmpty) {
      return const _EmptyState(
        icon: Icons.music_off_outlined,
        message: 'No songs found. Try a larger or more mainstream playlist.',
      );
    }
    return ListView.builder(
      itemCount: result.songs.length,
      itemBuilder: (ctx, i) {
        final scored = result.songs[i];
        final enrichment = result.enrichments[
            RecommendationEngine.normalizeKey(
                scored.track.artist, scored.track.title)];
        return _SongRow(
            rank: i + 1, scored: scored, enrichment: enrichment);
      },
    );
  }

  Widget _albumsTab(WidgetRef ref) {
    if (result.albums.isEmpty) {
      return const _EmptyState(
        icon: Icons.album_outlined,
        message: 'Not enough album data for these songs.',
      );
    }
    return ListView.builder(
      itemCount: result.albums.length,
      itemBuilder: (ctx, i) {
        final album = result.albums[i];
        final enrichment = result.albumEnrichments[
            albumEnrichmentKey(album.artist, album.name)];
        return _AlbumCard(album: album, enrichment: enrichment);
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

class _SongRow extends StatelessWidget {
  final int rank;
  final ScoredTrack scored;

  /// MusicBrainz annotation for this track, if any.
  final TrackEnrichment? enrichment;

  const _SongRow(
      {required this.rank, required this.scored, this.enrichment});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = scored.track;
    final reason = scored.reasons.length >= 2
        ? 'Because you liked ${scored.reasons[0]} and ${scored.reasons[1]}'
        : (scored.reasons.isNotEmpty ? scored.reasons.first : null);
    // Honest MusicBrainz line; never presented as Last.fm data.
    String? enrichmentLine;
    final e = enrichment;
    if (e != null && !e.isEmpty) {
      if (e.tags.isNotEmpty) {
        enrichmentLine = 'MusicBrainz: ${e.tags.take(3).join(', ')}';
      } else if (e.releaseYear != null) {
        enrichmentLine = 'MusicBrainz release: ${e.releaseYear}';
      }
    }
    return ListTile(
      leading: SizedBox(
        width: 32,
        child: Text('$rank',
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center),
      ),
      title: Text(track.title,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(track.artist,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (reason != null)
            Text(reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                    fontStyle: FontStyle.italic)),
          if (enrichmentLine != null)
            Text(enrichmentLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
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

/// Heart toggle persisted to the favorites repo (FR-12).
class _AlbumCard extends ConsumerWidget {
  final AlbumRec album;

  /// Discogs annotation for this album, if enrichment found one.
  final AlbumEnrichment? enrichment;

  const _AlbumCard({required this.album, this.enrichment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Honest Discogs line: year, styles, community rating. Never
    // presented as Last.fm data.
    String? enrichmentLine;
    final e = enrichment;
    if (e != null && !e.isEmpty && e.sources.contains('Discogs')) {
      final parts = <String>[];
      if (e.year != null) parts.add('${e.year}');
      if (e.styles.isNotEmpty) parts.add(e.styles.take(2).join(', '));
      if (e.communityRating != null) {
        final rating = '★ ${e.communityRating!.toStringAsFixed(1)}';
        parts.add(e.ratingCount != null
            ? '$rating (${e.ratingCount})'
            : rating);
      }
      if (parts.isNotEmpty) {
        enrichmentLine = 'Discogs: ${parts.join(' • ')}';
      }
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => AlbumDetailScreen(album: album)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _AlbumArt(album: album, size: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(album.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(album.artist,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    if (album.songCount > 0)
                      _badge(theme, '${album.songCount} recommended tracks')
                    else
                      _badge(theme, 'Surprise pick'),
                    if (enrichmentLine != null) ...[
                      const SizedBox(height: 4),
                      Text(enrichmentLine,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FavoriteAlbumButton(album: album),
                  IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Open album in…',
                    onPressed: () => showAlbumOutboundSheet(
                        context, album.artist, album.name),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(ThemeData theme, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
      );
}

/// Album art with lazy Last.fm fill (FR-11): shows cached art, else fetches
/// track.getInfo for the top recommended song once and caches the result.
class _AlbumArt extends ConsumerStatefulWidget {
  final AlbumRec album;
  final double size;

  const _AlbumArt({required this.album, required this.size});

  @override
  ConsumerState<_AlbumArt> createState() => _AlbumArtState();
}

class _AlbumArtState extends ConsumerState<_AlbumArt> {
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    if (widget.album.artUrl == null || widget.album.artUrl!.isEmpty) {
      _fetching = true;
      Future.microtask(_fetchArt);
    }
  }

  Future<void> _fetchArt() async {
    final key = _albumCacheKey(widget.album.artist, widget.album.name);
    final cache = ref.read(_albumArtCacheProvider);
    if (cache.containsKey(key)) {
      if (mounted) setState(() => _fetching = false);
      return;
    }
    String? url;
    try {
      if (widget.album.songs.isNotEmpty) {
        final top = widget.album.songs.first.track;
        final client =
            LastFmClient(dio: ref.read(dioProvider), apiKey: lastFmApiKey);
        final info = await client.getTrackInfo(top.artist, top.title);
        url = info.imageUrl;
      }
    } catch (_) {
      url = null; // art stays a placeholder; never breaks the card
    }
    ref.read(_albumArtCacheProvider.notifier).state = {...cache, key: url};
    if (mounted) setState(() => _fetching = false);
  }

  @override
  Widget build(BuildContext context) {
    final key = _albumCacheKey(widget.album.artist, widget.album.name);
    final cached = ref.watch(_albumArtCacheProvider)[key];
    final url = (widget.album.artUrl?.isNotEmpty ?? false)
        ? widget.album.artUrl
        : cached;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: url != null && url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator()),
                errorWidget: (_, __, ___) =>
                    const Icon(Icons.album_outlined, size: 40),
              )
            : _fetching
                ? const Center(
                    child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : const Icon(Icons.album_outlined, size: 40),
      ),
    );
  }
}
