// Full player screen (DESIGN.md: Full player): the now-playing spread.
// Big cover, title and artist, seekable progress with real times,
// transport, like, add to playlist, the queue below with the current
// row marked and draggable rows, shuffle and repeat. Swipe down on the
// header to dismiss back to the mini-player; drag the progress rule to
// scrub with a time bubble; swipe a queue row to remove it; double-tap
// the big cover to like. Live streams show "Live" instead of a
// duration, and only for true live streams. Related picks (Complex
// only) come from the other tracks in the current queue, real data
// only, and hide when the queue has fewer than 2 tracks.
//
// Motion follows the design tokens: the cover lifts on the floating
// shadow (the one-shadow rule in Compact, the deeper floating level in
// Complex), the heart pops and the scrub thumb grows over tokens.micro
// in Complex and instantly in Compact, and the progress fill ticks
// over tokens.progressTick.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// material_ui exports Flutter's RepeatMode (animation repeat); the
// player's RepeatMode comes from generation_provider.dart.
import 'package:material_ui/material_ui.dart' hide RepeatMode;

import '../../core/appearance.dart';
import '../../core/theme.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/album_art.dart' show coverUrlFor;
import '../widgets/swipe_action_row.dart';
import '../widgets/undo_snackbar.dart';

/// Toggle the favorite state of [track] with a haptic tick and an
/// Undo toast. Shared by the heart button and the double-tap-cover
/// gesture. Undo toggles it straight back.
void _toggleFavorite(BuildContext context, WidgetRef ref, Track track) {
  final repo = ref.read(favoritesRepositoryProvider);
  final nowFav = repo.toggle(track);
  ref.read(favoritesVersionProvider.notifier).state++;
  HapticFeedback.lightImpact();
  showUndoSnackBar(
    context,
    message: nowFav ? 'Added to favorites' : 'Removed from favorites',
    onUndo: () {
      repo.toggle(track);
      ref.read(favoritesVersionProvider.notifier).state++;
    },
  );
}

String _formatDuration(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class FullPlayerScreen extends ConsumerStatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  ConsumerState<FullPlayerScreen> createState() =>
      _FullPlayerScreenState();
}

/// Reports through the shared route observer whether this route is
/// the top route, so the app shell can hide its bottom bar under
/// the open player (see fullPlayerOnTop in providers.dart). The
/// player is the one widget that can subscribe: the shell sits
/// above the Navigator, so ModalRoute.of finds nothing there.
class _FullPlayerScreenState extends ConsumerState<FullPlayerScreen>
    with RouteAware {
  /// The last on-top value this screen reported. A route torn down
  /// without a pop never calls didPop, so dispose resets the shell
  /// signal from this flag instead of trusting didPop alone.
  bool _isTop = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      musicManRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    musicManRouteObserver.unsubscribe(this);
    if (_isTop) {
      fullPlayerOnTop.value = false;
    }
    super.dispose();
  }

  @override
  void didPush() => _reportTop(true);

  @override
  void didPop() => _reportTop(false);

  @override
  void didPushNext() => _reportTop(false);

  @override
  void didPopNext() => _reportTop(true);

  /// Flips the shell signal after the current frame: the observer
  /// calls didPush synchronously from subscribe during the first
  /// build, and flipping the notifier there would mark the shell
  /// dirty mid-build. Callbacks run in order, so a fast push-then-
  /// pop still lands on the last value.
  void _reportTop(bool onTop) {
    _isTop = onTop;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A stale true must not land after dispose (the dispose
      // reset already cleared the signal); a false is always safe
      // to apply, including after dispose, because the player is
      // gone by then. Callbacks run in order, so a fast
      // push-then-pop still lands on the last value.
      if (mounted || !onTop) {
        fullPlayerOnTop.value = onTop;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Select only the current track: a position tick must not
    // rebuild this screen (the progress rule below watches the
    // position on its own).
    final track =
        ref.watch(audioPlayerProvider.select((s) => s.currentTrack));
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Close player',
          onPressed: () => Navigator.of(context).pop(),
        ),
        // The 聞 (listen) stamp marks the player, the same motif other
        // screens use for their section stamp.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: theme.colorScheme.primary,
              padding: const EdgeInsets.all(4),
              child: Text(
                '聞',
                style: AppTheme.stampKanjiStyle(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text('Now playing'),
          ],
        ),
      ),
      body: track == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nothing playing right now. Play a song to see it here.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _PlayerBody(track: track, tokens: tokens),
    );
  }
}

