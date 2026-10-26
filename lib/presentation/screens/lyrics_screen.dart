// Lyrics view for one track (Phase 5, push 1). Reached from the
// lyrics button on a results song row. Plain lyrics first; a
// synced-only match shows its lines without timestamps (this view
// does not scroll along with playback — the app plays 30-second
// previews, not the full track). Instrumental tracks and tracks
// LRCLIB does not know get honest empty states, never an error:
// any failure anywhere in the load lands on the empty state, so the
// lyrics view can never break the track view that opened it.
//
// Lookup is cached in Hive for 30 days (hits and misses alike), and
// uses a plain Dio with short timeouts and no retry interceptor
// (plan §0). [client] and [cache] are overridable for tests.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../data/lyrics/lrclib_client.dart';
import '../../data/lyrics/lyrics_cache.dart';
import '../../data/models/music_models.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Text(track.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<LrclibLyrics?>(
        future: _load(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final lyrics = snapshot.data;
          if (lyrics == null) {
            return _EmptyState(
              icon: Icons.lyrics_outlined,
              title: 'No lyrics found',
              message: 'LRCLIB has no lyrics for '
                  '"${track.title}" by ${track.artist} yet. '
                  'Try again later — new lyrics are added by the '
                  'community all the time.',
            );
          }
          if (lyrics.instrumental) {
            return _EmptyState(
              icon: Icons.music_note_outlined,
              title: 'Instrumental',
              message: 'LRCLIB lists "${track.title}" as an '
                  'instrumental track, so there are no lyrics to show.',
            );
          }
          final text = lyrics.displayText;
          if (text == null || text.isEmpty) {
            return _EmptyState(
              icon: Icons.lyrics_outlined,
              title: 'No lyrics found',
              message: 'LRCLIB returned a match for '
                  '"${track.title}" but it carries no lyric text.',
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.artist,
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text('Lyrics: LRCLIB',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                SelectableText(text,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(height: 1.6)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyState(
      {required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56),
              const SizedBox(height: 12),
              Text(title,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
