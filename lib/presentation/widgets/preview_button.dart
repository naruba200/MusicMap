// Play/pause button for a full track, shared by the Results,
// Album Detail, and Playlist Detail screens (it was previously a
// private widget duplicated in Results and Album Detail).
//
// The button is always tappable: a tap on a track with no full song
// runs the full-song lookup in AudioPlayerNotifier instead of doing
// nothing. Every resolution is a full track (see AudioPlayerNotifier
// .streamSourceFor) — there are no previews anymore.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';

class PreviewButton extends ConsumerWidget {
  final Track track;

  /// The list the track was played from (results, playlist, album,
  /// Discover tab) — it becomes the shared player's next/previous
  /// queue. Without one the track plays on its own.
  final List<Track>? queue;

  const PreviewButton({super.key, required this.track, this.queue});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the player state (not just read the notifier) so the icon
    // rebuilds on play / pause / resolve transitions.
    final playerState = ref.watch(audioPlayerProvider);
    final player = ref.read(audioPlayerProvider.notifier);
    // Same normalization as the player and the fallback layer, so the
    // playing key matches even for remaster-suffixed titles.
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    final isPlaying =
        playerState.isPlaying && playerState.currentKey == key;
    final isResolving =
        playerState.isResolving && playerState.resolvingKey == key;
    if (isResolving) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return IconButton(
      icon: Icon(isPlaying ? Icons.pause : Icons.play_circle_outline,
          color: isPlaying ? Theme.of(context).colorScheme.primary : null),
      tooltip: isPlaying ? 'Pause full track' : 'Play full track',
      onPressed: () => player.play(track, queue: queue),
    );
  }
}