class _PlayerBody extends ConsumerWidget {
  const _PlayerBody({
    required this.track,
    required this.tokens,
  });

  final Track track;
  final MusicManDesignTokens? tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(audioPlayerProvider.notifier);
    final theme = Theme.of(context);
    final source = player.streamSourceFor(track);
    final metaLine = track.album ?? source;
    // The transport rows watch only the fields they render. The
    // progress rule and the queue are separate widgets below, so a
    // position tick rebuilds neither this body nor the queue.
    final isPlaying =
        ref.watch(audioPlayerProvider.select((s) => s.isPlaying));
    final hasPrevious =
        ref.watch(audioPlayerProvider.select((s) => s.hasPrevious));
    final hasNext =
        ref.watch(audioPlayerProvider.select((s) => s.hasNext));
    final shuffleEnabled = ref.watch(
        audioPlayerProvider.select((s) => s.shuffleEnabled));
    final repeatMode =
        ref.watch(audioPlayerProvider.select((s) => s.repeatMode));
    // Album art for a track with no cover of its own, when the
    // caller that started playback knew the album. Null elsewhere:
    // the big cover stays the plain note tile.
    final albumArtUrl = ref.watch(
        audioPlayerProvider.select((s) => s.currentAlbumArtUrl));

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _DismissHeader(
            track: track,
            tokens: tokens,
            metaLine: metaLine,
            fallbackImageUrl: albumArtUrl,
            onDismiss: () => Navigator.of(context).pop(),
          ),
        ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _ScrubProgress(),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  tooltip: 'Previous',
                  onPressed: hasPrevious ? () => player.previous() : null,
                ),
                IconButton(
                  icon: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 32),
                  tooltip: isPlaying ? 'Pause' : 'Play',
                  onPressed: () => player.togglePlayPause(),
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  tooltip: 'Next',
                  onPressed: hasNext ? () => player.next() : null,
                ),
                IconButton(
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop',
                  onPressed: () => player.stop(),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    color: shuffleEnabled
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  tooltip:
                      shuffleEnabled ? 'Shuffle on' : 'Shuffle off',
                  onPressed: () => player.toggleShuffle(),
                ),
                _LikeButton(track: track),
                IconButton(
                  icon: Icon(
                    repeatMode == RepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                    color: repeatMode == RepeatMode.off
                        ? null
                        : theme.colorScheme.primary,
                  ),
                  tooltip: switch (repeatMode) {
                    RepeatMode.off => 'Repeat off',
                    RepeatMode.all => 'Repeat all',
                    RepeatMode.one => 'Repeat one',
                  },
                  onPressed: () => player.cycleRepeat(),
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to playlist',
                  onPressed: () => _addToPlaylist(context, ref, track),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('Queue', style: theme.textTheme.titleMedium),
          ),
        ),
        const _QueueSliver(),
        const SliverToBoxAdapter(
          child: _RelatedPicks(),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
      ],
    );
  }

  Future<void> _addToPlaylist(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final result = await showAddToPlaylistSheet(context, track);
    if (result == null || !context.mounted) return;
    if (!result.added) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.message)));
      return;
    }
    showUndoSnackBar(
      context,
      message: result.message,
      onUndo: () {
        ref.read(playlistRepositoryProvider).removeTrack(
              result.platformId!,
              result.playlistId!,
              track,
            );
      },
    );
  }
}

