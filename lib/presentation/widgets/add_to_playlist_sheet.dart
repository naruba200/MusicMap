// Shared add-to-playlist sheet (mini-player and full player): the
// user's saved playlists, newest first. Tapping one appends the track
// (never twice) and pops with the message the caller shows.
//
// The sheet is opened from the mini-player, which lives above the
// Navigator in the app shell, so its own context cannot reach a
// Navigator: [showAddToPlaylistSheet] resolves a context that can
// (the local one when inside the Navigator, else the root navigator
// key's own context, which Navigator.of accepts).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/music_models.dart';
import '../providers/providers.dart';

/// Opens the sheet for [track] and returns the result message, or null
/// when the sheet was dismissed without picking a playlist.
Future<String?> showAddToPlaylistSheet(
  BuildContext context,
  Track track,
) async {
  final navContext = Navigator.maybeOf(context) != null
      ? context
      : navigatorKey.currentContext ?? context;
  return showModalBottomSheet<String>(
    context: navContext,
    builder: (context) => AddToPlaylistSheet(track: track),
  );
}

/// Picker for the add-to-playlist action: the user's saved playlists,
/// newest first. Tapping one appends the track (never twice) and pops
/// with the message the caller shows.
class AddToPlaylistSheet extends ConsumerWidget {
  final Track track;

  const AddToPlaylistSheet({super.key, required this.track});

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
                  'No saved playlists yet. Import one from Home first.'),
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
