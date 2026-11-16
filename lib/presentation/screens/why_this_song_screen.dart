// Why this song (DESIGN.md): a pushed view. The picked song at
// the top, then the liked songs and artists that drove the pick,
// named plainly. Back returns to Results.
//
// Data honesty: the engine records only reason strings on a pick
// (seed track titles, tag labels, "Trending now", fallback labels
// such as "More from X"). This screen shows those strings as they
// are, labelled by what kind of driver each one is, plus the liked
// artists from likedArtistsProvider. It never invents a driver
// song or an artist for a bare seed title.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/engine/recommendation_engine.dart';
import '../providers/news_provider.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/song_row.dart';
import 'results_screen.dart';

/// What kind of driver a reason string is, so the pick is named
/// plainly instead of guessing an artist for a bare seed title.
String driverLabelFor(String reason) {
  if (reason == 'Trending now') return 'Trending now';
  if (reason.startsWith('Popular in ')) return reason;
  if (reason.startsWith('More from ')) return reason;
  if (reason.startsWith('Similar artists to ')) return reason;
  if (reason == 'Based on your favorites') return reason;
  if (reason == 'From ListenBrainz') return reason;
  return 'Seed song from your playlist: $reason';
}

class WhyThisSongScreen extends ConsumerWidget {
  final ScoredTrack scored;

  const WhyThisSongScreen({super.key, required this.scored});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = theme.extension<MusicManDesignTokens>();
    final isComplex = tokens?.design == AppDesign.complex;
    final likedArtists = ref.watch(likedArtistsProvider).toList()..sort();
    final reason = reasonLineFor(scored);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Why this song'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          EditorialSongRow(
            track: scored.track,
            queue: [scored.track],
            doubleTapToLike: true,
            coverSize: isComplex ? 56 : 48,
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 16),
          const SectionHeader(
            kanji: '理',
            title: 'What drove this pick',
          ),
          const SizedBox(height: 12),
          if (reason.isNotEmpty)
            Text(
              reason,
              style: theme.textTheme.bodyMedium,
            ),
          if (scored.reasons.isEmpty) ...[
            const Text(
              'No reason was recorded for this pick.',
            ),
          ] else ...[
            const SizedBox(height: 12),
            for (final driver in scored.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 6),
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        driverLabelFor(driver),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 24),
          const SectionHeader(
            kanji: '好',
            title: 'Liked artists',
          ),
          const SizedBox(height: 12),
          if (likedArtists.isEmpty)
            Text(
              'No liked artists yet. Tap the heart on songs you like '
              'to teach the picker.',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant),
            )
          else
            for (final artist in likedArtists)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  artist,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
        ],
      ),
    );
  }
}
