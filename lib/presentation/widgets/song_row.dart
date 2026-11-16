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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import 'favorite_button.dart';

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
    this.coverSize = 48,
  });

  @override
  ConsumerState<EditorialSongRow> createState() => _EditorialSongRowState();
}

class _EditorialSongRowState extends ConsumerState<EditorialSongRow> {
  Timer? _playTimer;
  DateTime? _lastTap;

  @override
  void dispose() {
    _playTimer?.cancel();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nowFav ? 'Added to favorites' : 'Removed from favorites',
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _handleTap() {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = widget.track;
    final playback = ref.watch(audioPlayerProvider);
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    final isCurrent = playback.currentKey == key;
    final isResolving =
        playback.isResolving && playback.resolvingKey == key;
    final tokens = Theme.of(context).extension<MusicManDesignTokens>();
    final animatePlaying =
        tokens?.design == AppDesign.complex && isCurrent;

    return InkWell(
      onTap: _handleTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              child: isResolving
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, _, __) => placeholder,
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
