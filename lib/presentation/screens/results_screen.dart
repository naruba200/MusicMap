// Results screen (S-05/S-06, DESIGN.md): a chart. Songs as a
// numbered list, albums as cover-led cards, tabs Songs / Albums,
// export to YouTube as a text action. Tap a song row plays it after
// the 250 ms double-tap window; a fast second tap likes instead.
// Tap the reason line opens Why this song.
//
// Complex adds a summary header, a filter chips row, and per-track
// meta (year from MusicBrainz enrichment, duration from the track).
// There is no platform field on Track and no year on the track
// itself, so no platform is shown anywhere: only real data.
//
// Hearts persist to the favorites repo (FR-12); album art fills in
// lazily via track.getInfo (FR-11); outbound links need no OAuth (v1).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../../data/enrichment/enrichment_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/album_art.dart';
import '../widgets/editorial_route.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/favorite_button.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_row.dart';
import '../widgets/swipe_action_row.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/youtube_export_sheet.dart';
import 'album_detail_screen.dart';
import 'why_this_song_screen.dart';

/// The reason line shown under a result row, built from the scored
/// reasons exactly as before: the top two contributing seed titles.
String reasonLineFor(ScoredTrack scored) {
  if (scored.reasons.length >= 2) {
    return 'Because you liked ${scored.reasons[0]} and ${scored.reasons[1]}';
  }
  if (scored.reasons.isNotEmpty) return scored.reasons.first;
  return '';
}

/// Which source drove a pick, read off its reason strings (real
/// data only: the engine records seed titles, tag labels, and the
/// "Trending now" marker, nothing else).
enum ReasonBucket { similar, tag, trending }

ReasonBucket bucketFor(ScoredTrack scored) {
  for (final reason in scored.reasons) {
    if (reason == 'Trending now') return ReasonBucket.trending;
  }
  for (final reason in scored.reasons) {
    if (reason.startsWith('Popular in ')) return ReasonBucket.tag;
  }
  return ReasonBucket.similar;
}

