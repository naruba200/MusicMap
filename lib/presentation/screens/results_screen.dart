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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../../data/enrichment/enrichment_models.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/editorial_route.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/favorite_button.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/song_row.dart';
import '../widgets/youtube_export_sheet.dart';
import 'album_detail_screen.dart';
import 'lyrics_screen.dart';
import 'why_this_song_screen.dart';

/// Session cache for lazily fetched album art (FR-11): key → image URL
/// (null = looked up, none found).
final _albumArtCacheProvider =
    StateProvider<Map<String, String?>>((ref) => {});

String _albumCacheKey(String artist, String album) =>
    '${artist.toLowerCase().trim()}|${album.toLowerCase().trim()}';

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
        if (_filter == null || bucketFor(result.songs[i]) == _filter)
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
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final (rank, scored) = entries[i];
        final enrichment = result.enrichments[
            RecommendationEngine.normalizeKey(
                scored.track.artist, scored.track.title)];
        return EditorialSongRow(
          rank: rank + 1,
          track: scored.track,
          queue: queue,
          reason: reasonLineFor(scored).isEmpty
              ? null
              : reasonLineFor(scored),
          onReasonTap: () => Navigator.of(context).push(
            editorialRoute(
              context,
              (_) => WhyThisSongScreen(scored: scored),
            ),
          ),
          onOverflow: () => _showSongActions(context, scored),
          doubleTapToLike: true,
          meta: isComplex ? _trackMeta(scored, enrichment) : null,
          coverSize: isComplex ? 56 : 48,
        );
      },
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

  /// Overflow sheet: the row actions that used to sit on the row
  /// itself (Lyrics, Open in), plus Why this song, the same sheet
  /// the long-press opens (DESIGN.md).
  void _showSongActions(BuildContext context, ScoredTrack scored) {
    final track = scored.track;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.lyrics_outlined),
              title: const Text('Lyrics'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  editorialRoute(
                    context,
                    (_) => LyricsScreen(track: track),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open in…'),
              onTap: () {
                Navigator.pop(ctx);
                showOutboundSheet(context, track);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outlined),
              title: const Text('Why this song'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  editorialRoute(
                    context,
                    (_) => WhyThisSongScreen(scored: scored),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _albumsTab(GenerationResult result) {
    if (result.albums.isEmpty) {
      return const EditorialEmptyState(
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

/// Cover-led album card (DESIGN.md: Results Albums tab). Tap opens
/// the album detail; the heart likes the album, the open button
/// reaches the platforms.
class _AlbumCard extends ConsumerWidget {
  final AlbumRec album;

  /// Discogs annotation for this album, if enrichment found one.
  final AlbumEnrichment? enrichment;

  const _AlbumCard({required this.album, this.enrichment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    // the card art itself comes from TheAudioDB (see _AlbumArt).
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(tokens?.cardRadius ?? 4),
        boxShadow: isComplex ? (tokens?.raisedShadow ?? const []) : const [],
      ),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(tokens?.cardRadius ?? 4),
        onTap: () => Navigator.of(context).push(
          editorialRoute(
            context,
            (_) =>
                AlbumDetailScreen(album: album, enrichment: enrichment),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _AlbumArt(
                  album: album, size: 72, enrichment: enrichment),
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
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
      );
}

/// Album art with lazy Last.fm fill (FR-11): shows cached art, else fetches
/// track.getInfo for the top recommended song once and caches the result.
/// TheAudioDB art (Phase 2, step 3) is the last fallback, after Last.fm:
/// generation-time Last.fm art wins, and when enrichment art exists the
/// lazy fetch is skipped so the card shows art immediately.
class _AlbumArt extends ConsumerStatefulWidget {
  final AlbumRec album;
  final double size;

  /// TheAudioDB annotation for this album, if enrichment found one.
  final AlbumEnrichment? enrichment;

  const _AlbumArt(
      {required this.album, required this.size, this.enrichment});

  @override
  ConsumerState<_AlbumArt> createState() => _AlbumArtState();
}

class _AlbumArtState extends ConsumerState<_AlbumArt> {
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    final enrichArt = widget.enrichment?.artUrl;
    final enrichThumb = widget.enrichment?.artistThumbUrl;
    final hasEnrichArt =
        (enrichArt != null && enrichArt.isNotEmpty) ||
            (enrichThumb != null && enrichThumb.isNotEmpty);
    if ((widget.album.artUrl == null || widget.album.artUrl!.isEmpty) &&
        !hasEnrichArt) {
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
        : cached ??
            widget.enrichment?.artUrl ??
            widget.enrichment?.artistThumbUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
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
