// Global bottom mini-player (item 4): pinned above the bottom nav on
// every tab by the app shell in main.dart, and kept visible on pushed
// routes because the shell sits above the Navigator. Drives the single
// shared player: cover, title/artist, previous/play/next/stop, seekable
// progress, like and add-to-playlist. Renders nothing when nothing is
// loaded. It watches the player itself, so position ticks rebuild only
// the bar, never the shell or the tab behind it.
//
// Dismiss: the X button at the end of the top row, or a downward swipe
// on the bar, stops playback through the notifier's stop(), which
// clears the bar and the Android shade notification in one action.
// The drag follows the finger; releasing past about one third of the
// bar height, or with a downward fling, completes the dismiss, and
// below the threshold the bar springs back. A tap never dismisses:
// the body tap still opens the full player, and a drag never opens it.
//
// Editorial restyle (DESIGN.md): paper 2 surface with a hairline top
// border, no elevation, no old deep-purple seed. Bigger cover thumb.
// The line below the artist shows the album when present, else the
// source label the track was resolved from. Tapping the strip body
// (cover, title, artist) opens the full player; the buttons keep their
// own actions. Live streams show "Live" instead of a duration, and
// only for true live streams: a track with no duration that is not
// live shows no progress rule, just the zero times.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../screens/full_player_screen.dart';
import 'add_to_playlist_sheet.dart';
import 'album_art.dart' show coverUrlFor;
import 'editorial_route.dart';
import 'favorite_button.dart';
import 'undo_snackbar.dart';

