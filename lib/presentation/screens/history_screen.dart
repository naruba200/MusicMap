// History (S-08, FR-13): past runs newest-first; tapping re-opens the
// cached results without re-fetching.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time_ago.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import 'results_screen.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(historyVersionProvider);
    final runs = ref.watch(historyRepositoryProvider).getAll();
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
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_outlined, size: 56),
                    SizedBox(height: 12),
                    Text(
                      'No runs yet.\nGenerate recommendations and they\'ll show up here.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
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
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete_outline),
                  ),
                  onDismissed: (_) {
                    ref.read(historyRepositoryProvider).remove(run.id);
                    ref.read(historyVersionProvider.notifier).state++;
                  },
                  child: ListTile(
                    leading: Icon(
                      run.isSurprise
                          ? Icons.shuffle
                          : Icons.queue_music_outlined,
                      size: 40,
                    ),
                    title: Text(run.seedName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '$songCount songs · '
                      '$albumCount albums · '
                      '${timeAgo(run.timestamp)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      try {
                        final result =
                            GenerationResult.fromJson(run.resultJson);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  ResultsScreen(result: result)),
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
