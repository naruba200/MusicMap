// Playback log screen (full-song pivot, push 1): every full-song
// resolve attempt: track, time, and each source tried with its
// outcome and detail, newest first, expandable per-source detail.
// Reachable from Settings. The log is in-memory (last ~100 attempts)
// and clears when the app restarts.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/fullsong/resolution_log.dart';
import '../providers/providers.dart';
import '../widgets/editorial_widgets.dart';

class PlaybackLogScreen extends ConsumerWidget {
  const PlaybackLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(resolutionLogProvider);
    final ordered = entries.reversed.toList();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playback log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: entries.isEmpty
                ? null
                : () => ref.read(resolutionLogProvider.notifier).clear(),
          ),
        ],
      ),
      body: ordered.isEmpty
          ? const EditorialEmptyState(
              message: 'No playback attempts yet. Play a track and '
                  'the sources tried, and why each one matched or '
                  'failed, will show up here.',
            )
          : ListView.builder(
              itemCount: ordered.length,
              itemBuilder: (context, index) {
                final entry = ordered[index];
                return Container(
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: scheme.outline)),
                  ),
                  child: ExpansionTile(
                    title: Text('${entry.artist} - ${entry.title}'),
                    subtitle: Text(
                      '${entry.result} · ${_formatTime(entry.time)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant),
                    ),
                    children: [
                      for (final attempt in entry.attempts)
                        _AttemptRow(attempt: attempt),
                    ],
                  ),
                );
              },
            ),
    );
  }

  static String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// One source tried for one track. In Complex the reason shows
/// inline under the source and outcome; in Compact it sits behind
/// the row's expansion, so the log stays a short ruled list until
/// the reader opens the row that matters.
class _AttemptRow extends StatelessWidget {
  final SourceAttempt attempt;

  const _AttemptRow({required this.attempt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final complex = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.design ==
        AppDesign.complex;
    final failed = attempt.outcome == SourceOutcome.networkError ||
        attempt.outcome == SourceOutcome.sessionRejected;
    final icon = attempt.outcome == SourceOutcome.matched
        ? Icons.check_circle_outline
        : failed
            ? Icons.error_outline
            : Icons.remove_circle_outline;
    final iconColor = attempt.outcome == SourceOutcome.matched
        ? scheme.primary
        : failed
            ? scheme.error
            : scheme.onSurfaceVariant;
    final detail = attempt.detail.isEmpty
        ? attempt.outcome.label
        : '${attempt.outcome.label}: ${attempt.detail}';
    final tile = ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(attempt.source),
      subtitle: Text(
        complex ? detail : attempt.outcome.label,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
    if (complex || attempt.detail.isEmpty) return tile;
    return ExpansionTile(
      leading: Icon(icon, color: iconColor),
      title: Text(attempt.source),
      subtitle: Text(
        attempt.outcome.label,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      children: [
        Padding(
          padding:
              const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Text(
            attempt.detail,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
