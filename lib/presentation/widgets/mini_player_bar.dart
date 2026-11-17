// Global bottom mini-player (item 4): pinned above the bottom nav on
// every tab by the app shell in main.dart, and kept visible on pushed
// routes because the shell sits above the Navigator. Drives the single
// shared player: cover, title/artist, previous/play/next/stop, seekable
// progress, like and add-to-playlist. Renders nothing when nothing is
// loaded. It watches the player itself, so position ticks rebuild only
// the bar, never the shell or the tab behind it.
//
// Editorial restyle (DESIGN.md): paper 2 surface with a hairline top
// border, no elevation, no old deep-purple seed. Bigger cover thumb.
// The line below the artist shows the album when present, else the
// source label the track was resolved from. Tapping the strip body
// (cover, title, artist) opens the full player; the buttons keep their
// own actions. Live streams show "Live" instead of a duration, and
// only for true live streams: a track with no duration that is not
// live shows no progress rule, just the zero times.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../screens/full_player_screen.dart';
import 'add_to_playlist_sheet.dart';
import 'editorial_route.dart';
import 'favorite_button.dart';
import 'undo_snackbar.dart';

class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar> {
  @override
  Widget build(BuildContext context) {
    // Select only the fields the strip renders. Position ticks
    // rebuild nothing here: the progress row below is its own
    // widget watching position alone.
    final track = ref.watch(
        audioPlayerProvider.select((s) => s.currentTrack));
    if (track == null) return const SizedBox.shrink();
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

    return Material(
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
                          child: _cover(track, tokens),
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

Widget _cover(Track track, MusicManDesignTokens? tokens) {
  final radius = tokens?.coverRadius ?? 2;
  if (track.imageUrl != null) {
    // Disk-cached cover at about 2x the display size, so the strip
    // never re-fetches or re-decodes at full resolution. While
    // loading (or on error) it shows the same note mark as a
    // missing cover.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: track.imageUrl!,
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
