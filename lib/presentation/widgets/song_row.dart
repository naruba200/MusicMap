// The editorial song row (DESIGN.md: Results, Playlist detail).
//
// One ruled list row: rank, cover, title, artist, reason line,
// heart, overflow. The row's job is to play the song, so the tap
// does that; the heart stays for liking, actions stay behind
// overflow, and nothing is lost.
//
// Tap rules (DESIGN.md, rounds 4-6):
// - Results rows (doubleTapToLike: true): a single tap plays after
//   a fast 250 ms window, so a second tap inside the window likes
//   the song instead of playing it. Two taps after the window are
//   two separate plays. The same rule covers the cover thumb, since
//   it is part of the row.
// - Playlist rows (doubleTapToLike: false): a tap plays immediately.
// - A tap on the heart, overflow, or reason line cancels a pending
//   play, so liking or opening actions never starts playback.
//
// Gestures (DESIGN.md, Phase C group 3):
// - Swipe left (swipeActionsEnabled) reveals Like, Add, Remove
//   behind the row; the caller owns what Remove means.
// - Long-press (about 500 ms) then release without moving opens
//   the context sheet; hold then move drags the song onto a
//   playlist via the drop bar. A quick swipe never waits the hold
//   out, so the two gestures do not fight.

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import 'favorite_button.dart';
import 'add_to_playlist_sheet.dart';
import 'song_actions_sheet.dart';
import 'swipe_action_row.dart';
import 'undo_snackbar.dart';

/// The double-tap window (DESIGN.md): short enough that a single-tap
/// play still feels instant, long enough to catch a fast second tap.
const Duration kDoubleTapLikeWindow = Duration(milliseconds: 250);

class EditorialSongRow extends ConsumerStatefulWidget {
  final Track track;

  /// The list the track was played from, so next/previous work.
  final List<Track>? queue;

  /// Chart rank (Results). Null when the list is not ranked.
  final int? rank;

  /// The reason line ("Because you liked X and Y"). Null to hide it.
  final String? reason;

  /// Tapping the reason line opens Why this song. Null when the row
  /// has no reason view.
  final VoidCallback? onReasonTap;

  /// Overflow opens the context sheet. Null to hide the button.
  final VoidCallback? onOverflow;

  /// True on result rows: tap waits out the double-tap window.
  /// False on playlist rows: tap plays immediately.
  final bool doubleTapToLike;

  /// Extra metadata (year, duration, platform) shown under the
  /// artist in Complex. Callers pass it only in Complex.
  final String? meta;

  /// A small per-row state mark shown between the text and the heart
  /// in both designs (for example the YouTube match check on a
  /// playlist row after the Spotify review). Null hides it.
  final Widget? trailingMark;

  /// When true, a left swipe reveals the quick actions (Like, Add
  /// to playlist, Remove). Results and Playlist detail opt in;
  /// Favorites keeps its own Dismissible swipe-to-remove and
  /// Discover opts out, so both leave this false.
  final bool swipeActionsEnabled;

  /// The Remove quick action. Null hides Remove from the swipe
  /// actions. The meaning is the caller's: Results hides the row
  /// for the current view, Playlist detail removes the track from
  /// the saved playlist.
  final VoidCallback? onRemove;

  final double coverSize;

  const EditorialSongRow({
    super.key,
    required this.track,
    this.queue,
    this.rank,
    this.reason,
    this.onReasonTap,
    this.onOverflow,
    this.doubleTapToLike = true,
    this.meta,
    this.trailingMark,
    this.swipeActionsEnabled = false,
    this.onRemove,
    this.coverSize = 48,
  });

  @override
  ConsumerState<EditorialSongRow> createState() => _EditorialSongRowState();
}

class _EditorialSongRowState extends ConsumerState<EditorialSongRow> {
  Timer? _playTimer;
  DateTime? _lastTap;

  /// The playlist drop bar overlay, shown while a drag is in
  /// flight. Null when no drag is running.
  OverlayEntry? _dropBarEntry;

