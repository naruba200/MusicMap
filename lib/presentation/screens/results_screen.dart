// Results screen (S-05): Songs / Albums tabs over a GenerationResult.
// Hearts persist to the favorites repo (FR-12); album art fills in lazily
// via track.getInfo (FR-11); outbound links need no OAuth (v1).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
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
        return _SongRow(rank: i + 1, scored: scored);
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
        return _AlbumCard(album: album);
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

  const _SongRow({required this.rank, required this.scored});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = scored.track;
    final reason = scored.reasons.length >= 2
        ? 'Because you liked ${scored.reasons[0]} and ${scored.reasons[1]}'
        : (scored.reasons.isNotEmpty ? scored.reasons.first : null);
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
    final player = ref.read(audioPlayerProvider.notifier);
    final hasPreview = track.previewUrl != null && track.previewUrl!.isNotEmpty;
    final key = '${track.artist.toLowerCase().trim()} - ${track.title.toLowerCase().trim()}';
    final isPlaying = hasPreview && player.playingKey == key;

    if (!hasPreview) {
      return const Icon(
        Icons.audiotrack,
        size: 20,
        color: Colors.grey,
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

  const _AlbumCard({required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
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
