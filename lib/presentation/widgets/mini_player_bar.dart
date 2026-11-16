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

class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar> {
  /// Position the user is dragging the slider to; null when not
  /// dragging (the bar then shows the player's live position).
  Duration? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(audioPlayerProvider);
    final track = state.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final player = ref.read(audioPlayerProvider.notifier);
    final duration = state.duration;
    final position = _dragPosition ?? state.position;
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
                  onPressed:
                      state.hasPrevious ? () => player.previous() : null,
                ),
                IconButton(
                  icon: Icon(
                      state.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 32),
                  tooltip: state.isPlaying ? 'Pause' : 'Play',
                  onPressed: () => player.togglePlayPause(),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: state.isLive
                  ? Row(
                      children: [
                        Text('Live', style: theme.textTheme.bodySmall),
                        const SizedBox(width: 8),
                        const Expanded(child: LinearProgressIndicator()),
                      ],
                    )
                  : duration == null
                      // No duration and not live: no progress rule,
                      // just the zero times. Never "Live" here.
                      ? Row(
                          children: [
                            Text('0:00', style: theme.textTheme.bodySmall),
                            const Expanded(child: SizedBox.shrink()),
                            Text('0:00', style: theme.textTheme.bodySmall),
                          ],
                        )
                      : Row(
                          children: [
                            Text(_formatDuration(position),
                                style: theme.textTheme.bodySmall),
                            Expanded(
                              child: Slider(
                                value: position.inMilliseconds
                                    .toDouble()
                                    .clamp(
                                        0,
                                        duration.inMilliseconds
                                            .toDouble()),
                                max: duration.inMilliseconds > 0
                                    ? duration.inMilliseconds.toDouble()
                                    : 1,
                                onChanged: (value) => setState(() =>
                                    _dragPosition = Duration(
                                        milliseconds: value.round())),
                                onChangeEnd: (value) {
                                  setState(() => _dragPosition = null);
                                  player.seek(
                                      Duration(milliseconds: value.round()));
                                },
                              ),
                            ),
                            Text(_formatDuration(duration),
                                style: theme.textTheme.bodySmall),
                          ],
                        ),
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
    final message = await showAddToPlaylistSheet(context, track);
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

Widget _cover(Track track, MusicManDesignTokens? tokens) {
  final radius = tokens?.coverRadius ?? 2;
  if (track.imageUrl != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(track.imageUrl!,
          width: 56, height: 56, fit: BoxFit.cover),
    );
  }
  return const Icon(Icons.music_note, size: 44);
}

String _formatDuration(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
