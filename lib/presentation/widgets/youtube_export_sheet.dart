// YouTube export sheet (M6, FR-28..FR-31): resolves songs to video IDs
// with progress + Cancel, then shows chunk buttons, the unmatched list,
// and the "Tap Save" hint. Cancelling, or an export failure, leaves the
// underlying results screen untouched; a failure offers Retry.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/export/youtube_export.dart';
import '../../data/export/youtube_video_cache.dart';
import '../../data/models/music_models.dart';
import '../../data/platforms/open_in_app.dart';
import '../providers/providers.dart';

/// Resolves [tracks] and opens the export sheet. Songs only (FR-31).
Future<void> showYouTubeExportSheet(
    BuildContext context, WidgetRef ref, List<Track> tracks) async {
  if (tracks.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No songs to export.')),
    );
    return;
  }
  final outcome = await showDialog<_ExportOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExportProgressDialog(
      dio: ref.read(dioProvider),
      tracks: tracks,
    ),
  );
  if (!context.mounted) return;
  if (outcome == null) return; // cancelled via the Cancel button
  if (outcome.error != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not resolve YouTube videos: ${outcome.error}'),
        action: SnackBarAction(
          label: 'Retry',
          onPressed: () => showYouTubeExportSheet(context, ref, tracks),
        ),
      ),
    );
    return;
  }
  final resolution = outcome.resolution;
  if (resolution == null || resolution.cancelled) return;
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ExportResultSheet(resolution: resolution),
  );
}

class _ExportOutcome {
  final ExportResolution? resolution;
  final String? error;

  const _ExportOutcome({this.resolution, this.error});
}

class _ExportProgressDialog extends StatefulWidget {
  final Dio dio;
  final List<Track> tracks;

  const _ExportProgressDialog({required this.dio, required this.tracks});

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  int _done = 0;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_run);
  }

  Future<void> _run() async {
    HiveVideoIdCache? cache;
    try {
      cache = await HiveVideoIdCache.open();
    } catch (_) {
      cache = null; // export still works, just without persistence
    }
    if (!mounted) return;
    final resolver = YouTubeVideoResolver(widget.dio, cache: cache);
    try {
      final resolution = await resolver.resolveAll(
        widget.tracks,
        onProgress: (done, _) {
          if (mounted) setState(() => _done = done);
        },
        isCancelled: () => _cancelled,
      );
      if (mounted) {
        Navigator.of(context).pop(_ExportOutcome(resolution: resolution));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(_ExportOutcome(error: e.toString()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.tracks.length;
    return AlertDialog(
      title: const Text('Export to YouTube'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: total == 0 ? null : _done / total,
          ),
          const SizedBox(height: 12),
          Text('Resolving $_done/$total…'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ExportResultSheet extends StatelessWidget {
  final ExportResolution resolution;

  const _ExportResultSheet({required this.resolution});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (!await openLinkInAppFirst(uri)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chunks = resolution.chunks;
    final unmatched = resolution.unmatched;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Export to YouTube', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Best-effort matching: YouTube may pick a cover or live '
                'version instead of the official audio.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              if (chunks.isEmpty)
                const Text('No songs could be matched to YouTube videos.'),
              if (chunks.length == 1)
                FilledButton.icon(
                  onPressed: () => _open(context, chunks.single.url),
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Open playlist (${chunks.single.songCount} songs)'),
                ),
              if (chunks.length > 1)
                for (final chunk in chunks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FilledButton.tonalIcon(
                      onPressed: () => _open(context, chunk.url),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(
                          '${chunk.label} (${chunk.songCount} songs)'),
                    ),
                  ),
              const SizedBox(height: 16),
              const Text(
                  'Tap Save in YouTube / YouTube Music to keep this playlist.'),
              if (unmatched.isNotEmpty) ...[
                const Divider(height: 32),
                Text(
                  "${unmatched.length} songs couldn't be matched:",
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                for (final track in unmatched)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(track.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(track.artist,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