class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar>
    with SingleTickerProviderStateMixin {
  /// Release at or past this far down (about one third of the bar) to
  /// dismiss; below it the bar springs back. A tap never moves the
  /// bar, so it never dismisses.
  static const _kDismissThreshold = 56.0;

  /// A downward fling faster than this dismisses whatever the offset.
  static const _kFlingVelocity = 300.0;

  /// How far the bar has been dragged down, in pixels. Zero at rest.
  double _dragDy = 0;

  /// True while the exit slide is running; drags are ignored then,
  /// the bar is already on its way out.
  bool _dismissing = false;

  /// Drives one exit or spring-back slide; recreated per slide.
  AnimationController? _slideController;

  @override
  void dispose() {
    _slideController?.dispose();
    super.dispose();
  }

  /// The bar's own height, for the exit slide target; 200 when the
  /// layout is not available yet (the bar is about 170 tall).
  double get _barHeight => context.size?.height ?? 200.0;

  /// The motion duration for a dismiss slide: the design's player
  /// rise (220 ms in Complex, zero in Compact and under reduced
  /// motion), so the bar leaves with the same motion the player
  /// rose with, and instantly where the design has no motion.
  Duration _motionDuration() =>
      Theme.of(context).extension<MusicManDesignTokens>()?.playerRise ??
      Duration.zero;

  /// Dismiss through the notifier's stop(): one action clears the bar
  /// and the Android shade notification together, and bumps the play
  /// token, so a late resolve cannot resurrect the bar. Instant in
  /// Compact and under reduced motion; in Complex the bar slides
  /// down first, then stops.
  void _dismiss() {
    if (_dismissing) return;
    final player = ref.read(audioPlayerProvider.notifier);
    final duration = _motionDuration();
    if (duration == Duration.zero) {
      unawaited(player.stop());
      return;
    }
    _dismissing = true;
    _animateOffsetTo(
      _barHeight,
      duration,
      () {
        _dismissing = false;
        if (!mounted) return;
        unawaited(player.stop());
      },
    );
  }

  /// Slide back to rest after a short drag. Instant where the design
  /// has no motion.
  void _springBack() {
    if (_dismissing) return;
    final duration = _motionDuration();
    if (duration == Duration.zero) {
      if (_dragDy != 0) setState(() => _dragDy = 0);
      return;
    }
    _animateOffsetTo(0, duration, null);
  }

  /// Animate the drag offset to [target] over [duration], then run
  /// [onDone]. A drag starting mid-slide stops the slide and takes
  /// over from the current offset, so the bar never jumps.
  void _animateOffsetTo(
      double target, Duration duration, VoidCallback? onDone) {
    final start = _dragDy;
    if ((target - start).abs() < 0.5) {
      if (start != target) setState(() => _dragDy = target);
      onDone?.call();
      return;
    }
    _slideController?.dispose();
    final controller = AnimationController(vsync: this, duration: duration);
    _slideController = controller;
    final animation = Tween<double>(begin: start, end: target).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOut),
    );
    animation.addListener(() {
      if (mounted) setState(() => _dragDy = animation.value);
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) onDone?.call();
    });
    controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    // Select only the fields the strip renders. Position ticks
    // rebuild nothing here: the progress row below is its own
    // widget watching position alone.
    final track = ref.watch(
        audioPlayerProvider.select((s) => s.currentTrack));
    if (track == null) return const SizedBox.shrink();
    // Album art for a track with no cover of its own, when the
    // caller that started playback knew the album. Null everywhere
    // else: the placeholder tile stays.
    final albumArtUrl = ref.watch(
        audioPlayerProvider.select((s) => s.currentAlbumArtUrl));
    final isPlaying = ref.watch(
        audioPlayerProvider.select((s) => s.isPlaying));
    final hasPrevious = ref.watch(
        audioPlayerProvider.select((s) => s.hasPrevious));
    final hasNext = ref.watch(
        audioPlayerProvider.select((s) => s.hasNext));
    final player = ref.read(audioPlayerProvider.notifier);
    final theme = Theme.of(context);
    final tokens = theme.extension<MusicManDesignTokens>();
    // Album when present, else the source label (Deezer, Audius and
    // so on) the track was resolved from; nothing when neither exists.
    final metaLine = track.album ?? player.streamSourceFor(track);

    // The swipe surface is the whole bar: a downward drag follows
    // the finger, and the release either dismisses or springs back.
    // The vertical drag recognizer only claims on vertical movement,
    // so taps still reach the body and the buttons, the slider keeps
    // its horizontal drag, and a drag never opens the full player.
    return Transform.translate(
      offset: Offset(0, _dragDy),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => _slideController?.stop(),
        onVerticalDragUpdate: (details) {
          if (_dismissing) return;
          setState(() {
            _dragDy = (_dragDy + details.delta.dy)
                .clamp(0.0, _barHeight);
          });
        },
        onVerticalDragEnd: (details) {
          if (_dismissing) return;
          final velocity = details.velocity.pixelsPerSecond.dy;
          if (_dragDy >= _kDismissThreshold ||
              velocity > _kFlingVelocity) {
            _dismiss();
          } else {
            _springBack();
          }
        },
        onVerticalDragCancel: _springBack,
        child: Material(
          color: theme.colorScheme.surface,
          elevation: 0,
          child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outline),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openFullPlayer(context),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                          child: _cover(track, tokens,
                              fallbackImageUrl: albumArtUrl),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 0, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall),
                                Text(track.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall),
                                if (metaLine != null)
                                  Text(metaLine,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              color: theme.colorScheme
                                                  .onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                FavoriteButton(track: track),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to playlist',
                  onPressed: () => _addToPlaylist(context, track),
                ),
                // Dismiss: same stop() as the swipe, so the bar and
                // the shade notification clear together. IconButton
                // is 48x48, the minimum tap target.
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Dismiss player',
                  onPressed: _dismiss,
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  tooltip: 'Previous',
                  onPressed: hasPrevious ? () => player.previous() : null,
                ),
                IconButton(
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 32),
                  tooltip: isPlaying ? 'Pause' : 'Play',
                  onPressed: () => player.togglePlayPause(),
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _MiniPlayerProgress(),
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }

  /// Opens the full player on the root Navigator. The bar lives above
  /// the Navigator in the app shell, so its own context has no
  /// Navigator ancestor: fall back to the root navigator key.
  void _openFullPlayer(BuildContext context) {
    final nav = Navigator.maybeOf(context) ?? navigatorKey.currentState;
    nav?.push(playerRoute(context, (_) => const FullPlayerScreen()));
  }

  Future<void> _addToPlaylist(BuildContext context, Track track) async {
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
      onUndo: () async {
        await ref.read(playlistRepositoryProvider).removeTrack(
              result.platformId!,
              result.playlistId!,
              track,
            );
      },
    );
  }
}

