// Song context sheet (DESIGN.md: "Long-press context sheet").
// The full set of song actions in one modal bottom sheet, opened
// from a row's overflow button or from a long-press hold on the
// row. The entries are: Play next, Add to queue, Add to playlist,
// Lyrics, Why this song, Share.
//
// Lyrics is the only entry point to the lyrics view, so the sheet
// must carry it: no other screen links to Lyrics.
//
// Why this song is shown only when [onShowWhy] is given (the row
// has a reason view); otherwise the entry is hidden, never shown
// as a dead entry.
//
// Share uses share_plus, which is already a dependency (used by
// the Settings export). If the share call fails on the device, the
// text is copied to the clipboard instead and the toast says so,
// so the action never fails silently.
//
// Undo toasts: the sheet is popped before the action lands, so the
// Undo callbacks use the notifier and repo captured at build time,
// never ref after the pop (the sheet's ref is dead by then).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../screens/lyrics_screen.dart';
import 'add_to_playlist_sheet.dart';
import 'editorial_route.dart';
import 'undo_snackbar.dart';

/// Opens the context sheet for [track]. [reason] is the reason line
/// shown on the row; [onShowWhy] opens the Why this song view and
/// also gates the Why entry (null hides it).
Future<void> showSongActionsSheet(
  BuildContext context,
  Track track, {
  String? reason,
  VoidCallback? onShowWhy,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SongActionsSheet(
      track: track,
      reason: reason,
      onShowWhy: onShowWhy,
    ),
  );
}

class SongActionsSheet extends ConsumerWidget {
  final Track track;

  /// The reason line for this track, shown under the title. Null
  /// hides the line.
  final String? reason;

  /// Opens the Why this song view. Null hides the Why entry.
  final VoidCallback? onShowWhy;

  const SongActionsSheet({
    super.key,
    required this.track,
    this.reason,
    this.onShowWhy,
  });

  /// The text the Share action sends: "artist - title".
  String get _shareText => '${track.artist} - ${track.title}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(audioPlayerProvider.notifier);
    final playlistRepo = ref.read(playlistRepositoryProvider);
    final onShowWhy = this.onShowWhy;
    // The queue key of this track, for the Play next / Add to queue
    // Undo toasts.
    String queueKey(Track t) =>
        RecommendationEngine.normalizeKey(t.artist, t.title);
    return SafeArea(
      // The sheet scrolls instead of overflowing when the entries
      // are taller than the modal's height (short screens).
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(track.artist,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (reason != null) ...[
                  const SizedBox(height: 2),
                  Text(reason!,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.skip_next),
            title: const Text('Play next'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              // Capture the queue shape before the sheet pops: the
              // sheet's ref is dead after the pop, so the Undo math
              // runs on these values, not on a fresh read.
              final playback = ref.read(audioPlayerProvider);
              final oldIndex = playback.queue.indexWhere(
                  (t) => queueKey(t) == queueKey(track));
              final currentIndex = playback.queueIndex;
              final hasCurrent = playback.hasCurrentTrack;
              Navigator.pop(context);
              await player.playNext(track);
              if (!hasCurrent) {
                // Nothing was loaded, so Play next played the track
                // instead (it lands at the front of a fresh queue).
                // Undo takes it back out; a no-op when the resolve
                // failed and the queue stayed empty.
                showUndoSnackBarForMessenger(
                  messenger,
                  message: 'Will play next',
                  onUndo: () =>
                      unawaited(player.removeFromQueue(0)),
                );
                return;
              }
              if (oldIndex == currentIndex) {
                // Already playing: Play next changed nothing, so
                // there is nothing to undo.
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Will play next'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }
              // Where Play next put the track: right after the
              // current one. A track that was already queued moves
              // there from its old slot, which shifts the current
              // index down by one when it sat before it.
              final adjustedCurrent =
                  oldIndex >= 0 && oldIndex < currentIndex
                      ? currentIndex - 1
                      : currentIndex;
              final newIndex = adjustedCurrent + 1;
              showUndoSnackBarForMessenger(
                messenger,
                message: 'Will play next',
                onUndo: () {
                  if (oldIndex >= 0) {
                    player.moveInQueue(newIndex, oldIndex);
                  } else {
                    unawaited(player.removeFromQueue(newIndex));
                  }
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('Add to queue'),
            onTap: () {
              final messenger = ScaffoldMessenger.of(context);
              final queue = ref.read(audioPlayerProvider).queue;
              final wasThere = queue.indexWhere(
                      (t) => queueKey(t) == queueKey(track)) >=
                  0;
              // Add to queue appends, so the new slot is the old
              // length, captured before the sheet pops.
              final newIndex = queue.length;
              Navigator.pop(context);
              player.addToQueue(track);
              if (wasThere) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Already in queue'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }
              showUndoSnackBarForMessenger(
                messenger,
                message: 'Added to queue',
                onUndo: () =>
                    unawaited(player.removeFromQueue(newIndex)),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add to playlist'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final result =
                  await showAddToPlaylistSheet(context, track);
              if (!context.mounted) return;
              Navigator.pop(context);
              if (result == null) return;
              if (!result.added) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(result.message),
                    duration: const Duration(seconds: 2),
                  ),
                );
                return;
              }
              showUndoSnackBarForMessenger(
                messenger,
                message: result.message,
                onUndo: () {
                  unawaited(playlistRepo.removeTrack(
                    result.platformId!,
                    result.playlistId!,
                    track,
                  ));
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.lyrics_outlined),
            title: const Text('Lyrics'),
            onTap: () {
              // Capture the navigator and build the route before
              // popping: the sheet's context is dead after the pop.
              final navigator = Navigator.of(context);
              final route = editorialRoute(
                context,
                (_) => LyricsScreen(track: track),
              );
              Navigator.pop(context);
              navigator.push(route);
            },
          ),
          if (onShowWhy != null)
            ListTile(
              leading: const Icon(Icons.info_outlined),
              title: const Text('Why this song'),
              onTap: () {
                Navigator.pop(context);
                onShowWhy();
              },
            ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('Share'),
            onTap: () async {
              try {
                await Share.share(_shareText);
              } catch (_) {
                // Share is unavailable on this device: copy the
                // text instead so the action still does something.
                await Clipboard.setData(
                    ClipboardData(text: _shareText));
                if (context.mounted) {
                  showToast(context, 'Could not share. Copied to clipboard.');
                }
                return;
              }
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
        ),
      ),
    );
  }
}
