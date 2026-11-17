// Album detail (FR-11b, DESIGN.md): art header, album name and
// artist, track list with "Recommended" on the recommended tracks,
// per-track heart, "Open in platform".
//
// The tracklist is the WHOLE album, fetched from Last.fm
// album.getInfo when the screen opens (Group 4, part 1) and cached
// in Hive for 30 days, so reopening does not refetch. Recommended
// tracks are badged "Recommended" and play; every other track is a
// name-only row: it has no playable Track object, so it shows its
// name (and duration when Last.fm reports one) with no play
// affordance, muted, and no gestures. Surprise albums get a
// tracklist the same way: they no longer open empty.
//
// States (R-27): the recommended tracks already in hand show at
// once with a loading line while the full list fetches; a failed
// fetch keeps them and shows an error with Retry; an album with no
// tracklist anywhere shows an honest empty state.
//
// Recommended rows are EditorialSongRow with the SAME interactions
// as result songs: tap to play, fast double-tap to like inside the
// 250 ms window, swipe quick actions, long-press context sheet.
// The cover resolves with the shared chain (album art, enrichment
// art, enrichment artist thumb, lazy Last.fm art on the first
// song), so Favorites entries get covers too.
//
// Complex adds a notes line (the Discogs annotation, only when
// enrichment actually found one) and larger art.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../../data/models/music_models.dart';
import '../providers/providers.dart';
import '../widgets/album_art.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_row.dart';
import '../widgets/undo_snackbar.dart';

class AlbumDetailScreen extends ConsumerStatefulWidget {
  final AlbumRec album;

  /// Discogs / TheAudioDB annotation for this album, when the
  /// results screen had one. Null when opened from elsewhere
  /// (Favorites) or when no enrichment was found. Favorites has no
  /// enrichment source to pass: its covers come from the shared
  /// cover chain's lazy Last.fm step instead.
  final AlbumEnrichment? enrichment;

  const AlbumDetailScreen({super.key, required this.album, this.enrichment});

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

/// One row of the merged tracklist: either a recommended track
/// (playable, with its ScoredTrack) or a name-only album track.
class _MergedRow {
  final ScoredTrack? scored;
  final AlbumTrack? listed;
  final String title;
  final String artist;
  final int? durationMs;

  const _MergedRow._({
    this.scored,
    this.listed,
    required this.title,
    required this.artist,
    this.durationMs,
  });

  factory _MergedRow.recommended(ScoredTrack scored, AlbumTrack? listed) =>
      _MergedRow._(
        scored: scored,
        listed: listed,
        title: scored.track.title,
        artist: scored.track.artist,
        durationMs: listed?.durationMs ?? scored.track.durationMs,
      );

  factory _MergedRow.nameOnly(AlbumTrack listed, String artist) =>
      _MergedRow._(
        listed: listed,
        title: listed.name,
        artist: artist,
        durationMs: listed.durationMs,
      );

  bool get isRecommended => scored != null;
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _tracklistExpanded = true;
  bool _popping = false;
  Timer? _tapTimer;
  Timer? _popTimer;
  DateTime? _lastTap;

  /// Full album tracklist from Last.fm. Null while the fetch is in
  /// flight; an empty list means Last.fm has no tracklist (or a
  /// cached miss), not a failure.
  List<AlbumTrack>? _fetched;

  /// True when the fetch failed. The recommended tracks stay
  /// visible and the error carries a Retry.
  bool _failed = false;

  /// Guards a late fetch against a newer one (Retry).
  int _fetchSeq = 0;

  /// Recommended rows the user removed with the swipe Remove
  /// action, by normalized artist+title and by title alone (the
  /// fetched list may credit the track to the album artist).
  /// Hidden for this view only; the album is untouched.
  final _dismissedKeys = <String>{};
  final _dismissedTitles = <String>{};

  @override
  void initState() {
    super.initState();
    _loadTracklist();
  }

  Future<void> _loadTracklist() async {
    final seq = ++_fetchSeq;
    final service = ref.read(albumTracklistServiceProvider);
    List<AlbumTrack> tracks;
    try {
      tracks =
          await service.getTracklist(widget.album.artist, widget.album.name);
    } catch (_) {
      if (!mounted || seq != _fetchSeq) return;
      setState(() => _failed = true);
      return;
    }
    if (!mounted || seq != _fetchSeq) return;
    setState(() {
      _fetched = tracks;
      _failed = false;
    });
  }