/// The mini-player's progress row, kept as its own widget so a
/// position tick rebuilds only this row: the strip above (cover,
/// title, buttons) watches the track and the transport state, never
/// the position.
class _MiniPlayerProgress extends ConsumerStatefulWidget {
  const _MiniPlayerProgress();

  @override
  ConsumerState<_MiniPlayerProgress> createState() =>
      _MiniPlayerProgressState();
}

class _MiniPlayerProgressState
    extends ConsumerState<_MiniPlayerProgress> {
  /// Position the user is dragging the slider to; null when not
  /// dragging (the row then shows the player's live position).
  Duration? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final isLive =
        ref.watch(audioPlayerProvider.select((s) => s.isLive));
    final duration =
        ref.watch(audioPlayerProvider.select((s) => s.duration));
    final livePosition =
        ref.watch(audioPlayerProvider.select((s) => s.position));
    final position = _dragPosition ?? livePosition;
    final theme = Theme.of(context);
    final player = ref.read(audioPlayerProvider.notifier);

    if (isLive) {
      return Row(
        children: [
          Text('Live', style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          const Expanded(child: LinearProgressIndicator()),
        ],
      );
    }
    if (duration == null) {
      // No duration and not live: no progress rule, just the zero
      // times. Never "Live" here.
      return Row(
        children: [
          Text('0:00', style: theme.textTheme.bodySmall),
          const Expanded(child: SizedBox.shrink()),
          Text('0:00', style: theme.textTheme.bodySmall),
        ],
      );
    }
    return Row(
      children: [
        Text(_formatDuration(position),
            style: theme.textTheme.bodySmall),
        Expanded(
          child: Slider(
            value: position.inMilliseconds
                .toDouble()
                .clamp(0, duration.inMilliseconds.toDouble()),
            max: duration.inMilliseconds > 0
                ? duration.inMilliseconds.toDouble()
                : 1,
            onChanged: (value) => setState(() => _dragPosition =
                Duration(milliseconds: value.round())),
            onChangeEnd: (value) {
              setState(() => _dragPosition = null);
              player.seek(Duration(milliseconds: value.round()));
            },
          ),
        ),
        Text(_formatDuration(duration),
            style: theme.textTheme.bodySmall),
      ],
    );
  }
}

Widget _cover(Track track, MusicManDesignTokens? tokens,
    {String? fallbackImageUrl}) {
  final radius = tokens?.coverRadius ?? 2;
  // Chain: the track's own cover, then the album art passed in with
  // playback, then the plain note tile.
  final url = coverUrlFor(
    imageUrl: track.imageUrl,
    fallbackImageUrl: fallbackImageUrl,
  );
  if (url != null) {
    // Disk-cached cover at about 2x the display size, so the strip
    // never re-fetches or re-decodes at full resolution. While
    // loading (or on error) it shows the same note mark as a
    // missing cover.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        memCacheWidth: 112,
        memCacheHeight: 112,
        placeholder: (context, _) =>
            const Icon(Icons.music_note, size: 44),
        errorWidget: (context, _, __) =>
            const Icon(Icons.music_note, size: 44),
      ),
    );
  }
  return const Icon(Icons.music_note, size: 44);
}

String _formatDuration(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