String _formatDuration(int durationMs) {
  final d = Duration(milliseconds: durationMs);
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class ResultsScreen extends ConsumerStatefulWidget {
  final GenerationResult result;

  /// When true (the generating flow), the screen follows the live
  /// generation state so background enrichment merges in after the
  /// results-first publish. When false (History and other stored
  /// results), the passed-in snapshot is shown exactly as stored.
  final bool liveEnrichment;

  const ResultsScreen(
      {super.key, required this.result, this.liveEnrichment = false});

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  /// Active Complex filter chip. Null means all songs.
  ReasonBucket? _filter;

  /// Rows the user removed with the swipe Remove action, by
  /// normalized artist+title. Hidden for this results view only;
  /// the underlying generation result is untouched.
  final _dismissedKeys = <String>{};

  /// Swipe Remove on a result row: hide the row for this view,
  /// with an Undo toast that restores it.
  void _removeResult(ScoredTrack scored) {
    final key = RecommendationEngine.normalizeKey(
        scored.track.artist, scored.track.title);
    setState(() => _dismissedKeys.add(key));
    showUndoSnackBar(
      context,
      message: 'Removed ${scored.track.title} from results',
      onUndo: () {
        if (mounted) setState(() => _dismissedKeys.remove(key));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    final isComplex = tokens?.design == AppDesign.complex;
    // Live mode: the provider's latest result for this run (falling
    // back to the published snapshot if the provider has been reset).
    // Stored mode: the snapshot, untouched by any newer generation.
    final result = widget.liveEnrichment
        ? (ref.watch(generationProvider).result ?? widget.result)
        : widget.result;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(result.seedName),
          actions: [
            if (result.songs.isNotEmpty)
              TextButton(
                onPressed: () => showYouTubeExportSheet(
                    context, ref, [for (final s in result.songs) s.track]),
                child: const Text('Save to YouTube'),
              ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Songs'),
            Tab(text: 'Albums'),
          ]),
        ),
        body: Column(
          children: [
            if (isComplex)
              _summaryHeader(theme, result)
            else
              _statsLine(theme, result),
            if (isComplex) _filterChips(theme, result),
            if (result.sparseExplanation != null)
              _sparseBanner(theme, result.sparseExplanation!),
            Expanded(
              child: TabBarView(
                children: [
                  _songsTab(result, isComplex),
                  _albumsTab(result),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact counts line: the same counts as the Complex summary,
  /// as one plain line.
  Widget _statsLine(ThemeData theme, GenerationResult result) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _countsLine(result),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// Complex summary header (DESIGN.md): a raised paper-2 panel
  /// with the 選 stamp, the Picks heading, and the real counts.
  Widget _summaryHeader(ThemeData theme, GenerationResult result) {
    final tokens = theme.extension<MusicManDesignTokens>()!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(tokens.cardRadius),
        boxShadow: tokens.raisedShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            kanji: '選',
            title: 'Picks',
            accentWord: 'おすすめ',
          ),
          const SizedBox(height: 8),
          Text(
            _countsLine(result),
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _countsLine(GenerationResult result) {
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
    return parts.join(' • ');
  }

  /// Complex filter chips (DESIGN.md): one chip per real reason
  /// source, with real counts. A chip with no songs is not shown.
  /// Tapping the active chip again clears the filter.
  Widget _filterChips(ThemeData theme, GenerationResult result) {
    int count(ReasonBucket bucket) =>
        result.songs.where((s) => bucketFor(s) == bucket).length;
    final chips = <(String, ReasonBucket?)>[
      ('All (${result.songs.length})', null),
      if (count(ReasonBucket.similar) > 0)
        ('Similar (${count(ReasonBucket.similar)})', ReasonBucket.similar),
      if (count(ReasonBucket.tag) > 0)
        ('Tag picks (${count(ReasonBucket.tag)})', ReasonBucket.tag),
      if (count(ReasonBucket.trending) > 0)
        ('Trending (${count(ReasonBucket.trending)})',
            ReasonBucket.trending),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, bucket) in chips)
              ChoiceChip(
                label: Text(label),
                selected: _filter == bucket,
                onSelected: (selected) {
                  setState(() {
                    _filter = selected ? bucket : null;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Sparse-result explanation (Phase 1): when the sources ran dry
  /// and the list came up short, say why instead of silently showing
  /// few songs.
  Widget _sparseBanner(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(4),
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

  Widget _songsTab(GenerationResult result, bool isComplex) {
    final entries = <(int, ScoredTrack)>[
      for (var i = 0; i < result.songs.length; i++)
        if ((_filter == null || bucketFor(result.songs[i]) == _filter) &&
            !_dismissedKeys.contains(RecommendationEngine.normalizeKey(
                result.songs[i].track.artist,
                result.songs[i].track.title)))
          (i, result.songs[i]),
    ];
    if (result.songs.isEmpty) {
      return const EditorialEmptyState(
        message:
            'No songs found. Try a larger or more mainstream playlist.',
      );
    }
    if (entries.isEmpty) {
      return const EditorialEmptyState(
        message: 'No songs in this filter. Pick another chip to see more.',
      );
    }
    final queue = [for (final s in result.songs) s.track];
    // Album art per result track (Group 4, part 3): a track with no
    // cover of its own shows its album's art instead. New runs
    // already carry it from deriveAlbums; this covers stored runs
    // whose tracks were saved before the backfill.
    final albumArtByTrack = <String, String?>{};
    for (final album in result.albums) {
      final enrichment = result.albumEnrichments[
          albumEnrichmentKey(album.artist, album.name)];
      final art = albumArtFallbackUrl(album, enrichment);
      for (final s in album.songs) {
        albumArtByTrack.putIfAbsent(
          RecommendationEngine.normalizeKey(
              s.track.artist, s.track.title),
          () => art,
        );
      }
    }
    // Tapping anywhere in the list closes an open swipe row.
    return GestureDetector(
      onTap: SwipeActionRow.closeAnyOpen,
      child: ListView.builder(
        // Rows are built ahead while scrolling so a fling does not
        // decode covers mid-frame; rows have variable height (the
        // meta and reason lines are optional), so no fixed itemExtent.
        scrollCacheExtent: const ScrollCacheExtent.pixels(480),
        itemCount: entries.length,
        itemBuilder: (ctx, i) {
          final (rank, scored) = entries[i];
          final enrichment = result.enrichments[
              RecommendationEngine.normalizeKey(
                  scored.track.artist, scored.track.title)];
          final reason = reasonLineFor(scored);
          void onWhy() => Navigator.of(context).push(
                editorialRoute(
                  context,
                  (_) => WhyThisSongScreen(scored: scored),
                ),
              );
          // Each row paints in its own layer, so a playing-mark
          // tick or a swipe on one row never repaints its neighbors.
          return RepaintBoundary(
            child: EditorialSongRow(
              key: ValueKey('result-track-${RecommendationEngine.normalizeKey(scored.track.artist, scored.track.title)}'),
              rank: rank + 1,
              track: scored.track,
              queue: queue,
              reason: reason.isEmpty ? null : reason,
              onReasonTap: onWhy,
              onOverflow: () => showSongActionsSheet(
                context,
                scored.track,
                reason: reason.isEmpty ? null : reason,
                onShowWhy: onWhy,
              ),
              doubleTapToLike: true,
              meta: isComplex ? _trackMeta(scored, enrichment) : null,
              coverSize: isComplex ? 56 : 48,
              swipeActionsEnabled: true,
              onRemove: () => _removeResult(scored),
              fallbackImageUrl: albumArtByTrack[
                  RecommendationEngine.normalizeKey(
                      scored.track.artist, scored.track.title)],
            ),
          );
        },
      ),
    );
  }

  /// Complex per-track meta (DESIGN.md): year and duration, only
  /// where the data really exists. Year comes from the MusicBrainz
  /// enrichment (top tracks only); duration from the track itself.
  /// Track carries no platform and no year, so neither is invented.
  String? _trackMeta(ScoredTrack scored, TrackEnrichment? enrichment) {
    final parts = <String>[];
    final year = enrichment?.releaseYear;
    if (year != null) parts.add(year);
    final durationMs = scored.track.durationMs;
    if (durationMs != null) parts.add(_formatDuration(durationMs));
    final e = enrichment;
    if (e != null && e.tags.isNotEmpty) {
      parts.add(e.tags.take(3).join(', '));
    }
    if (parts.isEmpty) return null;
    return parts.join(' • ');
  }

  Widget _albumsTab(GenerationResult result) {
    if (result.albums.isEmpty) {
      return const EditorialEmptyState(
        message: 'Not enough album data for these songs.',
      );
    }
    return ListView.builder(
      // Cards are built ahead while scrolling so a fling does not
      // decode covers mid-frame.
      scrollCacheExtent: const ScrollCacheExtent.pixels(480),
      itemCount: result.albums.length,
      itemBuilder: (ctx, i) {
        final album = result.albums[i];
        final enrichment = result.albumEnrichments[
            albumEnrichmentKey(album.artist, album.name)];
        // Each card paints in its own layer, so an expand or a
        // heart pop on one card never repaints its neighbors.
        return RepaintBoundary(child: _AlbumCard(album: album, enrichment: enrichment));
      },
    );
  }
}

/// Cover-led album card (DESIGN.md: Results Albums tab). The cover
/// follows the album-cover gesture map: a single tap expands the
/// tracklist inline (after the 250 ms double-tap window, so a
/// double-tap never expands first), a double-tap likes the album
/// (heart pop plus a haptic tick). The heart likes the album too,
/// and "View album" still opens the album detail screen: the card
/// used to navigate on tap, and that path now lives behind the
/// expand instead.
class _AlbumCard extends ConsumerStatefulWidget {
  final AlbumRec album;

  /// Discogs annotation for this album, if enrichment found one.
  final AlbumEnrichment? enrichment;

  const _AlbumCard({required this.album, this.enrichment});

  @override
  ConsumerState<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends ConsumerState<_AlbumCard> {
  bool _expanded = false;
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

  void _cancelPendingTap() {
    _tapTimer?.cancel();
    _tapTimer = null;
    _lastTap = null;
  }

  void _handleCoverTap() {
    final now = DateTime.now();
    if (_lastTap != null &&
        now.difference(_lastTap!).inMilliseconds <=
            kDoubleTapLikeWindow.inMilliseconds) {
      _cancelPendingTap();
      _likeAlbum();
      return;
    }
    _lastTap = now;
    _tapTimer?.cancel();
    _tapTimer = Timer(kDoubleTapLikeWindow, () {
      _tapTimer = null;
      _lastTap = null;
      setState(() => _expanded = !_expanded);
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
    final enrichment = widget.enrichment;
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    final isComplex = tokens?.design == AppDesign.complex;
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
    // TheAudioDB lines: discography, plus an artwork credit when
    // the card art itself comes from TheAudioDB (see AlbumArtImage).
    String? tadbLine;
    final usesTadbArt = (album.artUrl == null || album.artUrl!.isEmpty) &&
        e != null &&
        ((e.artUrl != null && e.artUrl!.isNotEmpty) ||
            (e.artistThumbUrl != null && e.artistThumbUrl!.isNotEmpty));
    if (e != null &&
        e.sources.contains('TheAudioDB') &&
        e.discography.isNotEmpty) {
      tadbLine = 'More from ${album.artist} (TheAudioDB): '
          '${e.discography.take(3).join(', ')}';
    }
    final micro = tokens?.micro ?? Duration.zero;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(tokens?.cardRadius ?? 4),
        boxShadow: isComplex ? (tokens?.raisedShadow ?? const []) : const [],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius:
                BorderRadius.circular(tokens?.cardRadius ?? 4),
            onTap: _handleCoverTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      AlbumArtImage.square(
                          album: album,
                          size: 72,
                          enrichment: enrichment),
                      if (_popping)
                        AnimatedScale(
                          scale: 1,
                          duration: micro,
                          curve: Curves.easeOut,
                          child: Icon(
                            Icons.favorite,
                            size: 36,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
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
                          _badge(theme,
                              '${album.songCount} songs recommended from this album')
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
                        if (tadbLine != null) ...[
                          const SizedBox(height: 4),
                          Text(tadbLine,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                        if (usesTadbArt) ...[
                          const SizedBox(height: 4),
                          Text('Artwork: TheAudioDB',
                              maxLines: 1,
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
                      GestureDetector(
                        onTapDown: (_) => _cancelPendingTap(),
                        child: FavoriteAlbumButton(album: album),
                      ),
                      GestureDetector(
                        onTapDown: (_) => _cancelPendingTap(),
                        child: IconButton(
                          icon: const Icon(Icons.open_in_new),
                          tooltip: 'Open album in…',
                          onPressed: () => showAlbumOutboundSheet(
                              context, album.artist, album.name),
                        ),
                      ),
                      Icon(_expanded
                          ? Icons.expand_less
                          : Icons.expand_more),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            for (final scored in album.songs)
              // A ListTile paints its ink on the nearest Material
              // ancestor, and the card's decorated Container would
              // hide it: give each row its own Material in the
              // card's surface color so the tap ripple shows.
              Material(
                color: theme.colorScheme.surface,
                child: ListTile(
                  dense: true,
                  title: Text(scored.track.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(scored.track.artist,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.play_arrow, size: 20),
                  onTap: () => ref
                      .read(audioPlayerProvider.notifier)
                      .play(
                        scored.track,
                        queue: [for (final s in album.songs) s.track],
                        albumArtUrl:
                            albumArtFallbackUrl(album, enrichment),
                      ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  editorialRoute(
                    context,
                    (_) => AlbumDetailScreen(
                        album: album, enrichment: enrichment),
                  ),
                ),
                child: const Text('View album'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(ThemeData theme, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
      );
}