  /// True once a long-press drag has moved. A hold released
  /// without moving opens the context sheet instead of dragging.
  bool _dragMoved = false;

  /// While a drag ran, the row's tap is suppressed: the pointer-up
  /// that ends the drag must not also count as a tap to play.
  /// Cleared a moment after the drag ends.
  bool _suppressTap = false;
  Timer? _suppressTimer;

  @override
  void dispose() {
    _playTimer?.cancel();
    _suppressTimer?.cancel();
    _hideDropBar();
    super.dispose();
  }

  void _cancelPendingPlay() {
    _playTimer?.cancel();
    _playTimer = null;
    _lastTap = null;
  }

  void _play() {
    ref.read(audioPlayerProvider.notifier).play(
          widget.track,
          queue: widget.queue,
        );
  }

  void _like() {
    final repo = ref.read(favoritesRepositoryProvider);
    final nowFav = repo.toggle(widget.track);
    ref.read(favoritesVersionProvider.notifier).state++;
    HapticFeedback.lightImpact();
    showUndoSnackBar(
      context,
      message: nowFav ? 'Added to favorites' : 'Removed from favorites',
      onUndo: () {
        repo.toggle(widget.track);
        ref.read(favoritesVersionProvider.notifier).state++;
      },
    );
  }

  void _handleTap() {
    if (_suppressTap) return;
    if (!widget.doubleTapToLike) {
      _play();
      return;
    }
    final now = DateTime.now();
    if (_lastTap != null &&
        now.difference(_lastTap!).inMilliseconds <=
            kDoubleTapLikeWindow.inMilliseconds) {
      _cancelPendingPlay();
      _like();
      return;
    }
    _lastTap = now;
    _playTimer?.cancel();
    _playTimer = Timer(kDoubleTapLikeWindow, () {
      _playTimer = null;
      _lastTap = null;
      _play();
    });
  }

  // -- Long-press drag to a playlist (DESIGN.md) --------------------
  //
  // One LongPressDraggable per row disambiguates the hold from the
  // drag: the drag starts after about 500 ms held still
  // (LongPressDraggable's default delay). A hold released without
  // moving opens the context sheet; a hold followed by movement is
  // the drag, and the drop bar appears. A quick swipe never waits
  // the 500 ms out, so the swipe quick actions win that arena
  // instead. The pick-up tick comes from LongPressDraggable itself
  // (hapticFeedbackOnStart); the drop tick is in the drop bar.

  void _onDragStarted() {
    _cancelPendingPlay();
    _dragMoved = false;
    _suppressTap = true;
    _showDropBar();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragMoved = true;
  }