  void _retryTracklist() {
    setState(() {
      _failed = false;
      _fetched = null;
    });
    _loadTracklist();
  }

  bool _isDismissed(String artist, String title) =>
      _dismissedKeys.contains(
          RecommendationEngine.normalizeKey(artist, title)) ||
      _dismissedTitles.contains(title.toLowerCase().trim());

  /// Recommended tracks still visible in this view.
  List<ScoredTrack> get _visibleRecommended => [
        for (final s in widget.album.songs)
          if (!_isDismissed(s.track.artist, s.track.title)) s,
      ];

  /// The merged tracklist: the fetched album order, with the
  /// recommended tracks badged in place; recommended tracks Last.fm
  /// did not list are kept at the end, still badged and playable.
  /// Before the fetch lands (or when there is no tracklist) this is
  /// just the recommended tracks.
  List<_MergedRow> _mergedRows() {
    final recs = _visibleRecommended;
    final fetched = _fetched;
    if (fetched == null || fetched.isEmpty) {
      return [for (final s in recs) _MergedRow.recommended(s, null)];
    }
    final recByKey = {
      for (final s in recs)
        RecommendationEngine.normalizeKey(s.track.artist, s.track.title): s,
    };
    final recByTitle = {
      for (final s in recs) s.track.title.toLowerCase().trim(): s,
    };
    final used = <ScoredTrack>{};
    final rows = <_MergedRow>[];
    for (final t in fetched) {
      final artist =
          t.artist.trim().isEmpty ? widget.album.artist : t.artist;
      if (_isDismissed(artist, t.name)) continue;
      final rec = recByKey[RecommendationEngine.normalizeKey(
              artist, t.name)] ??
          recByTitle[t.name.toLowerCase().trim()];
      if (rec != null) {
        used.add(rec);
        rows.add(_MergedRow.recommended(rec, t));
      } else {
        rows.add(_MergedRow.nameOnly(t, artist));
      }
    }
    for (final s in recs) {
      if (!used.contains(s)) rows.add(_MergedRow.recommended(s, null));
    }
    return rows;
  }

