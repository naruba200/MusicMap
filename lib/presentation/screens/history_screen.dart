// History (S-08, FR-13): a log of past runs, newest first. Each run
// shows its playlist name, date, and counts; tap reopens the cached
// result without re-fetching; swipe a run to delete it. Complex shows
// each run's detail inline instead of behind the tap.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/time_ago.dart';
import '../../data/repositories/history_repository.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/editorial_route.dart';
import '../widgets/editorial_widgets.dart';
import 'results_screen.dart';

bool _isComplex(BuildContext context) =>
    Theme.of(context).extension<MusicManDesignTokens>()?.design ==
    AppDesign.complex;

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(historyVersionProvider);
    final runs = ref.watch(historyRepositoryProvider).getAll();
    final isComplex = _isComplex(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (runs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: () => _confirmClear(context, ref),
            ),
        ],
      ),
      body: runs.isEmpty
          ? Center(
              child: EditorialEmptyState(
                message: 'No runs yet. Generate recommendations and '
                    'they will show up here.',
                actionLabel: 'Generate recommendations',
                onAction: () =>
                    ref.read(tabIndexProvider.notifier).state = 0,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: SectionHeader(
                    kanji: '記',
                    title: 'Past runs',
                    trailing: Text(
                      '${runs.length} run${runs.length == 1 ? '' : 's'}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: runs.length,
                    itemBuilder: (_, i) {
                      final run = runs[i];
                      final songCount =
                          (run.resultJson['songs'] as List?)?.length ?? 0;
                      final albumCount =
                          (run.resultJson['albums'] as List?)?.length ?? 0;
                      return Dismissible(
                        key: ValueKey('run-${run.id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: scheme.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete_outline),
                        ),
                        onDismissed: (_) {
                          ref
                              .read(historyRepositoryProvider)
                              .remove(run.id);
                          ref.read(historyVersionProvider.notifier).state++;
                        },
                        child: ListTile(
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: scheme.surface,
                              border:
                                  Border.all(color: scheme.outline),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Icon(
                              run.isSurprise
                                  ? Icons.shuffle
                                  : Icons.queue_music_outlined,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          title: Text(run.seedName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: isComplex
                              ? _complexSubtitle(run, songCount, albumCount)
                              : Text(
                                  '$songCount songs · '
                                  '$albumCount albums · '
                                  '${timeAgo(run.timestamp)}',
                                ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            try {
                              final result = GenerationResult.fromJson(
                                  run.resultJson);
                              Navigator.of(context).push(
                                editorialRoute(
                                  context,
                                  (_) =>
                                      ResultsScreen(result: result),
                                ),
                              );
                            } catch (_) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Couldn\'t open those cached results.')),
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  /// Complex shows the run detail inline: seed and skip counts (from
  /// the cached result) on the first line, the run kind and date on
  /// the second.
  Widget _complexSubtitle(
      HistoryRun run, int songCount, int albumCount) {
    final parts = <String>[
      '$songCount songs',
      '$albumCount albums',
    ];
    final seedCount = (run.resultJson['seedCount'] as num?)?.toInt() ?? 0;
    final skippedSeeds =
        (run.resultJson['skippedSeeds'] as num?)?.toInt() ?? 0;
    if (seedCount > 0) {
      parts.add('seeded from $seedCount tracks');
    }
    if (skippedSeeds > 0) {
      parts.add('$skippedSeeds skipped');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(parts.join(' · ')),
        Text(
          '${run.isSurprise ? 'Surprise run' : 'Playlist run'} · '
          '${timeAgo(run.timestamp)}',
        ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content:
            const Text('Remove all past recommendation runs from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyRepositoryProvider).clear();
      ref.read(historyVersionProvider.notifier).state++;
    }
  }
}
