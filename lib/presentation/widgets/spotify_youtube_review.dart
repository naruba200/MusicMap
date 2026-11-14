// Spotify YouTube-match review (push 3): after importing a Spotify
// playlist, resolve each track to YouTube — same resolver + Hive cache
// as the export sheet — and show matched/unmatched per track. This
// widget owns the button, progress, Cancel, summary, and error/Retry,
// and reports the finished resolution up via [onResolved] so the
// detail screen can mark each track row (and push 4's Save to YouTube
// can reuse the same ExportResolution instead of resolving twice).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/export/youtube_export.dart';
import '../../data/export/youtube_video_cache.dart';
import '../../data/models/music_models.dart';
import '../providers/providers.dart';

/// "311 of 320 tracks readable — 9 restricted by Spotify", or null
/// when the readable list covers the whole playlist (or the total is
/// unknown). The review UI never presents a partial list as complete.
String? readableCountLabel({
  required int total,
  required int readable,
  required String platformName,
}) {
  if (total <= readable) return null;
  final missing = total - readable;
  return '$readable of $total tracks readable — '
      '$missing restricted by $platformName';
}

/// "287 of 311 found on YouTube — 24 unmatched".
String youTubeMatchSummary({required int matched, required int total}) {
  final unmatched = total - matched;
  return '$matched of $total found on YouTube — $unmatched unmatched';
}

/// True when a finished review has at least one YouTube-matched song
/// to save (a resolution with no chunks saves nothing).
bool canSaveToYouTube(ExportResolution? resolution) =>
    resolution != null && resolution.chunks.isNotEmpty;

class SpotifyYouTubeReview extends ConsumerStatefulWidget {
  final List<Track> tracks;
  final void Function(ExportResolution resolution) onResolved;

  /// Video-id cache. When null (production), the Hive cache is opened
  /// like the export sheet does; tests inject [InMemoryVideoIdCache]
  /// so no real Hive box is opened under the widget-test binding,
  /// whose fake async never completes real file I/O.
  final VideoIdCache? cache;

  const SpotifyYouTubeReview({
    super.key,
    required this.tracks,
    required this.onResolved,
    this.cache,
  });

  @override
  ConsumerState<SpotifyYouTubeReview> createState() =>
      _SpotifyYouTubeReviewState();
}

class _SpotifyYouTubeReviewState
    extends ConsumerState<SpotifyYouTubeReview> {
  bool _resolving = false;
  bool _cancelled = false;
  int _done = 0;
  String? _error;
  ExportResolution? _resolution;

  Future<void> _run() async {
    setState(() {
      _resolving = true;
      _cancelled = false;
      _done = 0;
      _error = null;
    });
    VideoIdCache? effectiveCache = widget.cache;
    if (effectiveCache == null) {
      try {
        effectiveCache = await HiveVideoIdCache.open();
      } catch (_) {
        effectiveCache = null; // review still works, just without persistence
      }
    }
    if (!mounted) return;
    final resolver =
        YouTubeVideoResolver(ref.read(dioProvider), cache: effectiveCache);
    try {
      final resolution = await resolver.resolveAll(
        widget.tracks,
        onProgress: (done, _) {
          if (mounted) setState(() => _done = done);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      if (resolution.cancelled) {
        setState(() => _resolving = false);
        return;
      }
      setState(() {
        _resolving = false;
        _resolution = resolution;
      });
      widget.onResolved(resolution);
    } catch (e) {
      if (mounted) {
        setState(() {
          _resolving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.tracks.length;
    final theme = Theme.of(context);
    if (_resolving) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: total == 0 ? null : _done / total,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('Finding matches on YouTube… $_done/$total'),
              ),
              TextButton(
                onPressed: () => setState(() => _cancelled = true),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      );
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not check YouTube matches: $_error',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _run,
            child: const Text('Retry'),
          ),
        ],
      );
    }
    if (_resolution != null) {
      final matched = _resolution!.resolved.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            youTubeMatchSummary(matched: matched, total: total),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Best-effort matching: YouTube may pick a cover or live '
            'version instead of the official audio. '
            '✓ found on YouTube · ✕ not found.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _run,
            child: const Text('Check again'),
          ),
        ],
      );
    }
    return OutlinedButton.icon(
      onPressed: total == 0 ? null : _run,
      icon: const Icon(Icons.youtube_searched_for),
      label: const Text('Check YouTube matches'),
    );
  }
}
