// Global bottom mini-player (item 4): pinned above the bottom nav on
// every tab by _RootScaffold. Drives the single shared player — cover,
// title/artist, previous/play/next/stop, seekable progress, like and
// add-to-playlist. Renders nothing when nothing is loaded. It watches
// the player itself, so position ticks rebuild only this bar, never
// the scaffold or the tab behind it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
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

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: _cover(track),
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
            child: duration == null
                ? Row(
                    children: [
                      Text('Live', style: theme.textTheme.bodySmall),
                      const SizedBox(width: 8),
                      const Expanded(child: LinearProgressIndicator()),
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
                              .clamp(0, duration.inMilliseconds.toDouble()),
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
    );
  }

  Future<void> _addToPlaylist(BuildContext context, Track track) async {
    final message = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => _AddToPlaylistSheet(track: track),
    );
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

Widget _cover(Track track) {
  if (track.imageUrl != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(track.imageUrl!,
          width: 48, height: 48, fit: BoxFit.cover),
    );
  }
  return const Icon(Icons.music_note, size: 40);
}

String _formatDuration(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Picker for the mini-player's add-to-playlist: the user's saved
/// playlists, newest first. Tapping one appends the track (never
/// twice) and pops with the message the bar shows.
class _AddToPlaylistSheet extends ConsumerWidget {
  final Track track;

  const _AddToPlaylistSheet({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider).getAll();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Add to playlist',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  'No saved playlists yet — import one from Home first.'),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final playlist in playlists)
                    ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(playlist.info.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle:
                          Text('${playlist.tracks.length} tracks'),
                      onTap: () async {
                        final added = await ref
                            .read(playlistRepositoryProvider)
                            .addTrack(playlist.info.platformId,
                                playlist.info.id, track);
                        if (context.mounted) {
                          Navigator.of(context).pop(added
                              ? 'Added to ${playlist.info.name}'
                              : 'Already in ${playlist.info.name}');
                        }
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
