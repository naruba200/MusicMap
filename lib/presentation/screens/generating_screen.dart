// Generating screen (S-04): determinate progress while the Last.fm
// fan-out runs, cancellable, with retryable error states (FR-10).
//
// DESIGN.md: determinate progress ("Analyzing track N of 20"), a thin
// vermillion progress rule, Cancel. Error state with Retry, never a
// blank screen. Unchanged between designs except the editorial voice,
// so the behavior here is identical to before.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/models/music_models.dart';
import '../providers/generation_provider.dart';
import '../widgets/editorial_route.dart';
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

  void _cancelAndClose() {
    ref.read(generationProvider.notifier).cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<GenerationState>(generationProvider, (prev, next) {
      if (next.result != null && mounted) {
        Navigator.of(context).pushReplacement(
          editorialRoute(
            context,
            (_) => ResultsScreen(
              result: next.result!,
              liveEnrichment: true,
            ),
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
          tooltip: 'Cancel',
          onPressed: _cancelAndClose,
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Could not generate recommendations',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            state.error!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
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
    final tokens = theme.extension<MusicManDesignTokens>();
    final isComplex = tokens?.design == AppDesign.complex;
    final fraction = progress != null && progress.total > 0
        ? progress.fraction
        : null;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.args.surprise ? 'Surprise picks' : widget.args.seedName,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          progress != null ? progress.phase : 'Warming up',
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        if (progress != null && progress.total > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${progress.done} of ${progress.total}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        // The thin vermillion progress rule. In Complex it eases to
        // each new value; in Compact it jumps instantly (MOTION 0).
        if (isComplex && fraction != null)
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: fraction),
            duration: tokens?.progressTick ?? Duration.zero,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              minHeight: 2,
            ),
          )
        else
          LinearProgressIndicator(
            value: fraction,
            minHeight: 2,
          ),
        const SizedBox(height: 24),
        Text(
          'Scoring candidates against your seeds.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton(
            onPressed: _cancelAndClose,
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}
