// Generating screen (S-04): determinate progress while the Last.fm fan-out
// runs, cancellable, with retryable error states (FR-10).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import 'results_screen.dart';

class GenerationArgs {
  final bool surprise;
  final String seedName;
  final String? seedPlaylistId;
  final String? seedPlatformId;
  final List<Track> tracks;
  final DiscoverySettings settings;

  const GenerationArgs({
    required this.surprise,
    required this.seedName,
    this.seedPlaylistId,
    this.seedPlatformId,
    required this.tracks,
    required this.settings,
  });
}

class GeneratingScreen extends ConsumerStatefulWidget {
  final GenerationArgs args;

  const GeneratingScreen({super.key, required this.args});

  @override
  ConsumerState<GeneratingScreen> createState() => _GeneratingScreenState();
}

class _GeneratingScreenState extends ConsumerState<GeneratingScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final notifier = ref.read(generationProvider.notifier);
      if (widget.args.surprise) {
        notifier.surprise(settings: widget.args.settings);
      } else {
        notifier.generateFromPlaylist(
          seedName: widget.args.seedName,
          tracks: widget.args.tracks,
          settings: widget.args.settings,
          seedPlaylistId: widget.args.seedPlaylistId,
          seedPlatformId: widget.args.seedPlatformId,
        );
      }
    });
  }

  void _run() {
    final notifier = ref.read(generationProvider.notifier);
    if (widget.args.surprise) {
      notifier.surprise(settings: widget.args.settings);
    } else {
      notifier.generateFromPlaylist(
        seedName: widget.args.seedName,
        tracks: widget.args.tracks,
        settings: widget.args.settings,
        seedPlaylistId: widget.args.seedPlaylistId,
        seedPlatformId: widget.args.seedPlatformId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<GenerationState>(generationProvider, (prev, next) {
      if (next.result != null && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ResultsScreen(result: next.result!),
          ),
        );
      }
    });

    final state = ref.watch(generationProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.args.surprise ? 'Surprise me' : 'Generating'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            ref.read(generationProvider.notifier).cancel();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _body(context, theme, state),
      ),
    );
  }

  Widget _body(BuildContext context, ThemeData theme, GenerationState state) {
    if (state.error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 56, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text('Could not generate recommendations',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(state.error!,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (state.canRetry)
                FilledButton(
                  onPressed: _run,
                  child: const Text('Retry'),
                ),
              if (state.canRetry) const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ],
      );
    }

    final progress = state.progress;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(strokeWidth: 5),
        ),
        const SizedBox(height: 24),
        Text(
          progress != null
              ? '${progress.phase} (${progress.done}/${progress.total})'
              : 'Warming up…',
          style: theme.textTheme.titleSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        if (progress != null && progress.total > 0)
          LinearProgressIndicator(value: progress.fraction),
        const SizedBox(height: 24),
        Text(
          'Scoring candidates against your seeds…',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () {
            ref.read(generationProvider.notifier).cancel();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