/// The queue as a sliver, isolated from the rest of the player body:
/// only the queue rows rebuild on a queue change, and rows are built
/// lazily as they scroll into view instead of all at once on every
/// rebuild (the old shrink-wrapped list inside a scroll view built
/// and laid out every row on every tick).
class _QueueSliver extends ConsumerWidget {
  const _QueueSliver();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue =
        ref.watch(audioPlayerProvider.select((s) => s.queue));
    final queueIndex =
        ref.watch(audioPlayerProvider.select((s) => s.queueIndex));
    final duration =
        ref.watch(audioPlayerProvider.select((s) => s.duration));
    final player = ref.read(audioPlayerProvider.notifier);
    return SliverReorderableList(
      itemCount: queue.length,
      // onReorderItem hands over the final index already
      // adjusted for the removed row, so no manual fix-up.
      onReorderItem: (oldIndex, newIndex) {
        player.moveInQueue(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final item = queue[index];
        final isCurrent = index == queueIndex;
        // Swipe to remove through the shared swipe row, not a
        // Dismissible: Dismissible asserts on zero durations,
        // so it can never be MOTION 0 in Compact. The swipe
        // row slides the reveal in Complex and applies it
        // instantly in Compact, with the same Undo toast.
        return SwipeActionRow(
          key: ValueKey('queue-row:${item.artist}::${item.title}'),
          actions: [
            SwipeAction(
              label: 'Remove',
              icon: Icons.delete_outline,
              onTap: () =>
                  _removeFromQueue(context, ref, index, item),
            ),
          ],
          child: _QueueRow(
            track: item,
            index: index,
            isCurrent: isCurrent,
            queueLength: queue.length,
            duration: _rowDuration(item, isCurrent, duration),
          ),
        );
      },
    );
  }
}

Duration? _rowDuration(
    Track item, bool isCurrent, Duration? currentDuration) {
  if (item.durationMs != null) {
    return Duration(milliseconds: item.durationMs!);
  }
  return isCurrent ? currentDuration : null;
}

/// Remove the row, with an Undo toast that puts the track back where
/// it was. Undo restores the queue entry; when the removed track was
/// the playing one, playback has already advanced and is not rewound.
Future<void> _removeFromQueue(
  BuildContext context,
  WidgetRef ref,
  int index,
  Track track,
) async {
  final player = ref.read(audioPlayerProvider.notifier);
  await player.removeFromQueue(index);
  if (!context.mounted) return;
  showUndoSnackBar(
    context,
    message: 'Removed ${track.title}',
    onUndo: () {
      player.addToQueue(track);
      final last = ref.read(audioPlayerProvider).queue.length - 1;
      if (last > index) player.moveInQueue(last, index);
    },
  );
}

/// Header: drag handle, big cover, title, artist, album or source line.
/// A downward drag past 100 px dismisses the player. The drag is read
/// from raw pointer events so it is not swallowed by the scroll view:
/// at the top of the screen a downward drag cannot scroll anything, so
/// it is unambiguously a dismiss; an upward drag still scrolls.
class _DismissHeader extends StatefulWidget {
  const _DismissHeader({
    required this.track,
    required this.tokens,
    required this.metaLine,
    required this.onDismiss,
    this.fallbackImageUrl,
  });

  final Track track;
  final MusicManDesignTokens? tokens;
  final String? metaLine;
  final VoidCallback onDismiss;

  /// Album art for a track with no cover of its own, passed in with
  /// playback. Null keeps the plain note tile.
  final String? fallbackImageUrl;

  @override
  State<_DismissHeader> createState() => _DismissHeaderState();
}

class _DismissHeaderState extends State<_DismissHeader> {
  static const _dismissThreshold = 100.0;
  double _dragDy = 0;

