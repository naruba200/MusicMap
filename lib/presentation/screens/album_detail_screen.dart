// Album detail (FR-11b, DESIGN.md): art header, album name and
// artist, track list with "Recommended" on the recommended tracks,
// per-track heart, "Open in platform". Track rows use
// EditorialSongRow with doubleTapToLike false, so a tap plays
// immediately, like a playlist row.
//
// The art header follows the album-cover gesture map: a single tap
// expands or collapses the tracklist inline (after the 250 ms
// double-tap window, so a double-tap never toggles it first), a
// double-tap likes the album (heart pop plus a haptic tick).
//
// Complex adds a notes line (the Discogs annotation, only when
// enrichment actually found one) and larger art.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../providers/providers.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_row.dart';
import '../widgets/undo_snackbar.dart';

class AlbumDetailScreen extends ConsumerStatefulWidget {
  final AlbumRec album;

  /// Discogs / TheAudioDB annotation for this album, when the
  /// results screen had one. Null when opened from elsewhere
  /// (Favorites) or when no enrichment was found.
  final AlbumEnrichment? enrichment;

  const AlbumDetailScreen({super.key, required this.album, this.enrichment});

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _tracklistExpanded = true;
  bool _popping = false;
  Timer? _tapTimer;
  Timer? _popTimer;
  DateTime? _lastTap;

  @override
  void dispose() {
    _tapTimer?.cancel();
    _popTimer?.cancel();
    super.dispose();
  }

  void _handleArtTap() {
    final now = DateTime.now();
    if (_lastTap != null &&
        now.difference(_lastTap!).inMilliseconds <=
            kDoubleTapLikeWindow.inMilliseconds) {
      _tapTimer?.cancel();
      _tapTimer = null;
      _lastTap = null;
      _likeAlbum();
      return;
    }
    _lastTap = now;
    _tapTimer?.cancel();
    _tapTimer = Timer(kDoubleTapLikeWindow, () {
      _tapTimer = null;
      _lastTap = null;
      if (mounted) setState(() => _tracklistExpanded = !_tracklistExpanded);
    });
  }

  void _likeAlbum() {
    final repo = ref.read(favoritesRepositoryProvider);
    final nowFav = repo.toggleAlbum(widget.album);
    ref.read(favoritesVersionProvider.notifier).state++;
    HapticFeedback.lightImpact();
    final micro = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.micro ??
        Duration.zero;
    setState(() => _popping = true);
    _popTimer?.cancel();
    _popTimer = Timer(
      micro + const Duration(milliseconds: 600),
      () {
        if (mounted) setState(() => _popping = false);
      },
    );
    showUndoSnackBar(
      context,
      message: nowFav ? 'Added to favorites' : 'Removed from favorites',
      onUndo: () {
        repo.toggleAlbum(widget.album);
        ref.read(favoritesVersionProvider.notifier).state++;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    final isComplex = tokens?.design == AppDesign.complex;
    final recommendedKeys = {
      for (final s in album.songs)
        RecommendationEngine.normalizeKey(s.track.artist, s.track.title)
    };
    final notesLine = _notesLine();
    final micro = tokens?.micro ?? Duration.zero;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: isComplex ? 360 : 240,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(album.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              background: GestureDetector(
                onTap: _handleArtTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    album.artUrl != null && album.artUrl!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: album.artUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                const Icon(Icons.album_outlined, size: 96),
                          )
                        : const Icon(Icons.album_outlined, size: 96),
                    if (_popping)
                      Center(
                        child: AnimatedScale(
                          scale: 1,
                          duration: micro,
                          curve: Curves.easeOut,
                          child: Icon(
                            Icons.favorite,
                            size: 72,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
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
                  if (isComplex && notesLine != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      notesLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => showAlbumOutboundSheet(
                        context, album.artist, album.name),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open in platform'),
                  ),
                ],
              ),
            ),
          ),
          if (album.songs.isEmpty)
            const SliverToBoxAdapter(
              child: EditorialEmptyState(
                message: 'Track listing unavailable for this surprise pick. '
                    'Open it in Spotify or Deezer to explore.',
              ),
            )
          else if (!_tracklistExpanded)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton(
                  onPressed: () =>
                      setState(() => _tracklistExpanded = true),
                  child:
                      Text('Show tracks (${album.songs.length})'),
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
                  return EditorialSongRow(
                    rank: i + 1,
                    track: track,
                    queue: [for (final s in album.songs) s.track],
                    reason: isRec ? 'Recommended' : null,
                    onOverflow: () => showSongActionsSheet(context, track),
                    doubleTapToLike: false,
                    meta: isComplex && track.durationMs != null
                        ? _formatDuration(track.durationMs!)
                        : null,
                  );
                },
                childCount: album.songs.length,
              ),
            ),
        ],
      ),
    );
  }

  /// Complex notes line: the honest Discogs annotation (year,
  /// styles, community rating), never presented as Last.fm data.
  /// Null when there is no enrichment to draw on.
  String? _notesLine() {
    final e = widget.enrichment;
    if (e == null || e.isEmpty || !e.sources.contains('Discogs')) {
      return null;
    }
    final parts = <String>[];
    if (e.year != null) parts.add('${e.year}');
    if (e.styles.isNotEmpty) parts.add(e.styles.take(2).join(', '));
    if (e.communityRating != null) {
      final rating = '★ ${e.communityRating!.toStringAsFixed(1)}';
      parts.add(e.ratingCount != null
          ? '$rating (${e.ratingCount})'
          : rating);
    }
    if (parts.isEmpty) return null;
    return 'Discogs: ${parts.join(' • ')}';
  }
}

String _formatDuration(int durationMs) {
  final d = Duration(milliseconds: durationMs);
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
