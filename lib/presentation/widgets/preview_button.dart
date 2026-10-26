// Play/pause button for a track preview, shared by the Results,
// Album Detail, and Playlist Detail screens (it was previously a
// private widget duplicated in Results and Album Detail).
//
// The button is always tappable: a tap on a preview-less track runs
// the on-demand lookup in AudioPlayerNotifier instead of doing
// nothing. A resolved Audius full track is labelled honestly as a
// full track, never as a preview (see AudioPlayerNotifier
// .previewSourceFor); every other resolution is a 30-second preview.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';

class PreviewButton extends ConsumerWidget {
  final Track track;

  const PreviewButton({super.key, required this.track});

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
    final isPlaying = playerState.valueOrNull == key;
    final isResolving =
        playerState is AsyncLoading && player.resolvingKey == key;
    final isFullTrack = player.previewSourceFor(track) == 'audius';

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
      tooltip: isFullTrack
          ? (isPlaying ? 'Pause full track (Audius)' : 'Play full track (Audius)')
          : (isPlaying ? 'Pause preview' : 'Play preview'),
      onPressed: () => player.play(track),
    );
  }
}