  /// The cover URL (with its decode size) already warmed, so a
  /// rebuild or a reopen of the same track never re-precaches.
  String? _precachedKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final url = coverUrlFor(
      imageUrl: widget.track.imageUrl,
      fallbackImageUrl: widget.fallbackImageUrl,
    );
    if (url == null) return;
    final coverSize =
        (MediaQuery.sizeOf(context).width - 48).clamp(0.0, 320.0);
    final memCache = (coverSize * 2).round();
    final key = '$url@$memCache';
    if (key == _precachedKey) return;
    _precachedKey = key;
    // Warm the full-size decode before the first frame, so the big
    // cover does not flash its placeholder when the player opens
    // from the 56 px mini-player thumb. Same provider (same
    // maxWidth/maxHeight) as the cover below, so the warmed entry
    // is the one the cover reads.
    precacheImage(
      CachedNetworkImageProvider(
        url,
        maxWidth: memCache,
        maxHeight: memCache,
      ),
      context,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverSize =
        (MediaQuery.sizeOf(context).width - 48).clamp(0.0, 320.0);
    // Chain: the track's own cover, then the album art passed in
    // with playback, then the plain note tile.
    final coverUrl = coverUrlFor(
      imageUrl: widget.track.imageUrl,
      fallbackImageUrl: widget.fallbackImageUrl,
    );

    return Listener(
      onPointerDown: (_) => _dragDy = 0,
      onPointerMove: (event) => _dragDy += event.delta.dy,
      onPointerUp: (_) {
        if (_dragDy > _dismissThreshold) widget.onDismiss();
        _dragDy = 0;
      },
      onPointerCancel: (_) => _dragDy = 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Double-tap likes the current song; a single tap on the
            // cover does nothing.
            Center(
              child: Consumer(
                builder: (context, ref, _) => GestureDetector(
                  onDoubleTap: () =>
                      _toggleFavorite(context, ref, widget.track),
                  child: Container(
                    key: const ValueKey('player-cover'),
                    width: coverSize,
                    height: coverSize,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                          widget.tokens?.coverRadius ?? 2),
                      boxShadow: widget.tokens?.floatingShadow,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                          widget.tokens?.coverRadius ?? 2),
                      child: coverUrl != null
                          ? CachedNetworkImage(
                              imageUrl: coverUrl,
                              width: coverSize,
                              height: coverSize,
                              fit: BoxFit.cover,
                              memCacheWidth: (coverSize * 2).round(),
                              memCacheHeight: (coverSize * 2).round(),
                              placeholder: (context, _) => Container(
                                color: theme.colorScheme.surface,
                                child: const Icon(Icons.music_note,
                                    size: 96),
                              ),
                              errorWidget: (context, _, __) => Container(
                                color: theme.colorScheme.surface,
                                child: const Icon(Icons.music_note,
                                    size: 96),
                              ),
                            )
                          : Container(
                              color: theme.colorScheme.surface,
                              child: const Icon(Icons.music_note, size: 96),
                            ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.track.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              widget.track.artist,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            if (widget.metaLine != null) ...[
              const SizedBox(height: 2),
              Text(
                widget.metaLine!,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Heart with a pop and a haptic tick on like: in Complex the heart
/// pops over tokens.micro; in Compact it fills instantly. The icon
/// always refreshes on tap, pop or not.
class _LikeButton extends ConsumerStatefulWidget {
  const _LikeButton({required this.track});

  final Track track;

  @override
  ConsumerState<_LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends ConsumerState<_LikeButton> {
  bool _popping = false;
  Timer? _popTimer;

  @override
  void dispose() {
    _popTimer?.cancel();
    super.dispose();
  }

  void _onPressed() {
    _toggleFavorite(context, ref, widget.track);
    final micro = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.micro ??
        Duration.zero;
    setState(() => _popping = micro != Duration.zero);
    if (micro == Duration.zero) return;
    _popTimer?.cancel();
    _popTimer = Timer(micro, () {
      if (mounted) setState(() => _popping = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(favoritesRepositoryProvider);
    final isFav = repo.isFavorite(widget.track.artist, widget.track.title);
    final micro = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.micro ??
        Duration.zero;
    return IconButton(
      icon: AnimatedScale(
        scale: _popping ? 1.3 : 1.0,
        duration: micro,
        curve: Curves.easeOut,
        child: Icon(
          isFav ? Icons.favorite : Icons.favorite_outline,
          color: isFav ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
      tooltip: isFav ? 'Remove from favorites' : 'Add to favorites',
      onPressed: _onPressed,
    );
  }
}

/// Custom progress rule for the full player (not the mini-player's
/// plain Slider): dragging shows a bubble with the time under the
/// thumb, and the thumb grows while scrubbing. Releasing seeks. The
/// fill ticks over tokens.progressTick (250 ms in Complex, instant in
/// Compact); the thumb grows over tokens.micro with an ease in Complex
/// and switches instantly in Compact.
class _ScrubProgress extends ConsumerStatefulWidget {
  const _ScrubProgress();

  @override
  ConsumerState<_ScrubProgress> createState() => _ScrubProgressState();
}

class _ScrubProgressState extends ConsumerState<_ScrubProgress> {
  double? _scrubFraction;

  void _updateScrub(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final width = box.size.width;
    if (width <= 0) return;
    final dx = globalPosition.dx - box.localToGlobal(Offset.zero).dx;
    setState(() => _scrubFraction = (dx / width).clamp(0.0, 1.0));
  }

  void _endScrub() {
    final fraction = _scrubFraction;
    final duration = ref.read(audioPlayerProvider).duration;
    setState(() => _scrubFraction = null);
    if (fraction != null && duration != null) {
      ref.read(audioPlayerProvider.notifier).seek(
            Duration(milliseconds: (fraction * duration.inMilliseconds).round()),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Select only the progress fields this rule renders, so a
    // position tick rebuilds this rule and nothing else on the
    // screen (not the header, the queue, or the transport rows).
    final isLive =
        ref.watch(audioPlayerProvider.select((s) => s.isLive));
    final duration =
        ref.watch(audioPlayerProvider.select((s) => s.duration));
    final livePosition =
        ref.watch(audioPlayerProvider.select((s) => s.position));
    final liveFraction = ref.watch(
        audioPlayerProvider.select((s) => s.progressFraction));
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    final micro = tokens?.micro ?? Duration.zero;
    final tick = tokens?.progressTick ?? Duration.zero;

    if (isLive) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Text('Live', style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            const Expanded(child: LinearProgressIndicator()),
          ],
        ),
      );
    }
    if (duration == null) {
      // No duration and not live: no progress rule, just the zero
      // times. Never "Live" here.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Text('0:00', style: theme.textTheme.bodySmall),
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: theme.colorScheme.outline,
              ),
            ),
            Text('0:00', style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    final scrubPosition = _scrubFraction == null
        ? null
        : Duration(
            milliseconds:
                (_scrubFraction! * duration.inMilliseconds).round());
    final position = scrubPosition ?? livePosition;
    final fraction = _scrubFraction ?? liveFraction;
    final scrubbing = _scrubFraction != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const ValueKey('scrub-area'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) =>
              _updateScrub(details.globalPosition),
          onHorizontalDragUpdate: (details) =>
              _updateScrub(details.globalPosition),
          onHorizontalDragEnd: (_) => _endScrub(),
          onHorizontalDragCancel: () =>
              setState(() => _scrubFraction = null),
          child: SizedBox(
            height: 56,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final thumbSize = scrubbing ? 20.0 : 12.0;
                final thumbLeft = (fraction * width - thumbSize / 2)
                    .clamp(0.0, width - thumbSize);
                final bubbleLeft =
                    (fraction * width - 26).clamp(0.0, width - 52);
                return Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 26,
                      child: Container(
                        height: 4,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 26,
                      child: AnimatedContainer(
                        duration: tick,
                        curve: Curves.easeOut,
                        width: fraction * width,
                        height: 4,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Positioned(
                      left: thumbLeft,
                      top: 28 - thumbSize / 2,
                      child: AnimatedContainer(
                        duration: micro,
                        curve: Curves.easeOut,
                        width: thumbSize,
                        height: thumbSize,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    if (scrubbing)
                      Positioned(
                        left: bubbleLeft,
                        top: 0,
                        child: Container(
                          key: const ValueKey('scrub-bubble'),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.inverseSurface,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _formatDuration(position),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onInverseSurface),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        Row(
          children: [
            Text(_formatDuration(position),
                style: theme.textTheme.bodySmall),
            const Spacer(),
            Text(_formatDuration(duration),
                style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

/// One queue row: grip handle (the drag path), cover, title and
/// artist with duration, the current-row mark, and the keyboard path
/// for reordering (move up / move down buttons wired to moveInQueue).
/// Tapping a row that is not playing plays it.
class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.queueLength,
    required this.duration,
  });

  final Track track;
  final int index;
  final bool isCurrent;
  final int queueLength;
  final Duration? duration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(audioPlayerProvider.notifier);
    final subtitle = duration == null
        ? track.artist
        : '${track.artist} · ${_formatDuration(duration!)}';
    return Container(
      color: isCurrent ? theme.colorScheme.surface : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!isCurrent) unawaited(player.playAt(index));
        },
        child: Row(
          children: [
            Tooltip(
              message: 'Drag to reorder',
              child: ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
              child: track.imageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: CachedNetworkImage(
                        imageUrl: track.imageUrl!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        memCacheWidth: 80,
                        memCacheHeight: 80,
                        placeholder: (context, _) =>
                            const Icon(Icons.music_note, size: 32),
                        errorWidget: (context, _, __) =>
                            const Icon(Icons.music_note, size: 32),
                      ),
                    )
                  : const Icon(Icons.music_note, size: 32),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: isCurrent
                            ? theme.colorScheme.primary
                            : null,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : null,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            // The trailing controls fade as the swipe row opens (see
            // SwipeTrailingFade): the row is transparent, so without
            // the fade the Playing mark and move buttons would sit
            // on top of the revealed Remove button mid-swipe.
            SwipeTrailingFade(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCurrent)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        'Playing',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: 'Move up',
                    onPressed: index > 0
                        ? () => player.moveInQueue(index, index - 1)
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward),
                    tooltip: 'Move down',
                    onPressed: index < queueLength - 1
                        ? () => player.moveInQueue(index, index + 1)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Related picks, Complex only: the other tracks in the current queue,
/// real data only. Hidden when the design is not Complex or the queue
/// has fewer than 2 tracks. Watches the queue alone, so a position
/// tick never rebuilds it.
class _RelatedPicks extends ConsumerWidget {
  const _RelatedPicks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<MusicManDesignTokens>();
    final queue =
        ref.watch(audioPlayerProvider.select((s) => s.queue));
    final queueIndex =
        ref.watch(audioPlayerProvider.select((s) => s.queueIndex));
    if (tokens?.design != AppDesign.complex || queue.length < 2) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final player = ref.read(audioPlayerProvider.notifier);
    final others = [
      for (var i = 0; i < queue.length; i++)
        if (i != queueIndex) (index: i, track: queue[i]),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text('Related picks',
              style: theme.textTheme.titleMedium),
        ),
        for (final entry in others)
          ListTile(
            leading: entry.track.imageUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: CachedNetworkImage(
                      imageUrl: entry.track.imageUrl!,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      memCacheWidth: 80,
                      memCacheHeight: 80,
                      placeholder: (context, _) =>
                          const Icon(Icons.music_note, size: 32),
                      errorWidget: (context, _, __) =>
                          const Icon(Icons.music_note, size: 32),
                    ),
                  )
                : const Icon(Icons.music_note, size: 32),
            title: Text(entry.track.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(entry.track.artist,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => unawaited(player.playAt(entry.index)),
          ),
      ],
    );
  }
}
