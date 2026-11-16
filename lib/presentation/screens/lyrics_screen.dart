// Lyrics view for one track (Phase 5, push 1). Reached from the
// lyrics button on a results song row. Plain lyrics first; a
// synced-only match shows its lines without timestamps (this view
// does not scroll along with playback; the app plays full tracks,
// not previews). Instrumental tracks and tracks LRCLIB does not
// know get honest empty states, never an error: any failure
// anywhere in the load lands on the empty state, so the lyrics view
// can never break the track view that opened it.
//
// Lookup is cached in Hive for 30 days (hits and misses alike), and
// uses a plain Dio with short timeouts and no retry interceptor.
// [client] and [cache] are overridable for tests.

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/lyrics/lrclib_client.dart';
import '../../data/lyrics/lyrics_cache.dart';
import '../../data/models/music_models.dart';
import '../widgets/editorial_widgets.dart';

class LyricsScreen extends StatelessWidget {
  final Track track;
  final LrclibClient? client;
  final LyricsCache? cache;

  const LyricsScreen({super.key, required this.track, this.client, this.cache});

  Future<LrclibLyrics?> _load() async {
    try {
      final lyricsCache = cache ?? await LyricsCache.open();
      final cached = lyricsCache.lookup(track.artist, track.title);
      if (cached != null) return cached;
      if (!lyricsCache.shouldRetry(
          track.artist, track.title, DateTime.now())) {
        return null; // fresh cached miss: don't re-hit the network
      }
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ));
      final lyrics = await (client ?? LrclibClient(dio)).fetchLyrics(
        artist: track.artist,
        title: track.title,
        album: track.album,
        durationSec: track.durationMs == null
            ? null
            : (track.durationMs! / 1000).round(),
      );
      if (lyrics != null) {
        lyricsCache.store(track.artist, track.title, lyrics);
      } else {
        lyricsCache.storeMiss(track.artist, track.title);
      }
      return lyrics;
    } catch (_) {
      return null; // any failure is an honest empty state, not a crash
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final complex = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.design ==
        AppDesign.complex;
    return Scaffold(
      appBar: AppBar(
        title: Text(track.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<LrclibLyrics?>(
        future: _load(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const EditorialLoadingState(
                message: 'Loading lyrics');
          }
          final lyrics = snapshot.data;
          if (lyrics == null) {
            return EditorialEmptyState(
              message: 'LRCLIB has no lyrics for "${track.title}" by '
                  '${track.artist} yet. Try again later, new lyrics '
                  'are added by the community all the time.',
            );
          }
          if (lyrics.instrumental) {
            return EditorialEmptyState(
              message: 'LRCLIB lists "${track.title}" as an '
                  'instrumental track, so there are no lyrics to show.',
            );
          }
          final text = lyrics.displayText;
          if (text == null || text.isEmpty) {
            return EditorialEmptyState(
              message: 'LRCLIB returned a match for "${track.title}" '
                  'but it carries no lyric text.',
            );
          }
          // Lyrics set like printed lyrics in a booklet: the song
          // and artist as the heading, the album line in Complex,
          // a hairline rule, then the lines in a reading measure
          // that widens in Complex.
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: complex ? 560 : 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(track.title,
                        style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(track.artist,
                        style: theme.textTheme.titleMedium?.copyWith(
                            color: scheme.onSurfaceVariant)),
                    if (complex && lyrics.albumName != null &&
                        lyrics.albumName!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('From the album ${lyrics.albumName}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 16),
                    Divider(height: 1, color: scheme.outline),
                    const SizedBox(height: 20),
                    SelectableText(text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                            height: complex ? 1.8 : 1.6)),
                    const SizedBox(height: 24),
                    Text('Lyrics: LRCLIB',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