  /// Swipe Remove on a recommended row: hide the row for this view,
  /// with an Undo toast that restores it.
  void _removeRecommended(ScoredTrack scored) {
    final track = scored.track;
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    setState(() {
      _dismissedKeys.add(key);
      _dismissedTitles.add(track.title.toLowerCase().trim());
    });
    showUndoSnackBar(
      context,
      message: 'Removed ${track.title} from this album view',
      onUndo: () {
        if (mounted) {
          setState(() {
            _dismissedKeys.remove(key);
            _dismissedTitles.remove(track.title.toLowerCase().trim());
          });
        }
      },
    );
  }

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
    final notesLine = _notesLine();
    final micro = tokens?.micro ?? Duration.zero;
    final rows = _mergedRows();
    final recCount = rows.where((r) => r.isRecommended).length;
    final playableQueue = [
      for (final r in rows)
        if (r.scored != null) r.scored!.track,
    ];
    final fetched = _fetched;
    final String countLine;
    if (fetched != null && fetched.isNotEmpty) {
      countLine = recCount > 0
          ? '${rows.length} tracks, $recCount recommended'
          : '${rows.length} tracks';
    } else if (album.songs.isNotEmpty) {
      countLine = album.songCount > 0
          ? '${album.songCount} recommended tracks on this album'
          : 'Surprise album pick';
    } else {
      countLine = 'Surprise album pick';
    }
    // The square is sized so the header (AppBar plus art) stays
    // near the old band height: a 240 square plus the AppBar would
    // push the tracklist's Retry below the fold on a short screen.
    final artSize = math.min(
      isComplex ? 280.0 : 200.0,
      MediaQuery.sizeOf(context).width - 32,
    );
    return Scaffold(
      // The art is a square block, not a full-bleed app bar: the old
      // wide SliverAppBar band cropped a square cover into a thin
      // strip. Complex gets the bigger square (bigger covers per
      // DESIGN.md), capped at the screen width minus padding.
      appBar: AppBar(
        title:
            Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: SizedBox(
                  width: artSize,
                  height: artSize,
                  child: GestureDetector(
                    onTap: _handleArtTap,
                    child: Stack(
                      children: [
                        AlbumArtImage(
                          album: album,
                          enrichment: widget.enrichment,
                          width: double.infinity,
                          height: double.infinity,
                          placeholderIconSize: 96,
                        ),
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
                    countLine,
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
          ..._tracklistSlivers(rows, playableQueue, isComplex),
        ],
      ),
    );
  }

  /// The tracklist area: loading, error, empty, or the merged list.
  /// The recommended tracks already in hand show at once while the
  /// full list fetches; a failed fetch never hides them.
  List<Widget> _tracklistSlivers(
    List<_MergedRow> rows,
    List<Track> playableQueue,
    bool isComplex,
  ) {
    if (!_tracklistExpanded) {
      final count =
          _fetched != null ? rows.length : widget.album.songs.length;
      return [
        SliverToBoxAdapter(
          child: Center(
            child: TextButton(
              onPressed: () => setState(() => _tracklistExpanded = true),
              child: Text('Show tracks ($count)'),
            ),
          ),
        ),
      ];
    }
    if (_fetched == null && !_failed) {
      // Still fetching: recommended rows now, loading line below
      // them; a surprise album has no rows yet, so the loading
      // state stands alone.
      return [
        if (rows.isNotEmpty) _rowsSliver(rows, playableQueue, isComplex),
        const SliverToBoxAdapter(
          child: EditorialLoadingState(message: 'Loading full tracklist'),
        ),
      ];
    }
    if (_failed) {
      return [
        if (rows.isNotEmpty) _rowsSliver(rows, playableQueue, isComplex),
        SliverToBoxAdapter(
          child: EditorialErrorState(
            message: 'Could not load the full tracklist. '
                'Check your connection and retry.',
            onRetry: _retryTracklist,
          ),
        ),
      ];
    }
    if (rows.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: EditorialEmptyState(
            message: 'No track listing available for this album. '
                'Open it in platform to explore.',
          ),
        ),
      ];
    }
    return [_rowsSliver(rows, playableQueue, isComplex)];
  }

  Widget _rowsSliver(
    List<_MergedRow> rows,
    List<Track> playableQueue,
    bool isComplex,
  ) {
    final album = widget.album;
    final fallbackArt = albumArtFallbackUrl(album, widget.enrichment);
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) {
          final row = rows[i];
          final scored = row.scored;
          if (scored == null) {
            // Name-only album track: display only, no play gesture,
            // no heart, no overflow. Muted text and no cover thumb
            // make clear it is not playable.
            return _NameOnlyRow(
              rank: i + 1,
              title: row.title,
              artist: row.artist == album.artist ? null : row.artist,
              durationMs: row.durationMs,
            );
          }
          final track = scored.track;
          return EditorialSongRow(
            rank: i + 1,
            track: track,
            queue: playableQueue,
            reason: 'Recommended',
            onOverflow: () => showSongActionsSheet(context, track),
            doubleTapToLike: true,
            swipeActionsEnabled: true,
            onRemove: () => _removeRecommended(scored),
            fallbackImageUrl: fallbackArt,
            meta: isComplex && row.durationMs != null
                ? _formatDuration(row.durationMs!)
                : null,
          );
        },
        childCount: rows.length,
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

/// A name-only album track: the track name, the artist only when it
/// differs from the album artist, and the duration when Last.fm
/// reports one. Plain muted text with no cover, no heart, and no
/// gesture: there is nothing to play, so nothing pretends there is.
class _NameOnlyRow extends StatelessWidget {
  final int rank;
  final String title;
  final String? artist;
  final int? durationMs;

  const _NameOnlyRow({
    required this.rank,
    required this.title,
    this.artist,
    this.durationMs,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final artist = this.artist;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (artist != null)
                  Text(
                    artist,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (durationMs != null)
            Text(
              _formatDuration(durationMs!),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

String _formatDuration(int durationMs) {
  final d = Duration(milliseconds: durationMs);
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