  void _onDragEnd(DraggableDetails details) {
    _hideDropBar();
    _suppressTimer?.cancel();
    _suppressTimer = Timer(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
    if (!_dragMoved && !details.wasAccepted && mounted) {
      showSongActionsSheet(
        context,
        widget.track,
        reason: widget.reason,
        onShowWhy: widget.onReasonTap,
      );
    }
  }

  void _onDragCanceled(Velocity velocity, Offset offset) {
    _hideDropBar();
    _suppressTimer?.cancel();
    _suppressTimer = Timer(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
  }

  void _showDropBar() {
    if (_dropBarEntry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _dropBarEntry = OverlayEntry(
      builder: (overlayContext) =>
          _PlaylistDropBar(track: widget.track),
    );
    overlay.insert(_dropBarEntry!);
  }

  void _hideDropBar() {
    _dropBarEntry?.remove();
    _dropBarEntry = null;
  }

  /// The swipe quick actions for this row: Like toggles the
  /// favorite, Add opens the shared add-to-playlist sheet, Remove
  /// is the caller's removal (hidden when the caller passes none).
  List<SwipeAction> _swipeActions() {
    final repo = ref.read(favoritesRepositoryProvider);
    final isFav = repo.isFavorite(widget.track.artist, widget.track.title);
    final onRemove = widget.onRemove;
    return [
      SwipeAction(
        label: 'Like',
        icon: isFav ? Icons.favorite : Icons.favorite_outline,
        onTap: _like,
      ),
      SwipeAction(
        label: 'Add',
        icon: Icons.playlist_add,
        onTap: () async {
          final result =
              await showAddToPlaylistSheet(context, widget.track);
          if (result == null || !mounted) return;
          if (!result.added) {
            showToast(context, result.message);
            return;
          }
          showUndoSnackBar(
            context,
            message: result.message,
            onUndo: () {
              unawaited(
                ref.read(playlistRepositoryProvider).removeTrack(
                      result.platformId!,
                      result.playlistId!,
                      widget.track,
                    ),
              );
            },
          );
        },
      ),
      if (onRemove != null)
        SwipeAction(
          label: 'Remove',
          icon: Icons.delete_outline,
          onTap: onRemove,
        ),
    ];
  }

  /// The small card that follows the finger during a drag.
  Widget _dragFeedback() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, size: 20),
            const SizedBox(width: 8),
            Text('${widget.track.artist} - ${widget.track.title}'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = widget.track;
    // Select only the playback fields this row renders: a position
    // tick must not rebuild every row on every kept-alive tab.
    final currentKey = ref.watch(
        audioPlayerProvider.select((s) => s.currentKey));
    final isResolving = ref.watch(
        audioPlayerProvider.select((s) => s.isResolving));
    final resolvingKey = ref.watch(
        audioPlayerProvider.select((s) => s.resolvingKey));
    // Rebuild when a favorite toggles so the swipe Like icon stays
    // honest (the heart button itself rebuilds via setState).
    ref.watch(favoritesVersionProvider);
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    final isCurrent = currentKey == key;
    final rowIsResolving = isResolving && resolvingKey == key;
    final tokens = Theme.of(context).extension<MusicManDesignTokens>();
    final animatePlaying =
        tokens?.design == AppDesign.complex && isCurrent;

    final row = InkWell(
      onTap: _handleTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              child: rowIsResolving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                  : isCurrent
                      ? PlayingMark(animated: animatePlaying)
                      : widget.rank != null
                          ? Text(
                              '${widget.rank}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            )
                          : const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            _CoverThumb(track: track, size: widget.coverSize),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    track.artist,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.meta != null)
                    Text(
                      widget.meta!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (widget.reason != null)
                    GestureDetector(
                      onTapDown: (_) => _cancelPendingPlay(),
                      onTap: widget.onReasonTap,
                      child: Text(
                        widget.reason!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (widget.trailingMark != null) ...[
              widget.trailingMark!,
              const SizedBox(width: 4),
            ],
            GestureDetector(
              onTapDown: (_) => _cancelPendingPlay(),
              child: FavoriteButton(track: track),
            ),
            if (widget.onOverflow != null)
              GestureDetector(
                onTapDown: (_) => _cancelPendingPlay(),
                child: IconButton(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'More actions',
                  onPressed: widget.onOverflow,
                ),
              ),
          ],
        ),
      ),
    );

    final withSwipe = widget.swipeActionsEnabled
        ? SwipeActionRow(actions: _swipeActions(), child: row)
        : row;
    return LongPressDraggable<Track>(
      data: track,
      feedback: _dragFeedback(),
      childWhenDragging: Opacity(opacity: 0.4, child: withSwipe),
      onDragStarted: _onDragStarted,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
      onDraggableCanceled: _onDragCanceled,
      child: withSwipe,
    );
  }
}

/// The playlist drop bar (DESIGN.md: "Drag a song onto a
/// playlist"). A bottom overlay listing the user's saved playlists
/// as DragTargets, shown while a row drag is in flight. It is
/// inserted into the root overlay, so it sits above the
/// mini-player strip and the bottom navigation. Dropping a track
/// adds it (never twice) with an Undo toast that removes it again;
/// the drop gives a light haptic tick.
class _PlaylistDropBar extends ConsumerWidget {
  final Track track;

  const _PlaylistDropBar({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider).getAll();
    // The bar sits just above the bottom strip: the navigation bar
    // (80) plus the mini-player when a track is loaded (about 168).
    final playing =
        ref.watch(audioPlayerProvider.select((s) => s.currentTrack != null));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: playing ? 256 : 88,
      child: Material(
        color: scheme.surface,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(top: BorderSide(color: scheme.outline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Drop on a playlist',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              if (playlists.isEmpty)
                Text(
                  'No saved playlists yet. Import one from Home first.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final playlist in playlists)
                      DragTarget<Track>(
                        builder: (context, candidate, rejected) {
                          final hovered = candidate.isNotEmpty;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: hovered
                                  ? scheme.primaryContainer
                                  : scheme.surface,
                              border: Border.all(
                                  color: hovered
                                      ? scheme.primary
                                      : scheme.outline),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              '${playlist.info.name} '
                              '(${playlist.tracks.length})',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: hovered
                                      ? scheme.onPrimaryContainer
                                      : null),
                            ),
                          );
                        },
                        onAcceptWithDetails: (details) async {
                          // Resolve the messenger before the await:
                          // the drop bar is removed when the drag
                          // ends, so its context is unmounted by
                          // the time the save lands. The messenger
                          // outlives the bar.
                          final messenger =
                              ScaffoldMessenger.of(context);
                          final repo =
                              ref.read(playlistRepositoryProvider);
                          final added = await repo.addTrack(
                            playlist.info.platformId,
                            playlist.info.id,
                            details.data,
                          );
                          HapticFeedback.lightImpact();
                          if (added) {
                            showUndoSnackBarForMessenger(
                              messenger,
                              message:
                                  'Added to ${playlist.info.name}',
                              onUndo: () {
                                repo.removeTrack(
                                  playlist.info.platformId,
                                  playlist.info.id,
                                  details.data,
                                );
                              },
                            );
                          } else {
                            showToastForMessenger(messenger,
                                'Already in ${playlist.info.name}');
                          }
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cover art with a geometric fallback (DESIGN.md: cover art is the
/// only other color on screen; a missing cover is a plain paper-2
/// tile with a note mark, never a broken image icon).
class _CoverThumb extends StatelessWidget {
  final Track track;
  final double size;

  const _CoverThumb({required this.track, required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = track.imageUrl;
    Widget placeholder = Container(
      width: size,
      height: size,
      color: scheme.surface,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: size * 0.45,
        color: scheme.onSurfaceVariant,
      ),
    );
    if (url == null || url.isEmpty) return placeholder;
    // Disk-cached cover at about 2x the display size, so a scroll
    // back never re-fetches or re-decodes at full resolution. While
    // loading (or on error) the row shows the same plain tile as a
    // missing cover, never a broken image icon.
    final memCache = (size * 2).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: memCache,
        memCacheHeight: memCache,
        placeholder: (context, _) => placeholder,
        errorWidget: (context, _, __) => placeholder,
      ),
    );
  }
}

/// The playing mark on the current row (DESIGN.md: Animated play
/// states). In Complex the three bars move; in Compact they stand
/// still, because Compact is MOTION 0.
class PlayingMark extends StatefulWidget {
  final bool animated;

  const PlayingMark({super.key, required this.animated});

  @override
  State<PlayingMark> createState() => _PlayingMarkState();
}

class _PlayingMarkState extends State<PlayingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.animated) _controller.repeat();
  }

  @override
  void didUpdateWidget(PlayingMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animated && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final heights = <double>[
          6.0 + (widget.animated ? 8.0 * (0.5 + 0.5 * math.sin(t * 2 * math.pi)) : 4.0),
          6.0 + (widget.animated ? 10.0 * (0.5 + 0.5 * math.sin(t * 2 * math.pi + 2.1)) : 8.0),
          6.0 + (widget.animated ? 8.0 * (0.5 + 0.5 * math.sin(t * 2 * math.pi + 4.2)) : 2.0),
        ];
        return SizedBox(
          width: 16,
          height: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final h in heights)
                Container(
                  width: 3,
                  height: h,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  color: accent,
                ),
            ],
          ),
        );
      },
    );
  }
}
