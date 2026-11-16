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

/// Toggle the favorite state of [track] with a haptic tick and a toast.
/// Shared by the heart button and the double-tap-cover gesture.
void _toggleFavorite(BuildContext context, WidgetRef ref, Track track) {
  final repo = ref.read(favoritesRepositoryProvider);
  final nowFav = repo.toggle(track);
  ref.read(favoritesVersionProvider.notifier).state++;
  HapticFeedback.lightImpact();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content:
        Text(nowFav ? 'Added to favorites' : 'Removed from favorites'),
    duration: const Duration(seconds: 1),
  ));
}

String _formatDuration(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class FullPlayerScreen extends ConsumerWidget {
  const FullPlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(audioPlayerProvider);
    final track = state.currentTrack;
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
          : _PlayerBody(state: state, track: track, tokens: tokens),
    );
  }
}

class _PlayerBody extends ConsumerWidget {
  const _PlayerBody({
    required this.state,
    required this.track,
    required this.tokens,
  });

  final PlaybackState state;
  final Track track;
  final MusicManDesignTokens? tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(audioPlayerProvider.notifier);
    final theme = Theme.of(context);
    final source = player.streamSourceFor(track);
    final metaLine = track.album ?? source;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DismissHeader(
            track: track,
            tokens: tokens,
            metaLine: metaLine,
            onDismiss: () => Navigator.of(context).pop(),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _ScrubProgress(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  tooltip: 'Previous',
                  onPressed:
                      state.hasPrevious ? () => player.previous() : null,
                ),
                IconButton(
                  icon: Icon(
                      state.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 32),
                  tooltip: state.isPlaying ? 'Pause' : 'Play',
                  onPressed: () => player.togglePlayPause(),
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  tooltip: 'Next',
                  onPressed: state.hasNext ? () => player.next() : null,
                ),
                IconButton(
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop',
                  onPressed: () => player.stop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    color: state.shuffleEnabled
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  tooltip:
                      state.shuffleEnabled ? 'Shuffle on' : 'Shuffle off',
                  onPressed: () => player.toggleShuffle(),
                ),
                _LikeButton(track: track),
                IconButton(
                  icon: Icon(
                    state.repeatMode == RepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                    color: state.repeatMode == RepeatMode.off
                        ? null
                        : theme.colorScheme.primary,
                  ),
                  tooltip: switch (state.repeatMode) {
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('Queue', style: theme.textTheme.titleMedium),
          ),
          ReorderableListView.builder(
            key: const ValueKey('queue-list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // The grip handle is the drag path; the default whole-row
            // handles stay off so a horizontal swipe on a row removes
            // it instead of starting a reorder.
            buildDefaultDragHandles: false,
            itemCount: state.queue.length,
            // onReorderItem hands over the final index already
            // adjusted for the removed row, so no manual fix-up.
            onReorderItem: (oldIndex, newIndex) {
              player.moveInQueue(oldIndex, newIndex);
            },
            itemBuilder: (context, index) {
              final item = state.queue[index];
              final isCurrent = index == state.queueIndex;
              return Dismissible(
                key: ValueKey('queue-dismiss:${item.artist}::${item.title}'),
                direction: DismissDirection.horizontal,
                background: _dismissBackground(context, Alignment.centerLeft),
                secondaryBackground:
                    _dismissBackground(context, Alignment.centerRight),
                onDismissed: (_) =>
                    _removeFromQueue(context, ref, index, item),
                child: _QueueRow(
                  track: item,
                  index: index,
                  isCurrent: isCurrent,
                  queueLength: state.queue.length,
                  duration: _rowDuration(item, isCurrent, state),
                ),
              );
            },
          ),
          if (tokens?.design == AppDesign.complex &&
              state.queue.length >= 2)
            _RelatedPicks(state: state),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _dismissBackground(BuildContext context, Alignment alignment) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.inverseSurface,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        'Remove',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onInverseSurface),
      ),
    );
  }

  Duration? _rowDuration(Track item, bool isCurrent, PlaybackState state) {
    if (item.durationMs != null) {
      return Duration(milliseconds: item.durationMs!);
    }
    return isCurrent ? state.duration : null;
  }

  Future<void> _addToPlaylist(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final message = await showAddToPlaylistSheet(context, track);
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Removed ${track.title}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          player.addToQueue(track);
          final last = ref.read(audioPlayerProvider).queue.length - 1;
          if (last > index) player.moveInQueue(last, index);
        },
      ),
    ));
  }
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
  });

  final Track track;
  final MusicManDesignTokens? tokens;
  final String? metaLine;
  final VoidCallback onDismiss;

  @override
  State<_DismissHeader> createState() => _DismissHeaderState();
}

class _DismissHeaderState extends State<_DismissHeader> {
  static const _dismissThreshold = 100.0;
  double _dragDy = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverSize =
        (MediaQuery.sizeOf(context).width - 48).clamp(0.0, 320.0);

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
                      child: widget.track.imageUrl != null
                          ? Image.network(
                              widget.track.imageUrl!,
                              width: coverSize,
                              height: coverSize,
                              fit: BoxFit.cover,
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
    final state = ref.watch(audioPlayerProvider);
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    final micro = tokens?.micro ?? Duration.zero;
    final tick = tokens?.progressTick ?? Duration.zero;
    final duration = state.duration;

    if (state.isLive) {
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
    final position = scrubPosition ?? state.position;
    final fraction = _scrubFraction ?? state.progressFraction;
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
                      child: Image.network(track.imageUrl!,
                          width: 40, height: 40, fit: BoxFit.cover),
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
    );
  }
}

/// Related picks, Complex only: the other tracks in the current queue,
/// real data only. Hidden when the queue has fewer than 2 tracks (the
/// caller gates on that).
class _RelatedPicks extends ConsumerWidget {
  const _RelatedPicks({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(audioPlayerProvider.notifier);
    final others = [
      for (var i = 0; i < state.queue.length; i++)
        if (i != state.queueIndex) (index: i, track: state.queue[i]),
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
                    child: Image.network(entry.track.imageUrl!,
                        width: 40, height: 40, fit: BoxFit.cover),
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
